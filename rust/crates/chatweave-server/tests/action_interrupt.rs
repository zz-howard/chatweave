use async_trait::async_trait;
use chatweave_server::action::{
    ActionError, ActionHandler, ActionOutcome, ActionRegistry, ActionType, MemoryActionStore,
    ResolvedAction,
};
use chatweave_server::protocol::{ActionRequest, DocumentKind, Message, Validator};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::Barrier;

const NOW: &str = "2026-10-26T09:31:00Z";
const SCOPE: &str = "scope_weather";
const PAUSED: &str = include_str!(
    "../../../../fixtures/conformance/streams/24-interrupt-paused.expected.json"
);

#[derive(Default)]
struct Counts {
    authorized: AtomicUsize,
    executed: AtomicUsize,
}

struct DeleteHandler(Arc<Counts>);

#[async_trait]
impl ActionHandler<String> for DeleteHandler {
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
        self.0.authorized.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    async fn execute(
        &self,
        _: &String,
        _: ResolvedAction,
    ) -> Result<ActionOutcome, ActionError> {
        self.0.executed.fetch_add(1, Ordering::SeqCst);
        tokio::task::yield_now().await;
        Ok(ActionOutcome::default())
    }
}

fn paused() -> Message {
    Message(serde_json::from_str(PAUSED).unwrap())
}

fn answer(id: &str, payload: Value) -> ActionRequest {
    ActionRequest(json!({
        "id":id,"protocolVersion":"0.1","type":"confirmation.respond","target":"todo.delete",
        "context":{"conversationId":"conv_weather","messageId":"msg_weather","blockId":"b1"},
        "payload":payload
    }))
}

fn new_store() -> MemoryActionStore<String> {
    MemoryActionStore::new(|ctx: &String| ctx.clone()).with_clock(|| NOW.to_owned())
}

async fn setup() -> (ActionRegistry<String>, MemoryActionStore<String>, Arc<Counts>) {
    let calls = Arc::new(Counts::default());
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(DeleteHandler(calls.clone()))).unwrap();
    let store = new_store();
    store.insert_message(SCOPE, paused()).await.unwrap();
    (registry, store, calls)
}

#[tokio::test]
async fn cancel_and_free_text_resume_the_interrupt_without_executing_a_destructive_handler() {
    for payload in [json!({"outcome":"cancel"}), json!({"freeText":"请保留待办"})] {
        let (registry, store, calls) = setup().await;
        let request = answer("action_answer", payload.clone());
        let result = registry.dispatch(&SCOPE.to_owned(), request.clone(), &store).await.unwrap();
        assert_eq!(result.0["status"], "accepted");
        assert_eq!(result.0["resume"]["messageId"], "msg_weather");
        assert!(result.0.get("patches").is_none());
        assert!(result.0.get("followUp").is_none());
        let stream = store.stream(SCOPE, "msg_weather").await.unwrap();
        assert_eq!(stream.last_seq().await, 8);
        let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
        assert_eq!(saved.0["status"], "streaming");
        assert_eq!(saved.0["rev"], 0);
        assert_eq!(saved.0["lastSeq"], 8);
        assert!(saved.0.get("interrupt").is_none());
        assert_eq!(saved.0["steps"][0]["state"], "running");
        let state = &saved.0["blocks"][0]["data"]["state"];
        assert_eq!(state["status"], "resolved");
        assert_eq!(state["resolvedAt"], NOW);
        for (key, value) in payload.as_object().unwrap() {
            assert_eq!(state[key], *value);
        }
        let service = store.resume_service();
        let tail = service.log.read_after("msg_weather", 6).await.unwrap().events;
        assert_eq!(tail.len(), 2);
        assert_eq!(tail[0].event_type(), "block.patch");
        assert_eq!(tail[0].seq(), Some(7));
        assert_eq!(tail[0].0["patch"]["data"]["state"], *state);
        assert!(tail[0].0.get("rev").is_none());
        assert_eq!(tail[1].event_type(), "message.resumed");
        assert_eq!(tail[1].seq(), Some(8));
        assert_eq!(tail[1].0["interruptId"], "int_1");
        let replay = registry.dispatch(&SCOPE.to_owned(), request, &store).await.unwrap();
        assert_eq!(replay.0["replayed"], true);
        assert_eq!(replay.0["resume"], result.0["resume"]);
        assert_eq!(stream.last_seq().await, 8);
        assert_eq!(service.log.read_after("msg_weather", 6).await.unwrap().events.len(), 2);
        assert_eq!(calls.authorized.load(Ordering::SeqCst), 2);
        assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
        Validator::default().validate(DocumentKind::Message, &saved.0).unwrap();
        // Negative control: treating a cancel/freeText answer as an instruction
        // to execute todo.delete increments this counter and fails the test.
    }
}

