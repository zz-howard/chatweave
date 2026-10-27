use crate::checkpoint::{Checkpoint, CheckpointStore};
use crate::event_log::{EventLog, EventSink};
use crate::{Error, Result, markdown, protocol_error};
use chatweave_protocol::{DocumentKind, FoldState, Message, StreamEvent, Validator};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;

pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).expect("RFC3339 timestamp")
}

#[derive(Clone)]
pub struct StreamConfig {
    pub message_id: String,
    pub conversation_id: Option<String>,
    pub created_at: String,
    pub metadata: Option<Value>,
    pub delta_chars: usize,
    pub delta_interval: Duration,
    pub checkpoint_interval: Duration,
    pub max_events: u64,
}

impl StreamConfig {
    pub fn new(message_id: impl Into<String>) -> Self {
        Self { message_id: message_id.into(), conversation_id: None, created_at: now_rfc3339(), metadata: None, delta_chars: 20, delta_interval: Duration::from_millis(50), checkpoint_interval: Duration::from_secs(5), max_events: 5_000 }
    }
}

#[derive(Clone)]
pub struct MessageStream { pub(crate) inner: Arc<Mutex<Inner>> }

pub(crate) struct StepClock {
    accumulated: Duration,
    since: Option<Instant>,
    parent: Option<String>,
    ended: bool,
}

pub(crate) struct Inner {
    pub(crate) config: StreamConfig,
    pub(crate) folder: FoldState,
    validator: Arc<Validator>,
    log: Arc<dyn EventLog>,
    sink: Arc<dyn EventSink>,
    checkpoints: Arc<dyn CheckpointStore>,
    next_block: u64,
    next_step: u64,
    clocks: HashMap<String, StepClock>,
    pending: HashMap<String, String>,
    last_delta: Instant,
    last_checkpoint: Instant,
    failed: bool,
    fallback: String,
}

impl Inner {
    pub(crate) async fn replace_persisted(&mut self, message: Message) -> Result<()> {
        if message.rev() < self.message()?.rev() { return Err(Error::Conflict); }
        self.validator.validate(DocumentKind::Message, &message.0).map_err(protocol_error)?;
        let seq = self.folder.last_seq();
        let candidate = FoldState::from_checkpoint(message, seq).map_err(protocol_error)?;
        self.checkpoints.commit(self.timing_checkpoint(candidate.message().map_err(protocol_error)?, seq), None).await?;
        self.folder = candidate;
        Ok(())
    }
    fn timing_checkpoint(&self, message: Message, last_seq: u64) -> Checkpoint {
        let step_work_ms = self.clocks.iter().filter(|(_, clock)| !clock.ended).map(|(id, clock)| {
            let elapsed = clock.accumulated + clock.since.map(|since| since.elapsed()).unwrap_or_default();
            (id.clone(), elapsed.as_millis().min(86_400_000) as u64)
        }).collect();
        Checkpoint { message, last_seq, step_work_ms }
    }
    pub(crate) fn message(&self) -> Result<Message> {
        let mut message = self.folder.message().map_err(protocol_error)?;
        if message.status() == "streaming" { message.0["fallbackText"] = json!(self.fallback); }
        Ok(message)
    }

