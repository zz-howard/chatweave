use crate::checkpoint::{Checkpoint, CheckpointStore};
use crate::event_log::{EventLog, EventSink};
use crate::stream::{MessageStream, StreamConfig};
use crate::{Error, Result};
use chatweave_protocol::{FoldState, Message, Validator};
use std::collections::HashMap;
use std::sync::Arc;

fn strip_last_seq(mut message: Message) -> Message {
    if let Some(object) = message.0.as_object_mut() {
        object.remove("lastSeq");
    }
    message
}

/// The host selects streaming messages whose producer lease has expired. A
/// paused checkpoint is authoritative and survives loss of the event log.
pub async fn recover_message(
    message_id: &str,
    validator: Arc<Validator>,
    log: Arc<dyn EventLog>,
    sink: Arc<dyn EventSink>,
    checkpoints: Arc<dyn CheckpointStore>,
) -> Result<Message> {
    let checkpoint = checkpoints.load(message_id).await?;
    if let Some(checkpoint) = &checkpoint
        && checkpoint.message.status() != "streaming"
    {
        return Ok(checkpoint.message.clone());
    }
    let mut folder = FoldState::new();
    let mut after = 0;
    let mut step_work_ms = HashMap::new();
    if let Some(checkpoint) = checkpoint {
        after = checkpoint.last_seq;
        step_work_ms = checkpoint.step_work_ms;
        folder =
            FoldState::from_checkpoint(checkpoint.message, after).map_err(crate::protocol_error)?;
    }
    let replay = log.read_after(message_id, after).await?;
    if replay.covered {
        for event in replay.events {
            folder.apply(event).map_err(crate::protocol_error)?;
        }
    } else if after == 0 {
        return Err(Error::Unavailable);
    } else if replay.head > after {
        // Events after the checkpoint were partly evicted: their content is
        // lost, but their sequence numbers are taken. Close after the log
        // head so no seq is ever reused; readers holding the evicted events
        // reconcile through the final checkpoint (snapshot).
        let message = folder.message().map_err(crate::protocol_error)?;
        folder = FoldState::from_checkpoint(strip_last_seq(message), replay.head)
            .map_err(crate::protocol_error)?;
    }
    let message = folder.message().map_err(crate::protocol_error)?;
    if message.status() != "streaming" {
        checkpoints
            .commit(
                Checkpoint {
                    message: message.clone(),
                    last_seq: folder.last_seq(),
                    step_work_ms,
                },
                None,
            )
            .await?;
        return Ok(message);
    }
    let mut config = StreamConfig::new(message_id);
    config.created_at = message.0["createdAt"].as_str().unwrap_or_default().into();
    let stream = MessageStream::from_checkpoint(
        Checkpoint {
            message,
            last_seq: folder.last_seq(),
            step_work_ms,
        },
        config,
        validator,
        log,
        sink,
        checkpoints,
    )
    .await?;
    stream
        .inner
        .lock()
        .await
        .terminate("upstream_failed", "Generation interrupted", "failed")
        .await?;
    stream.message().await
}
