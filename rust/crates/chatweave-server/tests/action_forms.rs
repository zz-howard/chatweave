use async_trait::async_trait;
use chatweave_server::action::{
    ActionError, ActionHandler, ActionOutcome, ActionRegistry, ActionType, MemoryActionStore,
    ResolvedAction,
};
use chatweave_server::protocol::{ActionRequest, DocumentKind, Message, Validator};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

const SCOPE: &str = "scope_weather";
const NOW: &str = "2026-10-26T09:31:00Z";

struct FormHandler(Arc<AtomicUsize>);

#[async_trait]
impl ActionHandler<String> for FormHandler {
    fn target(&self) -> &'static str {
        "todo.create"
    }

    fn accepts(&self) -> &'static [ActionType] {
        &[ActionType::FormSubmit]
    }

    async fn authorize(&self, _: &String, _: &ResolvedAction) -> Result<(), ActionError> {
        Ok(())
    }

    async fn execute(&self, _: &String, _: ResolvedAction) -> Result<ActionOutcome, ActionError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Ok(ActionOutcome::default())
    }
}

fn field(kind: &str, required: bool) -> Value {
    let mut field = json!({"key":"answer","label":"待办信息","type":kind,"required":required});
    match kind {
        "text" => field["maxLength"] = json!(5),
        "multiline_text" => field["maxLength"] = json!(8),
        "number" => {
            field["min"] = json!(0);
            field["max"] = json!(100);
        }
        "integer" => {
            field["min"] = json!(1);
            field["max"] = json!(3);
        }
        "single_select" | "multi_select" => {
            field["options"] = json!([
                {"id":"p1","label":"浇花"},
                {"id":"p2","label":"散步"}
            ]);
        }
        _ => {}
    }
    field
}

fn seed(field: Value) -> Message {
    Message(json!({
        "id":"msg_form","protocolVersion":"0.1","conversationId":"conv_weather",
        "role":"assistant","status":"complete","rev":1,
        "createdAt":"2026-10-26T09:30:00Z","fallbackText":"请补充待办信息",
        "blocks":[{"id":"b1","type":"form_intent","schemaVersion":1,
          "fallbackText":"请补充待办信息","data":{
            "fields":[field],"action":{"type":"form.submit","target":"todo.create"},
            "state":{"status":"open"}}}]
    }))
}

fn request(id: &str, values: Value) -> ActionRequest {
    ActionRequest(json!({
        "id":id,"protocolVersion":"0.1","type":"form.submit","target":"todo.create",
        "context":{"conversationId":"conv_weather","messageId":"msg_form","blockId":"b1"},
        "payload":{"values":values}
    }))
}

async fn setup(
    field: Value,
) -> (
    ActionRegistry<String>,
    MemoryActionStore<String>,
    Arc<AtomicUsize>,
) {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut registry = ActionRegistry::default();
    registry
        .register(Arc::new(FormHandler(calls.clone())))
        .unwrap();
    let store = MemoryActionStore::new(|ctx: &String| ctx.clone()).with_clock(|| NOW.to_owned());
    store.insert_message(SCOPE, seed(field)).await.unwrap();
    (registry, store, calls)
}

fn good_values() -> Vec<(&'static str, Vec<Value>)> {
    vec![
        ("text", vec![json!("浇花"), json!("12345")]),
        (
            "multiline_text",
            vec![json!("浇花\n散步"), json!("12345678")],
        ),
        ("number", vec![json!(0), json!(23.5), json!(100)]),
        ("integer", vec![json!(1), json!(2.0), json!(3)]),
        ("date", vec![json!("2024-02-29"), json!("2026-10-26")]),
        (
            "datetime",
            vec![
                json!("2026-10-26T09:30:00Z"),
                json!("2026-10-26T17:30:00+08:00"),
            ],
        ),
        ("boolean", vec![json!(false), json!(true)]),
        ("single_select", vec![json!("p1"), json!("p2")]),
        (
            "multi_select",
            vec![json!([]), json!(["p1"]), json!(["p1", "p2"])],
        ),
    ]
}

fn bad_values() -> Vec<(&'static str, Vec<Value>)> {
    vec![
        ("text", vec![json!("123456"), json!(42), json!(true)]),
        (
            "multiline_text",
            vec![json!("123456789"), json!(false), json!(3)],
        ),
        (
            "number",
            vec![json!(-0.1), json!(100.1), json!("24"), json!(true)],
        ),
        (
            "integer",
            vec![json!(0), json!(4), json!(1.5), json!("2"), json!(false)],
        ),
        (
            "date",
            vec![json!("2026-02-29"), json!("2026-13-01"), json!(42)],
        ),
        (
            "datetime",
            vec![
                json!("2026-10-26T09:30:00"),
                json!("2026-13-26T09:30:00Z"),
                json!("2026-10-26"),
                json!(true),
            ],
        ),
        ("boolean", vec![json!("true"), json!(1)]),
        (
            "single_select",
            vec![json!("missing"), json!(1), json!(["p1"])],
        ),
        (
            "multi_select",
            vec![json!("p1"), json!(["missing"]), json!(["p1", "p1"])],
        ),
    ]
}