    async fn emit_unchecked(&mut self, mut value: Value) -> Result<()> {
        if self.failed { return Err(Error::Conflict); }
        let next = self.folder.last_seq() + 1;
        value["protocolVersion"] = json!("0.1");
        value["messageId"] = json!(self.config.message_id);
        value["seq"] = json!(next);
        if value["type"] == "message.end" { value["ts"] = json!(now_rfc3339()); }
        self.validator.validate(DocumentKind::Event, &value).map_err(protocol_error)?;
        let event = StreamEvent(value);
        let mut candidate = self.folder.clone();
        candidate.apply(event.clone()).map_err(protocol_error)?;
        let mut candidate_message = candidate.message().map_err(protocol_error)?;
        let next_fallback = if candidate_message.status() == "streaming" && event.0["type"].as_str().is_some_and(|ty| ty.starts_with("block.")) {
            markdown::fallback_text(&candidate_message)
        } else if event.0["type"] == "message.resumed" || candidate_message.status() != "streaming" {
            candidate_message.0["fallbackText"].as_str().unwrap_or_default().to_owned()
        } else { self.fallback.clone() };
        if candidate_message.status() == "streaming" { candidate_message.0["fallbackText"] = json!(next_fallback); }
        if let Some(id) = event.0["blockId"].as_str() {
            if let Some(block) = candidate_message.0["blocks"].as_array().into_iter().flatten().find(|block| block["id"] == id) {
                self.validator.validate(DocumentKind::Block, block).map_err(protocol_error)?;
            }
        }
        let paused_transition = self.folder.message().is_ok_and(|message| message.status() == "paused")
            && !matches!(event.0["type"].as_str(), Some("message.resumed" | "message.end"));
        let checkpoint = !paused_transition && (matches!(event.0["type"].as_str(), Some("block.end" | "message.paused" | "message.resumed" | "message.end"))
            || self.last_checkpoint.elapsed() >= self.config.checkpoint_interval);
        let message = checkpoint.then_some(candidate_message);
        if let Some(message) = &message { self.validator.validate(DocumentKind::Message, &message.0).map_err(protocol_error)?; }
        // After a failed durable commit the stream is poisoned; no uncommitted
        // transition is broadcast or followed by further production.
        if let Some(message) = message {
            if let Err(error) = self.checkpoints.commit(self.timing_checkpoint(message, next), None).await {
                self.failed = true;
                return Err(error);
            }
            self.last_checkpoint = Instant::now();
        }
        if let Err(error) = self.log.append(event.clone()).await {
            self.failed = true;
            return Err(error);
        }
        self.folder = candidate;
        self.fallback = next_fallback;
        self.sink.publish(event).await
    }

    async fn emit(&mut self, value: Value) -> Result<()> {
        let closing = matches!(value["type"].as_str(), Some("block.end" | "step.finished" | "message.end"));
        let open_blocks = self.message()?.0["blocks"].as_array().into_iter().flatten().filter(|block| block["status"] == "pending").count() as u64;
        let active_steps = self.clocks.values().filter(|clock| !clock.ended).count() as u64;
        // Reserve each open block/step, a possible newly started item and end.
        let reserve = open_blocks + active_steps + self.pending.len() as u64 + 2;
        if !closing && (self.folder.last_seq() + reserve >= self.config.max_events
            || serde_json::to_vec(&value).map_err(protocol_error)?.len() + 256 > 128 * 1024)
        {
            self.terminate("limit_exceeded", "Content limit reached", "cancelled").await?;
            return Err(Error::Protocol("limit_exceeded".into()));
        }
        let result = self.emit_unchecked(value).await;
        if matches!(&result, Err(Error::Protocol(message)) if message.contains("limit_exceeded")) {
            self.terminate("limit_exceeded", "Content limit reached", "cancelled").await?;
        }
        result
    }

    async fn flush_text(&mut self, id: &str) -> Result<()> {
        let Some(text) = self.pending.remove(id) else { return Ok(()); };
        let mut chunk = String::new();
        for character in text.chars() {
            if chunk.len() + character.len_utf8() > 4096 {
                self.emit(json!({"type":"block.delta","blockId":id,"delta":{"text":chunk}})).await?;
                chunk = String::new();
            }
            chunk.push(character);
        }
        if !chunk.is_empty() { self.emit(json!({"type":"block.delta","blockId":id,"delta":{"text":chunk}})).await?; }
        self.last_delta = Instant::now();
        Ok(())
    }

    async fn flush_all(&mut self) -> Result<()> {
        let mut ids: Vec<_> = self.pending.keys().cloned().collect();
        ids.sort();
        for id in ids { self.flush_text(&id).await?; }
        Ok(())
    }

    async fn finish_step_locked(&mut self, id: &str, state: &str, summary: Option<String>) -> Result<()> {
        let clock = self.clocks.get(id).ok_or_else(|| Error::InvalidRequest("unknown step".into()))?;
        if clock.ended || self.clocks.values().any(|child| child.parent.as_deref() == Some(id) && !child.ended) {
            return Err(Error::Conflict);
        }
        let duration = clock.accumulated + clock.since.map(|since| since.elapsed()).unwrap_or_default();
        let mut value = json!({"type":"step.finished","stepId":id,"state":state,"durationMs":duration.as_millis().min(86_400_000) as u64});
        if let Some(summary) = summary { value["summary"] = json!(summary); }
        self.emit_unchecked(value).await?;
        if let Some(clock) = self.clocks.get_mut(id) { clock.ended = true; }
        Ok(())
    }

