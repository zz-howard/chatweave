//! Axum is optional; authorization belongs in the host's route middleware.
use crate::resume::{ResumeOptions, ResumeService, parse_cursor};
use crate::{Error, Result};
use axum::http::{HeaderMap, HeaderValue, header};
use axum::response::{IntoResponse, Response, Sse, sse::{Event, KeepAlive}};
use futures_util::StreamExt;
use std::time::Duration;

pub async fn sse_response(service: &ResumeService, message_id: &str, headers: &HeaderMap, after: Option<&str>, mut options: ResumeOptions) -> Result<Response> {
    let last_event_id = headers.get("last-event-id").map(|value| value.to_str().map_err(|_| Error::InvalidRequest("invalid Last-Event-ID".into()))).transpose()?;
    options.after = parse_cursor(last_event_id, after)?;
    let events = service.open(message_id, options).await?;
    let mut first = true;
    let stream = events.map(move |result| {
        let event = result?;
        let data = serde_json::to_string(&event).map_err(crate::protocol_error)?;
        let mut frame = Event::default().event(event.0["type"].as_str().unwrap_or("error")).data(data);
        if first { frame = frame.retry(Duration::from_secs(2)); first = false; }
        if let Some(seq) = crate::event_log::sequence(&event) { frame = frame.id(seq.to_string()); }
        Ok::<_, Error>(frame)
    });
    let mut response = Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)).text("ping")).into_response();
    response.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert("chatweave-protocol", HeaderValue::from_static("0.1"));
    response.headers_mut().insert("x-accel-buffering", HeaderValue::from_static("no"));
    Ok(response)
}
