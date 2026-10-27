//! Plain-text conversion never infers structured facts from prose.
use crate::{BlockHandle, MessageStream, Result};
use chatweave_protocol::Message;
use pulldown_cmark::{Event, Parser, TagEnd};

pub fn plain_text(markdown: &str) -> String {
    let mut text = String::new();
    for event in Parser::new(markdown) {
        match event {
            Event::Text(value) | Event::Code(value) | Event::Html(value) | Event::InlineHtml(value) => text.push_str(&value),
            Event::SoftBreak | Event::HardBreak | Event::Rule => text.push('\n'),
            Event::End(TagEnd::Paragraph | TagEnd::Heading(_) | TagEnd::Item | TagEnd::CodeBlock) => text.push('\n'),
            _ => {}
        }
    }
    text.trim_end().to_owned()
}

pub fn fallback_text(message: &Message) -> String {
    let text = message.0["blocks"].as_array().into_iter().flatten().map(|block| {
        if block["type"] == "markdown" && block["status"] != "error" {
            plain_text(block["data"]["text"].as_str().unwrap_or_default())
        } else {
            block["fallbackText"].as_str().unwrap_or_default().to_owned()
        }
    }).collect::<Vec<_>>().join("\n\n");
    if text.chars().count() > 16_000 {
        text.chars().take(15_999).chain(std::iter::once('…')).collect()
    } else { text }
}

pub struct MarkdownAdapter {
    stream: MessageStream,
    block: Option<BlockHandle>,
}

impl MarkdownAdapter {
    pub fn new(stream: MessageStream) -> Self { Self { stream, block: None } }
    pub async fn push_text(&mut self, text: &str) -> Result<()> {
        if self.block.is_none() {
            self.block = Some(self.stream.start_block("markdown", 1, "").await?);
        }
        if let Some(block) = &self.block {
            block.append_text(text).await?;
        }
        Ok(())
    }
    pub async fn finish(mut self) -> Result<Message> {
        if let Some(block) = self.block.take() {
            block.patch(serde_json::json!({"metadata":{"provenance":"adapter"}})).await?;
            block.finish().await?;
        }
        self.stream.finish().await
    }
}
