use async_trait::async_trait;
use chatweave_server::action::{
    ActionError, ActionHandler, ActionOutcome, ActionRegistry, ActionType, MemoryActionStore,
    ResolvedAction,
};
use chatweave_server::protocol::{ActionRequest, Message};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::Barrier;

#[derive(Default)]
struct Counts {
    authorized: AtomicUsize,
    executed: AtomicUsize,
}

struct ChoiceHandler(Arc<Counts>);

#[async_trait]
impl ActionHandler<String> for ChoiceHandler {
    fn target(&self) -> &'static str {
        "weather.select"
    }

    fn accepts(&self) -> &'static [ActionType] {
        &[ActionType::ChoiceSelect]
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
        // Give a competing request a deterministic opportunity to enter while
        // the first execute is in progress. A CAS performed only after execute
        // would allow both side effects and fail the counter assertion below.
        tokio::task::yield_now().await;
        Ok(ActionOutcome::default())
    }
}

fn seed() -> Message {
    Message(json!({
        "id":"msg_weather","protocolVersion":"0.1","conversationId":"conv_weather",
        "role":"assistant","status":"complete","rev":1,
        "createdAt":"2026-10-26T09:30:00Z","fallbackText":"请选择北京或上海",
        "blocks":[{"id":"b1","type":"choice","schemaVersion":1,
          "fallbackText":"请选择北京或上海","data":{
            "prompt":"查哪个城市？","selection":"single",
            "options":[{"id":"bj","label":"北京"},{"id":"sh","label":"上海"}],
            "action":{"type":"choice.select","target":"weather.select"},
            "state":{"status":"open"}}}]
    }))
}

fn request(id: &str, selected: &str) -> ActionRequest {
    ActionRequest(json!({
        "id":id,"protocolVersion":"0.1","type":"choice.select","target":"weather.select",
        "context":{"conversationId":"conv_weather","messageId":"msg_weather","blockId":"b1"},
        "payload":{"selected":[selected]}
    }))
}

async fn setup() -> (ActionRegistry<String>, MemoryActionStore<String>, Arc<Counts>) {
    let counts = Arc::new(Counts::default());
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(ChoiceHandler(counts.clone()))).unwrap();
    let store = MemoryActionStore::new(|ctx: &String| ctx.clone())
        .with_clock(|| "2026-10-26T09:31:00Z".to_owned());
    store.insert_message("scope_weather", seed()).await.unwrap();
    (registry, store, counts)
}

#[tokio::test]
async fn simultaneous_different_answers_execute_once_and_return_the_recorded_winner() {
    let (registry, store, counts) = setup().await;
    let barrier = Barrier::new(2);
    let ctx = "scope_weather".to_owned();
    let left = async {
        barrier.wait().await;
        registry.dispatch(&ctx, request("action_left", "bj"), &store).await.unwrap()
    };
    let right = async {
        barrier.wait().await;
        registry.dispatch(&ctx, request("action_right", "sh"), &store).await.unwrap()
    };
    let (left, right) = tokio::join!(left, right);
    let results = [left.0, right.0];
    assert_eq!(results.iter().filter(|result| result["status"] == "completed").count(), 1);
    let loser = results.iter().find(|result| result["status"] == "rejected").unwrap();
    assert_eq!(loser["error"]["code"], "already_resolved");
    let saved = store.load_message("scope_weather", "msg_weather").await.unwrap();
    let recorded = &saved.0["blocks"][0]["data"]["state"];
    assert_eq!(saved.0["rev"], 2);
    assert_eq!(recorded["status"], "resolved");
    assert_eq!(loser["patches"][0]["rev"], 2);
    assert_eq!(loser["patches"][0]["patch"]["data"]["state"], *recorded);
    let winner = results.iter().find(|result| result["status"] == "completed").unwrap();
    assert_eq!(winner["patches"][0]["patch"]["data"]["state"], *recorded);
    assert_eq!(counts.executed.load(Ordering::SeqCst), 1);
    assert_eq!(counts.authorized.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn simultaneous_same_id_requests_authorize_twice_but_execute_and_commit_once() {
    let (registry, store, counts) = setup().await;
    let barrier = Barrier::new(2);
    let ctx = "scope_weather".to_owned();
    let request = request("action_same", "bj");
    let first = async {
        barrier.wait().await;
        registry.dispatch(&ctx, request.clone(), &store).await.unwrap()
    };
    let second = async {
        barrier.wait().await;
        registry.dispatch(&ctx, request.clone(), &store).await.unwrap()
    };
    let (first, second) = tokio::join!(first, second);
    assert_eq!(first.0["status"], "completed");
    assert_eq!(second.0["status"], "completed");
    assert_eq!([&first.0, &second.0].iter().filter(|result| result["replayed"] == true).count(), 1);
    assert_eq!(first.0["patches"], second.0["patches"]);
    let saved = store.load_message("scope_weather", "msg_weather").await.unwrap();
    assert_eq!(saved.0["rev"], 2);
    assert_eq!(saved.0["blocks"][0]["data"]["state"]["selected"], json!(["bj"]));
    assert_eq!(counts.executed.load(Ordering::SeqCst), 1);
    assert_eq!(counts.authorized.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn same_action_id_in_a_different_scope_does_not_replay_another_scopes_result() {
    let (registry, store, counts) = setup().await;
    store.insert_message("scope_other", seed()).await.unwrap();
    let first = registry.dispatch(&"scope_weather".to_owned(), request("action_same", "bj"), &store).await.unwrap();
    let second = registry.dispatch(&"scope_other".to_owned(), request("action_same", "sh"), &store).await.unwrap();
    for result in [&first.0, &second.0] {
        assert_eq!(result["status"], "completed");
        assert_ne!(result["replayed"], true);
    }
    let first_saved = store.load_message("scope_weather", "msg_weather").await.unwrap();
    let second_saved = store.load_message("scope_other", "msg_weather").await.unwrap();
    assert_eq!(first_saved.0["blocks"][0]["data"]["state"]["selected"], json!(["bj"]));
    assert_eq!(second_saved.0["blocks"][0]["data"]["state"]["selected"], json!(["sh"]));
    assert_eq!(counts.executed.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn an_action_id_cannot_be_rebound_to_another_message_in_the_same_scope() {
    let (registry, store, counts) = setup().await;
    let mut other = seed();
    other.0["id"] = json!("msg_other");
    store.insert_message("scope_weather", other).await.unwrap();
    registry.dispatch(&"scope_weather".to_owned(), request("action_bound", "bj"), &store).await.unwrap();
    let mut changed = request("action_bound", "bj");
    changed.0["context"]["messageId"] = json!("msg_other");
    let result = registry.dispatch(&"scope_weather".to_owned(), changed, &store).await.unwrap();
    assert_eq!(result.0["status"], "rejected");
    assert_eq!(result.0["error"]["code"], "invalid_request");
    assert_eq!(counts.executed.load(Ordering::SeqCst), 1);
    let untouched: Value = store.load_message("scope_weather", "msg_other").await.unwrap().0;
    assert_eq!(untouched["rev"], 1);
    assert_eq!(untouched["blocks"][0]["data"]["state"]["status"], "open");
}
