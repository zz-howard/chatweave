use super::{
    ActionError, ActionOutcome, ActionStore, ActionTransaction, StoredActionResult, StoredBlock,
};
use crate::checkpoint::{Checkpoint, CheckpointStore, MemoryCheckpointStore};
use crate::event_log::{BroadcastHub, MemoryEventLog};
use crate::resume::ResumeService;
use crate::stream::{MessageStream, RecordedAnswer, StreamConfig, now_rfc3339};
use async_trait::async_trait;
use chatweave_protocol::{ActionRequest, ActionResult, DocumentKind, Message, Validator};
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, OwnedMutexGuard};
use tokio::time::Instant;

fn storage(error: impl std::fmt::Display) -> ActionError {
    ActionError::new("unavailable", &error.to_string())
}

type Key = (String, String);
type BlockKey = (String, String, String);
type BlockLocks = Arc<std::sync::Mutex<HashMap<BlockKey, Arc<Mutex<()>>>>>;

/// Default receipt and ended-message retention. Hosts with an offline retry
/// queue configure at least its longest retry period (security.md section 3).
pub const DEFAULT_RETENTION: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Default)]
struct Data {
    messages: HashMap<Key, (Message, Instant)>,
    results: HashMap<Key, (StoredActionResult, Instant)>,
    streams: HashMap<Key, MessageStream>,
}

impl Data {
    fn put_message(&mut self, key: Key, message: Message) {
        // Concurrent commits on different blocks may finish out of order;
        // never replace a newer revision with an older one.
        if self
            .messages
            .get(&key)
            .is_some_and(|(existing, _)| existing.rev() > message.rev())
        {
            return;
        }
        self.messages.insert(key, (message, Instant::now()));
    }
}

/// Scope is an opaque host-supplied partition. The default implementation is
/// process-local; durable stores must retain receipts for the host retry period.
type Resolver<Ctx> = Arc<dyn Fn(&Ctx) -> Option<String> + Send + Sync>;

/// Process-local reference store. Actions are serialised per block (protocol.md
/// section 5.2): the block reservation covers authorize, execute and commit,
/// while the store-wide map and the live stream are only locked briefly, never
/// across host callbacks.
pub struct MemoryActionStore<Ctx> {
    data: Arc<Mutex<Data>>,
    blocks: BlockLocks,
    retention: Duration,
    scope: Arc<dyn Fn(&Ctx) -> String + Send + Sync>,
    clock: Arc<dyn Fn() -> String + Send + Sync>,
    resolver: Resolver<Ctx>,
    validator: Arc<Validator>,
    log: Arc<MemoryEventLog>,
    sink: Arc<BroadcastHub>,
    checkpoints: Arc<MemoryCheckpointStore>,
}

