use super::*;
use crate::checkpoint::MemoryCheckpointStore;
use crate::event_log::{BroadcastHub, ReplayBatch};
use async_trait::async_trait;
use futures_util::StreamExt;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::Semaphore;

fn events() -> Vec<StreamEvent> {
    include_str!("../../../../../fixtures/conformance/streams/01-markdown.events.jsonl")
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn log() -> Arc<crate::event_log::MemoryEventLog> {
    Arc::default()
}
async fn append(log: &dyn EventLog, sink: &dyn EventSink, event: StreamEvent) {
    log.append(event.clone()).await.unwrap();
    sink.publish(event).await.unwrap();
}

struct Gate {
    point: ResumePoint,
    reached: Semaphore,
    release: Semaphore,
}
impl Gate {
    fn new(point: ResumePoint) -> Arc<Self> {
        Arc::new(Self {
            point,
            reached: Semaphore::new(0),
            release: Semaphore::new(0),
        })
    }
    async fn wait(&self) {
        tokio::time::timeout(Duration::from_secs(2), self.reached.acquire())
            .await
            .unwrap()
            .unwrap()
            .forget();
    }
    fn release(&self) {
        self.release.add_permits(1);
    }
}
#[async_trait]
impl ResumeHook for Gate {
    async fn reach(&self, point: ResumePoint, _: u64) {
        if point == self.point {
            self.reached.add_permits(1);
            self.release.acquire().await.unwrap().forget();
        }
    }
}

async fn race(point: ResumePoint) {
    let log = log();
    let hub = Arc::new(BroadcastHub::default());
    let expected = events();
    for event in &expected[..3] {
        log.append(event.clone()).await.unwrap();
    }
    let gate = Gate::new(point);
    let mut service = ResumeService::new(
        log.clone(),
        hub.clone(),
        Arc::new(MemoryCheckpointStore::default()),
    );
    service.hook = Some(gate.clone());
    let reader = tokio::spawn(async move {
        let mut stream = service
            .open("msg_weather", ResumeOptions::default())
            .await
            .unwrap();
        let mut received = Vec::new();
        while let Some(event) = stream.next().await {
            received.push(event.unwrap());
        }
        received
    });
    gate.wait().await;
    // Both writes happen while the reader is deterministically suspended.
    // In particular the last message.end must never disappear at handover.
    for event in &expected[3..] {
        append(log.as_ref(), hub.as_ref(), event.clone()).await;
    }
    gate.release();
    let received = tokio::time::timeout(Duration::from_secs(2), reader)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(received, expected);
    assert!(
        received
            .windows(2)
            .all(|pair| pair[0].seq().unwrap() < pair[1].seq().unwrap())
    );
    assert_eq!(received.last().unwrap().event_type(), "message.end");
}

#[tokio::test]
async fn after_replay_writes_including_last_end_are_complete_unique_and_ordered() {
    race(ResumePoint::AfterReplay).await;
}

#[tokio::test]
async fn after_subscribe_writes_are_deduplicated_against_log_replay() {
    race(ResumePoint::AfterSubscribe).await;
}

struct RecordingLog {
    inner: Arc<crate::event_log::MemoryEventLog>,
    repairs: Arc<AtomicUsize>,
}
#[async_trait]
impl EventLog for RecordingLog {
    async fn append(&self, event: StreamEvent) -> Result<()> {
        self.inner.append(event).await
    }
    async fn read_after(&self, id: &str, after: u64) -> Result<ReplayBatch> {
        self.inner.read_after(id, after).await
    }
    async fn read_range(&self, id: &str, after: u64, through: u64) -> Result<ReplayBatch> {
        self.repairs.fetch_add(1, Ordering::SeqCst);
        self.inner.read_range(id, after, through).await
    }
}

#[tokio::test]
async fn handover_gap_is_backfilled_from_log_before_the_end_is_emitted() {
    let inner = log();
    let repairs = Arc::new(AtomicUsize::new(0));
    let recording = Arc::new(RecordingLog {
        inner: inner.clone(),
        repairs: repairs.clone(),
    });
    let hub = Arc::new(BroadcastHub::default());
    let gate = Gate::new(ResumePoint::AfterReplay);
    let expected = events();
    for event in &expected[..3] {
        inner.append(event.clone()).await.unwrap();
    }
    let mut service = ResumeService::new(
        recording,
        hub.clone(),
        Arc::new(MemoryCheckpointStore::default()),
    );
    service.hook = Some(gate.clone());
    let reader = tokio::spawn(async move {
        let mut stream = service
            .open("msg_weather", ResumeOptions::default())
            .await
            .unwrap();
        let mut result = Vec::new();
        while let Some(event) = stream.next().await {
            result.push(event.unwrap());
        }
        result
    });
    gate.wait().await;
    // Deliberately suppress ONLY the seq 4 broadcast. This is not lag: the
    // receiver reports a normal seq 5 event and must repair (3, 5] from log.
    inner.append(expected[3].clone()).await.unwrap();
    append(inner.as_ref(), hub.as_ref(), expected[4].clone()).await;
    gate.release();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), reader)
            .await
            .unwrap()
            .unwrap(),
        expected
    );
    assert_eq!(repairs.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn lagged_receiver_closes_stream_instead_of_skipping_events() {
    let log = log();
    let hub = Arc::new(BroadcastHub::new(2));
    let expected = events();
    for event in &expected[..3] {
        log.append(event.clone()).await.unwrap();
    }
    let gate = Gate::new(ResumePoint::AfterReplay);
    let mut service = ResumeService::new(
        log.clone(),
        hub.clone(),
        Arc::new(MemoryCheckpointStore::default()),
    );
    service.hook = Some(gate.clone());
    let reader = tokio::spawn(async move {
        let mut stream = service
            .open("msg_weather", ResumeOptions::default())
            .await
            .unwrap();
        for _ in 0..3 {
            stream.next().await.unwrap().unwrap();
        }
        assert!(matches!(stream.next().await, Some(Err(Error::Lagged))));
        // Connection stream terminates after the failure, rather than waiting
        // for a later frame or swallowing the loss and emitting message.end.
        assert!(stream.next().await.is_none());
    });
    gate.wait().await;
    for event in &expected[3..] {
        append(log.as_ref(), hub.as_ref(), event.clone()).await;
    }
    for _ in 0..3 {
        hub.publish(StreamEvent(json!({"protocolVersion":"0.1","messageId":"msg_weather","type":"message.activity","activity":{"phase":"working"}}))).await.unwrap();
    }
    gate.release();
    tokio::time::timeout(Duration::from_secs(2), reader)
        .await
        .unwrap()
        .unwrap();
    // The producer still completed and a fresh subscriber can recover it.
    assert_eq!(
        log.read_after("msg_weather", 0).await.unwrap().events,
        expected
    );
}

struct OrderedSink {
    inner: Arc<BroadcastHub>,
    subscribed: Arc<AtomicBool>,
}
#[async_trait]
impl EventSink for OrderedSink {
    async fn subscribe(&self, id: &str) -> Result<crate::event_log::Subscription> {
        let subscription = self.inner.subscribe(id).await?;
        self.subscribed.store(true, Ordering::SeqCst);
        Ok(subscription)
    }
    async fn publish(&self, event: StreamEvent) -> Result<()> {
        self.inner.publish(event).await
    }
}
struct OrderedLog {
    inner: Arc<crate::event_log::MemoryEventLog>,
    subscribed: Arc<AtomicBool>,
}
#[async_trait]
impl EventLog for OrderedLog {
    async fn append(&self, event: StreamEvent) -> Result<()> {
        self.inner.append(event).await
    }
    async fn read_after(&self, id: &str, after: u64) -> Result<ReplayBatch> {
        assert!(
            self.subscribed.load(Ordering::SeqCst),
            "read happened before subscribe"
        );
        self.inner.read_after(id, after).await
    }
    async fn read_range(&self, id: &str, after: u64, through: u64) -> Result<ReplayBatch> {
        self.inner.read_range(id, after, through).await
    }
}

#[tokio::test]
async fn subscribe_precedes_every_initial_log_read() {
    // Negative control: moving read_after before subscribe in open must fail
    // this assertion even if a scheduler happens not to expose a lost event.
    let log = log();
    for event in events() {
        log.append(event).await.unwrap();
    }
    let subscribed = Arc::new(AtomicBool::new(false));
    let service = ResumeService::new(
        Arc::new(OrderedLog {
            inner: log,
            subscribed: subscribed.clone(),
        }),
        Arc::new(OrderedSink {
            inner: Arc::default(),
            subscribed,
        }),
        Arc::new(MemoryCheckpointStore::default()),
    );
    let mut stream = service
        .open("msg_weather", ResumeOptions::default())
        .await
        .unwrap();
    while let Some(event) = stream.next().await {
        event.unwrap();
    }
}

struct WriteDuringRead {
    inner: Arc<crate::event_log::MemoryEventLog>,
    sink: Arc<BroadcastHub>,
    inserted: AtomicBool,
}
#[async_trait]
impl EventLog for WriteDuringRead {
    async fn append(&self, event: StreamEvent) -> Result<()> {
        self.inner.append(event).await
    }
    async fn read_after(&self, id: &str, after: u64) -> Result<ReplayBatch> {
        let batch = self.inner.read_after(id, after).await?;
        if !self.inserted.swap(true, Ordering::SeqCst) {
            // Capture the old replay batch, then write the last two events
            // before returning it. A read-before-subscribe mutant loses both.
            for event in &events()[3..] {
                self.inner.append(event.clone()).await?;
                self.sink.publish(event.clone()).await?;
            }
        }
        Ok(batch)
    }
    async fn read_range(&self, id: &str, after: u64, through: u64) -> Result<ReplayBatch> {
        self.inner.read_range(id, after, through).await
    }
}

#[tokio::test]
async fn a_last_end_written_during_the_log_read_cannot_be_lost_at_subscription() {
    let inner = log();
    let hub = Arc::new(BroadcastHub::default());
    let expected = events();
    for event in &expected[..3] {
        inner.append(event.clone()).await.unwrap();
    }
    let service = ResumeService::new(
        Arc::new(WriteDuringRead {
            inner,
            sink: hub.clone(),
            inserted: AtomicBool::new(false),
        }),
        hub,
        Arc::new(MemoryCheckpointStore::default()),
    );
    let received = tokio::time::timeout(Duration::from_secs(2), async {
        let mut stream = service
            .open("msg_weather", ResumeOptions::default())
            .await
            .unwrap();
        let mut received = Vec::new();
        while let Some(event) = stream.next().await {
            received.push(event.unwrap());
        }
        received
    })
    .await
    .expect("read-before-subscribe loses message.end and times out");
    assert_eq!(received, expected);
}

#[test]
fn cursor_header_priority_and_invalid_values_are_explicit() {
    assert_eq!(parse_cursor(Some("2"), Some("9")).unwrap(), 2);
    assert!(parse_cursor(Some("bad"), Some("2")).is_err());
    for value in ["", "-1", "+1", "1.0", " 1", "18446744073709551616"] {
        assert!(parse_cursor(None, Some(value)).is_err());
    }
}

#[cfg(feature = "axum")]
#[tokio::test]
async fn lagged_sse_body_disconnects_instead_of_delivering_a_terminal_frame() {
    use http_body_util::BodyExt;
    let log = log();
    let hub = Arc::new(BroadcastHub::new(2));
    let expected = events();
    for event in &expected[..3] {
        log.append(event.clone()).await.unwrap();
    }
    let gate = Gate::new(ResumePoint::AfterReplay);
    let mut service = ResumeService::new(
        log.clone(),
        hub.clone(),
        Arc::new(MemoryCheckpointStore::default()),
    );
    service.hook = Some(gate.clone());
    let reader = tokio::spawn(async move {
        let response = crate::sse::sse_response(
            &service,
            "msg_weather",
            &axum::http::HeaderMap::new(),
            None,
            ResumeOptions::default(),
        )
        .await
        .unwrap();
        let mut body = response.into_body();
        let mut disconnected = false;
        while let Some(frame) = body.frame().await {
            match frame {
                Ok(frame) => {
                    if let Some(bytes) = frame.data_ref() {
                        assert!(!String::from_utf8_lossy(bytes).contains("event: message.end"));
                    }
                }
                Err(_) => {
                    disconnected = true;
                    break;
                }
            }
        }
        assert!(disconnected, "lag must disconnect the HTTP body");
    });
    gate.wait().await;
    for event in &expected[3..] {
        append(log.as_ref(), hub.as_ref(), event.clone()).await;
    }
    for _ in 0..3 {
        hub.publish(expected[4].clone()).await.unwrap();
    }
    gate.release();
    tokio::time::timeout(Duration::from_secs(2), reader)
        .await
        .unwrap()
        .unwrap();
}
