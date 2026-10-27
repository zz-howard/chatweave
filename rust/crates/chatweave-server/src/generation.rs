//! In-memory generation identity and active-message helpers. Hosts supply scope.
use crate::stream::MessageStream;
use crate::{Error, Result};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use tokio::sync::Mutex;

/// Object keys are sorted recursively; array order and JSON scalar types remain
/// significant. The hash contains no credentials or host-specific identity.
pub(crate) fn canonical_hash(value: &Value) -> Result<String> {
    fn canonical(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let sorted: BTreeMap<_, _> = map.iter().map(|(key, value)| (key.clone(), canonical(value))).collect();
                serde_json::to_value(sorted).expect("JSON values serialize")
            }
            Value::Array(values) => Value::Array(values.iter().map(canonical).collect()),
            _ => value.clone(),
        }
    }
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(&canonical(value)).map_err(crate::protocol_error)?)))
}

#[derive(Default)]
struct State {
    starts: HashMap<(String, String), (String, Value)>,
    active: HashMap<(String, String), Active>,
    stop_results: HashMap<(String, String), Value>,
    stop_gates: HashMap<(String, String), Arc<Mutex<()>>>,
}
#[derive(Clone)]
struct Active { conversation: String, reply_to: String, stream: MessageStream }

#[derive(Clone, Default)]
pub struct GenerationRegistry(Arc<Mutex<State>>);

impl GenerationRegistry {
    /// Call and return this response before starting any producer. The host is
    /// responsible for durable identity storage when process restart matters.
    pub async fn begin(&self, scope: &str, user_message: &Value) -> Result<Value> {
        crate::protocol::validate(crate::protocol::DocumentKind::Message, user_message).map_err(crate::protocol_error)?;
        if user_message["role"] != "user" { return Err(Error::InvalidRequest("start requires a user message".into())); }
        let id = user_message["id"].as_str().ok_or_else(|| Error::InvalidRequest("missing id".into()))?;
        let key = (scope.to_owned(), id.to_owned());
        let binding = canonical_hash(user_message)?;
        let mut state = self.0.lock().await;
        if let Some((previous, response)) = state.starts.get(&key) {
            if previous != &binding { return Err(Error::InvalidRequest("same id has different content".into())); }
            let mut response = response.clone();
            response["replayed"] = json!(true);
            return Ok(response);
        }
        let response = json!({"userMessageId":id,"messageId":uuid::Uuid::now_v7().to_string(),"streamable":true});
        state.starts.insert(key, (binding, response.clone()));
        Ok(response)
    }

    pub async fn register(&self, scope: &str, conversation: &str, reply_to: &str, stream: MessageStream) -> Result<()> {
        let id = stream.message().await?.id().to_owned();
        self.0.lock().await.active.insert((scope.into(), id), Active { conversation: conversation.into(), reply_to: reply_to.into(), stream });
        Ok(())
    }

    pub async fn active_messages(&self, scope: &str, conversation: &str) -> Result<Value> {
        let active: Vec<_> = self.0.lock().await.active.iter().filter(|((s, _), active)| s == scope && active.conversation == conversation).map(|((_, id), active)| (id.clone(), active.clone())).collect();
        let mut messages = Vec::new();
        for (id, active) in active {
            let message = active.stream.message().await?;
            if matches!(message.status(), "streaming" | "paused") {
                messages.push(json!({"messageId":id,"lastSeq":active.stream.last_seq().await,"replyTo":active.reply_to,"status":message.status()}));
            }
        }
        messages.sort_by(|a, b| a["messageId"].as_str().cmp(&b["messageId"].as_str()));
        let result = json!({"conversationId":conversation,"messages":messages});
        crate::protocol::validate(crate::protocol::DocumentKind::Generation, &result).map_err(crate::protocol_error)?;
        Ok(result)
    }

    pub async fn stop(&self, scope: &str, message_id: &str) -> Result<Value> {
        let key = (scope.to_owned(), message_id.to_owned());
        // Serialize one message's duplicate stops without holding the registry
        // lock across producer callbacks or storage awaits.
        let gate = self.0.lock().await.stop_gates.entry(key.clone()).or_default().clone();
        let _stop_guard = gate.lock().await;
        let active = {
            let state = self.0.lock().await;
            if let Some(result) = state.stop_results.get(&key) { return Ok(result.clone()); }
            state.active.get(&key).cloned().ok_or(Error::NotFound)?
        };
        let message = active.stream.message().await?;
        let stopping = matches!(message.status(), "streaming" | "paused");
        if stopping { active.stream.stop().await?; }
        let result = json!({"messageId":message_id,"status":if stopping {"stopping"} else {"already_ended"}});
        let mut state = self.0.lock().await;
        state.stop_results.insert(key.clone(), result.clone());
        // Compare before clearing so a replacement registration is retained.
        if state.active.get(&key).is_some_and(|entry| Arc::ptr_eq(&entry.stream.inner, &active.stream.inner)) {
            state.active.remove(&key);
        }
        Ok(result)
    }

    pub async fn clear_if_current(&self, scope: &str, message_id: &str, stream: &MessageStream) -> bool {
        let mut state = self.0.lock().await;
        let key = (scope.into(), message_id.into());
        if state.active.get(&key).is_some_and(|active| Arc::ptr_eq(&active.stream.inner, &stream.inner)) {
            state.active.remove(&key);
            true
        } else { false }
    }
}
