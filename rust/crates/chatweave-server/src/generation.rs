//! In-memory generation identity and active-message helpers. Hosts supply scope.
use crate::stream::MessageStream;
use crate::{Error, Result};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;

/// Object keys are sorted recursively; array order and JSON scalar types remain
/// significant. The hash contains no credentials or host-specific identity.
pub(crate) fn canonical_hash(value: &Value) -> Result<String> {
    fn canonical(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let sorted: BTreeMap<_, _> = map
                    .iter()
                    .map(|(key, value)| (key.clone(), canonical(value)))
                    .collect();
                serde_json::to_value(sorted).expect("JSON values serialize")
            }
            Value::Array(values) => Value::Array(values.iter().map(canonical).collect()),
            _ => value.clone(),
        }
    }
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&canonical(value)).map_err(crate::protocol_error)?)
    ))
}

#[derive(Default)]
struct State {
    /// Idempotent start responses, kept for the retention period.
    starts: HashMap<(String, String), (String, Value, Instant)>,
    active: HashMap<(String, String), Active>,
    /// Idempotent stop results, kept for the retention period.
    stop_results: HashMap<(String, String), (Value, Instant)>,
    stop_gates: HashMap<(String, String), Arc<Mutex<()>>>,
}

impl State {
    fn cleanup(&mut self, retention: Duration) {
        let now = Instant::now();
        self.starts
            .retain(|_, (_, _, at)| now.duration_since(*at) < retention);
        self.stop_results
            .retain(|_, (_, at)| now.duration_since(*at) < retention);
        // A gate only matters while some stop call holds or awaits it.
        self.stop_gates
            .retain(|_, gate| Arc::strong_count(gate) > 1);
    }
}
#[derive(Clone)]
struct Active {
    conversation: String,
    reply_to: String,
    stream: MessageStream,
}

/// Default retention for idempotent start/stop responses, matching the event
/// log retention (streaming.md section 4.1, D21).
pub const DEFAULT_RETENTION: Duration = Duration::from_secs(600);

#[derive(Clone)]
pub struct GenerationRegistry {
    state: Arc<Mutex<State>>,
    retention: Duration,
}

impl Default for GenerationRegistry {
    fn default() -> Self {
        Self::new(DEFAULT_RETENTION)
    }
}

impl GenerationRegistry {
    /// `retention` bounds how long idempotent start and stop responses are
    /// remembered; afterwards they are released (security.md section 3).
    pub fn new(retention: Duration) -> Self {
        Self {
            state: Arc::default(),
            retention,
        }
    }

    /// Release expired idempotency records. Also runs on every begin/stop.
    pub async fn cleanup(&self) {
        self.state.lock().await.cleanup(self.retention);
    }

    /// Number of retained records (starts, stop results, stop gates).
    pub async fn retained(&self) -> usize {
        let state = self.state.lock().await;
        state.starts.len() + state.stop_results.len() + state.stop_gates.len()
    }

    /// Call and return this response before starting any producer. The host is
    /// responsible for durable identity storage when process restart matters.
    pub async fn begin(&self, scope: &str, user_message: &Value) -> Result<Value> {
        crate::protocol::validate(crate::protocol::DocumentKind::Message, user_message)
            .map_err(crate::protocol_error)?;
        if user_message["role"] != "user" {
            return Err(Error::InvalidRequest(
                "start requires a user message".into(),
            ));
        }
        let id = user_message["id"]
            .as_str()
            .ok_or_else(|| Error::InvalidRequest("missing id".into()))?;
        let key = (scope.to_owned(), id.to_owned());
        let binding = canonical_hash(user_message)?;
        let mut state = self.state.lock().await;
        state.cleanup(self.retention);
        if let Some((previous, response, _)) = state.starts.get(&key) {
            if previous != &binding {
                return Err(Error::InvalidRequest(
                    "same id has different content".into(),
                ));
            }
            let mut response = response.clone();
            response["replayed"] = json!(true);
            return Ok(response);
        }
        let response = json!({"userMessageId":id,"messageId":uuid::Uuid::now_v7().to_string(),"streamable":true});
        state
            .starts
            .insert(key, (binding, response.clone(), Instant::now()));
        Ok(response)
    }

