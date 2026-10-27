//! Controlled actions. No identity, permission or business model is built in.
mod dispatch;
mod handler;
mod memory;
mod registry;
mod store;

pub use handler::{ActionError, ActionHandler, ActionOutcome, ActionType, ResolvedAction};
pub use memory::MemoryActionStore;
pub use registry::ActionRegistry;
pub use store::{ActionStore, ActionTransaction, StoredActionResult, StoredBlock};
