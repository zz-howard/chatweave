use chatweave_server::checkpoint::{CheckpointStore, MemoryCheckpointStore};
use chatweave_server::event_log::{BroadcastHub, EventLog, EventSink, MemoryEventLog};
use chatweave_server::protocol::{DocumentKind, Validator, fold};
use chatweave_server::stream::RecordedAnswer;
use chatweave_server::{MessageStream, StreamConfig};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

async fn setup(
    id: &str,
) -> (
    MessageStream,
    Arc<MemoryEventLog>,
    Arc<BroadcastHub>,
    Arc<MemoryCheckpointStore>,
) {
    let log = Arc::new(MemoryEventLog::default());
    let hub = Arc::new(BroadcastHub::default());
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let stream = MessageStream::start(
        StreamConfig::new(id),
        Arc::new(Validator::default()),
        log.clone(),
        hub.clone(),
        checkpoints.clone(),
    )
    .await
    .unwrap();
    (stream, log, hub, checkpoints)
}

fn choice_data() -> Value {
    json!({
        "prompt":"Which city?",
        "options":[{"id":"beijing","label":"Beijing"},{"id":"shanghai","label":"Shanghai"}],
        "selection":"single",
        "action":{"type":"choice.select","target":"weather.choose"},
        "state":{"status":"open"}
    })
}

fn answer(interrupt_id: &str) -> RecordedAnswer {
    RecordedAnswer {
        interrupt_id: interrupt_id.into(),
        payload: json!({"selected":["beijing"]}),
        resolved_at: "2026-10-27T00:00:00Z".into(),
        resolved_by: None,
    }
}

#[tokio::test]
async fn mixed_output_is_valid_and_folds_to_the_saved_message() {
    let (stream, log, _, checkpoints) = setup("msg_mixed").await;
    let step = stream.start_step("Check weather").await.unwrap();
    let first = stream.start_block("markdown", 1, "").await.unwrap();
    first.append_text("Today is **sunny**.").await.unwrap();
    first.finish().await.unwrap();
    let metric = stream
        .start_block("metric", 1, "High: 18 degrees")
        .await
        .unwrap();
    let last = stream.start_block("markdown", 1, "").await.unwrap();
    last.append_text("Take a walk.").await.unwrap();
    last.finish().await.unwrap();
    metric
        .data(
            json!({"label":"High","value":18,"unit":"°C"}),
            "High: 18 degrees",
            Some(json!({"provenance":"tool"})),
        )
        .await
        .unwrap();
    metric.finish().await.unwrap();
    step.finish("succeeded", Some("Forecast ready".into()))
        .await
        .unwrap();
    let message = stream.finish().await.unwrap();
    let events = log.read_after("msg_mixed", 0).await.unwrap();
    assert!(events.covered);
    let validator = Validator::default();
    for (index, event) in events.events.iter().enumerate() {
        assert_eq!(event.seq(), Some(index as u64 + 1));
        validator.validate(DocumentKind::Event, &event.0).unwrap();
    }
    validator
        .validate(DocumentKind::Message, &message.0)
        .unwrap();
    assert_eq!(fold(events.events).unwrap(), message);
    assert_eq!(
        checkpoints
            .load("msg_mixed")
            .await
            .unwrap()
            .unwrap()
            .message,
        message
    );
    assert_eq!(message.0["blocks"][1]["type"], "metric");
    assert_eq!(message.0["blocks"][2]["type"], "markdown");
    assert!(
        !message.0["fallbackText"]
            .as_str()
            .unwrap()
            .contains("Check weather")
    );
}

#[tokio::test]
async fn failed_step_and_component_do_not_fail_the_answer() {
    let (stream, _, _, _) = setup("msg_partial").await;
    let failed = stream.start_step("Read forecast").await.unwrap();
    let successful = stream.start_step("Read tasks").await.unwrap();
    failed
        .finish("failed", Some("Forecast unavailable".into()))
        .await
        .unwrap();
    successful
        .finish("succeeded", Some("Found three tasks".into()))
        .await
        .unwrap();
    let card = stream
        .start_block("metric", 1, "Forecast unavailable")
        .await
        .unwrap();
    card.fail("Forecast unavailable", "Weather service unavailable")
        .await
        .unwrap();
    let text = stream.start_block("markdown", 1, "").await.unwrap();
    text.append_text("Your tasks are still available.")
        .await
        .unwrap();
    text.finish().await.unwrap();
    let message = stream.finish().await.unwrap();
    assert_eq!(message.0["status"], "complete");
    assert_eq!(message.0["steps"][0]["state"], "failed");
    assert_eq!(message.0["steps"][1]["state"], "succeeded");
    assert_eq!(message.0["blocks"][0]["type"], "metric");
    assert_eq!(message.0["blocks"][0]["status"], "error");
    assert!(message.0["blocks"][0].get("data").is_none());
    Validator::default()
        .validate(DocumentKind::Message, &message.0)
        .unwrap();
}