#[tokio::test]
async fn concurrent_interrupt_answers_have_one_continuation_and_one_recorded_answer() {
    let (registry, store, calls) = setup().await;
    let ctx = SCOPE.to_owned();
    let barrier = Barrier::new(2);
    let confirm = async {
        barrier.wait().await;
        registry.dispatch(&ctx, answer("action_confirm", json!({"outcome":"confirm"})), &store).await.unwrap()
    };
    let cancel = async {
        barrier.wait().await;
        registry.dispatch(&ctx, answer("action_cancel", json!({"outcome":"cancel"})), &store).await.unwrap()
    };
    let (confirm, cancel) = tokio::join!(confirm, cancel);
    let results = [confirm.0, cancel.0];
    assert_eq!(results.iter().filter(|result| result["status"] == "accepted").count(), 1);
    let refused = results.iter().find(|result| result["status"] == "rejected").unwrap();
    assert_eq!(refused["error"]["code"], "already_resolved");
    assert_eq!(refused["resume"]["messageId"], "msg_weather");
    assert!(refused.get("patches").is_none());
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    let outcome = saved.0["blocks"][0]["data"]["state"]["outcome"].as_str().unwrap();
    assert!(matches!(outcome, "confirm" | "cancel"));
    assert_eq!(saved.0["lastSeq"], 8);
    assert_eq!(saved.0["rev"], 0);
    let service = store.resume_service();
    let tail = service.log.read_after("msg_weather", 6).await.unwrap().events;
    assert_eq!(tail.len(), 2);
    assert_eq!(tail.iter().filter(|event| event.event_type() == "message.resumed").count(), 1);
    assert_eq!(calls.executed.load(Ordering::SeqCst), usize::from(outcome == "confirm"));
    assert_eq!(calls.authorized.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_stopped_interrupt_refusal_carries_the_current_revision_one_state() {
    let (registry, store, calls) = setup().await;
    let stream = store.stream(SCOPE, "msg_weather").await.unwrap();
    stream.stop().await.unwrap();
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    assert_eq!(saved.0["status"], "interrupted");
    assert_eq!(saved.0["rev"], 1);
    let result = registry.dispatch(&SCOPE.to_owned(), answer("action_too_late", json!({"outcome":"confirm"})), &store).await.unwrap();
    assert_eq!(result.0["status"], "rejected");
    assert_eq!(result.0["error"]["code"], "already_resolved");
    assert!(result.0.get("resume").is_none());
    assert_eq!(result.0["patches"][0]["rev"], 1);
    assert_eq!(result.0["patches"][0]["patch"]["data"]["state"], saved.0["blocks"][0]["data"]["state"]);
    assert_eq!(result.0["patches"][0]["patch"]["data"]["state"]["reason"]["code"], "stopped");
    assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
    Validator::default().validate(DocumentKind::ActionResult, &result.0).unwrap();
}

#[tokio::test]
async fn a_paused_checkpoint_restores_answering_after_losing_the_entire_process_log() {
    let (registry, old_store, calls) = setup().await;
    let checkpoint = old_store.load_message(SCOPE, "msg_weather").await.unwrap();
    drop(old_store);
    let restarted = new_store();
    restarted.insert_message(SCOPE, checkpoint).await.unwrap();
    let result = registry.dispatch(&SCOPE.to_owned(), answer("action_restart", json!({"outcome":"cancel"})), &restarted).await.unwrap();
    assert_eq!(result.0["status"], "accepted");
    let saved = restarted.load_message(SCOPE, "msg_weather").await.unwrap();
    assert_eq!(saved.0["lastSeq"], 8);
    assert_eq!(saved.0["status"], "streaming");
    assert_eq!(saved.0["blocks"][0]["data"]["state"]["outcome"], "cancel");
    let service = restarted.resume_service();
    let tail = service.log.read_after("msg_weather", 6).await.unwrap().events;
    assert_eq!(tail.iter().map(|event| event.seq().unwrap()).collect::<Vec<_>>(), [7, 8]);
    assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn answering_and_stopping_share_the_interrupt_claim_without_duplicate_resume_events() {
    let (registry, store, calls) = setup().await;
    let stream = store.stream(SCOPE, "msg_weather").await.unwrap();
    let ctx = SCOPE.to_owned();
    let barrier = Barrier::new(2);
    let answer_future = async {
        barrier.wait().await;
        registry.dispatch(&ctx, answer("action_race", json!({"outcome":"confirm"})), &store).await.unwrap()
    };
    let stop_future = async {
        barrier.wait().await;
        stream.stop().await.unwrap();
    };
    let (result, ()) = tokio::join!(answer_future, stop_future);
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    assert_eq!(saved.0["status"], "interrupted");
    assert_eq!(saved.0["rev"], 1);
    let service = store.resume_service();
    let tail = service.log.read_after("msg_weather", 6).await.unwrap().events;
    let resumed = tail.iter().filter(|event| event.event_type() == "message.resumed").count();
    assert!(resumed <= 1);
    assert_eq!(tail.iter().filter(|event| event.event_type() == "message.end").count(), 1);
    match result.0["status"].as_str().unwrap() {
        "accepted" => {
            assert_eq!(resumed, 1);
            assert_eq!(calls.executed.load(Ordering::SeqCst), 1);
            assert_eq!(saved.0["blocks"][0]["data"]["state"]["outcome"], "confirm");
        }
        "rejected" => {
            assert_eq!(result.0["error"]["code"], "already_resolved");
            assert_eq!(resumed, 0);
            assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
            assert_eq!(saved.0["blocks"][0]["data"]["state"]["reason"]["code"], "stopped");
        }
        status => panic!("unexpected action status: {status}"),
    }
}

#[tokio::test]
async fn expired_answer_stop_and_expiration_race_close_the_interrupt_once() {
    let calls = Arc::new(Counts::default());
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(DeleteHandler(calls.clone()))).unwrap();
    let store = new_store();
    let mut seed = paused();
    seed.0["blocks"][0]["data"]["action"]["expiresAt"] = json!("2000-01-01T00:00:00Z");
    store.insert_message(SCOPE, seed).await.unwrap();
    let stream = store.stream(SCOPE, "msg_weather").await.unwrap();
    let ctx = SCOPE.to_owned();
    let barrier = Barrier::new(3);
    let submitted = async {
        barrier.wait().await;
        registry
            .dispatch(&ctx, answer("action_expired_race", json!({"outcome":"confirm"})), &store)
            .await
            .unwrap()
    };
    let stopped = async {
        barrier.wait().await;
        stream.stop().await.unwrap();
    };
    let expired = async {
        barrier.wait().await;
        // Losing the interrupt claim is expected when stop or dispatcher expiry
        // won; success is counted by the committed event sequence below.
        stream.expire_interrupt().await
    };
    let (result, (), _) = tokio::join!(submitted, stopped, expired);
    assert_eq!(result.0["status"], "rejected");
    assert!(matches!(
        result.0["error"]["code"].as_str(),
        Some("expired" | "already_resolved")
    ));
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    assert_eq!(saved.0["status"], "interrupted");
    assert_eq!(saved.0["rev"], 1);
    let service = store.resume_service();
    let tail = service.log.read_after("msg_weather", 6).await.unwrap().events;
    assert_eq!(tail.len(), 3);
    assert_eq!(tail[0].event_type(), "block.patch");
    assert_eq!(tail[1].event_type(), "step.finished");
    assert_eq!(tail[1].0["state"], "cancelled");
    assert_eq!(tail[2].event_type(), "message.end");
    assert_eq!(tail.iter().map(|event| event.seq().unwrap()).collect::<Vec<_>>(), [7, 8, 9]);
    match tail[2].0["error"]["code"].as_str().unwrap() {
        "cancelled" => assert_eq!(saved.0["blocks"][0]["data"]["state"]["reason"]["code"], "stopped"),
        "interrupt_expired" => assert_eq!(saved.0["blocks"][0]["data"]["state"]["status"], "expired"),
        code => panic!("unexpected terminal error code: {code}"),
    }
    assert_eq!(calls.authorized.load(Ordering::SeqCst), 0);
    assert_eq!(calls.executed.load(Ordering::SeqCst), 0);
}
