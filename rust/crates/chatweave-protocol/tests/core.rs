use chatweave_protocol::{
    Block, DocumentKind, FoldState, Limits, SchemaRegistry, StreamEvent, Validator, merge_patch,
};
use serde_json::{Value, json};

fn event(seq: u64, ty: &str, fields: Value) -> StreamEvent {
    let mut event = json!({"protocolVersion":"0.1","messageId":"message_1","seq":seq,"type":ty});
    merge_patch(&mut event, &fields);
    StreamEvent(event)
}
fn start() -> StreamEvent {
    event(
        1,
        "message.start",
        json!({"message":{"id":"message_1","role":"assistant","createdAt":"2026-10-26T09:30:00Z"}}),
    )
}
#[test]
fn invalid_event_does_not_mutate_state_and_replay_is_idempotent() {
    let mut state = FoldState::new();
    state.apply(start()).unwrap();
    let before = state.message().unwrap();
    assert!(
        state
            .apply(event(
                3,
                "block.start",
                json!({"blockId":"b1","index":0,"blockType":"markdown","schemaVersion":1})
            ))
            .is_err()
    );
    assert_eq!(state.last_seq(), 1);
    assert_eq!(state.message().unwrap(), before);
    state.apply(start()).unwrap();
    assert_eq!(state.message().unwrap(), before);
    state
        .apply(event(
            2,
            "x-weather.future",
            json!({"opaque":{"field":null}}),
        ))
        .unwrap();
    assert_eq!(state.last_seq(), 2);
    assert_eq!(state.message().unwrap().0["blocks"], json!([]));
}
#[test]
fn merge_patch_removes_null_and_replaces_arrays() {
    let mut value =
        json!({"data":{"keep":1,"remove":2,"items":[1,2]},"metadata":{"host":{"old":true}}});
    merge_patch(
        &mut value,
        &json!({"data":{"remove":null,"items":[3]},"metadata":null}),
    );
    assert_eq!(value, json!({"data":{"keep":1,"items":[3]}}));
}
#[test]
fn diagram_data_parses_nodes_and_preserves_optional_wire_fields() {
    use chatweave_protocol::BlockData;

    let value = json!({
        "title": "Message flow",
        "steps": [{"id": "source", "nodes": [{
            "label": "Client", "detail": "Sends a message", "icon": "smartphone",
            "highlight": false, "futureField": null
        }]}],
        "summary": "A message source"
    });
    let parsed = BlockData::parse("diagram", value.clone()).unwrap();
    let BlockData::Diagram(ref data) = parsed else {
        panic!("diagram must have typed data");
    };
    assert_eq!(data.steps[0].extra["id"], "source");
    assert_eq!(data.steps[0].nodes[0].label, "Client");
    assert_eq!(parsed.to_value().unwrap(), value);
    assert!(
        BlockData::parse(
            "diagram",
            json!({"steps": [{"id": "source", "nodes": [{"icon": "bot"}]}]})
        )
        .is_err()
    );
}
#[test]
fn diagram_defaults_and_group_ranges_use_wire_step_order() {
    let validator = Validator::default();
    let mut block = json!({
        "id": "diagram", "type": "diagram", "schemaVersion": 1,
        "fallbackText": "First then second",
        "data": {"steps": [
            {"nodes": [{"label": "First", "icon": "future-icon"}], "link": {}},
            {"nodes": [{"label": "Second"}], "link": {"arrow": "both"}}
        ]}
    });
    assert!(validator.validate(DocumentKind::Block, &block).is_ok());
    let parsed = Block(block.clone()).typed_data().unwrap().unwrap();
    assert_eq!(parsed.to_value().unwrap(), block["data"]);
    block["data"]["steps"][0]["id"] = json!("first");
    block["data"]["steps"][1]["id"] = json!("second");
    block["data"]["groups"] = json!([
        {"label": "First", "from": "first", "to": "first"},
        {"label": "Second", "from": "second", "to": "second"}
    ]);
    assert!(validator.validate(DocumentKind::Block, &block).is_ok());
    block["data"]["groups"][1]["from"] = json!("first");
    assert_eq!(
        validator
            .validate(DocumentKind::Block, &block)
            .unwrap_err()
            .code,
        "diagram_group_overlap"
    );
    block["data"]["groups"] = json!([{"label": "Reverse", "from": "second", "to": "first"}]);
    assert_eq!(
        validator
            .validate(DocumentKind::Block, &block)
            .unwrap_err()
            .code,
        "diagram_group_order"
    );
    block["data"]["groups"][0]["to"] = json!("missing");
    assert_eq!(
        validator
            .validate(DocumentKind::Block, &block)
            .unwrap_err()
            .code,
        "diagram_group_endpoint"
    );
    block["data"]["steps"][1]["id"] = json!("first");
    assert_eq!(
        validator
            .validate(DocumentKind::Block, &block)
            .unwrap_err()
            .code,
        "duplicate_diagram_step_id"
    );
}
#[test]
fn diagram_lifecycle_allows_absent_data_but_checks_present_data() {
    let validator = Validator::default();
    for status in ["pending", "error"] {
        let mut block = json!({
            "id": "diagram", "type": "diagram", "schemaVersion": 1,
            "status": status, "fallbackText": "Waiting for diagram"
        });
        assert!(validator.validate(DocumentKind::Block, &block).is_ok());
        assert!(Block(block.clone()).typed_data().unwrap().is_none());
        block["data"] = json!({});
        assert!(validator.validate(DocumentKind::Block, &block).is_err());
    }
}
#[test]
fn limits_measure_utf8_and_can_only_be_tightened() {
    let limits = Limits::default();
    assert!(
        limits
            .check_event(&json!({"delta":{"text":"晴".repeat(1365)}}))
            .is_ok()
    );
    assert!(
        limits
            .check_event(&json!({"delta":{"text":"晴".repeat(1366)}}))
            .is_err()
    );
    let mut tighter = limits.clone();
    tighter.max_delta_bytes = 3;
    assert!(tighter.validate_configuration().is_ok());
    assert!(
        tighter
            .check_event(&json!({"delta":{"text":"晴晴"}}))
            .is_err()
    );
    tighter.max_delta_bytes = limits.max_delta_bytes + 1;
    assert!(Validator::new(tighter, SchemaRegistry::default()).is_err());
}
#[test]
fn custom_registry_validates_without_external_retrieval() {
    let block = json!({"id":"b1","type":"x-todo.task_card","schemaVersion":1,"data":{"title":"Read a book"},"fallbackText":"Read a book"});
    assert!(
        Validator::default()
            .validate(DocumentKind::Block, &block)
            .is_err()
    );
    let mut registry = SchemaRegistry::default();
    registry.register("x-todo.task_card",1,json!({"type":"object","required":["title"],"additionalProperties":false,"properties":{"title":{"type":"string"}}})).unwrap();
    assert!(
        registry
            .register("x-todo.task_card", 1, json!({"type":"object"}))
            .is_err()
    );
    assert!(
        registry
            .register(
                "x-todo.external",
                1,
                json!({"$ref":"https://example.invalid/schema"})
            )
            .is_err()
    );
    let validator = Validator::new(Limits::default(), registry).unwrap();
    validator.validate(DocumentKind::Block, &block).unwrap();
    let mut invalid = block.clone();
    invalid["data"]["title"] = json!(5);
    assert!(validator.validate(DocumentKind::Block, &invalid).is_err());
    assert_eq!(
        Block(block.clone())
            .typed_data()
            .unwrap()
            .unwrap()
            .to_value()
            .unwrap(),
        block["data"]
    );
}
#[test]
fn final_time_is_only_taken_from_end_event() {
    for ts in [None, Some("2026-10-26T09:30:02+08:00")] {
        let mut state = FoldState::new();
        state.apply(start()).unwrap();
        let mut end = event(
            2,
            "message.end",
            json!({"status":"complete","fallbackText":"","blockCount":0,"rev":1}),
        );
        if let Some(ts) = ts {
            end.0["ts"] = ts.into();
        }
        state.apply(end).unwrap();
        assert_eq!(
            state
                .message()
                .unwrap()
                .0
                .get("completedAt")
                .and_then(Value::as_str),
            ts
        );
        assert!(state.message().unwrap().0.get("lastSeq").is_none());
    }
}

