use crate::{ProtocolError, Result};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Limits {
    pub max_block_data_bytes: usize,
    pub max_message_bytes: usize,
    pub max_event_bytes: usize,
    pub max_delta_bytes: usize,
    pub max_markdown_bytes: usize,
    pub max_data_depth: usize,
    pub max_block_nodes: usize,
    pub max_events: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self { max_block_data_bytes: 64 * 1024, max_message_bytes: 256 * 1024,
            max_event_bytes: 128 * 1024, max_delta_bytes: 4 * 1024, max_markdown_bytes: 32 * 1024,
            max_data_depth: 6, max_block_nodes: 5_000, max_events: 5_000 }
    }
}
impl Limits {
    pub fn validate_configuration(&self) -> Result<()> {
        let d = Self::default();
        let pairs = [(self.max_block_data_bytes,d.max_block_data_bytes),
            (self.max_message_bytes,d.max_message_bytes), (self.max_event_bytes,d.max_event_bytes),
            (self.max_delta_bytes,d.max_delta_bytes), (self.max_markdown_bytes,d.max_markdown_bytes), (self.max_data_depth,d.max_data_depth),
            (self.max_block_nodes,d.max_block_nodes), (self.max_events,d.max_events)];
        if pairs.iter().any(|(n,max)| *n == 0 || n > max) {
            return Err(ProtocolError::new("invalid_limits", "", "limits may only be tightened"));
        }
        Ok(())
    }
    pub fn check_bytes(&self, value: &Value, maximum: usize, path: &str) -> Result<()> {
        self.validate_configuration()?;
        let bytes = serde_json::to_vec(value).map_err(|e| ProtocolError::new("serialization",path,e.to_string()))?;
        if bytes.len() > maximum { return Err(ProtocolError::new("limit_exceeded", path, "UTF-8 byte limit exceeded")) }
        Ok(())
    }
    pub fn check_block(&self, block: &Value) -> Result<()> {
        self.validate_configuration()?;
        let mut stack = vec![block];
        let mut nodes = 0;
        while let Some(value) = stack.pop() {
            nodes += 1;
            if nodes > self.max_block_nodes {
                return Err(ProtocolError::new("limit_exceeded", "", "block node limit exceeded"));
            }
            match value {
                Value::Array(values) => stack.extend(values),
                Value::Object(values) => stack.extend(values.values()),
                _ => (),
            }
        }
        if block["type"] == "markdown" {
            if let Some(text) = block.pointer("/data/text").and_then(Value::as_str) {
                if text.len() > self.max_markdown_bytes {
                    return Err(ProtocolError::new("limit_exceeded", "/data/text", "UTF-8 markdown byte limit exceeded"));
                }
            }
        }
        if let Some(data) = block.get("data") {
            self.check_data(data)?;
        }
        Ok(())
    }
    pub fn check_data(&self, data: &Value) -> Result<()> {
        self.check_bytes(data,self.max_block_data_bytes,"/data")?;
        let mut stack = vec![(data,1usize)];
        let mut nodes = 0;
        while let Some((value,depth)) = stack.pop() {
            nodes += 1;
            if depth > self.max_data_depth || nodes > self.max_block_nodes {
                return Err(ProtocolError::new("limit_exceeded","/data","JSON depth or node limit exceeded"));
            }
            match value {
                Value::Array(values) => stack.extend(values.iter().map(|v|(v,depth+1))),
                Value::Object(values) => stack.extend(values.values().map(|v|(v,depth+1))),
                _ => (),
            }
        }
        Ok(())
    }
    pub fn check_event(&self, event: &Value) -> Result<()> {
        self.check_bytes(event,self.max_event_bytes,"")?;
        if let Some(data) = event.get("data") { self.check_data(data)?; }
        if let Some(text) = event.pointer("/delta/text").and_then(Value::as_str) {
            if text.len() > self.max_delta_bytes {
                return Err(ProtocolError::new("limit_exceeded","/delta/text","UTF-8 delta byte limit exceeded"));
            }
        }
        Ok(())
    }
    pub fn check_message(&self, message: &Value) -> Result<()> {
        self.check_bytes(message,self.max_message_bytes,"")?;
        if let Some(blocks) = message["blocks"].as_array() {
            for block in blocks { self.check_block(block)?; }
        }
        Ok(())
    }
}