#[tokio::test]
async fn stopping_closes_children_before_delegates_and_keeps_buffered_text() {
    let (stream, log, _, _) = setup("msg_stop").await;
    let outer = stream.start_delegate("Compare cities").await.unwrap();
    let inner = outer.start_delegate("Read forecasts").await.unwrap();
    let child = inner.start_step("Read Beijing forecast").await.unwrap();
    let text = stream.start_block("markdown", 1, "").await.unwrap();
    text.append_text("Sunny").await.unwrap();
    let pending = stream
        .start_block("metric", 1, "Forecast pending")
        .await
        .unwrap();
    stream.stop().await.unwrap();
    let head = stream.last_seq().await;
    stream.stop().await.unwrap();
    assert_eq!(stream.last_seq().await, head);
    let message = stream.message().await.unwrap();
    assert_eq!(message.0["status"], "interrupted");
    assert_eq!(message.0["blocks"][0]["data"]["text"], "Sunny");
    assert_eq!(message.0["blocks"][1]["id"], pending.id);
    assert_eq!(message.0["blocks"][1]["status"], "error");
    let events = log.read_after("msg_stop", 0).await.unwrap().events;
    let finished: Vec<_> = events
        .iter()
        .filter(|event| event.event_type() == "step.finished")
        .map(|event| {
            (
                event.0["stepId"].as_str().unwrap().to_owned(),
                event.0["state"].clone(),
            )
        })
        .collect();
    assert_eq!(
        finished,
        vec![
            (child.id, json!("cancelled")),
            (inner.as_step().id.clone(), json!("cancelled")),
            (outer.as_step().id.clone(), json!("cancelled")),
        ]
    );
    assert_eq!(events.last().unwrap().event_type(), "message.end");
    assert_eq!(events.last().unwrap().0["error"]["code"], "cancelled");
}

#[tokio::test]
async fn stopping_flushes_text_that_has_not_reached_the_batch_threshold() {
    let (stream, log, _, _) = setup("msg_stop_buffer").await;
    let text = stream.start_block("markdown", 1, "").await.unwrap();
    text.append_text("Sunny").await.unwrap();
    assert!(
        !log.read_after("msg_stop_buffer", 0)
            .await
            .unwrap()
            .events
            .iter()
            .any(|event| event.event_type() == "block.delta")
    );
    stream.stop().await.unwrap();
    assert_eq!(
        stream.message().await.unwrap().0["blocks"][0]["data"]["text"],
        "Sunny"
    );
    let events = log.read_after("msg_stop_buffer", 0).await.unwrap().events;
    assert!(
        events
            .iter()
            .any(|event| event.event_type() == "block.delta")
    );
    assert_eq!(events.last().unwrap().event_type(), "message.end");
}

