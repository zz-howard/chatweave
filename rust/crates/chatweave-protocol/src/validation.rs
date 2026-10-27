use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;
use serde_json::{Value, json};
use crate::{Block, FoldState, Limits, Message, ProtocolError, Result, StreamEvent};

const BASE: &str = "https://github.com/zz-howard/chatweave/schemas/v0.1/";
const SCHEMAS: [(&str, &str); 6] = [
    ("message.schema.json", include_str!("../../../../schemas/v0.1/message.schema.json")),
    ("content-block.schema.json", include_str!("../../../../schemas/v0.1/content-block.schema.json")),
    ("stream-event.schema.json", include_str!("../../../../schemas/v0.1/stream-event.schema.json")),
    ("action.schema.json", include_str!("../../../../schemas/v0.1/action.schema.json")),
    ("generation.schema.json", include_str!("../../../../schemas/v0.1/generation.schema.json")),
    ("capabilities.schema.json", include_str!("../../../../schemas/v0.1/capabilities.schema.json")),
];
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DocumentKind { Message, Block, Event, Action, ActionSpec, ActionRequest, ActionResult, Generation, Capabilities }
impl DocumentKind {
    pub fn from_schema(schema: &str) -> Option<Self> {
        if schema.contains("#/$defs/actionSpec") { return Some(Self::ActionSpec) }
        if schema.contains("#/$defs/actionRequest") { return Some(Self::ActionRequest) }
        if schema.contains("#/$defs/actionResult") { return Some(Self::ActionResult) }
        let name = schema.rsplit('/').next().unwrap_or(schema);
        match name {
            "message" | "message.schema.json" => Some(Self::Message),
            "block" | "content-block.schema.json" => Some(Self::Block),
            "event" | "stream-event.schema.json" => Some(Self::Event),
            "action.schema.json" | "action" => Some(Self::Action),
            "actionRequest" => Some(Self::ActionRequest),
            "actionResult" => Some(Self::ActionResult),
            "generation" | "generation.schema.json" => Some(Self::Generation),
            "capabilities" | "capabilities.schema.json" => Some(Self::Capabilities),
            _ => None,
        }
    }
    fn reference(self) -> String {
        let suffix = match self {
            Self::Message => "message.schema.json", Self::Block => "content-block.schema.json",
            Self::Event => "stream-event.schema.json", Self::Action => "action.schema.json", Self::ActionSpec => "action.schema.json#/$defs/actionSpec",
            Self::ActionRequest => "action.schema.json#/$defs/actionRequest",
            Self::ActionResult => "action.schema.json#/$defs/actionResult",
            Self::Generation => "generation.schema.json", Self::Capabilities => "capabilities.schema.json",
        };
        format!("{BASE}{suffix}")
    }
}
#[derive(Debug, Clone, Default)]
pub struct SchemaRegistry { schemas: BTreeMap<(String,u32),Value> }
impl SchemaRegistry {
    pub fn register(&mut self, block_type: &str, schema_version: u32, schema: Value) -> Result<()> {
        if !block_type.starts_with("x-") || schema_version == 0 {
            return Err(ProtocolError::new("invalid_schema","","custom types require a namespace and a positive version"));
        }
        let probe = json!({"id":"probe","type":block_type,"schemaVersion":schema_version,"status":"pending","fallbackText":""});
        builtin().validate_schema_only(DocumentKind::Block,&probe)?;
        jsonschema::meta::validate(&schema).map_err(|e| ProtocolError::new("invalid_schema","",e.to_string()))?;
        // Reject nonlocal references; a custom schema is a self-contained document.
        reject_external_refs(&schema)?;
        jsonschema::draft202012::options().should_validate_formats(true).build(&schema)
            .map_err(|e|ProtocolError::new("invalid_schema","",e.to_string()))?;
        let key = (block_type.to_owned(),schema_version);
        if self.schemas.contains_key(&key) { return Err(ProtocolError::new("duplicate_schema","",block_type)); }
        self.schemas.insert(key,schema);
        Ok(())
    }
}
fn reject_external_refs(value:&Value)->Result<()> {
    match value {
        Value::Object(map) => {
            if map.get("$ref").and_then(Value::as_str).is_some_and(|r|!r.starts_with('#')) {
                return Err(ProtocolError::new("external_reference","/$ref","external IO is disabled"));
            }
            for child in map.values() { reject_external_refs(child)?; }
        }
        Value::Array(values) => for child in values { reject_external_refs(child)?; },
        _ => (),
    }
    Ok(())
}
pub struct Validator {
    pub limits: Limits,
    validators: BTreeMap<DocumentKind,jsonschema::Validator>,
    custom: BTreeMap<(String,u32),jsonschema::Validator>,
}
impl Default for Validator {
    fn default() -> Self { Self::new(Limits::default(),SchemaRegistry::default()).expect("embedded schemas must be valid") }
}
impl Validator {
    pub fn new(limits:Limits, registry:SchemaRegistry)->Result<Self> {
        limits.validate_configuration()?;
        let documents:Vec<(String,Value)> = SCHEMAS.iter().map(|(name,text)| {
            serde_json::from_str::<Value>(text).map(|v|(format!("{BASE}{name}"),v))
                .map_err(|e|ProtocolError::new("invalid_schema",*name,e.to_string()))
        }).collect::<Result<_>>()?;
        for (_,value) in &documents {
            jsonschema::meta::validate(value).map_err(|e|ProtocolError::new("invalid_schema","",e.to_string()))?;
        }
        let mut validators = BTreeMap::new();
        for kind in [DocumentKind::Message,DocumentKind::Block,DocumentKind::Event,
            DocumentKind::Action,DocumentKind::ActionSpec,DocumentKind::ActionRequest,DocumentKind::ActionResult,
            DocumentKind::Generation,DocumentKind::Capabilities] {
            let mut options = jsonschema::draft202012::options().should_validate_formats(true);
            for (uri,value) in &documents {
                let resource = jsonschema::Resource::from_contents(value.clone())
                    .map_err(|e|ProtocolError::new("invalid_schema",uri,e.to_string()))?;
                options = options.with_resource(uri.clone(),resource);
            }
            let compiled = options.build(&json!({"$ref":kind.reference()}))
                .map_err(|e|ProtocolError::new("invalid_schema","",e.to_string()))?;
            validators.insert(kind,compiled);
        }
        let mut custom = BTreeMap::new();
        for (key,schema) in registry.schemas {
            reject_external_refs(&schema)?;
            let compiled = jsonschema::draft202012::options().should_validate_formats(true).build(&schema)
                .map_err(|e|ProtocolError::new("invalid_schema","",e.to_string()))?;
            custom.insert(key,compiled);
        }
        Ok(Self{limits,validators,custom})
    }
    pub fn validate_schema_only(&self,kind:DocumentKind,value:&Value)->Result<()> {
        self.validators[&kind].validate(value).map_err(|e| {
            ProtocolError::new("schema",e.instance_path.to_string(),e.to_string())
        })
    }
    pub fn validate(&self, kind:DocumentKind, value:&Value)->Result<()> {
        self.check_limits(kind,value)?;
        self.validate_schema_only(kind,value)?;
        match kind {
            DocumentKind::Block => self.check_block(value,true)?,
            DocumentKind::Message => self.check_message(value,true)?,
            DocumentKind::Event if value["type"] == "message.snapshot" => self.check_message(&value["message"],true)?,
            _ => (),
        }
        Ok(())
    }
    pub fn check_limits(&self,kind:DocumentKind,value:&Value)->Result<()> {
        match kind {
            DocumentKind::Block => self.limits.check_block(value),
            DocumentKind::Message => self.limits.check_message(value),
            DocumentKind::Event => self.limits.check_event(value),
            _ => self.limits.check_bytes(value,self.limits.max_event_bytes,""),
        }
    }
    pub(crate) fn check_block(&self,block:&Value,strict:bool)->Result<()> {
        self.validate_schema_only(DocumentKind::Block,block)?;
        self.limits.check_block(block)?;
        Block(block.clone()).typed_data()?;
        let ty = block["type"].as_str().unwrap_or("");
        if ty.starts_with("x-") {
            let version = block["schemaVersion"].as_u64().unwrap_or(0) as u32;
            match self.custom.get(&(ty.into(),version)) {
                Some(schema) => if let Some(data)=block.get("data") {
                    schema.validate(data).map_err(|e|ProtocolError::new("schema",format!("/data{}",e.instance_path),e.to_string()))?;
                },
                None if strict => return Err(ProtocolError::new("unregistered_type","/type",ty)),
                None => (),
            }
        }
        if block.pointer("/metadata/provenance") == Some(&Value::String("adapter".into())) && ty != "markdown" {
            return Err(ProtocolError::new("invalid_provenance","/metadata/provenance","adapters produce markdown only"));
        }
        Ok(())
    }
    pub(crate) fn check_message(&self,message:&Value,strict:bool)->Result<()> {
        self.validate_schema_only(DocumentKind::Message,message)?;
        self.limits.check_message(message)?;
        let mut block_ids = BTreeSet::new();
        if let Some(blocks)=message["blocks"].as_array() {
            for block in blocks {
                if !block_ids.insert(block["id"].as_str().unwrap_or("")) {
                    return Err(ProtocolError::new("duplicate_block_id","/blocks","duplicate block id"));
                }
                self.check_block(block,strict)?;
            }
        }
        let mut seen:BTreeMap<&str,(&str,usize)> = BTreeMap::new();
        if let Some(steps)=message["steps"].as_array() {
            for step in steps {
                let id=step["id"].as_str().unwrap_or("");
                if seen.contains_key(id) { return Err(ProtocolError::new("duplicate_step_id","/steps",id)); }
                let depth=if let Some(parent)=step["parentStepId"].as_str() {
                    let Some((kind,depth))=seen.get(parent) else { return Err(ProtocolError::new("invalid_parent","/steps",parent)) };
                    if *kind != "delegate" { return Err(ProtocolError::new("invalid_parent","/steps",parent)); }
                    depth+1
                } else {1};
                if depth>3 { return Err(ProtocolError::new("step_depth","/steps","maximum depth is three")); }
                if let Some(block)=step["blockId"].as_str() {
                    if !block_ids.contains(block) {return Err(ProtocolError::new("invalid_block_reference","/steps",block));}
                }
                if matches!(step["state"].as_str(), Some("running" | "awaiting_user")) {
                    if let Some(parent) = step["parentStepId"].as_str() {
                        let parent = steps.iter().find(|candidate| candidate["id"] == parent)
                            .ok_or_else(|| ProtocolError::new("invalid_parent", "/steps", parent))?;
                        if parent["state"] != "running" {
                            return Err(ProtocolError::new("invalid_parent", "/steps", "active child requires a running delegate"));
                        }
                    }
                }
                seen.insert(id,(step["kind"].as_str().unwrap_or(""),depth));
            }
            if message["status"]=="paused" {
                let interrupt=&message["interrupt"];
                let step=steps.iter().find(|s|s["id"]==interrupt["stepId"])
                    .ok_or_else(||ProtocolError::new("invalid_interrupt","/interrupt/stepId","missing step"))?;
                if step["state"]!="awaiting_user" || step["blockId"]!=interrupt["blockId"] {
                    return Err(ProtocolError::new("invalid_interrupt","/interrupt","step and block do not match"));
                }
                let mut allowed = BTreeSet::new();
                let mut current = step;
                allowed.insert(current["id"].as_str().unwrap_or(""));
                while let Some(parent) = current["parentStepId"].as_str() {
                    allowed.insert(parent);
                    current = steps.iter().find(|candidate| candidate["id"] == parent)
                        .ok_or_else(|| ProtocolError::new("invalid_parent", "/steps", parent))?;
                }
                if steps.iter().any(|s| s["state"] == "running" && !allowed.contains(s["id"].as_str().unwrap_or(""))) {
                    return Err(ProtocolError::new("pause_other_step", "/steps", "unrelated steps still running"));
                }
            }
        }
        if message["status"]=="paused" {
            let block=message["blocks"].as_array().and_then(|bs|bs.iter().find(|b|b["id"]==message["interrupt"]["blockId"]))
                .ok_or_else(||ProtocolError::new("invalid_interrupt","/interrupt/blockId","missing block"))?;
            if !matches!(block["type"].as_str(),Some("choice"|"confirmation"|"form_intent")) {
                return Err(ProtocolError::new("invalid_interrupt","/interrupt/blockId","not an interaction"));
            }
            if block.pointer("/data/state/status").and_then(Value::as_str).unwrap_or("open") != "open" {
                return Err(ProtocolError::new("invalid_interrupt", "/interrupt/blockId", "paused checkpoint requires an open interaction"));
            }
        }
        Ok(())
    }
    pub fn validate_stream(&self,events:&[StreamEvent])->Result<Message> {
        if events.iter().filter(|e|e.seq().is_some()).count()>self.limits.max_events {
            return Err(ProtocolError::new("limit_exceeded","","event count exceeded"));
        }
        let mut state=FoldState::new();
        for event in events {
            self.validate(DocumentKind::Event,&event.0)?;
            state.apply(event.clone())?;
            if event.event_type()=="block.data" {
                if let Some(block)=state.message()?.0["blocks"].as_array().and_then(|bs|bs.iter().find(|b|b["id"]==event.0["blockId"])) {
                    self.check_block(block,true)?;
                }
            }
        }
        let message=state.message()?;
        self.validate(DocumentKind::Message,&message.0)?;
        Ok(message)
    }
}
pub(crate) fn builtin()-> &'static Validator {
    static VALUE:OnceLock<Validator>=OnceLock::new();
    VALUE.get_or_init(Validator::default)
}
pub fn validate(kind:DocumentKind,value:&Value)->Result<()> { builtin().validate(kind,value) }
