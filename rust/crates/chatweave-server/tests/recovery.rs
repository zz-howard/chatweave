use chatweave_server::checkpoint::{Checkpoint, CheckpointStore, MemoryCheckpointStore};
use chatweave_server::event_log::{BroadcastHub, EventLog, MemoryEventLog};
use chatweave_server::protocol::{DocumentKind, Message, Validator};
use chatweave_server::recovery::recover_message;
use chatweave_server::stream::RecordedAnswer;
use chatweave_server::{Error, MessageStream, StreamConfig};
use serde_json::json;
use std::sync::Arc;

async fn start(
    id: &str,
    log: Arc<MemoryEventLog>,
    checkpoints: Arc<MemoryCheckpointStore>,
) -> MessageStream {
    let mut config = StreamConfig::new(id);
    config.delta_chars = 1;
    MessageStream::start(
        config,
        Arc::new(Validator::default()),
        log,
        Arc::new(BroadcastHub::default()),
        checkpoints,
    ).await.unwrap()
}

#[tokio::test]
async fn durable_log_recovery_keeps_uncheckpointed_content_and_fails_running_steps() {
    let log = Arc::new(MemoryEventLog::default());
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let stream = start("msg_log_recovery", log.clone(), checkpoints.clone()).await;
    stream.start_step("Read forecast").await.unwrap();
    let text = stream.start_block("markdown", 1, "").await.unwrap();
    text.append_text("Sunny with a high of 18°C.").await.unwrap();
    assert!(checkpoints.load("msg_log_recovery").await.unwrap().is_none());
    let recovered = recover_message(
        "msg_log_recovery",
        Arc::new(Validator::default()),
        log.clone(),
        Arc::new(BroadcastHub::default()),
        checkpoints.clone(),
    ).await.unwrap();
    assert_eq!(recovered.0["status"], "interrupted");
    assert_eq!(recovered.0["steps"][0]["state"], "failed");
    assert_eq!(recovered.0["blocks"][0]["data"]["text"], "Sunny with a high of 18°C.");
    assert_eq!(recovered.0["rev"], 1);
    let events = log.read_after("msg_log_recovery", 0).await.unwrap().events;
    let end = events.last().unwrap();
    assert_eq!(end.event_type(), "message.end");
    assert_eq!(end.0["error"]["code"], "upstream_failed");
    assert_eq!(events[events.len() - 2].event_type(), "step.finished");
    assert_eq!(checkpoints.load("msg_log_recovery").await.unwrap().unwrap().message, recovered);
    Validator::default().validate(DocumentKind::Message, &recovered.0).unwrap();
}

#[tokio::test]
async fn process_restart_recovers_the_last_checkpoint_and_not_lost_buffer_content() {
    let old_log = Arc::new(MemoryEventLog::default());
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let stream = start("msg_checkpoint_recovery", old_log, checkpoints.clone()).await;
    stream.start_step("Read tasks").await.unwrap();
    let saved = stream.start_block("markdown", 1, "").await.unwrap();
    saved.append_text("Three tasks are ready.").await.unwrap();
    saved.finish().await.unwrap();
    let durable = checkpoints.load("msg_checkpoint_recovery").await.unwrap().unwrap();
    let lost = stream.start_block("markdown", 1, "").await.unwrap();
    lost.append_text("This uncheckpointed tail is lost after restart.").await.unwrap();
    let new_log = Arc::new(MemoryEventLog::default());
    let recovered = recover_message(
        "msg_checkpoint_recovery",
        Arc::new(Validator::default()),
        new_log.clone(),
        Arc::new(BroadcastHub::default()),
        checkpoints.clone(),
    ).await.unwrap();
    assert_eq!(recovered.0["status"], "interrupted");
    assert_eq!(recovered.0["steps"][0]["state"], "failed");
    assert_eq!(recovered.0["blocks"].as_array().unwrap().len(), 1);
    assert!(!recovered.0["fallbackText"].as_str().unwrap().contains("uncheckpointed"));
    let tail = new_log.read_after("msg_checkpoint_recovery", durable.last_seq).await.unwrap();
    assert!(tail.covered);
    assert_eq!(tail.events.first().unwrap().seq(), Some(durable.last_seq + 1));
    assert_eq!(tail.events.last().unwrap().event_type(), "message.end");
}