#[test]
fn transport_replay_does_not_spend_the_reliable_event_budget_twice() {
    let limits = Limits {
        max_events: 2,
        ..Limits::default()
    };
    let validator = Validator::new(limits, SchemaRegistry::default()).unwrap();
    let beginning = start();
    let ending = event(
        2,
        "message.end",
        json!({
            "status":"complete", "fallbackText":"", "blockCount":0, "rev":1
        }),
    );
    let message = validator
        .validate_stream(&[beginning.clone(), beginning, ending.clone(), ending])
        .unwrap();
    assert_eq!(message.status(), "complete");
}

#[test]
fn snapshots_obey_event_byte_and_sequence_limits() {
    let final_message = json!({
        "id":"message_1", "protocolVersion":"0.1", "role":"assistant",
        "status":"complete", "rev":1, "fallbackText":"", "blocks":[],
        "createdAt":"2026-10-26T09:30:00Z"
    });
    let mut huge = event(2, "message.snapshot", json!({"message":final_message}));
    huge.0["message"]["metadata"] = json!({"note":"x".repeat(130 * 1024)});
    assert_eq!(
        FoldState::new().apply(huge).unwrap_err().code,
        "limit_exceeded"
    );
    let beyond_budget = event(5_001, "message.snapshot", json!({"message":final_message}));
    assert_eq!(
        FoldState::new().apply(beyond_budget).unwrap_err().code,
        "limit_exceeded"
    );
}

#[test]
fn storage_checkpoints_can_be_larger_than_transport_snapshot_events() {
    let message = chatweave_protocol::Message(json!({
        "id":"message_1", "protocolVersion":"0.1", "role":"assistant",
        "status":"streaming", "rev":0, "lastSeq":2,
        "fallbackText":"", "blocks":[],
        "createdAt":"2026-10-26T09:30:00Z",
        "metadata":{"note":"x".repeat(130 * 1024)}
    }));
    let size = serde_json::to_vec(&message).unwrap().len();
    assert!(size > 128 * 1024 && size < 256 * 1024);
    let mut restored = FoldState::from_checkpoint(message.clone(), 2).unwrap();
    assert_eq!(restored.last_seq(), 2);
    assert_eq!(restored.message().unwrap(), message);
    restored
        .apply(event(
            3,
            "message.end",
            json!({
                "status":"complete", "fallbackText":"", "blockCount":0, "rev":1
            }),
        ))
        .unwrap();
    assert_eq!(restored.message().unwrap().status(), "complete");
    assert!(restored.message().unwrap().0.get("lastSeq").is_none());
    assert!(FoldState::from_checkpoint(message, 3).is_err());
}

#[test]
fn stream_error_codes_match_the_schema_enum() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../../schemas/v0.1/stream-event.schema.json"
    ))
    .unwrap();
    let codes: Vec<&str> = schema["$defs"]["error"]["properties"]["code"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|code| code.as_str().unwrap())
        .collect();
    assert_eq!(codes, chatweave_protocol::STREAM_ERROR_CODES);
}
