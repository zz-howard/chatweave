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

const SCOPE: &str = "scope_weather";
const NOW: &str = "2026-10-26T09:31:00Z";

#[derive(Clone)]
struct Ctx {
    scope: String,
    member: String,
}

fn context(member: &str) -> Ctx {
    Ctx {
        scope: SCOPE.into(),
        member: member.into(),
    }
}

#[derive(Default)]
struct Counts {
    authorize: AtomicUsize,
    execute: AtomicUsize,
}

struct Handler {
    target: &'static str,
    destructive: bool,
    deny: bool,
    execution_error: Option<(&'static str, bool)>,
    calls: Arc<Counts>,
}

#[async_trait]
impl ActionHandler<Ctx> for Handler {
    fn target(&self) -> &'static str {
        self.target
    }

    fn accepts(&self) -> &'static [ActionType] {
        &[ActionType::ChoiceSelect, ActionType::ConfirmationRespond]
    }

    fn destructive(&self) -> bool {
        self.destructive
    }

    async fn authorize(&self, _: &Ctx, _: &ResolvedAction) -> Result<(), ActionError> {
        self.calls.authorize.fetch_add(1, Ordering::SeqCst);
        if self.deny {
            Err(ActionError::forbidden())
        } else {
            Ok(())
        }
    }

    async fn execute(&self, _: &Ctx, _: ResolvedAction) -> Result<ActionOutcome, ActionError> {
        self.calls.execute.fetch_add(1, Ordering::SeqCst);
        tokio::task::yield_now().await;
        match self.execution_error {
            Some((code, retryable)) => Err(ActionError {
                code: code.into(),
                message: "暂时无法完成操作".into(),
                retryable,
            }),
            None => Ok(ActionOutcome::default()),
        }
    }
}

fn choice(target: &str) -> Message {
    Message(json!({
        "id":"msg_weather","protocolVersion":"0.1","conversationId":"conv_weather",
        "role":"assistant","status":"complete","rev":1,
        "createdAt":"2026-10-26T09:30:00Z","fallbackText":"请选择城市",
        "blocks":[{"id":"b1","type":"choice","schemaVersion":1,"fallbackText":"请选择城市",
          "data":{"prompt":"查哪个城市？","selection":"single",
          "options":[{"id":"bj","label":"北京"},{"id":"sh","label":"上海"}],
          "action":{"type":"choice.select","target":target},"state":{"status":"open"}}}]
    }))
}

fn request(id: &str, target: &str, city: &str) -> ActionRequest {
    ActionRequest(json!({
        "id":id,"protocolVersion":"0.1","type":"choice.select","target":target,
        "context":{"conversationId":"conv_weather","messageId":"msg_weather","blockId":"b1"},
        "payload":{"selected":[city]}
    }))
}

fn store() -> MemoryActionStore<Ctx> {
    MemoryActionStore::new(|ctx: &Ctx| ctx.scope.clone())
        .with_clock(|| NOW.to_owned())
        .with_resolver(|ctx: &Ctx| Some(ctx.member.clone()))
}

fn registry(handler: Handler) -> ActionRegistry<Ctx> {
    let mut registry = ActionRegistry::default();
    registry.register(Arc::new(handler)).unwrap();
    registry
}

#[tokio::test]
async fn execution_errors_are_failed_results_preserving_code_and_retryability() {
    for (code, retryable) in [
        ("internal", false),
        ("unavailable", true),
        ("conflict", false),
    ] {
        let calls = Arc::new(Counts::default());
        let registry = registry(Handler {
            target: "weather.select",
            destructive: false,
            deny: false,
            execution_error: Some((code, retryable)),
            calls: calls.clone(),
        });
        let store = store();
        let seed = choice("weather.select");
        store.insert_message(SCOPE, seed.clone()).await.unwrap();
        let result = registry
            .dispatch(
                &context("member_weather_a"),
                request("action_failure", "weather.select", "bj"),
                &store,
            )
            .await
            .unwrap();
        assert_eq!(result.0["status"], "failed", "execute error {code}");
        assert_eq!(result.0["error"]["code"], code);
        assert_eq!(
            result.0["error"]["retryable"].as_bool().unwrap_or(false),
            retryable
        );
        assert!(result.0.get("patches").is_none());
        assert!(result.0.get("resume").is_none());
        assert_ne!(result.0["replayed"], true);
        assert_eq!(
            store.load_message(SCOPE, "msg_weather").await.unwrap(),
            seed
        );
        assert_eq!(calls.authorize.load(Ordering::SeqCst), 1);
        assert_eq!(calls.execute.load(Ordering::SeqCst), 1);
        Validator::default()
            .validate(DocumentKind::ActionResult, &result.0)
            .unwrap();
        // Negative control: returning every handler error as rejected loses the
        // execution-stage distinction and fails the status assertion above.
    }
}

#[tokio::test]
async fn authorization_errors_remain_rejections_and_do_not_execute_or_resolve() {
    let calls = Arc::new(Counts::default());
    let registry = registry(Handler {
        target: "weather.select",
        destructive: false,
        deny: true,
        execution_error: None,
        calls: calls.clone(),
    });
    let store = store();
    let seed = choice("weather.select");
    store.insert_message(SCOPE, seed.clone()).await.unwrap();
    let result = registry
        .dispatch(
            &context("member_weather_a"),
            request("action_forbidden", "weather.select", "bj"),
            &store,
        )
        .await
        .unwrap();
    assert_eq!(result.0["status"], "rejected");
    assert_eq!(result.0["error"]["code"], "forbidden");
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 1);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 0);
    assert_eq!(
        store.load_message(SCOPE, "msg_weather").await.unwrap(),
        seed
    );
}