    pub(crate) async fn resume_locked(&mut self, answer: RecordedAnswer) -> Result<()> {
        let message = self.message()?;
        if message.0["status"] != "paused" || message.0["interrupt"]["id"] != answer.interrupt_id {
            return Err(Error::Conflict);
        }
        let block_id = message.0["interrupt"]["blockId"].clone();
        let mut state = answer.payload;
        if !state.is_object() { return Err(Error::InvalidRequest("answer payload must be an object".into())); }
        state["status"] = json!("resolved");
        state["resolvedAt"] = json!(answer.resolved_at);
        if let Some(by) = answer.resolved_by { state["resolvedBy"] = json!(by); }
        let mut candidate = self.folder.clone();
        let mut events = Vec::new();
        for mut value in [json!({"type":"block.patch","blockId":block_id,"patch":{"data":{"state":state}}}), json!({"type":"message.resumed","interruptId":answer.interrupt_id})] {
            value["protocolVersion"] = json!("0.1");
            value["messageId"] = json!(self.config.message_id);
            value["seq"] = json!(candidate.last_seq() + 1);
            self.validator.validate(DocumentKind::Event, &value).map_err(protocol_error)?;
            let event = StreamEvent(value);
            candidate.apply(event.clone()).map_err(protocol_error)?;
            events.push(event);
        }
        let resumed = candidate.message().map_err(protocol_error)?;
        self.validator.validate(DocumentKind::Message, &resumed.0).map_err(protocol_error)?;
        // Commit the answer and continuation position together before either
        // event is externally visible. No durable resolved-but-paused state.
        self.checkpoints.commit(self.timing_checkpoint(resumed, candidate.last_seq()), None).await?;
        for event in &events {
            if let Err(error) = self.log.append(event.clone()).await { self.failed = true; return Err(error); }
        }
        self.folder = candidate;
        self.last_checkpoint = Instant::now();
        for clock in self.clocks.values_mut().filter(|clock| !clock.ended) { clock.since = Some(Instant::now()); }
        for event in events { self.sink.publish(event).await?; }
        Ok(())
    }

    pub(crate) async fn terminate(&mut self, code: &str, description: &str, step_state: &str) -> Result<()> {
        self.terminate_with_status(code, description, step_state, "interrupted").await
    }