impl<Ctx: Send + Sync + 'static> MemoryActionStore<Ctx> {
    pub fn new(scope: impl Fn(&Ctx) -> String + Send + Sync + 'static) -> Self {
        Self {
            data: Arc::default(),
            blocks: Arc::default(),
            retention: DEFAULT_RETENTION,
            scope: Arc::new(scope),
            clock: Arc::new(now_rfc3339),
            resolver: Arc::new(|_| None),
            validator: Arc::new(Validator::default()),
            log: Arc::default(),
            sink: Arc::default(),
            checkpoints: Arc::default(),
        }
    }
    pub fn with_clock(mut self, clock: impl Fn() -> String + Send + Sync + 'static) -> Self {
        self.clock = Arc::new(clock);
        self
    }
    pub fn with_validator(mut self, validator: Arc<Validator>) -> Self {
        self.validator = validator;
        self
    }
    pub fn with_resolver(
        mut self,
        resolver: impl Fn(&Ctx) -> Option<String> + Send + Sync + 'static,
    ) -> Self {
        self.resolver = Arc::new(resolver);
        self
    }
    /// How long action receipts and ended messages are kept after their last
    /// write. Unfinished (streaming/paused) messages are never released.
    pub fn with_retention(mut self, retention: Duration) -> Self {
        self.retention = retention;
        self
    }
    pub fn resume_service(&self) -> ResumeService {
        ResumeService::new(
            self.log.clone(),
            self.sink.clone(),
            self.checkpoints.clone(),
        )
    }

    /// Release receipts and ended messages older than the retention period.
    pub async fn cleanup(&self) {
        let retention = self.retention;
        let now = Instant::now();
        let streams: Vec<_> = {
            let data = self.data.lock().await;
            data.streams
                .iter()
                .map(|(key, stream)| (key.clone(), stream.clone()))
                .collect()
        };
        let mut unfinished = std::collections::HashSet::new();
        for (key, stream) in streams {
            if stream
                .message()
                .await
                .is_ok_and(|message| matches!(message.status(), "streaming" | "paused"))
            {
                unfinished.insert(key);
            }
        }
        let mut data = self.data.lock().await;
        data.results
            .retain(|_, (_, at)| now.duration_since(*at) < retention);
        let expired: Vec<Key> = data
            .messages
            .iter()
            .filter(|(key, (message, at))| {
                now.duration_since(*at) >= retention
                    && !unfinished.contains(*key)
                    && !matches!(message.status(), "streaming" | "paused")
            })
            .map(|(key, _)| key.clone())
            .collect();
        for key in expired {
            data.messages.remove(&key);
            data.streams.remove(&key);
        }
    }

    /// Retained (messages, receipts, live streams).
    pub async fn retained(&self) -> (usize, usize, usize) {
        let data = self.data.lock().await;
        (data.messages.len(), data.results.len(), data.streams.len())
    }

    pub async fn insert_message(&self, scope: &str, message: Message) -> Result<(), ActionError> {
        self.validator
            .validate(DocumentKind::Message, &message.0)
            .map_err(storage)?;
        let key = (scope.into(), message.id().to_owned());
        let live = if message.status() == "paused" {
            let last_seq = message.0["lastSeq"]
                .as_u64()
                .ok_or_else(|| storage("paused checkpoint lacks seq"))?;
            let checkpoint = Checkpoint::new(message.clone(), last_seq);
            self.checkpoints
                .commit(checkpoint.clone(), None)
                .await
                .map_err(storage)?;
            let mut config = StreamConfig::new(message.id());
            config.created_at = message.0["createdAt"].as_str().unwrap_or_default().into();
            Some(
                MessageStream::from_checkpoint(
                    checkpoint,
                    config,
                    self.validator.clone(),
                    self.log.clone(),
                    self.sink.clone(),
                    self.checkpoints.clone(),
                )
                .await
                .map_err(storage)?,
            )
        } else {
            None
        };
        let mut data = self.data.lock().await;
        if data.messages.contains_key(&key) {
            return Err(ActionError::new("conflict", "message already exists"));
        }
        data.messages.insert(key.clone(), (message, Instant::now()));
        if let Some(stream) = live {
            data.streams.insert(key, stream);
        }
        Ok(())
    }

    pub async fn attach_stream(
        &self,
        scope: &str,
        stream: MessageStream,
    ) -> Result<(), ActionError> {
        let message = stream.message().await.map_err(storage)?;
        let key = (scope.into(), message.id().to_owned());
        let mut data = self.data.lock().await;
        data.messages.insert(key.clone(), (message, Instant::now()));
        data.streams.insert(key, stream);
        Ok(())
    }

    pub async fn stream(&self, scope: &str, message_id: &str) -> Option<MessageStream> {
        self.data
            .lock()
            .await
            .streams
            .get(&(scope.into(), message_id.into()))
            .cloned()
    }
    /// Safe to call from handlers: no store lock is held during host callbacks.
    pub async fn load_message(
        &self,
        scope: &str,
        message_id: &str,
    ) -> Result<Message, ActionError> {
        let key = (scope.into(), message_id.into());
        let (live, stored) = {
            let data = self.data.lock().await;
            (
                data.streams.get(&key).cloned(),
                data.messages.get(&key).map(|(message, _)| message.clone()),
            )
        };
        if let Some(stream) = live {
            return stream.message().await.map_err(storage);
        }
        stored.ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
}

struct Transaction {
    data: Arc<Mutex<Data>>,
    blocks: BlockLocks,
    reservation: Option<OwnedMutexGuard<()>>,
    live: Option<MessageStream>,
    scope: String,
    message_id: String,
    block_id: String,
    now: String,
    validator: Arc<Validator>,
    resolved_by: Option<String>,
}

impl Drop for Transaction {
    fn drop(&mut self) {
        // Release the reservation first, then forget the lock if unused.
        self.reservation.take();
        let key = (
            self.scope.clone(),
            self.message_id.clone(),
            self.block_id.clone(),
        );
        if let Ok(mut blocks) = self.blocks.lock()
            && blocks
                .get(&key)
                .is_some_and(|lock| Arc::strong_count(lock) == 1)
        {
            blocks.remove(&key);
        }
    }
}

