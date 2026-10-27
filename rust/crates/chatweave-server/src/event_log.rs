//! Bounded per-message event history and independent bounded live subscriptions.
use crate::{Error, Result};
use async_trait::async_trait;
use chatweave_protocol::StreamEvent;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, broadcast};
use tokio::time::Instant;

pub fn sequence(event: &StreamEvent) -> Option<u64> {
    event.0.get("seq").and_then(serde_json::Value::as_u64)
}

pub fn is_terminal(event: &StreamEvent) -> bool {
    matches!(event.0["type"].as_str(), Some("message.end" | "message.paused" | "error"))
        || (event.0["type"] == "message.snapshot"
            && matches!(event.0["message"]["status"].as_str(), Some("paused" | "complete" | "interrupted" | "error")))
}

#[derive(Clone, Debug)]
pub struct ReplayBatch {
    pub events: Vec<StreamEvent>,
    pub head: u64,
    /// False means some requested events have expired or have been evicted.
    pub covered: bool,
}

#[async_trait]
pub trait EventLog: Send + Sync {
    async fn append(&self, event: StreamEvent) -> Result<()>;
    async fn read_after(&self, message_id: &str, after: u64) -> Result<ReplayBatch>;
    async fn read_range(&self, message_id: &str, after: u64, through: u64) -> Result<ReplayBatch>;
}

struct History {
    events: VecDeque<(StreamEvent, usize)>,
    bytes: usize,
    head: u64,
    expires: Option<Instant>,
}

#[derive(Clone)]
pub struct MemoryEventLog {
    histories: Arc<Mutex<HashMap<String, History>>>,
    max_events: usize,
    max_bytes: usize,
    retention: Duration,
}

impl Default for MemoryEventLog {
    fn default() -> Self {
        Self::new(5_000, 8 * 1024 * 1024, Duration::from_secs(600))
    }
}

impl MemoryEventLog {
    pub fn new(max_events: usize, max_bytes: usize, retention: Duration) -> Self {
        Self { histories: Arc::default(), max_events: max_events.max(1), max_bytes: max_bytes.max(1), retention }
    }

    /// Release expired histories. Durable checkpoints retain their watermark.
    pub async fn cleanup(&self) {
        let mut histories = self.histories.lock().await;
        histories.retain(|_, history| history.expires.is_none_or(|at| at > Instant::now()));
    }

    pub async fn clear(&self, message_id: &str) {
        if let Some(history) = self.histories.lock().await.get_mut(message_id) {
            history.events.clear();
            history.bytes = 0;
        }
    }
}

#[async_trait]
impl EventLog for MemoryEventLog {
    async fn append(&self, event: StreamEvent) -> Result<()> {
        let seq = sequence(&event).filter(|seq| *seq > 0)
            .ok_or_else(|| Error::InvalidRequest("reliable log events need a positive seq".into()))?;
        if event.event_type() == "message.activity" {
            return Err(Error::InvalidRequest("activity cannot enter the log".into()));
        }
        let message_id = event.0["messageId"].as_str().ok_or_else(|| Error::InvalidRequest("missing messageId".into()))?.to_owned();
        let size = serde_json::to_vec(&event).map_err(crate::protocol_error)?.len();
        let mut histories = self.histories.lock().await;
        let history = histories.entry(message_id.clone()).or_insert_with(|| History { events: VecDeque::new(), bytes: 0, head: seq - 1, expires: None });
        if seq != history.head + 1 {
            return Err(Error::Conflict);
        }
        if history.expires.is_some_and(|at| at <= Instant::now()) {
            history.events.clear();
            history.bytes = 0;
        }
        history.expires = if is_terminal(&event) { Some(Instant::now() + self.retention) } else { None };
        history.head = seq;
        history.bytes += size;
        history.events.push_back((event, size));
        while history.events.len() > self.max_events || history.bytes > self.max_bytes {
            if let Some((_, bytes)) = history.events.pop_front() { history.bytes -= bytes; }
        }
        if let Some(expires) = history.expires {
            let histories = self.histories.clone();
            tokio::spawn(async move {
                tokio::time::sleep_until(expires).await;
                let mut histories = histories.lock().await;
                if histories.get(&message_id).is_some_and(|history| history.expires.is_some_and(|at| at <= Instant::now())) {
                    histories.remove(&message_id);
                }
            });
        }
        Ok(())
    }

    async fn read_after(&self, message_id: &str, after: u64) -> Result<ReplayBatch> {
        self.cleanup().await;
        let histories = self.histories.lock().await;
        let Some(history) = histories.get(message_id) else {
            return Ok(ReplayBatch { events: vec![], head: 0, covered: false });
        };
        let events: Vec<_> = history.events.iter().filter(|(event, _)| sequence(event).is_some_and(|seq| seq > after)).map(|(event, _)| event.clone()).collect();
        let covered = after == history.head || (events.first().and_then(sequence) == Some(after + 1) && events.last().and_then(sequence) == Some(history.head));
        Ok(ReplayBatch { events, head: history.head, covered })
    }

    async fn read_range(&self, message_id: &str, after: u64, through: u64) -> Result<ReplayBatch> {
        if through < after {
            return Err(Error::InvalidRequest("range ends before its cursor".into()));
        }
        let mut batch = self.read_after(message_id, after).await?;
        batch.events.retain(|event| sequence(event).is_some_and(|seq| seq <= through));
        batch.covered = batch.events.len() as u64 == through.saturating_sub(after)
            && batch.events.iter().enumerate().all(|(i, event)| sequence(event) == Some(after + i as u64 + 1));
        Ok(batch)
    }
}

pub struct Subscription {
    receiver: broadcast::Receiver<StreamEvent>,
}

impl Subscription {
    pub async fn recv(&mut self) -> Result<Option<StreamEvent>> {
        match self.receiver.recv().await {
            Ok(event) => Ok(Some(event)),
            Err(broadcast::error::RecvError::Closed) => Ok(None),
            Err(broadcast::error::RecvError::Lagged(_)) => Err(Error::Lagged),
        }
    }
}

#[async_trait]
pub trait EventSink: Send + Sync {
    async fn subscribe(&self, message_id: &str) -> Result<Subscription>;
    async fn publish(&self, event: StreamEvent) -> Result<()>;
}

#[derive(Clone)]
pub struct BroadcastHub {
    channels: Arc<Mutex<HashMap<String, broadcast::Sender<StreamEvent>>>>,
    capacity: usize,
}

impl Default for BroadcastHub {
    fn default() -> Self { Self::new(256) }
}

impl BroadcastHub {
    pub fn new(capacity: usize) -> Self { Self { channels: Arc::default(), capacity: capacity.max(1) } }
    async fn sender(&self, message_id: &str) -> broadcast::Sender<StreamEvent> {
        self.channels.lock().await.entry(message_id.into()).or_insert_with(|| broadcast::channel(self.capacity).0).clone()
    }
}

#[async_trait]
impl EventSink for BroadcastHub {
    async fn subscribe(&self, message_id: &str) -> Result<Subscription> {
        Ok(Subscription { receiver: self.sender(message_id).await.subscribe() })
    }
    async fn publish(&self, event: StreamEvent) -> Result<()> {
        let id = event.0["messageId"].as_str().ok_or_else(|| Error::InvalidRequest("missing messageId".into()))?;
        // Having no connected subscribers must never cancel the producer.
        let _ = self.sender(id).await.send(event);
        Ok(())
    }
}