    async fn terminate_with_status(&mut self, code: &str, description: &str, step_state: &str, status: &str) -> Result<()> {
        if self.failed { return Err(Error::Conflict); }
        let message = self.message()?;
        if !matches!(message.status(), "streaming" | "paused") { return Ok(()); }
        let mut values = Vec::new();
        if message.status() == "paused" {
            let state = if code == "interrupt_expired" { json!({"status":"expired"}) } else { json!({"status":"cancelled","reason":{"code":"stopped"}}) };
            values.push(json!({"type":"block.patch","blockId":message.0["interrupt"]["blockId"],"patch":{"data":{"state":state}}}));
        } else {
            for (id, text) in &self.pending {
                for chunk in utf8_chunks(text, 4096) { values.push(json!({"type":"block.delta","blockId":id,"delta":{"text":chunk}})); }
            }
            for block in message.0["blocks"].as_array().into_iter().flatten().filter(|block| block["status"] == "pending") {
                if block.get("data").is_some() {
                    values.push(json!({"type":"block.end","blockId":block["id"],"status":"complete"}));
                } else {
                    values.push(json!({"type":"block.end","blockId":block["id"],"status":"error","fallbackText":block["fallbackText"],"error":{"code":"cancelled","message":"Content unavailable"}}));
                }
            }
        }
        // Reverse start order gives a child-before-parent topological order.
        for step in message.0["steps"].as_array().into_iter().flatten().rev().filter(|step| matches!(step["state"].as_str(), Some("running" | "awaiting_user"))) {
            let id = step["id"].as_str().ok_or(Error::Conflict)?;
            let clock = self.clocks.get(id).ok_or(Error::Conflict)?;
            let duration = clock.accumulated + clock.since.map(|since| since.elapsed()).unwrap_or_default();
            values.push(json!({"type":"step.finished","stepId":id,"state":step_state,"durationMs":duration.as_millis().min(86_400_000) as u64}));
        }
        let mut candidate = self.folder.clone();
        let mut events = Vec::new();
        for mut value in values {
            value["protocolVersion"] = json!("0.1");
            value["messageId"] = json!(self.config.message_id);
            value["seq"] = json!(candidate.last_seq() + 1);
            self.validator.validate(DocumentKind::Event, &value).map_err(protocol_error)?;
            let event = StreamEvent(value);
            candidate.apply(event.clone()).map_err(protocol_error)?;
            events.push(event);
        }
        let preview = candidate.message().map_err(protocol_error)?;
        let fallback = if status == "error" { description.to_owned() } else { markdown::fallback_text(&preview) };
        let end = StreamEvent(json!({"protocolVersion":"0.1","messageId":self.config.message_id,"seq":candidate.last_seq()+1,"type":"message.end","ts":now_rfc3339(),"status":status,"rev":1,"fallbackText":fallback,"blockCount":preview.0["blocks"].as_array().map_or(0, Vec::len),"error":{"code":code,"message":description}}));
        self.validator.validate(DocumentKind::Event, &end.0).map_err(protocol_error)?;
        candidate.apply(end.clone()).map_err(protocol_error)?;
        if candidate.last_seq() > self.config.max_events { return Err(Error::Protocol("limit_exceeded".into())); }
        let final_message = candidate.message().map_err(protocol_error)?;
        self.validator.validate(DocumentKind::Message, &final_message.0).map_err(protocol_error)?;
        events.push(end);
        // Publish the complete closing checkpoint before exposing any partial
        // closing sequence. Snapshots cannot observe an invalid paused state.
        self.checkpoints.commit(self.timing_checkpoint(final_message, candidate.last_seq()), None).await?;
        for event in &events {
            if let Err(error) = self.log.append(event.clone()).await { self.failed = true; return Err(error); }
        }
        self.folder = candidate;
        self.pending.clear();
        for clock in self.clocks.values_mut() { clock.ended = true; clock.since = None; }
        for event in events { self.sink.publish(event).await?; }
        Ok(())
    }

}

fn utf8_chunks(text: &str, max_bytes: usize) -> Vec<String> {
    let mut output = Vec::new();
    let mut chunk = String::new();
    for character in text.chars() {
        if chunk.len() + character.len_utf8() > max_bytes { output.push(std::mem::take(&mut chunk)); }
        chunk.push(character);
    }
    if !chunk.is_empty() { output.push(chunk); }
    output
}

#[derive(Clone, Debug)]
pub struct RecordedAnswer {
    pub interrupt_id: String,
    pub payload: Value,
    pub resolved_at: String,
    pub resolved_by: Option<String>,
}

impl MessageStream {
    pub async fn start(config: StreamConfig, validator: Arc<Validator>, log: Arc<dyn EventLog>, sink: Arc<dyn EventSink>, checkpoints: Arc<dyn CheckpointStore>) -> Result<Self> {
        if !(2..=5000).contains(&config.max_events) { return Err(Error::InvalidRequest("event budget must allow start/end and may not exceed 5000".into())); }
        let mut message = json!({"id":config.message_id,"role":"assistant","createdAt":config.created_at});
        if let Some(id) = &config.conversation_id { message["conversationId"] = json!(id); }
        if let Some(metadata) = &config.metadata { message["metadata"] = metadata.clone(); }
        let mut inner = Inner { config, validator, log, sink, checkpoints, folder: FoldState::new(), next_block: 1, next_step: 1, clocks: HashMap::new(), pending: HashMap::new(), last_delta: Instant::now(), last_checkpoint: Instant::now(), failed: false, fallback: String::new() };
        inner.emit_unchecked(json!({"type":"message.start","message":message})).await?;
        Ok(Self { inner: Arc::new(Mutex::new(inner)) })
    }