#[async_trait]
impl<Ctx: Send + Sync + 'static> ActionStore<Ctx> for MemoryActionStore<Ctx> {
    async fn begin(
        &self,
        ctx: &Ctx,
        message_id: &str,
        block_id: &str,
    ) -> Result<Box<dyn ActionTransaction>, ActionError> {
        let scope = (self.scope)(ctx);
        let key = (scope.clone(), message_id.to_owned());
        if !self.data.lock().await.messages.contains_key(&key) {
            return Err(ActionError::new("not_found", "请求被拒绝"));
        }
        let lock = self
            .blocks
            .lock()
            .map_err(storage)?
            .entry((scope.clone(), message_id.to_owned(), block_id.to_owned()))
            .or_default()
            .clone();
        let mut transaction = Transaction {
            data: self.data.clone(),
            blocks: self.blocks.clone(),
            reservation: None,
            live: None,
            scope,
            message_id: message_id.into(),
            block_id: block_id.into(),
            now: (self.clock)(),
            validator: self.validator.clone(),
            resolved_by: (self.resolver)(ctx),
        };
        // The per-block reservation spans the whole dispatch (load, authorize,
        // execute, commit), so two answers to one block never both execute.
        transaction.reservation = Some(lock.lock_owned().await);
        transaction.live = self.data.lock().await.streams.get(&key).cloned();
        Ok(Box::new(transaction))
    }
}

impl Transaction {
    fn key(&self) -> Key {
        (self.scope.clone(), self.message_id.clone())
    }
    async fn message(&self) -> Result<Message, ActionError> {
        if let Some(live) = &self.live {
            return live.message().await.map_err(storage);
        }
        self.data
            .lock()
            .await
            .messages
            .get(&self.key())
            .map(|(message, _)| message.clone())
            .ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
    fn block_index(&self, message: &Message) -> Result<usize, ActionError> {
        message.0["blocks"]
            .as_array()
            .and_then(|blocks| blocks.iter().position(|block| block["id"] == self.block_id))
            .ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
    fn open_index(&self, message: &Message) -> Result<usize, ActionError> {
        let index = self.block_index(message)?;
        let state_status = message.0["blocks"][index]["data"]["state"]["status"]
            .as_str()
            .unwrap_or("open");
        if state_status != "open" {
            return Err(ActionError::new("already_resolved", "问题已经回答"));
        }
        Ok(index)
    }
    /// Read-modify-write of a non-interrupt block state with `rev + 1`, under
    /// the live stream lock or the store lock (whichever owns the message).
    async fn revise(
        &mut self,
        update: impl FnOnce(&mut Message, usize) -> Result<(), ActionError> + Send,
    ) -> Result<Message, ActionError> {
        let message = if let Some(live) = &self.live {
            let mut inner = live.inner.lock().await;
            let mut message = inner.message().map_err(storage)?;
            if matches!(message.status(), "streaming" | "paused") {
                return Err(ActionError::new(
                    "conflict",
                    "unfinished non-interrupt block",
                ));
            }
            let index = self.block_index(&message)?;
            update(&mut message, index)?;
            self.validator
                .validate(DocumentKind::Message, &message.0)
                .map_err(storage)?;
            inner
                .replace_persisted(message.clone())
                .await
                .map_err(storage)?;
            self.data
                .lock()
                .await
                .put_message(self.key(), message.clone());
            message
        } else {
            // Held across the (synchronous) update: commits on other blocks of
            // the same message cannot interleave and lose a revision.
            let mut data = self.data.lock().await;
            let mut message = data
                .messages
                .get(&self.key())
                .map(|(message, _)| message.clone())
                .ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))?;
            if matches!(message.status(), "streaming" | "paused") {
                return Err(ActionError::new(
                    "conflict",
                    "unfinished non-interrupt block",
                ));
            }
            let index = self.block_index(&message)?;
            update(&mut message, index)?;
            self.validator
                .validate(DocumentKind::Message, &message.0)
                .map_err(storage)?;
            data.put_message(self.key(), message.clone());
            message
        };
        Ok(message)
    }
}