#[tokio::test]
async fn a_forged_choice_cannot_bypass_a_destructive_handler_confirmation_requirement() {
    let calls = Arc::new(Counts::default());
    let registry = registry(Handler {
        target: "todo.delete",
        destructive: true,
        deny: false,
        execution_error: None,
        calls: calls.clone(),
    });
    let store = store();
    let seed = choice("todo.delete");
    store.insert_message(SCOPE, seed.clone()).await.unwrap();
    let valid_wire = request("action_forged", "todo.delete", "bj");
    Validator::default()
        .validate(DocumentKind::ActionRequest, &valid_wire.0)
        .unwrap();
    let result = registry
        .dispatch(&context("member_weather_a"), valid_wire.clone(), &store)
        .await
        .unwrap();
    assert_eq!(result.0["status"], "rejected");
    assert_eq!(result.0["error"]["code"], "confirmation_required");
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 0);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 0);
    assert_eq!(
        store.load_message(SCOPE, "msg_weather").await.unwrap(),
        seed
    );

    let mut injected = valid_wire;
    injected.0["requiresConfirmation"] = json!(true);
    assert!(
        registry
            .dispatch(&context("member_weather_a"), injected, &store)
            .await
            .is_err()
    );
    let mut invalid_declaration = seed.clone();
    invalid_declaration.0["blocks"][0]["data"]["action"]["requiresConfirmation"] = json!(true);
    assert!(
        Validator::default()
            .validate(DocumentKind::Message, &invalid_declaration.0)
            .is_err()
    );
    assert_eq!(calls.execute.load(Ordering::SeqCst), 0);
    // Neither a well-formed forged request nor an extra client-supplied flag
    // can turn the persisted choice into a destructive confirmation block.
}

#[tokio::test]
async fn concurrent_group_answers_record_the_winner_and_return_that_identity_to_the_loser() {
    let calls = Arc::new(Counts::default());
    let registry = registry(Handler {
        target: "weather.select",
        destructive: false,
        deny: false,
        execution_error: None,
        calls: calls.clone(),
    });
    let store = store();
    store
        .insert_message(SCOPE, choice("weather.select"))
        .await
        .unwrap();
    let member_a = context("member_weather_a");
    let member_b = context("member_weather_b");
    let barrier = Barrier::new(2);
    let first = async {
        barrier.wait().await;
        registry
            .dispatch(
                &member_a,
                request("action_member_a", "weather.select", "bj"),
                &store,
            )
            .await
            .unwrap()
    };
    let second = async {
        barrier.wait().await;
        registry
            .dispatch(
                &member_b,
                request("action_member_b", "weather.select", "sh"),
                &store,
            )
            .await
            .unwrap()
    };
    let (first, second) = tokio::join!(first, second);
    let results = [first.0, second.0];
    assert_eq!(
        results
            .iter()
            .filter(|result| result["status"] == "completed")
            .count(),
        1
    );
    let winner = results
        .iter()
        .find(|result| result["status"] == "completed")
        .unwrap();
    let loser = results
        .iter()
        .find(|result| result["status"] == "rejected")
        .unwrap();
    let (member, selected) = if winner["actionId"] == "action_member_a" {
        ("member_weather_a", "bj")
    } else {
        assert_eq!(winner["actionId"], "action_member_b");
        ("member_weather_b", "sh")
    };
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    let state = &saved.0["blocks"][0]["data"]["state"];
    assert_eq!(state["resolvedBy"], member);
    assert_eq!(state["resolvedAt"], NOW);
    assert_eq!(state["selected"], json!([selected]));
    assert_eq!(loser["error"]["code"], "already_resolved");
    assert_eq!(loser["patches"][0]["patch"]["data"]["state"], *state);
    assert_eq!(winner["patches"][0]["patch"]["data"]["state"], *state);
    assert_eq!(loser["patches"][0]["rev"], 2);
    assert_eq!(saved.0["rev"], 2);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 1);
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn interrupt_answer_records_the_host_resolved_member_in_the_stream_state() {
    let calls = Arc::new(Counts::default());
    let registry = registry(Handler {
        target: "todo.delete",
        destructive: true,
        deny: false,
        execution_error: None,
        calls: calls.clone(),
    });
    let store = store();
    let seed: Value = serde_json::from_str(include_str!(
        "../../../../fixtures/conformance/streams/24-interrupt-paused.expected.json"
    ))
    .unwrap();
    store.insert_message(SCOPE, Message(seed)).await.unwrap();
    let request = ActionRequest(json!({
        "id":"action_member_cancel","protocolVersion":"0.1","type":"confirmation.respond",
        "target":"todo.delete","context":{"messageId":"msg_weather","blockId":"b1"},
        "payload":{"outcome":"cancel"}
    }));
    let result = registry
        .dispatch(&context("member_weather_b"), request, &store)
        .await
        .unwrap();
    assert_eq!(result.0["status"], "accepted");
    assert!(result.0.get("patches").is_none());
    let saved = store.load_message(SCOPE, "msg_weather").await.unwrap();
    assert_eq!(
        saved.0["blocks"][0]["data"]["state"]["resolvedBy"],
        "member_weather_b"
    );
    assert_eq!(saved.0["blocks"][0]["data"]["state"]["outcome"], "cancel");
    let service = store.resume_service();
    let events = service
        .log
        .read_after("msg_weather", 6)
        .await
        .unwrap()
        .events;
    assert_eq!(events.len(), 2);
    assert_eq!(
        events[0].0["patch"]["data"]["state"]["resolvedBy"],
        "member_weather_b"
    );
    assert_eq!(events[0].seq(), Some(7));
    assert_eq!(events[1].event_type(), "message.resumed");
    assert_eq!(events[1].seq(), Some(8));
    assert_eq!(calls.execute.load(Ordering::SeqCst), 0);
}
