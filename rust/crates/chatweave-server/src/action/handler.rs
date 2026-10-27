use super::StoredBlock;
use async_trait::async_trait;
use chatweave_protocol::ActionRequest;
use serde_json::Value;

pub use chatweave_protocol::ActionType;

#[derive(Debug, Clone, thiserror::Error)]
#[error("{code}: {message}")]
pub struct ActionError {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}
impl ActionError {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            retryable: false,
        }
    }
    pub fn forbidden() -> Self {
        Self::new("forbidden", "无权回答")
    }
}

#[derive(Clone, Debug)]
pub struct ResolvedAction {
    pub request: ActionRequest,
    pub stored: StoredBlock,
}

#[derive(Clone, Debug)]
pub struct ActionOutcome {
    pub status: String,
    pub follow_up: Option<Value>,
}
impl Default for ActionOutcome {
    fn default() -> Self {
        Self {
            status: "completed".into(),
            follow_up: None,
        }
    }
}

#[async_trait]
pub trait ActionHandler<Ctx>: Send + Sync {
    fn target(&self) -> &'static str;
    fn accepts(&self) -> &'static [ActionType];
    fn destructive(&self) -> bool {
        false
    }
    async fn authorize(&self, ctx: &Ctx, action: &ResolvedAction) -> Result<(), ActionError>;
    async fn execute(
        &self,
        ctx: &Ctx,
        action: ResolvedAction,
    ) -> Result<ActionOutcome, ActionError>;
}