#[async_trait]
impl ActionTransaction for Transaction {
    async fn load_block(&mut self) -> Result<StoredBlock, ActionError> {
        let message = self.message().await?;
        let block = message.0["blocks"][self.block_index(&message)?].clone();
        Ok(StoredBlock {
            message,
            block,
            now: self.now.clone(),
        })
    }
    async fn find_result(
        &mut self,
        action_id: &str,
    ) -> Result<Option<StoredActionResult>, ActionError> {
        Ok(self
            .data
            .lock()
            .await
            .results
            .get(&(self.scope.clone(), action_id.into()))
            .map(|(result, _)| result.clone()))
    }
    async fn expire(&mut self) -> Result<StoredBlock, ActionError> {
        let message = self.message().await?;
        if message.status() == "paused" && message.0["interrupt"]["blockId"] == self.block_id {
            let live = self
                .live
                .as_ref()
                .ok_or_else(|| storage("missing paused runtime"))?;
            let mut inner = live.inner.lock().await;
            inner
                .terminate("interrupt_expired", "Confirmation expired", "cancelled")
                .await
                .map_err(storage)?;
            let message = inner.message().map_err(storage)?;
            drop(inner);
            self.data.lock().await.put_message(self.key(), message);
        } else {
            match self
                .revise(|message, index| {
                    message.0["blocks"][index]["data"]["state"] = json!({"status":"expired"});
                    message.0["rev"] = json!(message.rev() + 1);
                    Ok(())
                })
                .await
            {
                Ok(_) => {}
                // Already moved on (another answer won): report its state.
                Err(error) if error.code == "already_resolved" => {}
                Err(error) => return Err(error),
            }
        }
        self.load_block().await
    }
    async fn commit(
        &mut self,
        request: &ActionRequest,
        binding: &str,
        outcome: ActionOutcome,
    ) -> Result<ActionResult, ActionError> {
        let action_id: String = request.0["id"]
            .as_str()
            .ok_or_else(|| storage("missing action id"))?
            .into();
        let mut state = request.0["payload"].clone();
        state["status"] = json!("resolved");
        state["resolvedAt"] = json!(self.now);
        if let Some(by) = &self.resolved_by {
            state["resolvedBy"] = json!(by);
        }
        let interrupt = self.message().await.is_ok_and(|message| {
            message.status() == "paused" && message.0["interrupt"]["blockId"] == self.block_id
        });
        let result = if interrupt {
            let live = self
                .live
                .as_ref()
                .ok_or_else(|| storage("missing paused runtime"))?;
            // The stream lock is held only for this check-and-resume, never
            // across authorize/execute.
            let mut inner = live.inner.lock().await;
            let message = inner.message().map_err(storage)?;
            if message.status() != "paused" || message.0["interrupt"]["blockId"] != self.block_id {
                return Err(ActionError::new("conflict", "interrupt is no longer open"));
            }
            self.open_index(&message)?;
            let interrupt_id = message.0["interrupt"]["id"]
                .as_str()
                .ok_or_else(|| storage("missing interrupt"))?
                .to_owned();
            inner
                .resume_locked(RecordedAnswer {
                    interrupt_id,
                    payload: request.0["payload"].clone(),
                    resolved_at: self.now.clone(),
                    resolved_by: self.resolved_by.clone(),
                })
                .await
                .map_err(storage)?;
            let message = inner.message().map_err(storage)?;
            drop(inner);
            self.data.lock().await.put_message(self.key(), message);
            json!({"actionId":action_id,"status":"accepted","resume":{"messageId":self.message_id,"streamable":true}})
        } else {
            let block_id = self.block_id.clone();
            let patch_state = state.clone();
            let message = self
                .revise(move |message, index| {
                    if message.0["blocks"][index]["id"] != block_id
                        || message.0["blocks"][index]["data"]["state"]["status"]
                            .as_str()
                            .unwrap_or("open")
                            != "open"
                    {
                        return Err(ActionError::new("already_resolved", "问题已经回答"));
                    }
                    message.0["blocks"][index]["data"]["state"] = patch_state;
                    message.0["rev"] = json!(message.rev() + 1);
                    Ok(())
                })
                .await?;
            let mut result = json!({"actionId":action_id,"status":outcome.status,"patches":[{"messageId":self.message_id,"blockId":self.block_id,"rev":message.rev(),"patch":{"data":{"state":state}}}]});
            if let Some(follow_up) = outcome.follow_up {
                result["followUp"] = follow_up;
            }
            result
        };
        self.validator
            .validate(DocumentKind::ActionResult, &result)
            .map_err(storage)?;
        let result = ActionResult(result);
        self.data.lock().await.results.insert(
            (self.scope.clone(), action_id),
            (
                StoredActionResult {
                    binding: binding.into(),
                    result: result.clone(),
                },
                Instant::now(),
            ),
        );
        Ok(result)
    }
}