#[tokio::test]
async fn paused_checkpoint_survives_restart_and_can_resume_to_completion() {
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let original = start("msg_resume_recovery", Arc::new(MemoryEventLog::default()), checkpoints.clone()).await;
    let step = original.start_step("Choose forecast city").await.unwrap();
    let card = original.start_block("choice", 1, "Choose city").await.unwrap();
    card.data(json!({
        "prompt":"Choose city","options":[{"id":"beijing","label":"Beijing"},{"id":"shanghai","label":"Shanghai"}],
        "action":{"type":"choice.select","target":"weather.choose"},"state":{"status":"open"}
    }), "Choose city", None).await.unwrap();
    card.finish().await.unwrap();
    let paused = original.pause(&step, &card, "interrupt_city", "input_required", true).await.unwrap();
    let new_log = Arc::new(MemoryEventLog::default());
    let recovered = recover_message(
        "msg_resume_recovery", Arc::new(Validator::default()), new_log.clone(),
        Arc::new(BroadcastHub::default()), checkpoints.clone(),
    ).await.unwrap();
    assert_eq!(recovered, paused.message);
    assert!(new_log.read_after("msg_resume_recovery", 0).await.unwrap().events.is_empty());
    let restored = MessageStream::from_checkpoint(
        paused.clone(), StreamConfig::new("msg_resume_recovery"),
        Arc::new(Validator::default()), new_log.clone(),
        Arc::new(BroadcastHub::default()), checkpoints.clone(),
    ).await.unwrap();
    restored.resume(RecordedAnswer {
        interrupt_id: "interrupt_city".into(), payload: json!({"selected":["beijing"]}),
        resolved_at: "2026-10-27T00:00:00Z".into(), resolved_by: None,
    }).await.unwrap();
    restored.step_handle(&step.id).await.unwrap().finish("succeeded", Some("City selected".into()))
        .await.unwrap();
    let message = restored.finish().await.unwrap();
    assert_eq!(message.0["status"], "complete");
    assert_eq!(message.0["steps"][0]["state"], "succeeded");
    assert_eq!(message.0["steps"][0]["blockId"], card.id);
    let replay = new_log.read_after("msg_resume_recovery", paused.last_seq).await.unwrap();
    assert_eq!(replay.events[0].event_type(), "block.patch");
    assert_eq!(replay.events[1].event_type(), "message.resumed");
    assert_eq!(replay.events.last().unwrap().event_type(), "message.end");
}

#[tokio::test]
async fn checkpoint_store_rejects_stale_and_wrong_expected_sequence_writes() {
    let store = MemoryCheckpointStore::default();
    let message = Message(json!({"id":"msg_conditional"}));
    store.commit(Checkpoint::new(message.clone(), 5), None).await.unwrap();
    assert!(matches!(store.commit(Checkpoint::new(message.clone(), 4), None).await, Err(Error::Conflict)));
    assert!(matches!(store.commit(Checkpoint::new(message.clone(), 6), Some(4)).await, Err(Error::Conflict)));
    assert_eq!(store.load("msg_conditional").await.unwrap().unwrap().last_seq, 5);
    store.commit(Checkpoint::new(message, 6), Some(5)).await.unwrap();
    assert_eq!(store.load("msg_conditional").await.unwrap().unwrap().last_seq, 6);
}

#[tokio::test]
async fn missing_recovery_state_is_reported_instead_of_inventing_content() {
    assert!(matches!(recover_message(
        "msg_missing", Arc::new(Validator::default()), Arc::new(MemoryEventLog::default()),
        Arc::new(BroadcastHub::default()), Arc::new(MemoryCheckpointStore::default()),
    ).await, Err(Error::Unavailable)));
}
