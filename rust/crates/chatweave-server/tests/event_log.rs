use chatweave_server::Error;
use chatweave_server::event_log::{BroadcastHub, EventLog, EventSink, MemoryEventLog, sequence};
use chatweave_server::protocol::StreamEvent;
use serde_json::json;
use std::time::Duration;

fn event(message_id: &str, seq: u64) -> StreamEvent {
    StreamEvent(json!({
        "protocolVersion":"0.1", "messageId":message_id, "seq":seq,
        "type":"step.started", "stepId":format!("s{seq}"), "label":"Read forecast"
    }))
}

fn terminal(message_id: &str, seq: u64, paused: bool) -> StreamEvent {
    if paused {
        StreamEvent(json!({
            "protocolVersion":"0.1", "messageId":message_id, "seq":seq,
            "type":"message.paused", "blockCount":1, "fallbackText":"Choose city",
            "interrupt":{"id":"interrupt_1","stepId":"s1","blockId":"b1","reason":"input_required"}
        }))
    } else {
        StreamEvent(json!({
            "protocolVersion":"0.1", "messageId":message_id, "seq":seq,
            "type":"message.end", "status":"complete", "blockCount":0,
            "fallbackText":"Forecast ready", "rev":1
        }))
    }
}

#[tokio::test]
async fn messages_have_independent_sequences_and_ranges_are_ordered() {
    let log = MemoryEventLog::default();
    for seq in 1..=4 {
        log.append(event("msg_weather", seq)).await.unwrap();
    }
    log.append(event("msg_tasks", 1)).await.unwrap();
    let batch = log.read_range("msg_weather", 1, 3).await.unwrap();
    assert!(batch.covered);
    assert_eq!(batch.head, 4);
    assert_eq!(
        batch.events.iter().map(sequence).collect::<Vec<_>>(),
        vec![Some(2), Some(3)]
    );
    assert_eq!(log.read_after("msg_tasks", 0).await.unwrap().head, 1);
    let missing = log.read_after("msg_absent", 0).await.unwrap();
    assert!(!missing.covered);
    assert!(missing.events.is_empty());
}

#[tokio::test]
async fn event_capacity_evicts_payloads_and_reports_missing_coverage() {
    let log = MemoryEventLog::new(2, usize::MAX, Duration::from_secs(600));
    for seq in 1..=3 {
        log.append(event("msg_ring", seq)).await.unwrap();
    }
    let old = log.read_after("msg_ring", 0).await.unwrap();
    assert!(!old.covered);
    assert_eq!(old.head, 3);
    assert_eq!(
        old.events.iter().map(sequence).collect::<Vec<_>>(),
        vec![Some(2), Some(3)]
    );
    assert!(log.read_after("msg_ring", 1).await.unwrap().covered);
    assert!(!log.read_range("msg_ring", 0, 2).await.unwrap().covered);
    log.clear("msg_ring").await;
    let cleared = log.read_after("msg_ring", 1).await.unwrap();
    assert_eq!(cleared.head, 3);
    assert!(cleared.events.is_empty());
    assert!(!cleared.covered);
}

#[tokio::test]
async fn byte_capacity_is_bounded_independently_of_event_count() {
    let one = event("msg_bytes", 1);
    let two = event("msg_bytes", 2);
    let capacity = serde_json::to_vec(&two).unwrap().len();
    let log = MemoryEventLog::new(100, capacity, Duration::from_secs(600));
    log.append(one).await.unwrap();
    log.append(two.clone()).await.unwrap();
    let batch = log.read_after("msg_bytes", 0).await.unwrap();
    assert!(!batch.covered);
    assert_eq!(batch.events, vec![two]);
}

#[tokio::test(start_paused = true)]
async fn retention_starts_at_pause_and_resumption_opens_a_new_segment() {
    let log = MemoryEventLog::default();
    log.append(event("msg_retention", 1)).await.unwrap();
    tokio::time::advance(Duration::from_secs(3_600)).await;
    assert!(log.read_after("msg_retention", 0).await.unwrap().covered);
    log.append(terminal("msg_retention", 2, true))
        .await
        .unwrap();
    tokio::time::advance(Duration::from_secs(599)).await;
    assert_eq!(
        log.read_after("msg_retention", 0)
            .await
            .unwrap()
            .events
            .len(),
        2
    );
    tokio::time::advance(Duration::from_secs(1)).await;
    let expired = log.read_after("msg_retention", 0).await.unwrap();
    assert_eq!(expired.head, 0);
    assert!(!expired.covered);
    assert!(expired.events.is_empty());
    log.append(StreamEvent(json!({
        "protocolVersion":"0.1", "messageId":"msg_retention", "seq":3,
        "type":"message.resumed", "interruptId":"interrupt_1"
    })))
    .await
    .unwrap();
    tokio::time::advance(Duration::from_secs(3_600)).await;
    assert!(log.read_after("msg_retention", 2).await.unwrap().covered);
    assert!(!log.read_after("msg_retention", 0).await.unwrap().covered);
    log.append(terminal("msg_retention", 4, false))
        .await
        .unwrap();
    tokio::time::advance(Duration::from_secs(600)).await;
    assert!(
        log.read_after("msg_retention", 2)
            .await
            .unwrap()
            .events
            .is_empty()
    );
}

#[tokio::test]
async fn duplicate_and_gap_appends_do_not_change_the_head() {
    let log = MemoryEventLog::default();
    log.append(event("msg_conflict", 1)).await.unwrap();
    assert!(matches!(
        log.append(event("msg_conflict", 1)).await,
        Err(Error::Conflict)
    ));
    assert!(matches!(
        log.append(event("msg_conflict", 3)).await,
        Err(Error::Conflict)
    ));
    assert_eq!(log.read_after("msg_conflict", 0).await.unwrap().head, 1);
    log.append(event("msg_conflict", 2)).await.unwrap();
    assert_eq!(
        log.read_after("msg_conflict", 0)
            .await
            .unwrap()
            .events
            .len(),
        2
    );
}

#[tokio::test]
async fn activity_is_rejected_by_log_and_live_lag_is_not_swallowed() {
    let activity = StreamEvent(json!({
        "protocolVersion":"0.1","messageId":"msg_live","type":"message.activity",
        "activity":{"phase":"working","label":"Checking weather"}
    }));
    assert!(MemoryEventLog::default().append(activity).await.is_err());
    let hub = BroadcastHub::new(2);
    let mut slow = hub.subscribe("msg_live").await.unwrap();
    for seq in 1..=5 {
        hub.publish(event("msg_live", seq)).await.unwrap();
    }
    assert!(matches!(slow.recv().await, Err(Error::Lagged)));
    let mut fresh = hub.subscribe("msg_live").await.unwrap();
    hub.publish(event("msg_live", 6)).await.unwrap();
    assert_eq!(fresh.recv().await.unwrap().unwrap().seq(), Some(6));
    drop(slow);
    drop(fresh);
    hub.publish(event("msg_live", 7)).await.unwrap();
}
