use super::{ActionError, ActionOutcome, ActionRegistry, ActionStore, ActionType, ResolvedAction, StoredBlock};
use chatweave_protocol::{ActionRequest, ActionResult};
use serde_json::{Value, json};

fn refused() -> ActionError { ActionError::new("invalid_payload", "请求被拒绝") }

pub(super) fn rejection(request: &ActionRequest, error: &ActionError) -> ActionResult {
    let mut value = json!({"actionId":request.0["id"],"status":"rejected","error":{"code":error.code,"message":error.message}});
    if error.retryable { value["error"]["retryable"] = json!(true); }
    ActionResult(value)
}

pub(super) fn state_rejection(request: &ActionRequest, stored: &StoredBlock) -> ActionResult {
    let code = match stored.state() { "expired" => "expired", "superseded" => "superseded", _ => "already_resolved" };
    let message = if stored.unfinished() { "另一台设备已经回答" } else if stored.state() == "resolved" { "问题已经回答" } else { "问题已关闭" };
    let mut result = rejection(request, &ActionError::new(code, message));
    if stored.unfinished() {
        result.0["resume"] = json!({"messageId":stored.message.id()});
    } else {
        result.0["patches"] = json!([{"messageId":stored.message.id(),"blockId":stored.block["id"],"rev":stored.message.rev(),"patch":{"data":{"state":stored.block["data"]["state"]}}}]);
    }
    result
}

pub(super) async fn dispatch<Ctx: Send + Sync + 'static>(registry: &ActionRegistry<Ctx>, ctx: &Ctx, request: &ActionRequest, store: &dyn ActionStore<Ctx>) -> Result<ActionResult, ActionError> {
    let r = &request.0;
    let mut transaction = store.begin(ctx, r["context"]["messageId"].as_str().ok_or_else(refused)?, r["context"]["blockId"].as_str().ok_or_else(refused)?).await?;
    // 1. Scope-checked load and lookup of a request-bound receipt. Looking up a
    // receipt here NEVER returns it to the caller before authorization below.
    let mut stored = transaction.load_block().await?;
    let binding = crate::generation::canonical_hash(&json!({"type":r["type"],"target":r["target"],"messageId":stored.message.id(),"blockId":stored.block["id"],"payload":r["payload"]})).map_err(|e| ActionError::new("internal", &e.to_string()))?;
    let previous = transaction.find_result(r["id"].as_str().ok_or_else(refused)?).await?;
    if previous.as_ref().is_some_and(|previous| previous.binding != binding) {
        return Err(ActionError::new("invalid_request", "动作ID已绑定其他请求"));
    }
    if previous.is_none() && (stored.block["data"]["action"]["type"] != r["type"] || stored.block["data"]["action"]["target"] != r["target"]) {
        return Err(ActionError::new("target_mismatch", "请求被拒绝"));
    }
    let target = r["target"].as_str().ok_or_else(refused)?;
    let handler = registry.handlers.get(target).ok_or_else(|| ActionError::new("unsupported", "请求被拒绝"))?;
    let action_type = serde_json::from_value::<ActionType>(r["type"].clone()).map_err(|_| refused())?;
    let answer_only = stored.is_interrupt() && (r["payload"].get("freeText").is_some() || r["payload"]["outcome"] == "cancel");
    if previous.is_none() {
        // 2. Match the server-authored declaration, state and expiration.
        let spec = &stored.block["data"]["action"];
        if spec["type"] != r["type"] || spec["target"] != r["target"] || !handler.accepts().contains(&action_type) {
            return Err(ActionError::new("target_mismatch", "请求被拒绝"));
        }
        if stored.state() != "open" { return Ok(state_rejection(request, &stored)); }
        if r["context"].get("conversationId").is_some_and(|id| *id != stored.message.0["conversationId"]) { return Err(ActionError::new("not_found", "请求被拒绝")); }
        if let Some(expires) = spec["expiresAt"].as_str() {
            let parse = |s: &str| time::OffsetDateTime::parse(s, &time::format_description::well_known::Rfc3339);
            if parse(expires).map_err(|_| refused())? <= parse(&stored.now).map_err(|_| refused())? {
                stored = transaction.expire().await?;
                return Ok(state_rejection(request, &stored));
            }
        }
        // 3. Values are checked against the stored block, never a client spec.
        check_payload(&stored, &r["payload"])?;
        // 4. A cancel/free-text interrupt answer records data only. Every
        // actual destructive execute still requires an explicit confirmation.
        if handler.destructive() && !answer_only
            && (stored.block["type"] != "confirmation" || stored.block["data"]["severity"] != "destructive" || r["payload"]["outcome"] != "confirm")
        { return Err(ActionError::new("confirmation_required", "请求被拒绝")); }
    }
    let resolved = ResolvedAction { request: request.clone(), stored };
    // 5. Always reauthorize, including successfully committed retries.
    handler.authorize(ctx, &resolved).await?;
    // 6. Only now may a bound result be replayed. No execute on this path.
    if let Some(previous) = previous {
        let mut result = previous.result;
        result.0["replayed"] = json!(true);
        return Ok(result);
    }
    let outcome = if answer_only { ActionOutcome::default() } else {
        match handler.execute(ctx, resolved).await {
            Ok(outcome) => outcome,
            Err(error) => {
                let mut result = rejection(request, &error);
                result.0["status"] = json!("failed");
                return Ok(result);
            }
        }
    };
    // 7. The transaction still owns the open block and continuation claim.
    transaction.commit(request, &binding, outcome).await
}

