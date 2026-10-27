use super::{ActionError, ActionOutcome, ActionStore, ActionTransaction, StoredActionResult, StoredBlock};
use crate::checkpoint::{Checkpoint, CheckpointStore, MemoryCheckpointStore};
use crate::event_log::{BroadcastHub, MemoryEventLog};
use crate::resume::ResumeService;
use crate::stream::{Inner, MessageStream, RecordedAnswer, StreamConfig, now_rfc3339};
use async_trait::async_trait;
use chatweave_protocol::{ActionRequest, ActionResult, DocumentKind, Message, Validator};
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, OwnedMutexGuard};

fn storage(error: impl std::fmt::Display) -> ActionError { ActionError::new("unavailable", &error.to_string()) }

#[derive(Default)]
struct Data {
    messages: HashMap<(String, String), Message>,
    results: HashMap<(String, String), StoredActionResult>,
    streams: HashMap<(String, String), MessageStream>,
}

/// Scope is an opaque host-supplied partition. The default implementation is
/// process-local; durable stores must retain receipts for the host retry period.
pub struct MemoryActionStore<Ctx> {
    data: Arc<Mutex<Data>>,
    scope: Arc<dyn Fn(&Ctx) -> String + Send + Sync>,
    clock: Arc<dyn Fn() -> String + Send + Sync>,
    resolver: Arc<dyn Fn(&Ctx) -> Option<String> + Send + Sync>,
    validator: Arc<Validator>,
    log: Arc<MemoryEventLog>,
    sink: Arc<BroadcastHub>,
    checkpoints: Arc<MemoryCheckpointStore>,
}