#[tokio::test]
async fn all_nine_declared_form_types_accept_their_valid_values_and_boundaries() {
    let definitions = good_values();
    assert_eq!(definitions.len(), 9);
    let validator = Validator::default();
    for (kind, values) in definitions {
        assert!(!values.is_empty(), "no good-value cases for {kind}");
        for value in values {
            let (registry, store, calls) = setup(field(kind, true)).await;
            let values = json!({"answer":value});
            let result = registry
                .dispatch(
                    &SCOPE.to_owned(),
                    request("action_form_valid", values.clone()),
                    &store,
                )
                .await
                .unwrap();
            assert_eq!(result.0["status"], "completed", "{kind}: {values}");
            assert_eq!(result.0["patches"][0]["rev"], 2);
            assert_eq!(
                result.0["patches"][0]["patch"]["data"]["state"]["values"],
                values
            );
            let saved = store.load_message(SCOPE, "msg_form").await.unwrap();
            assert_eq!(saved.0["blocks"][0]["data"]["state"]["values"], values);
            assert_eq!(saved.0["blocks"][0]["data"]["state"]["resolvedAt"], NOW);
            assert_eq!(saved.0["rev"], 2);
            assert_eq!(calls.load(Ordering::SeqCst), 1);
            validator.validate(DocumentKind::Message, &saved.0).unwrap();
        }
    }
}

#[tokio::test]
async fn all_nine_form_types_reject_invalid_types_ranges_dates_options_and_duplicates() {
    let definitions = bad_values();
    assert_eq!(definitions.len(), 9);
    for (kind, values) in definitions {
        let (registry, store, calls) = setup(field(kind, true)).await;
        let original = store.load_message(SCOPE, "msg_form").await.unwrap();
        assert!(!values.is_empty(), "no bad-value cases for {kind}");
        for (index, value) in values.into_iter().enumerate() {
            let request = request(&format!("action_bad_{index}"), json!({"answer":value}));
            // These are legal ActionRequest objects. Rejection must come from
            // comparison with the server's field declaration, not JSON shape.
            Validator::default()
                .validate(DocumentKind::ActionRequest, &request.0)
                .unwrap();
            let result = registry
                .dispatch(&SCOPE.to_owned(), request, &store)
                .await
                .unwrap();
            assert_eq!(result.0["status"], "rejected", "{kind}: {value}");
            assert_eq!(
                result.0["error"]["code"], "invalid_payload",
                "{kind}: {value}"
            );
            assert!(result.0.get("patches").is_none());
            assert_eq!(
                store.load_message(SCOPE, "msg_form").await.unwrap(),
                original
            );
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0, "{kind}");
    }
}

#[tokio::test]
async fn every_required_type_rejects_missing_and_null_values() {
    for (kind, _) in good_values() {
        let (registry, store, calls) = setup(field(kind, true)).await;
        for (index, values) in [json!({}), json!({"answer":null})].into_iter().enumerate() {
            let result = registry
                .dispatch(
                    &SCOPE.to_owned(),
                    request(&format!("action_required_{index}"), values),
                    &store,
                )
                .await
                .unwrap();
            assert_eq!(result.0["status"], "rejected", "{kind}");
            assert_eq!(result.0["error"]["code"], "invalid_payload", "{kind}");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(
            store.load_message(SCOPE, "msg_form").await.unwrap().0["rev"],
            1
        );
    }
}

#[tokio::test]
async fn optional_fields_may_be_omitted_or_null_but_unknown_fields_are_always_rejected() {
    for (kind, _) in good_values() {
        for values in [json!({}), json!({"answer":null})] {
            let (registry, store, calls) = setup(field(kind, false)).await;
            let unknown = registry
                .dispatch(
                    &SCOPE.to_owned(),
                    request("action_unknown", json!({"extra":"浇花"})),
                    &store,
                )
                .await
                .unwrap();
            assert_eq!(unknown.0["error"]["code"], "invalid_payload", "{kind}");
            assert_eq!(calls.load(Ordering::SeqCst), 0);
            let accepted = registry
                .dispatch(
                    &SCOPE.to_owned(),
                    request("action_optional", values.clone()),
                    &store,
                )
                .await
                .unwrap();
            assert_eq!(accepted.0["status"], "completed", "{kind}");
            assert_eq!(
                accepted.0["patches"][0]["patch"]["data"]["state"]["values"],
                values
            );
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        }
    }
}

#[tokio::test]
async fn text_max_length_counts_unicode_characters_instead_of_utf8_bytes() {
    let mut definition = field("text", true);
    definition["maxLength"] = json!(2);
    let (registry, store, calls) = setup(definition).await;
    let too_long = registry
        .dispatch(
            &SCOPE.to_owned(),
            request("action_text_long", json!({"answer":"天气好"})),
            &store,
        )
        .await
        .unwrap();
    assert_eq!(too_long.0["error"]["code"], "invalid_payload");
    let exact = registry
        .dispatch(
            &SCOPE.to_owned(),
            request("action_text_exact", json!({"answer":"天气"})),
            &store,
        )
        .await
        .unwrap();
    assert_eq!(exact.0["status"], "completed");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
