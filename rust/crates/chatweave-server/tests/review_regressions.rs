//! Regression tests for the CW1 review findings (PR #1).
use async_trait::async_trait;
use chatweave_server::action::{
    ActionError, ActionHandler, ActionOutcome, ActionRegistry, ActionType, MemoryActionStore,
    ResolvedAction,
};
use chatweave_server::checkpoint::{CheckpointStore, MemoryCheckpointStore};
use chatweave_server::event_log::{BroadcastHub, EventLog, EventSink, MemoryEventLog};
use chatweave_server::generation::GenerationRegistry;
use chatweave_server::protocol::{
    ActionRequest, DocumentKind, Message, StreamEvent, Validator, fold,
};
use chatweave_server::recovery::recover_message;
use chatweave_server::{MessageStream, StreamConfig};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::Notify;

const CAP: usize = 256 * 1024;
const PAUSED: &str =
    include_str!("../../../../fixtures/conformance/streams/24-interrupt-paused.expected.json");

// ---------------------------------------------------------------- helpers

#[derive(Default)]
struct Calls {
    authorized: AtomicUsize,
    executed: AtomicUsize,
}

/// Choice handler. Executions on `gated_block` announce themselves and wait
/// for `release`; every execute also reads the store (handlers may do so).
struct ChoiceHandler {
    target: &'static str,
    calls: Arc<Calls>,
    gated_block: Option<&'static str>,
    entered: Arc<Notify>,
    release: Arc<Notify>,
    store: Option<Arc<MemoryActionStore<String>>>,
}

impl ChoiceHandler {
    fn new(target: &'static str, calls: Arc<Calls>) -> Self {
        Self {
            target,
            calls,
            gated_block: None,
            entered: Arc::default(),
            release: Arc::default(),
            store: None,
        }
    }
}

#[async_trait]
impl ActionHandler<String> for ChoiceHandler {
    fn target(&self) -> &'static str {
        self.target
    }
    fn accepts(&self) -> &'static [ActionType] {
        &[ActionType::ChoiceSelect]
    }
    async fn authorize(&self, _: &String, _: &ResolvedAction) -> Result<(), ActionError> {
        self.calls.authorized.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn execute(
        &self,
        ctx: &String,
        action: ResolvedAction,
    ) -> Result<ActionOutcome, ActionError> {
        self.calls.executed.fetch_add(1, Ordering::SeqCst);
        if let Some(store) = &self.store {
            store.load_message(ctx, action.stored.message.id()).await?;
        }
        if self
            .gated_block
            .is_some_and(|id| action.stored.block["id"] == id)
        {
            self.entered.notify_one();
            self.release.notified().await;
        }
        Ok(ActionOutcome::default())
    }
}

/// Destructive confirmation handler whose execute waits for `release`.
struct GatedDelete {
    entered: Arc<Notify>,
    release: Arc<Notify>,
}

#[async_trait]
impl ActionHandler<String> for GatedDelete {
    fn target(&self) -> &'static str {
        "todo.delete"
    }
    fn accepts(&self) -> &'static [ActionType] {
        &[ActionType::ConfirmationRespond]
    }
    fn destructive(&self) -> bool {
        true
    }
    async fn authorize(&self, _: &String, _: &ResolvedAction) -> Result<(), ActionError> {
        Ok(())
    }
    async fn execute(&self, _: &String, _: ResolvedAction) -> Result<ActionOutcome, ActionError> {
        self.entered.notify_one();
        self.release.notified().await;
        Ok(ActionOutcome::default())
    }
}

fn choice_block(id: &str, target: &str) -> Value {
    json!({"id":id,"type":"choice","schemaVersion":1,"fallbackText":"Choose a city","data":{
        "prompt":"Which city?","selection":"single",
        "options":[{"id":"bj","label":"Beijing"},{"id":"sh","label":"Shanghai"}],
        "action":{"type":"choice.select","target":target},"state":{"status":"open"}}})
}

fn two_choices() -> Message {
    Message(json!({
        "id":"msg_two_blocks","protocolVersion":"0.1","conversationId":"conv_1",
        "role":"assistant","status":"complete","rev":1,
        "createdAt":"2026-10-26T09:30:00Z","fallbackText":"Choose a city",
        "blocks":[choice_block("b1","city.choose"), choice_block("b2","city.choose")]
    }))
}

