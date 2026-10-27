use super::{ActionError, ActionOutcome};
use async_trait::async_trait;
use chatweave_protocol::{ActionRequest, ActionResult, Message};
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct StoredBlock {
    pub message: Message,
    pub block: Value,
    pub now: String,
}
impl StoredBlock {
    pub fn is_interrupt(&self) -> bool {
        self.message.0["status"] == "paused"
            && self.message.0["interrupt"]["blockId"] == self.block["id"]
    }
    pub fn state(&self) -> &str {
        self.block["data"]["state"]["status"]
            .as_str()
            .unwrap_or("open")
    }
    pub fn unfinished(&self) -> bool {
        matches!(self.message.status(), "streaming" | "paused")
    }
}

#[derive(Clone, Debug)]
pub struct StoredActionResult {
    pub binding: String,
    pub result: ActionResult,
}

/// Acquiring the transaction precedes step 1. The guard must cover execute as
/// well as commit; a compare-and-set only after execute is insufficient.
#[async_trait]
pub trait ActionStore<Ctx>: Send + Sync {
    async fn begin(
        &self,
        ctx: &Ctx,
        message_id: &str,
        block_id: &str,
    ) -> Result<Box<dyn ActionTransaction>, ActionError>;
}

#[async_trait]
pub trait ActionTransaction: Send {
    async fn load_block(&mut self) -> Result<StoredBlock, ActionError>;
    async fn find_result(
        &mut self,
        action_id: &str,
    ) -> Result<Option<StoredActionResult>, ActionError>;
    async fn expire(&mut self) -> Result<StoredBlock, ActionError>;
    /// Atomically save state, request binding and result. Interrupt commits must
    /// also durably schedule the single continuation (e.g. a host outbox).
    async fn commit(
        &mut self,
        request: &ActionRequest,
        binding: &str,
        outcome: ActionOutcome,
    ) -> Result<ActionResult, ActionError>;
}
