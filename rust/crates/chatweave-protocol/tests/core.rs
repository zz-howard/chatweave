use chatweave_protocol::{Block, DocumentKind, FoldState, Limits, SchemaRegistry, StreamEvent, Validator, merge_patch};
use serde_json::{Value, json};

fn event(seq:u64,ty:&str,fields:Value)->StreamEvent {
    let mut event=json!({"protocolVersion":"0.1","messageId":"message_1","seq":seq,"type":ty});
    merge_patch(&mut event,&fields);
    StreamEvent(event)
}
fn start()->StreamEvent {
    event(1,"message.start",json!({"message":{"id":"message_1","role":"assistant","createdAt":"2026-10-26T09:30:00Z"}}))
}
#[test]
fn invalid_event_does_not_mutate_state_and_replay_is_idempotent() {
    let mut state=FoldState::new();
    state.apply(start()).unwrap();
    let before=state.message().unwrap();
    assert!(state.apply(event(3,"block.start",json!({"blockId":"b1","index":0,"blockType":"markdown","schemaVersion":1}))).is_err());
    assert_eq!(state.last_seq(),1);
    assert_eq!(state.message().unwrap(),before);
    state.apply(start()).unwrap();
    assert_eq!(state.message().unwrap(),before);
    state.apply(event(2,"x-weather.future",json!({"opaque":{"field":null}}))).unwrap();
    assert_eq!(state.last_seq(),2);
    assert_eq!(state.message().unwrap().0["blocks"],json!([]));
}
#[test]
fn merge_patch_removes_null_and_replaces_arrays() {
    let mut value=json!({"data":{"keep":1,"remove":2,"items":[1,2]},"metadata":{"host":{"old":true}}});
    merge_patch(&mut value,&json!({"data":{"remove":null,"items":[3]},"metadata":null}));
    assert_eq!(value,json!({"data":{"keep":1,"items":[3]}}));
}
#[test]
fn limits_measure_utf8_and_can_only_be_tightened() {
    let limits=Limits::default();
    assert!(limits.check_event(&json!({"delta":{"text":"晴".repeat(1365)}})).is_ok());
    assert!(limits.check_event(&json!({"delta":{"text":"晴".repeat(1366)}})).is_err());
    let mut tighter=limits.clone();
    tighter.max_delta_bytes=3;
    assert!(tighter.validate_configuration().is_ok());
    assert!(tighter.check_event(&json!({"delta":{"text":"晴晴"}})).is_err());
    tighter.max_delta_bytes=limits.max_delta_bytes+1;
    assert!(Validator::new(tighter,SchemaRegistry::default()).is_err());
}
#[test]
fn custom_registry_validates_without_external_retrieval() {
    let block=json!({"id":"b1","type":"x-todo.task_card","schemaVersion":1,"data":{"title":"Read a book"},"fallbackText":"Read a book"});
    assert!(Validator::default().validate(DocumentKind::Block,&block).is_err());
    let mut registry=SchemaRegistry::default();
    registry.register("x-todo.task_card",1,json!({"type":"object","required":["title"],"additionalProperties":false,"properties":{"title":{"type":"string"}}})).unwrap();
    assert!(registry.register("x-todo.task_card",1,json!({"type":"object"})).is_err());
    assert!(registry.register("x-todo.external",1,json!({"$ref":"https://example.invalid/schema"})).is_err());
    let validator=Validator::new(Limits::default(),registry).unwrap();
    validator.validate(DocumentKind::Block,&block).unwrap();
    let mut invalid=block.clone();
    invalid["data"]["title"]=json!(5);
    assert!(validator.validate(DocumentKind::Block,&invalid).is_err());
    assert_eq!(Block(block.clone()).typed_data().unwrap().unwrap().to_value().unwrap(),block["data"]);
}
#[test]
fn final_time_is_only_taken_from_end_event() {
    for ts in [None,Some("2026-10-26T09:30:02+08:00")] {
        let mut state=FoldState::new();
        state.apply(start()).unwrap();
        let mut end=event(2,"message.end",json!({"status":"complete","fallbackText":"","blockCount":0,"rev":1}));
        if let Some(ts)=ts {end.0["ts"]=ts.into();}
        state.apply(end).unwrap();
        assert_eq!(state.message().unwrap().0.get("completedAt").and_then(Value::as_str),ts);
        assert!(state.message().unwrap().0.get("lastSeq").is_none());
    }
}
