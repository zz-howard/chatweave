//! Subscribe first, replay second, then bridge by sequence number.
use crate::checkpoint::{Checkpoint, CheckpointStore};
use crate::event_log::{EventLog, EventSink, is_terminal, sequence};
use crate::{Error, Result};
use chatweave_protocol::{FoldState, StreamEvent};
use futures_core::Stream;
use serde_json::json;
use std::pin::Pin;
use std::sync::Arc;

pub type EventStream = Pin<Box<dyn Stream<Item = Result<StreamEvent>> + Send>>;

#[derive(Clone, Debug)]
pub struct ResumeOptions {
    pub after: u64,
    pub snapshots: bool,
    pub activity: bool,
}
impl Default for ResumeOptions {
    fn default() -> Self { Self { after: 0, snapshots: true, activity: false } }
}

#[derive(Clone)]
pub struct ResumeService {
    pub log: Arc<dyn EventLog>,
    pub sink: Arc<dyn EventSink>,
    pub checkpoints: Arc<dyn CheckpointStore>,
    #[cfg(test)]
    hook: Option<Arc<dyn ResumeHook>>,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResumePoint { AfterSubscribe, AfterReplay }
#[cfg(test)]
#[async_trait::async_trait]
trait ResumeHook: Send + Sync {
    async fn reach(&self, point: ResumePoint, last_sent: u64);
}

impl ResumeService {
    pub fn new(log: Arc<dyn EventLog>, sink: Arc<dyn EventSink>, checkpoints: Arc<dyn CheckpointStore>) -> Self {
        Self { log, sink, checkpoints, #[cfg(test)] hook: None }
    }

    pub async fn open(&self, message_id: &str, options: ResumeOptions) -> Result<EventStream> {
        // Keep this before every read (including a snapshot read). No write
        // can slip through the handover without either a replay or a notice.
        let mut subscription = self.sink.subscribe(message_id).await?;
        #[cfg(test)]
        if let Some(hook) = &self.hook { hook.reach(ResumePoint::AfterSubscribe, options.after).await; }
        let batch = self.log.read_after(message_id, options.after).await?;
        let checkpoint = self.checkpoints.load(message_id).await?;
        let head = batch.head.max(checkpoint.as_ref().map_or(0, |checkpoint| checkpoint.last_seq));
        if options.after > head { return Err(Error::InvalidRequest("cursor exceeds message head".into())); }
        if head == 0 && checkpoint.is_none() { return Err(Error::NotFound); }
        let snapshot_terminal = checkpoint.as_ref().is_some_and(|cp| cp.message.0["status"] != "streaming");
        let revised_final = checkpoint.as_ref().is_some_and(|cp| cp.message.rev() > 1);
        let initial = if !batch.covered || revised_final || (batch.events.is_empty() && snapshot_terminal) {
            let checkpoint = self.current_checkpoint(message_id, checkpoint).await?;
            if checkpoint.as_ref().is_some_and(|cp| cp.last_seq < options.after) { return Err(Error::Unavailable); }
            vec![snapshot_or_error(message_id, checkpoint, &options)?]
        } else { batch.events };
        let service = self.clone();
        let message_id = message_id.to_owned();
        Ok(Box::pin(async_stream::try_stream! {
            let mut last = options.after;
            for event in initial {
                if !matches!(event.0["type"].as_str(), Some("message.snapshot" | "error")) && sequence(&event).is_some_and(|seq| seq <= last) { continue; }
                if let Some(seq) = sequence(&event) { last = seq; }
                let terminal = is_terminal(&event);
                yield event;
                if terminal { return; }
            }
            #[cfg(test)]
            if let Some(hook) = &service.hook { hook.reach(ResumePoint::AfterReplay, last).await; }
            loop {
                let Some(event) = subscription.recv().await? else { return; };
                if event.0["type"] == "message.activity" {
                    if options.activity { yield event; }
                    continue;
                }
                let seq = sequence(&event).ok_or_else(|| Error::Protocol("broadcast event has no seq".into()))?;
                if seq <= last { continue; }
                if seq > last + 1 {
                    let repair = service.log.read_range(&message_id, last, seq).await?;
                    if !repair.covered {
                        let cp = service.checkpoints.load(&message_id).await?;
                        let cp = service.current_checkpoint(&message_id, cp).await?;
                        let current_options = ResumeOptions { after: last, ..options.clone() };
                        let snapshot = snapshot_or_error(&message_id, cp, &current_options)?;
                        if sequence(&snapshot).is_some_and(|seq| seq < last) { Err::<(), Error>(Error::Unavailable)?; }
                        let terminal = is_terminal(&snapshot);
                        if let Some(seq) = sequence(&snapshot) { last = seq; }
                        yield snapshot;
                        if terminal { return; }
                    } else {
                        for missing in repair.events {
                            if sequence(&missing) != Some(last + 1) { Err::<(), Error>(Error::Unavailable)?; }
                            last += 1;
                            let terminal = is_terminal(&missing);
                            yield missing;
                            if terminal { return; }
                        }
                    }
                    continue;
                }
                last = seq;
                let terminal = is_terminal(&event);
                yield event;
                if terminal { return; }
            }
        }))
    }

    async fn current_checkpoint(&self, message_id: &str, checkpoint: Option<Checkpoint>) -> Result<Option<Checkpoint>> {
        let Some(mut checkpoint) = checkpoint else { return Ok(None); };
        // A periodic checkpoint can lag the live head. Bring it up to date
        // only with a contiguous tail; an old snapshot must not hide a hole.
        let tail = self.log.read_after(message_id, checkpoint.last_seq).await?;
        if tail.head > checkpoint.last_seq {
            if !tail.covered { return Err(Error::Unavailable); }
            let mut fold = FoldState::from_checkpoint(checkpoint.message, checkpoint.last_seq).map_err(crate::protocol_error)?;
            for event in tail.events { fold.apply(event).map_err(crate::protocol_error)?; }
            checkpoint.message = fold.message().map_err(crate::protocol_error)?;
            checkpoint.last_seq = fold.last_seq();
        }
        Ok(Some(checkpoint))
    }
}

fn snapshot_or_error(message_id: &str, checkpoint: Option<Checkpoint>, options: &ResumeOptions) -> Result<StreamEvent> {
    if !options.snapshots {
        // This is a connection-local transport error. It does not enter the
        // canonical event log or mutate the generation's sequence counter.
        return Ok(StreamEvent(json!({"protocolVersion":"0.1","type":"error","messageId":message_id,"seq":options.after.max(1),"error":{"code":"resume_unavailable","message":"Replay is no longer available","retryable":false}})));
    }
    let checkpoint = checkpoint.ok_or(Error::Unavailable)?;
    let snapshot = StreamEvent(json!({"protocolVersion":"0.1","type":"message.snapshot","messageId":message_id,"seq":checkpoint.last_seq,"message":checkpoint.message}));
    chatweave_protocol::Limits::default().check_event(&snapshot.0).map_err(|_| Error::Unavailable)?;
    Ok(snapshot)
}

/// The header has priority even when it is malformed; do not silently use the
/// query to bypass a bad header. A cursor is a nonnegative decimal integer.
pub fn parse_cursor(last_event_id: Option<&str>, after: Option<&str>) -> Result<u64> {
    match last_event_id.or(after) {
        None => Ok(0),
        Some(value) if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) =>
            value.parse().map_err(|_| Error::InvalidRequest("invalid cursor".into())),
        Some(_) => Err(Error::InvalidRequest("invalid cursor".into())),
    }
}

#[cfg(test)]
mod tests;
