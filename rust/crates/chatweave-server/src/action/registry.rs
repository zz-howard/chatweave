use super::{ActionError, ActionHandler, ActionStore};
use chatweave_protocol::{ActionRequest, ActionResult, Validator};
use std::collections::HashMap;
use std::sync::Arc;

pub struct ActionRegistry<Ctx> {
    pub(super) handlers: HashMap<String, Arc<dyn ActionHandler<Ctx>>>,
    pub(super) validator: Arc<Validator>,
}
impl<Ctx: Send + Sync + 'static> Default for ActionRegistry<Ctx> {
    fn default() -> Self {
        Self::new(Arc::new(Validator::default()))
    }
}
impl<Ctx: Send + Sync + 'static> ActionRegistry<Ctx> {
    pub fn new(validator: Arc<Validator>) -> Self {
        Self {
            handlers: HashMap::new(),
            validator,
        }
    }
    pub fn register(&mut self, handler: Arc<dyn ActionHandler<Ctx>>) -> Result<(), ActionError> {
        let target = handler.target().to_owned();
        if self.handlers.contains_key(&target) {
            return Err(ActionError::new("conflict", "duplicate target"));
        }
        self.handlers.insert(target, handler);
        Ok(())
    }
    pub async fn dispatch(
        &self,
        ctx: &Ctx,
        request: ActionRequest,
        store: &dyn ActionStore<Ctx>,
    ) -> Result<ActionResult, ActionError> {
        self.validator
            .validate(chatweave_protocol::DocumentKind::ActionRequest, &request.0)
            .map_err(|_| ActionError::new("invalid_request", "Malformed action request"))?;
        let result = match super::dispatch::dispatch(self, ctx, &request, store).await {
            Ok(result) => result,
            Err(error) => {
                let mut result = super::dispatch::rejection(&request, &error);
                if error.code == "unavailable" {
                    result.0["status"] = serde_json::json!("failed");
                }
                result
            }
        };
        self.validator
            .validate(chatweave_protocol::DocumentKind::ActionResult, &result.0)
            .map_err(|error| ActionError::new("internal", &error.to_string()))?;
        Ok(result)
    }
}
