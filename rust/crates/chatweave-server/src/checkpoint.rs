use crate::{Error, Result};
use async_trait::async_trait;
use chatweave_protocol::Message;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone, Debug)]
pub struct Checkpoint {
    pub message: Message,
    pub last_seq: u64,
    /// Producer timing state, never serialized into the protocol Message.
    pub step_work_ms: HashMap<String, u64>,
}
impl Checkpoint {
    pub fn new(message: Message, last_seq: u64) -> Self {
        Self {
            message,
            last_seq,
            step_work_ms: HashMap::new(),
        }
    }
}

#[async_trait]
pub trait CheckpointStore: Send + Sync {
    async fn load(&self, message_id: &str) -> Result<Option<Checkpoint>>;
    /// Conditional, monotonic replacement. Pause and end commits are mandatory.
    async fn commit(&self, checkpoint: Checkpoint, expected_seq: Option<u64>) -> Result<()>;
}

#[derive(Clone, Default)]
pub struct MemoryCheckpointStore(Arc<Mutex<HashMap<String, Checkpoint>>>);

#[async_trait]
impl CheckpointStore for MemoryCheckpointStore {
    async fn load(&self, message_id: &str) -> Result<Option<Checkpoint>> {
        Ok(self.0.lock().await.get(message_id).cloned())
    }
    async fn commit(&self, checkpoint: Checkpoint, expected_seq: Option<u64>) -> Result<()> {
        let mut messages = self.0.lock().await;
        let id = checkpoint.message.0["id"]
            .as_str()
            .ok_or_else(|| Error::InvalidRequest("missing message id".into()))?
            .to_owned();
        if let Some(previous) = messages.get(&id) {
            if checkpoint.last_seq < previous.last_seq
                || checkpoint.message.rev() < previous.message.rev()
                || expected_seq.is_some_and(|seq| seq != previous.last_seq)
            {
                return Err(Error::Conflict);
            }
        } else if expected_seq.is_some() {
            return Err(Error::Conflict);
        }
        messages.insert(id, checkpoint);
        Ok(())
    }
}
