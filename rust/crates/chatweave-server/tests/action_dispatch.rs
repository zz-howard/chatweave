use async_trait::async_trait;
use chatweave_server::action::{
    ActionError, ActionHandler, ActionOutcome, ActionRegistry, ActionType, MemoryActionStore,
    ResolvedAction,
};
use chatweave_server::protocol::{ActionRequest, DocumentKind, Message, Validator};
use chatweave_server::stream::RecordedAnswer;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const NOW: &str = "2026-10-26T09:31:00Z";
const SCOPE: &str = "scope_weather";
const SCENARIOS: &str = include_str!("../../../../fixtures/conformance/action-scenarios.json");

#[derive(Default)]
struct Calls {
    authorize: AtomicUsize,
    execute: AtomicUsize,
    decisions: Vec<bool>,
    trace: Mutex<Vec<&'static str>>,
}

struct Handler {
    target: &'static str,
    destructive: bool,
    calls: Arc<Calls>,
}

#[async_trait]
impl ActionHandler<String> for Handler {
    fn target(&self) -> &'static str {
        self.target
    }

    fn accepts(&self) -> &'static [ActionType] {
        &[
            ActionType::ChoiceSelect,
            ActionType::ConfirmationRespond,
            ActionType::FormSubmit,
        ]
    }

    fn destructive(&self) -> bool {
        self.destructive
    }

    async fn authorize(&self, _: &String, _: &ResolvedAction) -> Result<(), ActionError> {
        self.calls.trace.lock().unwrap().push("authorize");
        let index = self.calls.authorize.fetch_add(1, Ordering::SeqCst);
        if self.calls.decisions.get(index).copied().unwrap_or(true) {
            Ok(())
        } else {
            Err(ActionError::forbidden())
        }
    }

    async fn execute(&self, _: &String, _: ResolvedAction) -> Result<ActionOutcome, ActionError> {
        self.calls.trace.lock().unwrap().push("execute");
        self.calls.execute.fetch_add(1, Ordering::SeqCst);
        Ok(ActionOutcome::default())
    }
}

fn registry(calls: Arc<Calls>) -> ActionRegistry<String> {
    let mut registry = ActionRegistry::default();
    for (target, destructive) in [
        ("weather.select", false),
        ("weather.other", false),
        ("todo.create", false),
        ("todo.delete", true),
    ] {
        registry
            .register(Arc::new(Handler {
                target,
                destructive,
                calls: calls.clone(),
            }))
            .unwrap();
    }
    registry
}

fn store() -> MemoryActionStore<String> {
    MemoryActionStore::new(|ctx: &String| ctx.clone()).with_clock(|| NOW.to_owned())
}

fn scenarios() -> Vec<Value> {
    let document: Value = serde_json::from_str(SCENARIOS).unwrap();
    assert_eq!(document["formatVersion"], 1);
    document["scenarios"].as_array().unwrap().clone()
}

fn normal_seed() -> Value {
    scenarios()
        .into_iter()
        .find(|scenario| scenario["name"] == "normal-answer")
        .unwrap()["seedMessage"]
        .clone()
}

fn normal_request() -> Value {
    scenarios()
        .into_iter()
        .find(|scenario| scenario["name"] == "normal-answer")
        .unwrap()["requests"][0]
        .clone()
}

// Error prose is deliberately not a protocol constant. All other wire fields,
// including current-state patches and revision numbers, must match exactly.
fn without_error_prose(mut value: Value) -> Value {
    if let Some(error) = value.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    value
}

#[tokio::test]
async fn every_ordered_action_fixture_is_executed_and_checked() {
    let fixtures = scenarios();
    assert_eq!(
        fixtures.len(),
        28,
        "the full promised scenario inventory must run"
    );
    let mut exercised = BTreeSet::new();
    let validator = Validator::default();
    for scenario in fixtures {
        let name = scenario["name"].as_str().unwrap();
        assert!(
            exercised.insert(name.to_owned()),
            "duplicate scenario: {name}"
        );
        let decisions = scenario["authorizeDecisions"]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .map(|value| value.as_bool().unwrap())
                    .collect()
            })
            .unwrap_or_default();
        let calls = Arc::new(Calls {
            decisions,
            ..Calls::default()
        });
        let registry = registry(calls.clone());
        let store = store();
        let ctx = SCOPE.to_owned();
        let seed = Message(scenario["seedMessage"].clone());
        store.insert_message(SCOPE, seed.clone()).await.unwrap();
        if let Some(payload) = scenario.get("concurrentAnswer") {
            store
                .stream(SCOPE, seed.id())
                .await
                .expect("a paused fixture must restore its stream")
                .resume(RecordedAnswer {
                    interrupt_id: seed.0["interrupt"]["id"].as_str().unwrap().into(),
                    payload: payload.clone(),
                    resolved_at: NOW.into(),
                    resolved_by: None,
                })
                .await
                .unwrap();
        }
        let requests = scenario["requests"].as_array().unwrap();
        let results = scenario["results"].as_array().unwrap();
        assert!(!requests.is_empty(), "empty scenario: {name}");
        assert_eq!(requests.len(), results.len(), "scenario: {name}");
        for (request, expected) in requests.iter().zip(results) {
            validator
                .validate(DocumentKind::ActionRequest, request)
                .unwrap();
            let actual = registry
                .dispatch(&ctx, ActionRequest(request.clone()), &store)
                .await
                .unwrap_or_else(|error| panic!("{name}: {error}"));
            validator
                .validate(DocumentKind::ActionResult, &actual.0)
                .unwrap();
            assert_eq!(
                without_error_prose(actual.0),
                without_error_prose(expected.clone()),
                "scenario: {name}"
            );
        }
        let actual = store.load_message(SCOPE, seed.id()).await.unwrap();
        assert_eq!(actual.0, scenario["expectedMessage"], "scenario: {name}");
        // normal-answer is the sole early fixture without an explicit count.
        let expected_execute = scenario["executeCount"].as_u64().unwrap_or_else(|| {
            assert_eq!(name, "normal-answer");
            1
        });
        assert_eq!(
            calls.execute.load(Ordering::SeqCst) as u64,
            expected_execute,
            "scenario: {name}"
        );
        if let Some(decisions) = scenario["authorizeDecisions"].as_array() {
            assert_eq!(
                calls.authorize.load(Ordering::SeqCst),
                decisions.len(),
                "scenario: {name}"
            );
        }
    }
    assert_eq!(exercised.len(), 28);
}