fn check_payload(stored: &StoredBlock, payload: &Value) -> Result<(), ActionError> {
    if let Some(text) = payload["freeText"].as_str() {
        if !stored.is_interrupt() || stored.message.0["interrupt"]["otherInput"] == false || !(1..=500).contains(&text.chars().count()) { return Err(refused()); }
        return Ok(());
    }
    let data = &stored.block["data"];
    match stored.block["type"].as_str() {
        Some("choice") => {
            let selected = payload["selected"].as_array().ok_or_else(refused)?;
            let options = data["options"].as_array().ok_or_else(refused)?;
            let single = data["selection"].as_str().unwrap_or("single") == "single";
            let min = data["minSelect"].as_u64().unwrap_or(1) as usize;
            let max = data["maxSelect"].as_u64().unwrap_or(options.len() as u64) as usize;
            if (single && selected.len() != 1) || selected.len() < min || selected.len() > max || selected.iter().any(|id| !options.iter().any(|option| option["id"] == *id)) { return Err(refused()); }
        }
        Some("confirmation") => if !matches!(payload["outcome"].as_str(), Some("confirm" | "cancel")) { return Err(refused()); },
        Some("form_intent") => {
            let values = payload["values"].as_object().ok_or_else(refused)?;
            let fields = data["fields"].as_array().ok_or_else(refused)?;
            if values.keys().any(|key| !fields.iter().any(|field| field["key"] == *key)) { return Err(refused()); }
            for field in fields {
                let key = field["key"].as_str().ok_or_else(refused)?;
                match values.get(key) {
                    None | Some(Value::Null) if field["required"] == true => return Err(refused()),
                    None | Some(Value::Null) => continue,
                    Some(value) => check_field(field, value)?,
                }
            }
        }
        _ => return Err(refused()),
    }
    Ok(())
}

fn check_field(field: &Value, value: &Value) -> Result<(), ActionError> {
    match field["type"].as_str() {
        Some("text" | "multiline_text") => {
            let text = value.as_str().ok_or_else(refused)?;
            if text.chars().count() > field["maxLength"].as_u64().unwrap_or(2000) as usize { return Err(refused()); }
        }
        Some("number" | "integer") => {
            let number = value.as_f64().ok_or_else(refused)?;
            if (field["type"] == "integer" && number.fract() != 0.0)
                || field["min"].as_f64().is_some_and(|min| number < min)
                || field["max"].as_f64().is_some_and(|max| number > max) { return Err(refused()); }
        }
        Some("boolean") => if !value.is_boolean() { return Err(refused()); },
        Some("date") => {
            let format = time::format_description::parse("[year]-[month]-[day]").map_err(|_| refused())?;
            time::Date::parse(value.as_str().ok_or_else(refused)?, &format).map_err(|_| refused())?;
        }
        Some("datetime") => { time::OffsetDateTime::parse(value.as_str().ok_or_else(refused)?, &time::format_description::well_known::Rfc3339).map_err(|_| refused())?; }
        Some("single_select") => if !field["options"].as_array().into_iter().flatten().any(|option| option["id"] == *value) { return Err(refused()); },
        Some("multi_select") => {
            let selected = value.as_array().ok_or_else(refused)?;
            if selected.iter().enumerate().any(|(i, value)| selected[..i].contains(value) || !field["options"].as_array().into_iter().flatten().any(|option| option["id"] == *value)) { return Err(refused()); }
        }
        _ => return Err(refused()),
    }
    Ok(())
}