#[tokio::test]
async fn handles_reject_parent_first_and_fourth_level_steps() {
    let (stream, _, _, _) = setup("msg_depth").await;
    let outer = stream.start_delegate("Compare weather").await.unwrap();
    let inner = outer.start_delegate("Delegate lookup").await.unwrap();
    let third = inner.start_delegate("Delegate detail").await.unwrap();
    assert!(third.start_step("Too deep").await.is_err());
    assert!(outer.clone().finish("succeeded", None).await.is_err());
    third.finish("succeeded", None).await.unwrap();
    inner.finish("succeeded", None).await.unwrap();
    outer.finish("succeeded", None).await.unwrap();
    stream.finish().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn pause_excludes_waiting_time_and_commits_authoritative_checkpoint() {
    let (stream, log, _, checkpoints) = setup("msg_pause").await;
    let step = stream.start_step("Choose forecast city").await.unwrap();
    tokio::time::advance(Duration::from_millis(200)).await;
    let card = stream
        .start_block("choice", 1, "Choose a city")
        .await
        .unwrap();
    card.data(choice_data(), "Choose a city", None)
        .await
        .unwrap();
    card.finish().await.unwrap();
    let paused = stream
        .pause(&step, &card, "interrupt_city", "input_required", true)
        .await
        .unwrap();
    assert_eq!(paused.message.0["status"], "paused");
    assert_eq!(paused.message.0["lastSeq"], paused.last_seq);
    assert_eq!(paused.message.0["steps"][0]["state"], "awaiting_user");
    assert_eq!(
        checkpoints
            .load("msg_pause")
            .await
            .unwrap()
            .unwrap()
            .message,
        paused.message
    );
    let prefix = log.read_after("msg_pause", 0).await.unwrap().events;
    assert_eq!(fold(prefix).unwrap(), paused.message);
    tokio::time::advance(Duration::from_secs(3_600)).await;
    stream.resume(answer("interrupt_city")).await.unwrap();
    tokio::time::advance(Duration::from_millis(300)).await;
    step.finish("succeeded", None).await.unwrap();
    let message = stream.finish().await.unwrap();
    assert_eq!(message.0["steps"][0]["durationMs"], 500);
    assert_eq!(
        message.0["blocks"][0]["data"]["state"]["selected"],
        json!(["beijing"])
    );
    let resumed = log
        .read_after("msg_pause", paused.last_seq)
        .await
        .unwrap()
        .events;
    assert_eq!(resumed[0].event_type(), "block.patch");
    assert_eq!(resumed[1].event_type(), "message.resumed");
    assert!(resumed[0].0.get("rev").is_none());
}

#[tokio::test]
async fn pause_requires_closed_blocks_and_no_unrelated_running_steps() {
    let (stream, _, _, _) = setup("msg_pause_checks").await;
    let question = stream.start_step("Choose city").await.unwrap();
    let unrelated = stream.start_step("Read tasks").await.unwrap();
    let card = stream
        .start_block("choice", 1, "Choose city")
        .await
        .unwrap();
    card.data(choice_data(), "Choose city", None).await.unwrap();
    assert!(
        stream
            .pause(&question, &card, "interrupt_1", "input_required", true)
            .await
            .is_err()
    );
    card.finish().await.unwrap();
    assert!(
        stream
            .pause(&question, &card, "interrupt_1", "input_required", true)
            .await
            .is_err()
    );
    unrelated.finish("succeeded", None).await.unwrap();
    stream
        .pause(&question, &card, "interrupt_1", "input_required", true)
        .await
        .unwrap();
    stream.stop().await.unwrap();
}

#[tokio::test]
async fn stopping_and_expiring_a_nested_interrupt_emit_the_required_closing_order() {
    for expired in [false, true] {
        let id = if expired {
            "msg_expire_pause"
        } else {
            "msg_stop_pause"
        };
        let (stream, log, _, _) = setup(id).await;
        let delegate = stream
            .start_delegate("Ask before changing task")
            .await
            .unwrap();
        let step = delegate.start_step("Confirm task deletion").await.unwrap();
        let card = stream
            .start_block("confirmation", 1, "Delete task?")
            .await
            .unwrap();
        card.data(
            json!({
                "title":"Delete task?","severity":"destructive",
                "action":{"type":"confirmation.respond","target":"todo.delete",
                          "requiresConfirmation":true,"expiresAt":"2000-01-01T00:00:00Z"},
                "state":{"status":"open"}
            }),
            "Delete task?",
            None,
        )
        .await
        .unwrap();
        card.finish().await.unwrap();
        let paused = stream
            .pause(&step, &card, "interrupt_delete", "confirmation", true)
            .await
            .unwrap();
        assert_eq!(paused.message.0["steps"][0]["state"], "running");
        assert_eq!(paused.message.0["steps"][1]["state"], "awaiting_user");
        if expired {
            stream.expire_interrupt().await.unwrap();
        } else {
            stream.stop().await.unwrap();
        }
        let tail = log.read_after(id, paused.last_seq).await.unwrap().events;
        assert_eq!(tail.len(), 4);
        assert_eq!(tail[0].event_type(), "block.patch");
        assert_eq!(
            tail[0].0["patch"]["data"]["state"]["status"],
            if expired { "expired" } else { "cancelled" }
        );
        if !expired {
            assert_eq!(
                tail[0].0["patch"]["data"]["state"]["reason"]["code"],
                "stopped"
            );
        }
        assert_eq!(tail[1].0["stepId"], step.id);
        assert_eq!(tail[1].0["state"], "cancelled");
        assert_eq!(tail[2].0["stepId"], delegate.as_step().id);
        assert_eq!(tail[2].0["state"], "cancelled");
        assert_eq!(tail[3].event_type(), "message.end");
        assert_eq!(tail[3].0["status"], "interrupted");
        assert_eq!(
            tail[3].0["error"]["code"],
            if expired {
                "interrupt_expired"
            } else {
                "cancelled"
            }
        );
        Validator::default()
            .validate(DocumentKind::Message, &stream.message().await.unwrap().0)
            .unwrap();
    }
}

#[tokio::test]
async fn activity_is_ephemeral_and_disconnect_does_not_cancel_generation() {
    let (stream, log, hub, _) = setup("msg_activity").await;
    let mut subscriber = hub.subscribe("msg_activity").await.unwrap();
    let before = stream.message().await.unwrap();
    let seq = stream.last_seq().await;
    stream
        .activity("working", Some("Checking weather"))
        .await
        .unwrap();
    let hint = subscriber.recv().await.unwrap().unwrap();
    assert_eq!(hint.event_type(), "message.activity");
    assert_eq!(hint.seq(), None);
    assert_eq!(stream.last_seq().await, seq);
    assert_eq!(stream.message().await.unwrap(), before);
    assert_eq!(
        log.read_after("msg_activity", 0)
            .await
            .unwrap()
            .events
            .len(),
        1
    );
    drop(subscriber);
    let block = stream.start_block("markdown", 1, "").await.unwrap();
    block.append_text("The forecast is ready.").await.unwrap();
    block.finish().await.unwrap();
    assert_eq!(stream.finish().await.unwrap().0["status"], "complete");
}

#[tokio::test(start_paused = true)]
async fn tick_flushes_small_deltas_and_periodically_saves_a_checkpoint() {
    let (stream, log, _, checkpoints) = setup("msg_tick").await;
    let block = stream.start_block("markdown", 1, "").await.unwrap();
    block.append_text("Sunny").await.unwrap();
    assert!(
        !log.read_after("msg_tick", 0)
            .await
            .unwrap()
            .events
            .iter()
            .any(|event| event.event_type() == "block.delta")
    );
    tokio::time::advance(Duration::from_millis(50)).await;
    stream.tick().await.unwrap();
    assert!(
        log.read_after("msg_tick", 0)
            .await
            .unwrap()
            .events
            .iter()
            .any(|event| event.event_type() == "block.delta")
    );
    tokio::time::advance(Duration::from_secs(5)).await;
    stream.tick().await.unwrap();
    let checkpoint = checkpoints.load("msg_tick").await.unwrap().unwrap();
    assert_eq!(checkpoint.last_seq, stream.last_seq().await);
    assert_eq!(checkpoint.message.0["blocks"][0]["status"], "pending");
    assert_eq!(checkpoint.message.0["blocks"][0]["data"]["text"], "Sunny");
    assert_eq!(checkpoint.message.0["fallbackText"], "Sunny");
    block.finish().await.unwrap();
    assert!(
        checkpoints
            .load("msg_tick")
            .await
            .unwrap()
            .unwrap()
            .last_seq
            > checkpoint.last_seq
    );
    stream.finish().await.unwrap();
}

#[cfg(debug_assertions)]
#[tokio::test]
#[should_panic(expected = "finish called with unfinished steps")]
async fn debug_build_reports_unfinished_steps_as_a_host_defect() {
    let (stream, _, _, _) = setup("msg_unfinished").await;
    stream.start_step("Read forecast").await.unwrap();
    let _ = stream.finish().await;
}

#[tokio::test]
async fn an_upstream_failure_without_content_ends_with_an_explanatory_error_message() {
    let (stream, log, _, checkpoints) = setup("msg_upstream_failure").await;
    let message = stream.fail("Weather assistant unavailable").await.unwrap();
    assert_eq!(message.status(), "error");
    assert_eq!(message.0["fallbackText"], "Weather assistant unavailable");
    let events = log
        .read_after("msg_upstream_failure", 0)
        .await
        .unwrap()
        .events;
    assert_eq!(events.last().unwrap().event_type(), "message.end");
    assert!(!events.iter().any(|event| event.event_type() == "error"));
    assert_eq!(
        checkpoints
            .load("msg_upstream_failure")
            .await
            .unwrap()
            .unwrap()
            .message,
        message
    );
}

#[tokio::test]
async fn failed_markdown_flushes_buffered_text_before_closing_its_block() {
    let (stream, _, _, _) = setup("msg_failed_text").await;
    let block = stream.start_block("markdown", 1, "").await.unwrap();
    block.append_text("Short").await.unwrap();
    block
        .fail("Partial answer unavailable", "Upstream failed")
        .await
        .unwrap();
    let message = stream.finish().await.unwrap();
    assert_eq!(message.0["blocks"][0]["data"]["text"], "Short");
    assert_eq!(message.0["blocks"][0]["status"], "error");
}

#[tokio::test]
async fn unregistered_custom_blocks_are_rejected_before_any_block_event_is_logged() {
    let (stream, log, _, _) = setup("msg_unknown_custom").await;
    assert!(
        stream
            .start_block("x-todo.task_card", 1, "Task unavailable")
            .await
            .is_err()
    );
    let events = log
        .read_after("msg_unknown_custom", 0)
        .await
        .unwrap()
        .events;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type(), "message.start");
}

