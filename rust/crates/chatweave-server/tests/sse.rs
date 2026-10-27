#![cfg(feature = "axum")]

use axum::Router;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum_test::TestServer;
use chatweave_server::checkpoint::{Checkpoint, CheckpointStore, MemoryCheckpointStore};
use chatweave_server::event_log::{BroadcastHub, EventLog, EventSink, MemoryEventLog};
use chatweave_server::protocol::{Message, StreamEvent, fold};
use chatweave_server::resume::{ResumeOptions, ResumeService};
use chatweave_server::sse::sse_response;
use http_body_util::BodyExt;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

fn fixture_events() -> Vec<StreamEvent> {
    include_str!("../../../../fixtures/conformance/streams/01-markdown.events.jsonl")
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn expected_message() -> Message {
    serde_json::from_str(include_str!(
        "../../../../fixtures/conformance/streams/01-markdown.expected.json"
    ))
    .unwrap()
}

fn data_events(wire: &str) -> Vec<StreamEvent> {
    wire.lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .map(|data| serde_json::from_str(data.trim_start()).unwrap())
        .collect()
}

#[derive(Default, Deserialize)]
struct Parameters {
    after: Option<String>,
    snapshots: Option<bool>,
}

async fn endpoint(
    State(service): State<ResumeService>,
    Query(parameters): Query<Parameters>,
    headers: HeaderMap,
) -> Response {
    let options = ResumeOptions {
        snapshots: parameters.snapshots.unwrap_or(true),
        ..ResumeOptions::default()
    };
    match sse_response(
        &service,
        "msg_weather",
        &headers,
        parameters.after.as_deref(),
        options,
    )
    .await
    {
        Ok(response) => response,
        Err(error) => (StatusCode::BAD_REQUEST, error.to_string()).into_response(),
    }
}

fn test_server(service: ResumeService) -> TestServer {
    TestServer::new(Router::new().route("/stream", get(endpoint)).with_state(service)).unwrap()
}

async fn setup(
    count: usize,
    final_checkpoint: bool,
) -> (
    ResumeService,
    Arc<MemoryEventLog>,
    Arc<BroadcastHub>,
    Arc<MemoryCheckpointStore>,
) {
    let log = Arc::new(MemoryEventLog::default());
    let hub = Arc::new(BroadcastHub::default());
    let checkpoints = Arc::new(MemoryCheckpointStore::default());
    let events = fixture_events();
    for event in &events[..count] {
        log.append(event.clone()).await.unwrap();
    }
    if final_checkpoint {
        checkpoints
            .commit(Checkpoint::new(expected_message(), 5), None)
            .await
            .unwrap();
    }
    (
        ResumeService::new(log.clone(), hub.clone(), checkpoints.clone()),
        log,
        hub,
        checkpoints,
    )
}

#[tokio::test]
async fn dropped_sse_body_reconnects_with_last_event_id_and_matches_the_full_fold() {
    let (service, log, hub, checkpoints) = setup(3, false).await;
    let response = sse_response(
        &service,
        "msg_weather",
        &HeaderMap::new(),
        None,
        ResumeOptions::default(),
    )
    .await
    .unwrap();
    let mut body = response.into_body();
    let mut received = String::new();
    while data_events(&received).last().and_then(StreamEvent::seq) != Some(3) {
        let frame = tokio::time::timeout(Duration::from_secs(2), body.frame())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Some(bytes) = frame.data_ref() {
            received.push_str(std::str::from_utf8(bytes).unwrap());
        }
    }
    // Drop the actual streaming body before the producer emits block.end/end.
    drop(body);
    for event in &fixture_events()[3..] {
        log.append(event.clone()).await.unwrap();
        hub.publish(event.clone()).await.unwrap();
    }
    checkpoints
        .commit(Checkpoint::new(expected_message(), 5), None)
        .await
        .unwrap();
    let server = test_server(service);
    let response = server
        .get("/stream")
        .add_header(
            HeaderName::from_static("last-event-id"),
            HeaderValue::from_static("3"),
        )
        .await;
    response.assert_status_ok();
    let resumed = data_events(&response.text());
    assert_eq!(resumed.iter().map(StreamEvent::seq).collect::<Vec<_>>(), vec![Some(4), Some(5)]);
    let mut combined = data_events(&received);
    combined.extend(resumed);
    assert_eq!(fold(combined).unwrap(), expected_message());
}

#[tokio::test]
async fn http_response_has_protocol_cache_and_proxy_headers_and_ordered_sse_ids() {
    let (service, _, _, _) = setup(5, true).await;
    let response = test_server(service).get("/stream").await;
    response.assert_status_ok();
    response.assert_header(header::CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    response.assert_header(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.assert_header(HeaderName::from_static("chatweave-protocol"), HeaderValue::from_static("0.1"));
    response.assert_header(HeaderName::from_static("x-accel-buffering"), HeaderValue::from_static("no"));
    let text = response.text();
    assert!(text.contains("retry: 2000"));
    let ids: Vec<_> = text.lines().filter_map(|line| line.strip_prefix("id:"))
        .map(|id| id.trim().parse::<u64>().unwrap()).collect();
    assert_eq!(ids, vec![1, 2, 3, 4, 5]);
    assert_eq!(data_events(&text).last().unwrap().event_type(), "message.end");
}

#[tokio::test]
async fn cleared_log_returns_one_authoritative_snapshot_and_closes() {
    let (service, log, _, _) = setup(5, true).await;
    log.clear("msg_weather").await;
    let response = test_server(service).get("/stream").await;
    response.assert_status_ok();
    let events = data_events(&response.text());
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type(), "message.snapshot");
    assert_eq!(events[0].seq(), Some(5));
    assert_eq!(events[0].0["message"], expected_message().0);
    assert_eq!(fold(events).unwrap(), expected_message());
}

#[tokio::test]
async fn missing_replay_without_snapshot_capability_sends_error_and_closes() {
    let (service, log, _, _) = setup(5, true).await;
    log.clear("msg_weather").await;
    let response = test_server(service)
        .get("/stream")
        .add_query_param("snapshots", false)
        .await;
    response.assert_status_ok();
    let events = data_events(&response.text());
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type(), "error");
    assert_eq!(events[0].0["error"]["code"], "resume_unavailable");
    assert_eq!(log.read_after("msg_weather", 0).await.unwrap().head, 5);
}

#[tokio::test]
async fn header_cursor_takes_priority_and_bad_or_future_cursors_are_rejected() {
    let (service, _, _, _) = setup(5, true).await;
    let server = test_server(service);
    let response = server.get("/stream")
        .add_query_param("after", "999")
        .add_header(HeaderName::from_static("last-event-id"), HeaderValue::from_static("3"))
        .await;
    response.assert_status_ok();
    assert_eq!(data_events(&response.text())[0].seq(), Some(4));
    let bad_header = server.get("/stream")
        .add_query_param("after", "3")
        .add_header(HeaderName::from_static("last-event-id"), HeaderValue::from_static("bad"))
        .expect_failure()
        .await;
    bad_header.assert_status(StatusCode::BAD_REQUEST);
    let future = server.get("/stream").add_query_param("after", "6").expect_failure().await;
    future.assert_status(StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn live_activity_frames_have_no_id_and_are_filtered_by_capability() {
    for enabled in [false, true] {
        let (service, log, hub, _) = setup(3, false).await;
        let response = sse_response(
            &service, "msg_weather", &HeaderMap::new(), None,
            ResumeOptions { activity: enabled, ..ResumeOptions::default() },
        ).await.unwrap();
        hub.publish(StreamEvent(json!({
            "protocolVersion":"0.1","messageId":"msg_weather","type":"message.activity",
            "activity":{"phase":"working","label":"Checking weather"}
        }))).await.unwrap();
        for event in &fixture_events()[3..] {
            log.append(event.clone()).await.unwrap();
            hub.publish(event.clone()).await.unwrap();
        }
        let bytes = tokio::time::timeout(Duration::from_secs(2), response.into_body().collect())
            .await.unwrap().unwrap().to_bytes();
        let text = std::str::from_utf8(&bytes).unwrap();
        let normalized = text.replace("\r\n", "\n");
        let activity_frames: Vec<_> = normalized.split("\n\n")
            .filter(|frame| frame.contains("event: message.activity")).collect();
        assert_eq!(activity_frames.len(), usize::from(enabled));
        for frame in activity_frames {
            assert!(!frame.lines().any(|line| line.starts_with("id:")));
        }
        assert_eq!(log.read_after("msg_weather", 0).await.unwrap().events.len(), 5);
        assert_eq!(fold(data_events(text)).unwrap(), expected_message());
    }
}

#[tokio::test(start_paused = true)]
async fn heartbeat_is_a_comment_and_does_not_advance_the_event_cursor() {
    let (service, log, hub, _) = setup(3, false).await;
    let response = sse_response(
        &service, "msg_weather", &HeaderMap::new(), None, ResumeOptions::default(),
    ).await.unwrap();
    let mut body = response.into_body();
    let mut wire = String::new();
    while data_events(&wire).last().and_then(StreamEvent::seq) != Some(3) {
        let frame = body.frame().await.unwrap().unwrap();
        if let Some(bytes) = frame.data_ref() { wire.push_str(std::str::from_utf8(bytes).unwrap()); }
    }
    tokio::time::advance(Duration::from_secs(15)).await;
    let frame = body.frame().await.unwrap().unwrap();
    let heartbeat = std::str::from_utf8(frame.data_ref().unwrap()).unwrap();
    assert!(heartbeat.contains(": ping"));
    assert!(!heartbeat.lines().any(|line| line.starts_with("id:")));
    assert_eq!(log.read_after("msg_weather", 0).await.unwrap().head, 3);
    for event in &fixture_events()[3..] {
        log.append(event.clone()).await.unwrap();
        hub.publish(event.clone()).await.unwrap();
    }
    body.collect().await.unwrap();
}