    pub async fn from_checkpoint(checkpoint: Checkpoint, config: StreamConfig, validator: Arc<Validator>, log: Arc<dyn EventLog>, sink: Arc<dyn EventSink>, checkpoints: Arc<dyn CheckpointStore>) -> Result<Self> {
        if checkpoint.message.0["id"] != config.message_id { return Err(Error::Conflict); }
        validator.validate(DocumentKind::Message, &checkpoint.message.0).map_err(protocol_error)?;
        let folder = FoldState::from_checkpoint(checkpoint.message, checkpoint.last_seq).map_err(protocol_error)?;
        let message = folder.message().map_err(protocol_error)?;
        let clocks = message.0["steps"].as_array().into_iter().flatten().filter_map(|step| {
            let id = step["id"].as_str()?.to_owned();
            let accumulated = Duration::from_millis(checkpoint.step_work_ms.get(&id).copied().unwrap_or(0));
            Some((id, StepClock { accumulated, since: None, parent: step["parentStepId"].as_str().map(str::to_owned), ended: !matches!(step["state"].as_str(), Some("running" | "awaiting_user")) }))
        }).collect();
        let next_block = message.0["blocks"].as_array().map_or(0, Vec::len) as u64 + 1;
        let next_step = message.0["steps"].as_array().map_or(0, Vec::len) as u64 + 1;
        let fallback = message.0["fallbackText"].as_str().unwrap_or_default().to_owned();
        Ok(Self { inner: Arc::new(Mutex::new(Inner { config, folder, validator, log, sink, checkpoints, next_block, next_step, clocks, pending: HashMap::new(), last_delta: Instant::now(), last_checkpoint: Instant::now(), failed: false, fallback })) })
    }

    pub async fn message(&self) -> Result<Message> { self.inner.lock().await.message() }
    pub async fn last_seq(&self) -> u64 { self.inner.lock().await.folder.last_seq() }

    pub async fn step_handle(&self, id: &str) -> Result<StepHandle> {
        let inner = self.inner.lock().await;
        if inner.clocks.get(id).is_none_or(|clock| clock.ended) { return Err(Error::NotFound); }
        Ok(StepHandle { stream: self.clone(), id: id.into() })
    }

    pub async fn delegate_handle(&self, id: &str) -> Result<DelegateStepHandle> {
        let handle = self.step_handle(id).await?;
        let message = self.message().await?;
        if !message.0["steps"].as_array().into_iter().flatten().any(|step| step["id"] == id && step["kind"] == "delegate") { return Err(Error::Conflict); }
        Ok(DelegateStepHandle(handle))
    }

    pub async fn start_block(&self, block_type: &str, schema_version: u32, fallback: &str) -> Result<BlockHandle> {
        let mut inner = self.inner.lock().await;
        inner.flush_all().await?;
        let message = inner.message()?;
        let index = message.0["blocks"].as_array().map_or(0, Vec::len);
        while message.0["blocks"].as_array().into_iter().flatten().any(|block| block["id"] == format!("b{}", inner.next_block)) { inner.next_block += 1; }
        let id = format!("b{}", inner.next_block);
        inner.validator.validate(DocumentKind::Block, &json!({"id":id,"type":block_type,"schemaVersion":schema_version,"status":"pending","fallbackText":fallback})).map_err(protocol_error)?;
        inner.emit(json!({"type":"block.start","blockId":id,"index":index,"blockType":block_type,"schemaVersion":schema_version})).await?;
        inner.next_block += 1;
        if !fallback.is_empty() { inner.emit(json!({"type":"block.patch","blockId":id,"patch":{"fallbackText":fallback}})).await?; }
        Ok(BlockHandle { stream: self.clone(), id })
    }

    async fn start_step_at(&self, label: &str, delegate: bool, parent: Option<&str>) -> Result<StepHandle> {
        let mut inner = self.inner.lock().await;
        while inner.clocks.contains_key(&format!("s{}", inner.next_step)) { inner.next_step += 1; }
        let id = format!("s{}", inner.next_step);
        let mut value = json!({"type":"step.started","stepId":id,"label":label});
        if delegate { value["kind"] = json!("delegate"); }
        if let Some(parent) = parent { value["parentStepId"] = json!(parent); }
        inner.emit(value).await?;
        inner.next_step += 1;
        inner.clocks.insert(id.clone(), StepClock { accumulated: Duration::ZERO, since: Some(Instant::now()), parent: parent.map(str::to_owned), ended: false });
        Ok(StepHandle { stream: self.clone(), id })
    }

