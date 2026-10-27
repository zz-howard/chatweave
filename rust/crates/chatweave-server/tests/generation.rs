use chatweave_server::checkpoint::MemoryCheckpointStore;
use chatweave_server::event_log::{BroadcastHub, MemoryEventLog};
use chatweave_server::generation::GenerationRegistry;
use chatweave_server::protocol::{DocumentKind, Validator};
use chatweave_server::{Error, MessageStream, StreamConfig};
use serde_json::{Value, json};
use std::sync::Arc;

fn user_message() -> Value {
    json!({
        "id":"user_weather_01","protocolVersion":"0.1","role":"user",
        "conversationId":"conv_weather","status":"complete","rev":1,
        "createdAt":"2026-10-27T00:00:00Z","fallbackText":"Check today's forecast",
        "blocks":[{"id":"b1","type":"markdown","schemaVersion":1,
                   "data":{"text":"Check today's forecast"}}]
    })
}

async fn stream(id: &str) -> MessageStream {
    MessageStream::start(
        StreamConfig::new(id),
        Arc::new(Validator::default()),
        Arc::new(MemoryEventLog::default()),
        Arc::new(BroadcastHub::default()),
        Arc::new(MemoryCheckpointStore::default()),
    ).await.unwrap()
}

#[tokio::test]
async fn duplicate_start_reuses_identity_and_rejects_changed_content() {
    let registry = GenerationRegistry::default();
    let user = user_message();
    let first = registry.begin("scope_a", &user).await.unwrap();
    let repeated = registry.begin("scope_a", &user).await.unwrap();
    assert_eq!(first["messageId"], repeated["messageId"]);
    assert_eq!(repeated["replayed"], true);
    assert_eq!(first["streamable"], true);
    Validator::default().validate(DocumentKind::Generation, &first).unwrap();
    Validator::default().validate(DocumentKind::Generation, &repeated).unwrap();
    let mut changed = user.clone();
    changed["blocks"][0]["data"]["text"] = json!("Check tomorrow's forecast");
    changed["fallbackText"] = json!("Check tomorrow's forecast");
    assert!(matches!(registry.begin("scope_a", &changed).await, Err(Error::InvalidRequest(_))));
    let other_scope = registry.begin("scope_b", &user).await.unwrap();
    assert_ne!(first["messageId"], other_scope["messageId"]);
    assert!(registry.active_messages("scope_a", "conv_weather").await.unwrap()["messages"]
        .as_array().unwrap().is_empty());
}

#[tokio::test]
async fn concurrent_duplicate_starts_create_only_one_reply_identity() {
    let registry = GenerationRegistry::default();
    let user = user_message();
    let (first, second) = tokio::join!(registry.begin("scope_a", &user), registry.begin("scope_a", &user));
    assert_eq!(first.unwrap()["messageId"], second.unwrap()["messageId"]);
}

#[tokio::test]
async fn active_query_is_scoped_and_lists_both_streaming_and_paused_messages() {
    let registry = GenerationRegistry::default();
    let producing = stream("msg_active").await;
    let paused = stream("msg_paused").await;
    let step = paused.start_step("Choose city").await.unwrap();
    let card = paused.start_block("choice", 1, "Choose city").await.unwrap();
    card.data(json!({
        "prompt":"Choose city","options":[{"id":"beijing","label":"Beijing"},{"id":"shanghai","label":"Shanghai"}],
        "action":{"type":"choice.select","target":"weather.choose"},"state":{"status":"open"}
    }), "Choose city", None).await.unwrap();
    card.finish().await.unwrap();
    paused.pause(&step, &card, "interrupt_city", "input_required", true).await.unwrap();
    registry.register("scope_a", "conv_weather", "user_weather_01", producing.clone()).await.unwrap();
    registry.register("scope_a", "conv_weather", "user_weather_02", paused.clone()).await.unwrap();
    registry.register("scope_b", "conv_weather", "user_weather_03", stream("msg_other_scope").await).await.unwrap();
    registry.register("scope_a", "conv_other", "user_weather_04", stream("msg_other_conv").await).await.unwrap();
    let response = registry.active_messages("scope_a", "conv_weather").await.unwrap();
    let messages = response["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["messageId"], "msg_active");
    assert_eq!(messages[0]["status"], "streaming");
    assert_eq!(messages[0]["replyTo"], "user_weather_01");
    assert_eq!(messages[1]["messageId"], "msg_paused");
    assert_eq!(messages[1]["status"], "paused");
    assert_eq!(messages[1]["lastSeq"], paused.last_seq().await);
    Validator::default().validate(DocumentKind::Generation, &response).unwrap();
    producing.finish().await.unwrap();
    let response = registry.active_messages("scope_a", "conv_weather").await.unwrap();
    assert_eq!(response["messages"].as_array().unwrap().len(), 1);
    assert_eq!(response["messages"][0]["status"], "paused");
}

#[tokio::test]
async fn stop_is_idempotent_and_clears_only_the_matching_active_entry() {
    let registry = GenerationRegistry::default();
    let first = stream("msg_stop_first").await;
    let second = stream("msg_stop_second").await;
    registry.register("scope_a", "conv_weather", "user_weather_01", first.clone()).await.unwrap();
    registry.register("scope_a", "conv_weather", "user_weather_02", second).await.unwrap();
    let result = registry.stop("scope_a", "msg_stop_first").await.unwrap();
    assert_eq!(result["status"], "stopping");
    let last_seq = first.last_seq().await;
    assert_eq!(registry.stop("scope_a", "msg_stop_first").await.unwrap(), result);
    assert_eq!(first.last_seq().await, last_seq);
    let active = registry.active_messages("scope_a", "conv_weather").await.unwrap();
    assert_eq!(active["messages"].as_array().unwrap().len(), 1);
    assert_eq!(active["messages"][0]["messageId"], "msg_stop_second");
    assert!(matches!(registry.stop("scope_b", "msg_stop_second").await, Err(Error::NotFound)));
    assert_eq!(first.message().await.unwrap().0["status"], "interrupted");
}

#[tokio::test]
async fn completed_message_stop_reports_already_ended() {
    let registry = GenerationRegistry::default();
    let ended = stream("msg_ended").await;
    registry.register("scope_a", "conv_weather", "user_weather_01", ended.clone()).await.unwrap();
    ended.finish().await.unwrap();
    let seq = ended.last_seq().await;
    let response = registry.stop("scope_a", "msg_ended").await.unwrap();
    assert_eq!(response["status"], "already_ended");
    assert_eq!(ended.last_seq().await, seq);
    assert_eq!(registry.stop("scope_a", "msg_ended").await.unwrap(), response);
}

#[tokio::test]
async fn stale_cleanup_cannot_remove_a_replacement_registration() {
    let registry = GenerationRegistry::default();
    let previous = stream("msg_replaced").await;
    let replacement = stream("msg_replaced").await;
    registry.register("scope_a", "conv_weather", "user_weather_01", previous.clone()).await.unwrap();
    registry.register("scope_a", "conv_weather", "user_weather_01", replacement.clone()).await.unwrap();
    assert!(!registry.clear_if_current("scope_a", "msg_replaced", &previous).await);
    assert_eq!(registry.active_messages("scope_a", "conv_weather").await.unwrap()["messages"]
        .as_array().unwrap().len(), 1);
    assert!(registry.clear_if_current("scope_a", "msg_replaced", &replacement).await);
    assert!(registry.active_messages("scope_a", "conv_weather").await.unwrap()["messages"]
        .as_array().unwrap().is_empty());
}