#[tokio::test]
async fn revoked_permission_is_checked_before_a_successful_receipt_is_replayed() {
    let calls = Arc::new(Calls {
        decisions: vec![true, false],
        ..Calls::default()
    });
    let registry = registry(calls.clone());
    let store = store();
    store
        .insert_message(SCOPE, Message(normal_seed()))
        .await
        .unwrap();
    let request = ActionRequest(normal_request());
    let first = registry
        .dispatch(&SCOPE.to_owned(), request.clone(), &store)
        .await
        .unwrap();
    assert_eq!(first.0["status"], "completed");
    let second = registry
        .dispatch(&SCOPE.to_owned(), request, &store)
        .await
        .unwrap();
    assert_eq!(second.0["status"], "rejected");
    assert_eq!(second.0["error"]["code"], "forbidden");
    assert_ne!(second.0["replayed"], true);
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 2);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 1);
    assert_eq!(
        *calls.trace.lock().unwrap(),
        ["authorize", "execute", "authorize"]
    );
    // Negative control: moving receipt replay above authorize makes the second
    // request succeed and removes the final trace entry, so this test fails.
}

#[tokio::test]
async fn an_open_but_expired_block_is_closed_before_execution_and_returns_current_state() {
    let calls = Arc::new(Calls::default());
    let registry = registry(calls.clone());
    let store = store();
    let mut seed = normal_seed();
    seed["blocks"][0]["data"]["action"]["expiresAt"] = json!("2000-01-01T00:00:00Z");
    store.insert_message(SCOPE, Message(seed)).await.unwrap();
    let result = registry
        .dispatch(&SCOPE.to_owned(), ActionRequest(normal_request()), &store)
        .await
        .unwrap();
    assert_eq!(result.0["status"], "rejected");
    assert_eq!(result.0["error"]["code"], "expired");
    assert_eq!(result.0["patches"][0]["rev"], 2);
    assert_eq!(
        result.0["patches"][0]["patch"]["data"]["state"]["status"],
        "expired"
    );
    assert_eq!(
        store.load_message(SCOPE, "msg_weather").await.unwrap().0["rev"],
        2
    );
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 0);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn scope_checks_hide_both_the_block_and_its_saved_receipt() {
    let calls = Arc::new(Calls::default());
    let registry = registry(calls.clone());
    let store = store();
    store
        .insert_message(SCOPE, Message(normal_seed()))
        .await
        .unwrap();
    let request = ActionRequest(normal_request());
    assert_eq!(
        registry
            .dispatch(&SCOPE.to_owned(), request.clone(), &store)
            .await
            .unwrap()
            .0["status"],
        "completed"
    );
    let hidden = registry
        .dispatch(&"scope_other".to_owned(), request, &store)
        .await
        .unwrap();
    assert_eq!(hidden.0["status"], "rejected");
    assert_eq!(hidden.0["error"]["code"], "not_found");
    assert!(hidden.0.get("patches").is_none());
    assert!(hidden.0.get("replayed").is_none());
    assert_eq!(calls.execute.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn canonical_binding_ignores_client_timestamp_but_rejects_changed_payload() {
    let calls = Arc::new(Calls::default());
    let registry = registry(calls.clone());
    let store = store();
    store
        .insert_message(SCOPE, Message(normal_seed()))
        .await
        .unwrap();
    let mut request = normal_request();
    request["clientTs"] = json!("2026-10-26T09:30:01Z");
    registry
        .dispatch(&SCOPE.to_owned(), ActionRequest(request.clone()), &store)
        .await
        .unwrap();
    request["clientTs"] = json!("2026-10-26T09:30:02Z");
    let repeated = registry
        .dispatch(&SCOPE.to_owned(), ActionRequest(request.clone()), &store)
        .await
        .unwrap();
    assert_eq!(repeated.0["replayed"], true);
    request["payload"] = json!({"selected":["sh"]});
    let changed = registry
        .dispatch(&SCOPE.to_owned(), ActionRequest(request), &store)
        .await
        .unwrap();
    assert_eq!(changed.0["error"]["code"], "invalid_request");
    assert_ne!(changed.0["replayed"], true);
    assert_eq!(calls.execute.load(Ordering::SeqCst), 1);
    assert_eq!(calls.authorize.load(Ordering::SeqCst), 2);
}