#[tokio::test]
async fn registered_custom_data_is_checked_before_delivery_and_can_be_retried() {
    use chatweave_server::protocol::{Limits, SchemaRegistry};
    let mut registry = SchemaRegistry::default();
    registry
        .register(
            "x-todo.task_card",
            1,
            json!({
                "type":"object","required":["taskId"],"additionalProperties":false,
                "properties":{"taskId":{"type":"string"}}
            }),
        )
        .unwrap();
    let validator = Arc::new(Validator::new(Limits::default(), registry).unwrap());
    let log = Arc::new(MemoryEventLog::default());
    let stream = MessageStream::start(
        StreamConfig::new("msg_custom"),
        validator,
        log.clone(),
        Arc::new(BroadcastHub::default()),
        Arc::new(MemoryCheckpointStore::default()),
    )
    .await
    .unwrap();
    let block = stream
        .start_block("x-todo.task_card", 1, "Buy tea")
        .await
        .unwrap();
    let before = stream.last_seq().await;
    assert!(
        block
            .data(json!({"taskId":42}), "Buy tea", None)
            .await
            .is_err()
    );
    assert_eq!(stream.last_seq().await, before);
    assert_eq!(
        log.read_after("msg_custom", before)
            .await
            .unwrap()
            .events
            .len(),
        0
    );
    block
        .data(json!({"taskId":"task_tea"}), "Buy tea", None)
        .await
        .unwrap();
    block.finish().await.unwrap();
    assert_eq!(
        stream.finish().await.unwrap().0["blocks"][0]["data"]["taskId"],
        "task_tea"
    );
}

#[tokio::test]
async fn a_tight_event_budget_still_reserves_a_terminal_limit_event() {
    let mut config = StreamConfig::new("msg_event_limit");
    config.max_events = 4;
    let log = Arc::new(MemoryEventLog::default());
    let stream = MessageStream::start(
        config,
        Arc::new(Validator::default()),
        log.clone(),
        Arc::new(BroadcastHub::default()),
        Arc::new(MemoryCheckpointStore::default()),
    )
    .await
    .unwrap();
    let block = stream.start_block("markdown", 1, "").await.unwrap();
    // The next nonclosing write cannot consume the slots needed by block.end
    // and message.end, so production ends without exceeding its event budget.
    assert!(
        block
            .patch(json!({"metadata":{"provenance":"model"}}))
            .await
            .is_err()
    );
    let events = log.read_after("msg_event_limit", 0).await.unwrap().events;
    assert!(events.len() <= 4);
    assert_eq!(events.last().unwrap().event_type(), "message.end");
    assert_eq!(events.last().unwrap().0["error"]["code"], "limit_exceeded");
}