    pub async fn start_step(&self, label: &str) -> Result<StepHandle> { self.start_step_at(label, false, None).await }
    pub async fn start_delegate(&self, label: &str) -> Result<DelegateStepHandle> { Ok(DelegateStepHandle(self.start_step_at(label, true, None).await?)) }

    pub async fn pause(&self, step: &StepHandle, block: &BlockHandle, interrupt_id: &str, reason: &str, other_input: bool) -> Result<Checkpoint> {
        if !Arc::ptr_eq(&self.inner, &step.stream.inner) || !Arc::ptr_eq(&self.inner, &block.stream.inner) { return Err(Error::Conflict); }
        let mut inner = self.inner.lock().await;
        inner.flush_all().await?;
        let active_steps = inner.clocks.values().filter(|clock| !clock.ended).count() as u64;
        if inner.folder.last_seq() + active_steps + 4 >= inner.config.max_events {
            inner.terminate("limit_exceeded", "Content limit reached", "cancelled").await?;
            return Err(Error::Protocol("limit_exceeded".into()));
        }
        let message = inner.message()?;
        inner.emit(json!({"type":"message.paused","interrupt":{"id":interrupt_id,"stepId":step.id,"blockId":block.id,"reason":reason,"otherInput":other_input},"fallbackText":markdown::fallback_text(&message),"blockCount":message.0["blocks"].as_array().map_or(0, Vec::len)})).await?;
        for clock in inner.clocks.values_mut().filter(|clock| !clock.ended) {
            if let Some(since) = clock.since.take() { clock.accumulated += since.elapsed(); }
        }
        Ok(inner.timing_checkpoint(inner.message()?, inner.folder.last_seq()))
    }

    pub async fn resume(&self, answer: RecordedAnswer) -> Result<()> { self.inner.lock().await.resume_locked(answer).await }
    pub async fn stop(&self) -> Result<()> { self.inner.lock().await.terminate("cancelled", "Stopped", "cancelled").await }
    pub async fn fail(&self, description: &str) -> Result<Message> {
        let mut inner = self.inner.lock().await;
        if inner.message()?.status() == "paused" { return Err(Error::Conflict); }
        let has_content = !markdown::fallback_text(&inner.message()?).trim().is_empty() || inner.pending.values().any(|text| !text.is_empty());
        inner.terminate_with_status("upstream_failed", description, "failed", if has_content { "interrupted" } else { "error" }).await?;
        inner.message()
    }
    pub async fn expire_interrupt(&self) -> Result<()> {
        let mut inner = self.inner.lock().await;
        let message = inner.message()?;
        if message.0["status"] != "paused" { return Err(Error::Conflict); }
        let id = message.0["interrupt"]["blockId"].as_str().ok_or(Error::Conflict)?;
        let block = message.0["blocks"].as_array().into_iter().flatten().find(|block| block["id"] == id).ok_or(Error::Conflict)?;
        let at = block["data"]["action"]["expiresAt"].as_str().ok_or_else(|| Error::InvalidRequest("interrupt has no expiration".into()))?;
        let deadline = time::OffsetDateTime::parse(at, &time::format_description::well_known::Rfc3339).map_err(protocol_error)?;
        if deadline > time::OffsetDateTime::now_utc() { return Err(Error::Conflict); }
        inner.terminate("interrupt_expired", "Confirmation expired", "cancelled").await
    }

    /// Hosts call this from their scheduler even while no text is arriving.
    pub async fn tick(&self) -> Result<()> {
        let mut inner = self.inner.lock().await;
        if inner.last_delta.elapsed() >= inner.config.delta_interval { inner.flush_all().await?; }
        if inner.last_checkpoint.elapsed() >= inner.config.checkpoint_interval {
            let checkpoint = inner.timing_checkpoint(inner.message()?, inner.folder.last_seq());
            inner.checkpoints.commit(checkpoint, None).await?;
            inner.last_checkpoint = Instant::now();
        }
        Ok(())
    }