    pub async fn register(
        &self,
        scope: &str,
        conversation: &str,
        reply_to: &str,
        stream: MessageStream,
    ) -> Result<()> {
        let id = stream.message().await?.id().to_owned();
        self.state.lock().await.active.insert(
            (scope.into(), id),
            Active {
                conversation: conversation.into(),
                reply_to: reply_to.into(),
                stream,
            },
        );
        Ok(())
    }

    pub async fn active_messages(&self, scope: &str, conversation: &str) -> Result<Value> {
        let active: Vec<_> = self
            .state
            .lock()
            .await
            .active
            .iter()
            .filter(|((s, _), active)| s == scope && active.conversation == conversation)
            .map(|((_, id), active)| (id.clone(), active.clone()))
            .collect();
        let mut messages = Vec::new();
        let mut ended = Vec::new();
        for (id, active) in active {
            let message = active.stream.message().await?;
            if matches!(message.status(), "streaming" | "paused") {
                messages.push(json!({"messageId":id,"lastSeq":active.stream.last_seq().await,"replyTo":active.reply_to,"status":message.status()}));
            } else {
                ended.push((id, active.stream));
            }
        }
        if !ended.is_empty() {
            // Ended registrations are no longer active; release them (compared
            // first, so a newer registration under the same id survives).
            let mut state = self.state.lock().await;
            for (id, stream) in ended {
                let key = (scope.to_owned(), id);
                if state
                    .active
                    .get(&key)
                    .is_some_and(|entry| Arc::ptr_eq(&entry.stream.inner, &stream.inner))
                {
                    state.active.remove(&key);
                }
            }
        }
        messages.sort_by(|a, b| a["messageId"].as_str().cmp(&b["messageId"].as_str()));
        let result = json!({"conversationId":conversation,"messages":messages});
        crate::protocol::validate(crate::protocol::DocumentKind::Generation, &result)
            .map_err(crate::protocol_error)?;
        Ok(result)
    }

    pub async fn stop(&self, scope: &str, message_id: &str) -> Result<Value> {
        let key = (scope.to_owned(), message_id.to_owned());
        // Serialize one message's duplicate stops without holding the registry
        // lock across producer callbacks or storage awaits.
        let gate = self
            .state
            .lock()
            .await
            .stop_gates
            .entry(key.clone())
            .or_default()
            .clone();
        let _stop_guard = gate.lock().await;
        let active = {
            let mut state = self.state.lock().await;
            state.cleanup(self.retention);
            if let Some((result, _)) = state.stop_results.get(&key) {
                return Ok(result.clone());
            }
            state.active.get(&key).cloned().ok_or(Error::NotFound)?
        };
        let message = active.stream.message().await?;
        let stopping = matches!(message.status(), "streaming" | "paused");
        if stopping {
            active.stream.stop().await?;
        }
        let result = json!({"messageId":message_id,"status":if stopping {"stopping"} else {"already_ended"}});
        let mut state = self.state.lock().await;
        state
            .stop_results
            .insert(key.clone(), (result.clone(), Instant::now()));
        // Compare before clearing so a replacement registration is retained.
        if state
            .active
            .get(&key)
            .is_some_and(|entry| Arc::ptr_eq(&entry.stream.inner, &active.stream.inner))
        {
            state.active.remove(&key);
        }
        // Only the map and this call hold the gate: nobody waits behind us.
        if Arc::strong_count(&gate) == 2 {
            state.stop_gates.remove(&key);
        }
        Ok(result)
    }

    pub async fn clear_if_current(
        &self,
        scope: &str,
        message_id: &str,
        stream: &MessageStream,
    ) -> bool {
        let mut state = self.state.lock().await;
        let key = (scope.into(), message_id.into());
        if state
            .active
            .get(&key)
            .is_some_and(|active| Arc::ptr_eq(&active.stream.inner, &stream.inner))
        {
            state.active.remove(&key);
            true
        } else {
            false
        }
    }
}
