//! ChatWeave 0.1 values, validation and deterministic folding. No runtime or IO.
#![forbid(unsafe_code)]

mod data;
mod fold;
mod limits;
mod validation;

pub use data::*;
pub use fold::{FoldState, fold, merge_patch};
pub use limits::Limits;
use serde::{Deserialize, Serialize};
use serde_json::Value;
pub use validation::{DocumentKind, SchemaRegistry, Validator, validate};

pub const PROTOCOL_VERSION: &str = "0.1";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{code} at {path}: {message}")]
pub struct ProtocolError {
    pub code: String,
    pub path: String,
    pub message: String,
}
pub type ValidationError = ProtocolError;
pub type Result<T> = std::result::Result<T, ProtocolError>;
impl ProtocolError {
    pub fn new(code: &str, path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            path: path.into(),
            message: message.into(),
        }
    }
}

macro_rules! wire_value {
    ($($name:ident),+ $(,)?) => {$(
        /// Lossless wire representation. Call `validate` before producing it.
        #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub Value);
        impl $name {
            pub fn as_value(&self) -> &Value { &self.0 }
            pub fn into_value(self) -> Value { self.0 }
        }
        impl From<Value> for $name {
            fn from(value: Value) -> Self { Self(value) }
        }
    )+};
}
wire_value!(
    Message,
    Block,
    StreamEvent,
    ActionSpec,
    ActionRequest,
    ActionResult,
    ClientCapabilities,
    GenerationResponse
);

impl Message {
    pub fn id(&self) -> &str {
        self.0["id"].as_str().unwrap_or("")
    }
    pub fn status(&self) -> &str {
        self.0["status"].as_str().unwrap_or("")
    }
    pub fn rev(&self) -> u64 {
        self.0["rev"].as_u64().unwrap_or(0)
    }
}
impl Block {
    pub fn id(&self) -> &str {
        self.0["id"].as_str().unwrap_or("")
    }
    pub fn block_type(&self) -> &str {
        self.0["type"].as_str().unwrap_or("")
    }
    pub fn status(&self) -> &str {
        self.0["status"].as_str().unwrap_or("complete")
    }
    pub fn typed_data(&self) -> Result<Option<BlockData>> {
        let Some(data) = self.0.get("data") else {
            return Ok(None);
        };
        Ok(Some(BlockData::parse(self.block_type(), data.clone())?))
    }
}
impl StreamEvent {
    pub fn event_type(&self) -> &str {
        self.0["type"].as_str().unwrap_or("")
    }
    pub fn message_id(&self) -> &str {
        self.0["messageId"].as_str().unwrap_or("")
    }
    pub fn seq(&self) -> Option<u64> {
        self.0.get("seq").and_then(Value::as_u64)
    }
    pub fn is_terminal(&self) -> bool {
        matches!(
            self.event_type(),
            "message.end" | "message.paused" | "error"
        ) || (self.event_type() == "message.snapshot"
            && self.0["message"]["status"]
                .as_str()
                .is_some_and(|s| s != "streaming"))
    }
}
