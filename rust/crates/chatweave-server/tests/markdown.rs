use chatweave_server::checkpoint::MemoryCheckpointStore;
use chatweave_server::event_log::{BroadcastHub, EventLog, MemoryEventLog};
use chatweave_server::markdown::{MarkdownAdapter, fallback_text, plain_text};
use chatweave_server::protocol::{DocumentKind, Message, Validator};
use chatweave_server::{MessageStream, StreamConfig};
use serde_json::json;
use std::sync::Arc;

#[test]
fn plain_text_removes_formatting_but_preserves_code_html_and_line_breaks() {
    assert_eq!(plain_text("Today is **sunny** and `18°C`.\nTake a walk."),
        "Today is sunny and 18°C.\nTake a walk.");
    assert!(plain_text("<b>Weather</b>").contains("<b>Weather</b>"));
    assert_eq!(plain_text("**unfinished"), "**unfinished");
}

#[test]
fn fallback_uses_content_blocks_and_never_process_steps() {
    let message = Message(json!({
        "blocks":[
            {"type":"markdown","data":{"text":"**Sunny**"}},
            {"type":"metric","data":{"value":18},"fallbackText":"High: 18°C"},
            {"type":"markdown","status":"error","fallbackText":"Text unavailable"},
            {"type":"x-todo.task_card","fallbackText":"Buy tea"}
        ],
        "steps":[{"label":"PRIVATE STEP LABEL","summary":"PRIVATE STEP SUMMARY"}]
    }));
    assert_eq!(fallback_text(&message), "Sunny\n\nHigh: 18°C\n\nText unavailable\n\nBuy tea");
}

#[tokio::test]
async fn adapter_preserves_prose_and_never_extracts_structured_facts() {
    let log = Arc::new(MemoryEventLog::default());
    let stream = MessageStream::start(
        StreamConfig::new("msg_adapter"),
        Arc::new(Validator::default()),
        log.clone(),
        Arc::new(BroadcastHub::default()),
        Arc::new(MemoryCheckpointStore::default()),
    ).await.unwrap();
    let mut adapter = MarkdownAdapter::new(stream);
    adapter.push_text("Forecast: **18°C**. ").await.unwrap();
    adapter.push_text("There are three tasks.\n```json\n{\"value\":18}\n```")
        .await.unwrap();
    let message = adapter.finish().await.unwrap();
    let blocks = message.0["blocks"].as_array().unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0]["type"], "markdown");
    assert_eq!(blocks[0]["metadata"]["provenance"], "adapter");
    assert_eq!(blocks[0]["data"]["text"],
        "Forecast: **18°C**. There are three tasks.\n```json\n{\"value\":18}\n```");
    assert!(message.0["fallbackText"].as_str().unwrap().contains("{\"value\":18}"));
    let validator = Validator::default();
    validator.validate(DocumentKind::Message, &message.0).unwrap();
    for event in log.read_after("msg_adapter", 0).await.unwrap().events {
        validator.validate(DocumentKind::Event, &event.0).unwrap();
    }
}

#[tokio::test]
async fn empty_adapter_can_finish_without_inventing_a_block() {
    let stream = MessageStream::start(
        StreamConfig::new("msg_empty_adapter"),
        Arc::new(Validator::default()),
        Arc::new(MemoryEventLog::default()),
        Arc::new(BroadcastHub::default()),
        Arc::new(MemoryCheckpointStore::default()),
    ).await.unwrap();
    let message = MarkdownAdapter::new(stream).finish().await.unwrap();
    assert_eq!(message.0["blocks"], json!([]));
    assert_eq!(message.0["fallbackText"], "");
}