impl<Ctx: Send + Sync + 'static> MemoryActionStore<Ctx> {
    pub fn new(scope: impl Fn(&Ctx) -> String + Send + Sync + 'static) -> Self {
        Self { data: Arc::default(), scope: Arc::new(scope), clock: Arc::new(now_rfc3339), resolver: Arc::new(|_| None), validator: Arc::new(Validator::default()), log: Arc::default(), sink: Arc::default(), checkpoints: Arc::default() }
    }
    pub fn with_clock(mut self, clock: impl Fn() -> String + Send + Sync + 'static) -> Self { self.clock = Arc::new(clock); self }
    pub fn with_validator(mut self, validator: Arc<Validator>) -> Self { self.validator = validator; self }
    pub fn with_resolver(mut self, resolver: impl Fn(&Ctx) -> Option<String> + Send + Sync + 'static) -> Self { self.resolver = Arc::new(resolver); self }
    pub fn resume_service(&self) -> ResumeService { ResumeService::new(self.log.clone(), self.sink.clone(), self.checkpoints.clone()) }

    pub async fn insert_message(&self, scope: &str, message: Message) -> Result<(), ActionError> {
        self.validator.validate(DocumentKind::Message, &message.0).map_err(storage)?;
        let key = (scope.into(), message.id().to_owned());
        let live = if message.status() == "paused" {
            let last_seq = message.0["lastSeq"].as_u64().ok_or_else(|| storage("paused checkpoint lacks seq"))?;
            let checkpoint = Checkpoint::new(message.clone(), last_seq);
            self.checkpoints.commit(checkpoint.clone(), None).await.map_err(storage)?;
            let mut config = StreamConfig::new(message.id());
            config.created_at = message.0["createdAt"].as_str().unwrap_or_default().into();
            Some(MessageStream::from_checkpoint(checkpoint, config, self.validator.clone(), self.log.clone(), self.sink.clone(), self.checkpoints.clone()).await.map_err(storage)?)
        } else { None };
        let mut data = self.data.lock().await;
        if data.messages.contains_key(&key) { return Err(ActionError::new("conflict", "message already exists")); }
        data.messages.insert(key.clone(), message);
        if let Some(stream) = live { data.streams.insert(key, stream); }
        Ok(())
    }

    pub async fn attach_stream(&self, scope: &str, stream: MessageStream) -> Result<(), ActionError> {
        let message = stream.message().await.map_err(storage)?;
        let key = (scope.into(), message.id().to_owned());
        let mut data = self.data.lock().await;
        data.messages.insert(key.clone(), message);
        data.streams.insert(key, stream);
        Ok(())
    }

    pub async fn stream(&self, scope: &str, message_id: &str) -> Option<MessageStream> {
        self.data.lock().await.streams.get(&(scope.into(), message_id.into())).cloned()
    }
    pub async fn load_message(&self, scope: &str, message_id: &str) -> Result<Message, ActionError> {
        let data = self.data.lock().await;
        let key = (scope.into(), message_id.into());
        if let Some(stream) = data.streams.get(&key) { return stream.message().await.map_err(storage); }
        data.messages.get(&key).cloned().ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
}

struct Transaction {
    data: OwnedMutexGuard<Data>,
    live: Option<OwnedMutexGuard<Inner>>,
    scope: String,
    message_id: String,
    block_id: String,
    now: String,
    validator: Arc<Validator>,
    resolved_by: Option<String>,
}

#[async_trait]
impl<Ctx: Send + Sync + 'static> ActionStore<Ctx> for MemoryActionStore<Ctx> {
    async fn begin(&self, ctx: &Ctx, message_id: &str, block_id: &str) -> Result<Box<dyn ActionTransaction>, ActionError> {
        let scope = (self.scope)(ctx);
        let data = self.data.clone().lock_owned().await;
        let key = (scope.clone(), message_id.to_owned());
        if !data.messages.contains_key(&key) { return Err(ActionError::new("not_found", "请求被拒绝")); }
        let live = if let Some(stream) = data.streams.get(&key) { Some(stream.inner.clone().lock_owned().await) } else { None };
        Ok(Box::new(Transaction { data, live, scope, message_id: message_id.into(), block_id: block_id.into(), now: (self.clock)(), validator: self.validator.clone(), resolved_by: (self.resolver)(ctx) }))
    }
}

impl Transaction {
    fn message(&self) -> Result<Message, ActionError> {
        if let Some(live) = &self.live { return live.message().map_err(storage); }
        self.data.messages.get(&(self.scope.clone(), self.message_id.clone())).cloned().ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
    fn block_index(&self, message: &Message) -> Result<usize, ActionError> {
        message.0["blocks"].as_array().and_then(|blocks| blocks.iter().position(|block| block["id"] == self.block_id)).ok_or_else(|| ActionError::new("not_found", "请求被拒绝"))
    }
}

#[async_trait]
impl ActionTransaction for Transaction {
    async fn load_block(&mut self) -> Result<StoredBlock, ActionError> {
        let message = self.message()?;
        let block = message.0["blocks"][self.block_index(&message)?].clone();
        Ok(StoredBlock { message, block, now: self.now.clone() })
    }
    async fn find_result(&mut self, action_id: &str) -> Result<Option<StoredActionResult>, ActionError> {
        Ok(self.data.results.get(&(self.scope.clone(), action_id.into())).cloned())
    }
    async fn expire(&mut self) -> Result<StoredBlock, ActionError> {
        let mut message = self.message()?;
        let index = self.block_index(&message)?;
        if message.status() == "paused" {
            let live = self.live.as_mut().ok_or_else(|| storage("missing paused runtime"))?;
            live.terminate("interrupt_expired", "Confirmation expired", "cancelled").await.map_err(storage)?;
            message = live.message().map_err(storage)?;
        } else {
            message.0["blocks"][index]["data"]["state"] = json!({"status":"expired"});
            message.0["rev"] = json!(message.rev() + 1);
        }
        self.validator.validate(DocumentKind::Message, &message.0).map_err(storage)?;
        if message.rev() > 0 {
            if let Some(live) = self.live.as_mut() { live.replace_persisted(message.clone()).await.map_err(storage)?; }
        }
        self.data.messages.insert((self.scope.clone(), self.message_id.clone()), message);
        self.load_block().await
    }
    async fn commit(&mut self, request: &ActionRequest, binding: &str, outcome: ActionOutcome) -> Result<ActionResult, ActionError> {
        let mut message = self.message()?;
        let index = self.block_index(&message)?;
        let state_status = message.0["blocks"][index]["data"]["state"]["status"].as_str().unwrap_or("open");
        if state_status != "open" { return Err(ActionError::new("already_resolved", "问题已经回答")); }
        let mut state = request.0["payload"].clone();
        state["status"] = json!("resolved");
        state["resolvedAt"] = json!(self.now);
        if let Some(by) = &self.resolved_by { state["resolvedBy"] = json!(by); }
        let result = if message.status() == "paused" && message.0["interrupt"]["blockId"] == self.block_id {
            let interrupt_id = message.0["interrupt"]["id"].as_str().ok_or_else(|| storage("missing interrupt"))?.to_owned();
            let live = self.live.as_mut().ok_or_else(|| storage("missing paused runtime"))?;
            live.resume_locked(RecordedAnswer { interrupt_id, payload: request.0["payload"].clone(), resolved_at: self.now.clone(), resolved_by: self.resolved_by.clone() }).await.map_err(storage)?;
            message = live.message().map_err(storage)?;
            json!({"actionId":request.0["id"],"status":"accepted","resume":{"messageId":self.message_id,"streamable":true}})
        } else {
            if matches!(message.status(), "streaming" | "paused") { return Err(ActionError::new("conflict", "unfinished non-interrupt block")); }
            let rev = message.rev() + 1;
            message.0["blocks"][index]["data"]["state"] = state.clone();
            message.0["rev"] = json!(rev);
            let mut result = json!({"actionId":request.0["id"],"status":outcome.status,"patches":[{"messageId":self.message_id,"blockId":self.block_id,"rev":rev,"patch":{"data":{"state":state}}}]});
            if let Some(follow_up) = outcome.follow_up { result["followUp"] = follow_up; }
            result
        };
        self.validator.validate(DocumentKind::Message, &message.0).map_err(storage)?;
        self.validator.validate(DocumentKind::ActionResult, &result).map_err(storage)?;
        if message.rev() > 0 {
            if let Some(live) = self.live.as_mut() { live.replace_persisted(message.clone()).await.map_err(storage)?; }
        }
        let result = ActionResult(result);
        self.data.messages.insert((self.scope.clone(), self.message_id.clone()), message);
        self.data.results.insert((self.scope.clone(), request.0["id"].as_str().ok_or_else(|| storage("missing action id"))?.into()), StoredActionResult { binding: binding.into(), result: result.clone() });
        Ok(result)
    }
}