    pub async fn activity(&self, phase: &str, label: Option<&str>) -> Result<()> {
        let inner = self.inner.lock().await;
        if inner.message()?.0["status"] != "streaming" { return Err(Error::Conflict); }
        let mut value = json!({"protocolVersion":"0.1","type":"message.activity","messageId":inner.config.message_id,"activity":{"phase":phase}});
        if let Some(label) = label { value["activity"]["label"] = json!(label); }
        inner.validator.validate(DocumentKind::Event, &value).map_err(protocol_error)?;
        inner.sink.publish(StreamEvent(value)).await
    }

    pub async fn finish(&self) -> Result<Message> {
        let mut inner = self.inner.lock().await;
        if inner.clocks.values().any(|clock| !clock.ended) {
            debug_assert!(false, "finish called with unfinished steps");
            return Err(Error::Conflict);
        }
        inner.flush_all().await?;
        let message = inner.message()?;
        inner.emit(json!({"type":"message.end","status":"complete","rev":1,"fallbackText":markdown::fallback_text(&message),"blockCount":message.0["blocks"].as_array().map_or(0, Vec::len)})).await?;
        inner.message()
    }
}

#[derive(Clone)]
pub struct BlockHandle { stream: MessageStream, pub id: String }
impl BlockHandle {
    pub async fn append_text(&self, text: &str) -> Result<()> {
        let mut inner = self.stream.inner.lock().await;
        let message = inner.message()?;
        if message.status() != "streaming" || !message.0["blocks"].as_array().into_iter().flatten().any(|block| block["id"] == self.id && block["type"] == "markdown" && block["status"] == "pending") { return Err(Error::Conflict); }
        let buffer = inner.pending.entry(self.id.clone()).or_default();
        buffer.push_str(text);
        if buffer.chars().count() >= inner.config.delta_chars || inner.last_delta.elapsed() >= inner.config.delta_interval { inner.flush_text(&self.id).await?; }
        Ok(())
    }
    pub async fn data(&self, data: Value, fallback: &str, metadata: Option<Value>) -> Result<()> {
        let mut inner = self.stream.inner.lock().await;
        let mut value = json!({"type":"block.data","blockId":self.id,"data":data,"fallbackText":fallback});
        if let Some(metadata) = metadata { value["metadata"] = metadata; }
        inner.emit(value).await
    }
    pub async fn patch(&self, patch: Value) -> Result<()> { self.stream.inner.lock().await.emit(json!({"type":"block.patch","blockId":self.id,"patch":patch})).await }
    pub async fn finish(&self) -> Result<()> {
        let mut inner = self.stream.inner.lock().await;
        inner.flush_text(&self.id).await?;
        inner.emit(json!({"type":"block.end","blockId":self.id,"status":"complete"})).await
    }
    pub async fn fail(&self, fallback: &str, reason: &str) -> Result<()> {
        let mut inner = self.stream.inner.lock().await;
        inner.flush_text(&self.id).await?;
        inner.emit(json!({"type":"block.end","blockId":self.id,"status":"error","fallbackText":fallback,"error":{"code":"upstream_failed","message":reason}})).await
    }
}

#[derive(Clone)]
pub struct StepHandle { stream: MessageStream, pub id: String }
impl StepHandle {
    pub async fn finish(self, state: &str, summary: Option<String>) -> Result<()> { self.stream.inner.lock().await.finish_step_locked(&self.id, state, summary).await }
}

#[derive(Clone)]
pub struct DelegateStepHandle(StepHandle);
impl DelegateStepHandle {
    pub fn as_step(&self) -> &StepHandle { &self.0 }
    pub async fn start_step(&self, label: &str) -> Result<StepHandle> { self.0.stream.start_step_at(label, false, Some(&self.0.id)).await }
    pub async fn start_delegate(&self, label: &str) -> Result<DelegateStepHandle> { Ok(Self(self.0.stream.start_step_at(label, true, Some(&self.0.id)).await?)) }
    pub async fn finish(self, state: &str, summary: Option<String>) -> Result<()> { self.0.finish(state, summary).await }
}