fn select(id: &str, message: &str, block: &str) -> ActionRequest {
    ActionRequest(json!({
        "id":id,"protocolVersion":"0.1","type":"choice.select","target":"city.choose",
        "context":{"conversationId":"conv_1","messageId":message,"blockId":block},
        "payload":{"selected":["bj"]}
    }))
}

fn store() -> MemoryActionStore<String> {
    MemoryActionStore::new(|ctx: &String| ctx.clone()).with_clock(|| "2026-10-26T09:31:00Z".into())
}

async fn start(
    id: &str,
    log: Arc<MemoryEventLog>,
    checkpoints: Arc<MemoryCheckpointStore>,
    configure: impl FnOnce(&mut StreamConfig),
) -> MessageStream {
    let mut config = StreamConfig::new(id);
    configure(&mut config);
    MessageStream::start(
        config,
        Arc::new(Validator::default()),
        log,
        Arc::new(BroadcastHub::default()),
        checkpoints,
    )
    .await
    .unwrap()
}

async fn within<T>(future: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(2), future)
        .await
        .expect("operation blocked")
}

// --------------------------------------------- 1. unfinished non-interrupt

#[tokio::test]
async fn non_interrupt_block_of_an_unfinished_message_is_refused_before_authorize_and_execute() {
    let calls = Arc::new(Calls::default());
    let mut registry = ActionRegistry::default();
    registry
        .register(Arc::new(ChoiceHandler::new("city.choose", calls.clone())))
        .unwrap();
    let store = store();
    let stream = start("msg_live", Arc::default(), Arc::default(), |config| {
        config.conversation_id = Some("conv_1".into())
    })
    .await;
    let card = stream
        .start_block("choice", 1, "Choose a city")
        .await
        .unwrap();
    card.data(
        choice_block("b1", "city.choose")["data"].clone(),
        "Choose a city",
        None,
    )
    .await
    .unwrap();
    card.finish().await.unwrap();
    store.attach_stream("scope", stream.clone()).await.unwrap();

    for attempt in 0..2 {
        // The retry must not execute either (it used to run again each time).
        let result = registry
            .dispatch(
                &"scope".into(),
                select("action_0001", "msg_live", "b1"),
                &store,
            )
            .await
            .unwrap();
        assert_eq!(result.0["status"], "rejected", "attempt {attempt}");
        assert_eq!(result.0["error"]["code"], "conflict");
    }
    assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
    assert_eq!(calls.authorized.load(Ordering::SeqCst), 0);
    let open = store.load_message("scope", "msg_live").await.unwrap();
    assert_eq!(open.0["blocks"][0]["data"]["state"]["status"], "open");

    // Once the message has ended, the same block is answerable exactly once.
    stream.finish().await.unwrap();
    let result = registry
        .dispatch(
            &"scope".into(),
            select("action_0001", "msg_live", "b1"),
            &store,
        )
        .await
        .unwrap();
    assert_eq!(result.0["status"], "completed");
    assert_eq!(calls.executed.load(Ordering::SeqCst), 1);
    let saved = store.load_message("scope", "msg_live").await.unwrap();
    assert_eq!(saved.0["rev"], 2);
    assert_eq!(saved.0["blocks"][0]["data"]["state"]["status"], "resolved");
}

// ------------------------------------------------- 2. message size cap

