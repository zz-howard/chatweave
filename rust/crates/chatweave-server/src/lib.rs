//! Transport and storage adapters for the host-neutral ChatWeave protocol.
#![forbid(unsafe_code)]

pub mod action;
pub mod checkpoint;
pub mod event_log;
pub mod generation;
pub mod markdown;
pub mod recovery;
pub mod resume;
#[cfg(feature = "axum")]
pub mod sse;
pub mod stream;

pub use chatweave_protocol as protocol;
pub use stream::{
    BlockHandle, Cancellation, DelegateStepHandle, MessageStream, StepHandle, StreamConfig,
};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("storage error: {0}")]
    Storage(String),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("event log no longer covers the requested range")]
    Unavailable,
    #[error("subscriber fell behind")]
    Lagged,
    #[error("message not found")]
    NotFound,
    #[error("conflicting transition")]
    Conflict,
}

pub type Result<T> = std::result::Result<T, Error>;

pub(crate) fn protocol_error(error: impl std::fmt::Display) -> Error {
    Error::Protocol(error.to_string())
}