fn assert_limit_ended(message: &Message, events: &[StreamEvent]) {
    assert_eq!(message.0["status"], "interrupted");
    let end = events.last().unwrap();
    assert_eq!(end.event_type(), "message.end");
    assert_eq!(end.0["error"]["code"], "limit_exceeded");
    assert!(serde_json::to_vec(&message.0).unwrap().len() <= CAP);
    Validator::default()
        .validate(DocumentKind::Message, &message.0)
        .unwrap();
    assert!(!message.0["fallbackText"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn producer_hitting_the_cap_with_fallback_ends_the_message_with_limit_exceeded() {
    let log = Arc::new(MemoryEventLog::default());
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let stream = start("msg_capped", log.clone(), checkpoints.clone(), |_| {}).await;
    // 10,000 CJK characters per block: 30 KB of text, and the 16,000
    // character fallback adds up to 48 KB on top of the blocks.
    let text = "晴".repeat(10_000);
    let mut refused = false;
    for _ in 0..12 {
        let Ok(block) = stream.start_block("markdown", 1, "").await else {
            refused = true;
            break;
        };
        if block.append_text(&text).await.is_err() || block.finish().await.is_err() {
            refused = true;
            break;
        }
    }
    assert!(refused, "the cap must be reached");
    let message = stream.message().await.unwrap();
    let events = log.read_after("msg_capped", 0).await.unwrap().events;
    assert_limit_ended(&message, &events);
    let checkpoint = checkpoints.load("msg_capped").await.unwrap().unwrap();
    assert_eq!(checkpoint.message.0["status"], "interrupted");
    assert_eq!(fold(events).unwrap().0["status"], "interrupted");
    // Ended, not stuck: further production is refused, stop is a no-op.
    assert!(stream.start_block("markdown", 1, "").await.is_err());
    stream.stop().await.unwrap();
}

fn stamp(id: &str, seq: u64, mut value: Value) -> StreamEvent {
    value["protocolVersion"] = json!("0.1");
    value["messageId"] = json!(id);
    value["seq"] = json!(seq);
    StreamEvent(value)
}

#[tokio::test]
async fn recovery_of_a_message_whose_closing_fallback_overflows_the_cap_still_ends_it() {
    // A log written right up to the cap (checked with an empty streaming
    // fallback), so the ordinary closing with its full fallback cannot fit.
    let id = "msg_cap_recover";
    let log = Arc::new(MemoryEventLog::default());
    let mut seq = 1;
    log.append(stamp(id, seq, json!({"type":"message.start","message":{"id":id,"role":"assistant","createdAt":"2026-10-26T09:30:00Z"}})))
        .await
        .unwrap();
    for index in 0..7 {
        let block = format!("b{}", index + 1);
        seq += 1;
        log.append(stamp(id, seq, json!({"type":"block.start","blockId":block,"index":index,"blockType":"markdown","schemaVersion":1})))
            .await
            .unwrap();
        for _ in 0..8 {
            seq += 1;
            log.append(stamp(
                id,
                seq,
                json!({"type":"block.delta","blockId":block,"delta":{"text":"雨".repeat(1300)}}),
            ))
            .await
            .unwrap();
        }
        seq += 1;
        log.append(stamp(
            id,
            seq,
            json!({"type":"block.end","blockId":block,"status":"complete"}),
        ))
        .await
        .unwrap();
    }
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let recovered = recover_message(
        id,
        Arc::new(Validator::default()),
        log.clone(),
        Arc::new(BroadcastHub::default()),
        checkpoints.clone(),
    )
    .await
    .expect("recovery must be able to end the message");
    let events = log.read_after(id, 0).await.unwrap().events;
    assert_limit_ended(&recovered, &events);
    let fallback = recovered.0["fallbackText"].as_str().unwrap();
    assert!(fallback.ends_with('…') && fallback.chars().count() < 16_000);
    assert_eq!(recovered.0["blocks"].as_array().unwrap().len(), 7);
    let checkpoint = checkpoints.load(id).await.unwrap().unwrap();
    assert_eq!(checkpoint.last_seq, seq + 1);
}

// ------------------------------------------------------- 3. cancellation

#[tokio::test]
async fn stop_cancels_the_producer_and_pending_work_observes_it() {
    let registry = GenerationRegistry::default();
    let stream = start("msg_stop", Arc::default(), Arc::default(), |_| {}).await;
    registry
        .register("scope", "conv_1", "user_1", stream.clone())
        .await
        .unwrap();
    let mut cancellation = stream.cancellation();
    assert!(!cancellation.is_cancelled());
    let producer = tokio::spawn(async move {
        tokio::select! {
            _ = cancellation.cancelled() => "cancelled",
            _ = tokio::time::sleep(Duration::from_secs(60)) => "kept running",
        }
    });
    tokio::task::yield_now().await;
    let result = registry.stop("scope", "msg_stop").await.unwrap();
    assert_eq!(result["status"], "stopping");
    assert_eq!(within(producer).await.unwrap(), "cancelled");
    assert!(stream.cancellation().is_cancelled());
    assert_eq!(stream.message().await.unwrap().0["status"], "interrupted");
}

// ------------------------------------------- 4. per-block serialisation

#[tokio::test]
async fn actions_on_different_blocks_run_concurrently_and_handlers_can_read_the_store() {
    let calls = Arc::new(Calls::default());
    let store = Arc::new(store());
    let mut handler = ChoiceHandler::new("city.choose", calls.clone());
    handler.gated_block = Some("b1");
    handler.store = Some(store.clone());
    let (entered, release) = (handler.entered.clone(), handler.release.clone());
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(handler)).unwrap();
    let registry = Arc::new(registry);
    store.insert_message("scope", two_choices()).await.unwrap();

    let first = tokio::spawn({
        let (registry, store) = (registry.clone(), store.clone());
        async move {
            registry
                .dispatch(
                    &"scope".into(),
                    select("action_b1_0001", "msg_two_blocks", "b1"),
                    store.as_ref(),
                )
                .await
                .unwrap()
        }
    });
    within(entered.notified()).await;
    // b1's execute is still running; b2 is not serialised behind it.
    let second = within(registry.dispatch(
        &"scope".into(),
        select("action_b2_0001", "msg_two_blocks", "b2"),
        store.as_ref(),
    ))
    .await
    .unwrap();
    assert_eq!(second.0["status"], "completed");
    release.notify_one();
    let first = within(first).await.unwrap();
    assert_eq!(first.0["status"], "completed");
    // Both answers survive: no revision lost to the interleaving.
    let saved = store.load_message("scope", "msg_two_blocks").await.unwrap();
    assert_eq!(saved.0["rev"], 3);
    for block in saved.0["blocks"].as_array().unwrap() {
        assert_eq!(block["data"]["state"]["status"], "resolved");
    }
    assert_eq!(calls.executed.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn interrupt_execute_does_not_hold_the_stream_lock() {
    let handler = GatedDelete {
        entered: Arc::default(),
        release: Arc::default(),
    };
    let (entered, release) = (handler.entered.clone(), handler.release.clone());
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(handler)).unwrap();
    let registry = Arc::new(registry);
    let store = Arc::new(store());
    store
        .insert_message("scope", Message(serde_json::from_str(PAUSED).unwrap()))
        .await
        .unwrap();
    let request = ActionRequest(json!({
        "id":"action_confirm_01","protocolVersion":"0.1","type":"confirmation.respond",
        "target":"todo.delete",
        "context":{"conversationId":"conv_weather","messageId":"msg_weather","blockId":"b1"},
        "payload":{"outcome":"confirm"}
    }));
    let dispatch = tokio::spawn({
        let (registry, store) = (registry.clone(), store.clone());
        async move {
            registry
                .dispatch(&"scope".into(), request, store.as_ref())
                .await
                .unwrap()
        }
    });
    within(entered.notified()).await;
    // While the host executes, the stream and the store stay readable.
    let stream = within(store.stream("scope", "msg_weather")).await.unwrap();
    assert_eq!(
        within(stream.message()).await.unwrap().0["status"],
        "paused"
    );
    within(store.load_message("scope", "msg_weather"))
        .await
        .unwrap();
    release.notify_one();
    let result = within(dispatch).await.unwrap();
    assert_eq!(result.0["status"], "accepted");
    assert_eq!(stream.message().await.unwrap().0["status"], "streaming");
}

// ------------------------------------------------ 5. bounded retention

#[tokio::test]
async fn broadcast_channels_are_not_kept_without_subscribers() {
    let hub = BroadcastHub::default();
    let activity = |id: &str| {
        StreamEvent(
            json!({"protocolVersion":"0.1","messageId":id,"type":"message.activity","activity":{"phase":"working"}}),
        )
    };
    for index in 0..100 {
        hub.publish(activity(&format!("msg_{index}")))
            .await
            .unwrap();
    }
    assert_eq!(hub.channel_count().await, 0);
    let subscription = hub.subscribe("msg_live").await.unwrap();
    hub.publish(activity("msg_live")).await.unwrap();
    assert_eq!(hub.channel_count().await, 1);
    drop(subscription);
    hub.publish(activity("msg_live")).await.unwrap();
    assert_eq!(hub.channel_count().await, 0);
    let subscription = hub.subscribe("msg_other").await.unwrap();
    drop(subscription);
    hub.cleanup().await;
    assert_eq!(hub.channel_count().await, 0);
}

fn user_message() -> Value {
    json!({
        "id":"user_msg_01","protocolVersion":"0.1","role":"user",
        "conversationId":"conv_1","status":"complete","rev":1,
        "createdAt":"2026-10-27T00:00:00Z","fallbackText":"Hi",
        "blocks":[{"id":"b1","type":"markdown","schemaVersion":1,"data":{"text":"Hi"}}]
    })
}

#[tokio::test(start_paused = true)]
async fn generation_registry_releases_idempotency_records_after_retention() {
    let registry = GenerationRegistry::new(Duration::from_secs(60));
    let first = registry.begin("scope", &user_message()).await.unwrap();
    let stream = start("msg_retained", Arc::default(), Arc::default(), |_| {}).await;
    registry
        .register("scope", "conv_1", "user_msg_01", stream)
        .await
        .unwrap();
    registry.stop("scope", "msg_retained").await.unwrap();
    // One start record and one stop result; the stop gate is already gone.
    assert_eq!(registry.retained().await, 2);
    let replay = registry.begin("scope", &user_message()).await.unwrap();
    assert_eq!(replay["replayed"], true);
    tokio::time::advance(Duration::from_secs(61)).await;
    registry.cleanup().await;
    assert_eq!(registry.retained().await, 0);
    let again = registry.begin("scope", &user_message()).await.unwrap();
    assert_ne!(again["messageId"], first["messageId"]);
}

#[tokio::test(start_paused = true)]
async fn action_store_releases_receipts_and_ended_messages_after_retention() {
    let calls = Arc::new(Calls::default());
    let mut registry = ActionRegistry::default();
    registry
        .register(Arc::new(ChoiceHandler::new("city.choose", calls)))
        .unwrap();
    let store = store().with_retention(Duration::from_secs(60));
    store.insert_message("scope", two_choices()).await.unwrap();
    store
        .insert_message("scope", Message(serde_json::from_str(PAUSED).unwrap()))
        .await
        .unwrap();
    registry
        .dispatch(
            &"scope".into(),
            select("action_0001", "msg_two_blocks", "b1"),
            &store,
        )
        .await
        .unwrap();
    assert_eq!(store.retained().await, (2, 1, 1));
    tokio::time::advance(Duration::from_secs(30)).await;
    store.cleanup().await;
    assert_eq!(store.retained().await, (2, 1, 1));
    tokio::time::advance(Duration::from_secs(31)).await;
    store.cleanup().await;
    // The paused message (and its live stream) is unfinished: never released.
    assert_eq!(store.retained().await, (1, 0, 1));
    assert!(store.load_message("scope", "msg_weather").await.is_ok());
}

// ------------------------------------------ 8. recovery after eviction

#[tokio::test]
async fn recovery_after_partial_log_eviction_never_reuses_a_sequence_number() {
    let id = "msg_evicted";
    // Keep only the three newest events.
    let log = Arc::new(MemoryEventLog::new(
        3,
        8 * 1024 * 1024,
        Duration::from_secs(600),
    ));
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let stream = start(id, log.clone(), checkpoints.clone(), |config| {
        config.delta_chars = 1;
    })
    .await;
    let first = stream.start_block("markdown", 1, "").await.unwrap();
    first.append_text("a").await.unwrap();
    first.finish().await.unwrap();
    let checkpointed = checkpoints.load(id).await.unwrap().unwrap().last_seq;
    let second = stream.start_block("markdown", 1, "").await.unwrap();
    for text in ["b", "c", "d", "e"] {
        second.append_text(text).await.unwrap();
    }
    let head = stream.last_seq().await;
    drop((first, second, stream)); // producer lost
    let replay = log.read_after(id, checkpointed).await.unwrap();
    assert!(!replay.covered && replay.head == head);

    let recovered = recover_message(
        id,
        Arc::new(Validator::default()),
        log.clone(),
        Arc::new(BroadcastHub::default()),
        checkpoints.clone(),
    )
    .await
    .unwrap();
    assert_eq!(recovered.0["status"], "interrupted");
    let tail = log.read_after(id, head).await.unwrap().events;
    assert_eq!(tail.len(), 1);
    assert_eq!(tail[0].event_type(), "message.end");
    assert_eq!(tail[0].0["seq"], head + 1);
    assert_eq!(
        checkpoints.load(id).await.unwrap().unwrap().last_seq,
        head + 1
    );
}
