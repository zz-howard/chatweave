use std::collections::BTreeSet;
use serde_json::{Value,json};
use crate::{DocumentKind, Message, ProtocolError, Result, StreamEvent};
use crate::validation::builtin;

/// RFC 7396: null removes an object member; arrays and scalars replace wholly.
pub fn merge_patch(target:&mut Value,patch:&Value) {
    if let Value::Object(patch)=patch {
        if !target.is_object() { *target=json!({}); }
        let target=target.as_object_mut().expect("object assigned above");
        for (key,value) in patch {
            if value.is_null() { target.remove(key); }
            else { merge_patch(target.entry(key).or_insert(Value::Null),value); }
        }
    } else { *target=patch.clone(); }
}
fn error(code:&str,message:impl Into<String>)->ProtocolError { ProtocolError::new(code,"",message) }
fn required<'a>(value:&'a Value,key:&str)->Result<&'a str> {
    value[key].as_str().ok_or_else(||error("invalid_event",format!("missing string {key}")))
}
fn active(state:&Value)->bool { matches!(state.as_str(),Some("running"|"awaiting_user")) }

#[derive(Debug,Clone,Default)]
pub struct FoldState {
    message:Option<Value>,
    last_seq:u64,
    interrupt_ids:BTreeSet<String>,
    previous_answer:Option<(u64,String)>,
    legacy_steps:bool,
}
impl FoldState {
    pub fn new()->Self {Self::default()}
    /// Simulates consumers that do not implement stream.steps.
    pub fn with_legacy_steps()->Self { Self{legacy_steps:true,..Self::default()} }
    pub fn last_seq(&self)->u64 {self.last_seq}
    pub fn message(&self)->Result<Message> {
        let mut value=self.message.clone().ok_or_else(||error("missing_start","no message state"))?;
        if matches!(value["status"].as_str(),Some("streaming"|"paused")) {
            value["lastSeq"]=self.last_seq.into();
        } else {value.as_object_mut().expect("message object").remove("lastSeq");}
        Ok(Message(value))
    }
    /// An invalid event never leaves a partially mutated state.
    pub fn apply(&mut self,event:StreamEvent)->Result<()> {
        let mut candidate=self.clone();
        candidate.apply_inner(event)?;
        *self=candidate;
        Ok(())
    }
    fn apply_inner(&mut self,event:StreamEvent)->Result<()> {
        let e=&event.0;
        let ty=required(e,"type")?;
        if ty=="message.activity" {
            builtin().validate_schema_only(DocumentKind::Event,e)?;
            builtin().limits.check_event(e)?;
            return Ok(());
        }
        let seq=e["seq"].as_u64().filter(|n|*n>0).ok_or_else(||error("missing_seq","reliable event needs seq"))?;
        if ty=="message.snapshot" {
            if seq<self.last_seq {return Ok(());}
            builtin().validate_schema_only(DocumentKind::Event,e)?;
            let mut message=e["message"].clone();
            if message["id"]!=e["messageId"] {return Err(error("message_mismatch","snapshot id differs"));}
            builtin().check_message(&message,false)?;
            if let Some(last)=message["lastSeq"].as_u64() {
                if last!=seq {return Err(error("snapshot_seq","checkpoint seq differs"));}
            }
            message.as_object_mut().expect("message object").remove("lastSeq");
            if self.legacy_steps {message.as_object_mut().expect("message object").remove("steps");}
            if let Some(id)=message.pointer("/interrupt/id").and_then(Value::as_str) {self.interrupt_ids.insert(id.into());}
            self.message=Some(message);
            self.last_seq=seq;
            self.previous_answer=None;
            return Ok(());
        }
        if seq<=self.last_seq {return Ok(());}
        if seq!=self.last_seq+1 {return Err(error("seq_gap",format!("expected {}, received {seq}",self.last_seq+1)));}
        if seq>builtin().limits.max_events as u64 {return Err(error("limit_exceeded","event count exceeded"));}
        builtin().limits.check_event(e)?;
        if is_known(ty) {builtin().validate_schema_only(DocumentKind::Event,e)?;}
        else {
            required(e,"protocolVersion")?;
            required(e,"messageId")?;
        }
        if let Some(message)=&self.message {
            if message["id"]!=e["messageId"] {return Err(error("message_mismatch","event belongs to another message"));}
        }
        if ty=="message.start" {
            if self.message.is_some() {return Err(error("duplicate_start","message already started"));}
            if e["message"]["id"]!=e["messageId"] {return Err(error("message_mismatch","start id differs"));}
            let mut message=e["message"].clone();
            message["protocolVersion"]=e["protocolVersion"].clone();
            message["status"]="streaming".into();
            message["rev"]=0.into();
            message["fallbackText"]="".into();
            message["blocks"]=json!([]);
            self.message=Some(message);
            self.last_seq=seq;
            return Ok(());
        }
        let status=self.message.as_ref().ok_or_else(||error("missing_start","event before message.start"))?["status"].as_str().unwrap_or("").to_owned();
        if status=="paused" { self.check_paused_event(e)?; }
        if !matches!(status.as_str(),"streaming"|"paused") && ty!="block.patch" {
            return Err(error("message_ended","only persisted revision patches may follow message.end"));
        }
        if self.legacy_steps && matches!(ty,"step.started"|"step.finished") {
            self.last_seq=seq;
            return Ok(());
        }
        let mut answer=None;
        match ty {
            "block.start" => self.block_start(e)?,
            "block.delta" => {
                let index=self.block_index(required(e,"blockId")?)?;
                let block=&mut self.message.as_mut().expect("started")["blocks"][index];
                if block["status"]!="pending" {return Err(error("block_ended","delta on closed block"));}
                if block["type"]!="markdown" {return Err(error("invalid_delta","only markdown accepts delta"));}
                let mut text=block["data"]["text"].as_str().unwrap_or("").to_owned();
                text.push_str(required(&e["delta"],"text")?);
                block["data"]["text"]=text.into();
                builtin().check_block(block,false)?;
            }
            "block.data" => {
                let index=self.block_index(required(e,"blockId")?)?;
                let block=&mut self.message.as_mut().expect("started")["blocks"][index];
                if block["status"]!="pending" {return Err(error("block_ended","data on closed block"));}
                if block.get("data").is_some() {return Err(error("duplicate_block_data","component data delivered twice"));}
                if block["type"]=="markdown" {return Err(error("invalid_data","markdown uses delta"));}
                block["data"]=e["data"].clone();
                block["fallbackText"]=e["fallbackText"].clone();
                if let Some(metadata)=e.get("metadata") {block["metadata"]=metadata.clone();}
                builtin().check_block(block,false)?;
            }
            "block.patch" => {
                let index=self.block_index(required(e,"blockId")?)?;
                let message=self.message.as_mut().expect("started");
                let current_rev=message["rev"].as_u64().unwrap_or(0);
                if current_rev>0 {
                    let rev=e["rev"].as_u64().ok_or_else(||error("missing_rev","persisted patch needs rev"))?;
                    if rev<=current_rev {self.last_seq=seq;return Ok(());}
                    if rev!=current_rev+1 {return Err(error("rev_gap","revision gap requires authoritative message"));}
                    message["rev"]=rev.into();
                } else if e.get("rev").is_some() {return Err(error("unexpected_rev","unfinished message patch has no rev"));}
                let block=&mut message["blocks"][index];
                merge_patch(block,&e["patch"]);
                builtin().check_block(block,false)?;
                if status=="paused" && block.pointer("/data/state/status")==Some(&json!("resolved")) {
                    answer=Some((seq,required(block,"id")?.to_owned()));
                }
            }
            "block.end" => {
                let index=self.block_index(required(e,"blockId")?)?;
                let block=&mut self.message.as_mut().expect("started")["blocks"][index];
                if block["status"]!="pending" {return Err(error("block_ended","block ended twice"));}
                if e["status"]=="error" {
                    block["status"]="error".into();
                    if let Some(text)=e.pointer("/error/message").and_then(Value::as_str) {block["reason"]=text.into();}
                } else {block.as_object_mut().expect("block object").remove("status");}
                if let Some(text)=e.get("fallbackText") {block["fallbackText"]=text.clone();}
                if block["type"]=="markdown" && block["fallbackText"]=="" && block.get("status").is_none() {
                    block.as_object_mut().expect("block object").remove("fallbackText");
                }
                builtin().check_block(block,false)?;
            }
            "step.started" => self.step_start(e)?,
            "step.finished" => self.step_finish(e)?,
            "message.paused" => self.pause(e)?,
            "message.resumed" => {
                let message=self.message.as_mut().expect("started");
                if status!="paused" || message["interrupt"]["id"]!=e["interruptId"] {
                    return Err(error("interrupt_mismatch","resumed interrupt differs"));
                }
                let block_id=required(&message["interrupt"],"blockId")?.to_owned();
                if self.previous_answer.as_ref()!=Some(&(seq-1,block_id)) {
                    return Err(error("resume_order","resumed must immediately follow the recorded answer"));
                }
                let step_id=required(&message["interrupt"],"stepId")?.to_owned();
                if !self.legacy_steps {
                    let steps=message["steps"].as_array_mut().ok_or_else(||error("invalid_interrupt","missing steps"))?;
                    let step=steps.iter_mut().find(|s|s["id"]==step_id).ok_or_else(||error("invalid_interrupt","missing step"))?;
                    step["state"]="running".into();
                }
                message["status"]="streaming".into();
                message.as_object_mut().expect("message object").remove("interrupt");
            }
            "message.end" => {
                let message=self.message.as_mut().expect("started");
                if message["blocks"].as_array().expect("blocks").iter().any(|b|b["status"]=="pending") {
                    return Err(error("unfinished_block","all blocks must end before message.end"));
                }
                if message["steps"].as_array().is_some_and(|steps|steps.iter().any(|s|active(&s["state"]))) {
                    return Err(error("unfinished_step","all steps must finish before message.end"));
                }
                if e["blockCount"].as_u64()!=Some(message["blocks"].as_array().expect("blocks").len() as u64) {
                    return Err(error("block_count","message.end block count differs"));
                }
                if e["rev"]!=1 {return Err(error("invalid_rev","initial final revision must be one"));}
                message["status"]=e["status"].clone();
                message["rev"]=e["rev"].clone();
                message["fallbackText"]=e["fallbackText"].clone();
                if let Some(ts)=e.get("ts") {message["completedAt"]=ts.clone();}
                message.as_object_mut().expect("message object").remove("interrupt");
                builtin().check_message(message,false)?;
            }
            "error" => (),
            _ => (), // Unknown reliable event still advances seq.
        }
        self.last_seq=seq;
        self.previous_answer=answer;
        if let Some(message)=&self.message {builtin().limits.check_message(message)?;}
        Ok(())
    }
    fn block_index(&self,id:&str)->Result<usize> {
        self.message.as_ref().and_then(|m|m["blocks"].as_array()).and_then(|bs|bs.iter().position(|b|b["id"]==id))
            .ok_or_else(||error("unknown_block",id))
    }
    fn step_index(&self,id:&str)->Result<usize> {
        self.message.as_ref().and_then(|m|m["steps"].as_array()).and_then(|ss|ss.iter().position(|s|s["id"]==id))
            .ok_or_else(||error("unknown_step",id))
    }
    fn block_start(&mut self,e:&Value)->Result<()> {
        let id=required(e,"blockId")?;
        if self.block_index(id).is_ok() {return Err(error("duplicate_block_id",id));}
        let message=self.message.as_mut().expect("started");
        let blocks=message["blocks"].as_array_mut().expect("blocks");
        if e["index"].as_u64()!=Some(blocks.len() as u64) {return Err(error("block_index","blocks start in index order"));}
        if e["blockType"]=="markdown" && blocks.iter().any(|b|b["type"]=="markdown"&&b["status"]=="pending") {
            return Err(error("multiple_markdown","only one markdown block may be open"));
        }
        let mut block=json!({"id":id,"type":e["blockType"],"schemaVersion":e["schemaVersion"],"status":"pending","fallbackText":""});
        if e["blockType"]=="markdown" {block["data"]=json!({"text":""});}
        builtin().check_block(&block,false)?;
        blocks.push(block);
        Ok(())
    }
    fn step_start(&mut self,e:&Value)->Result<()> {
        let id=required(e,"stepId")?;
        if self.step_index(id).is_ok() {return Err(error("duplicate_step_id",id));}
        if let Some(parent)=e["parentStepId"].as_str() {
            let index=self.step_index(parent).map_err(|_|error("invalid_parent",parent))?;
            let steps=self.message.as_ref().expect("started")["steps"].as_array().expect("steps");
            if steps[index]["kind"]!="delegate" || steps[index]["state"]!="running" {return Err(error("invalid_parent",parent));}
            let mut depth=2;
            let mut current=&steps[index];
            while let Some(parent)=current["parentStepId"].as_str() {
                depth+=1;
                current=&steps[self.step_index(parent)?];
            }
            if depth>3 {return Err(error("step_depth","maximum depth is three"));}
        }
        let message=self.message.as_mut().expect("started");
        if message.get("steps").is_none() {message["steps"]=json!([]);}
        let steps=message["steps"].as_array_mut().expect("steps");
        if steps.len()>=64 {return Err(error("limit_exceeded","maximum steps exceeded"));}
        let mut step=json!({"id":id,"label":e["label"],"state":"running"});
        for key in ["kind","parentStepId"] {if let Some(value)=e.get(key) {step[key]=value.clone();}}
        steps.push(step);
        Ok(())
    }
    fn step_finish(&mut self,e:&Value)->Result<()> {
        let id=required(e,"stepId")?;
        let index=self.step_index(id)?;
        let message=self.message.as_mut().expect("started");
        let steps=message["steps"].as_array_mut().expect("steps");
        if !active(&steps[index]["state"]) {return Err(error("step_ended",id));}
        if steps.iter().any(|s|s["parentStepId"]==id&&active(&s["state"])) {return Err(error("unfinished_child",id));}
        steps[index]["state"]=e["state"].clone();
        steps[index]["durationMs"]=e["durationMs"].clone();
        if let Some(summary)=e.get("summary") {steps[index]["summary"]=summary.clone();}
        Ok(())
    }
    fn pause(&mut self,e:&Value)->Result<()> {
        let message=self.message.as_ref().expect("started");
        if message["status"]!="streaming" {return Err(error("already_paused","message is not streaming"));}
        if message["blocks"].as_array().expect("blocks").iter().any(|b|b["status"]=="pending") {
            return Err(error("pause_open_block","all blocks must finish before pausing"));
        }
        if e["blockCount"].as_u64()!=Some(message["blocks"].as_array().expect("blocks").len() as u64) {
            return Err(error("block_count","paused block count differs"));
        }
        let interrupt=&e["interrupt"];
        let id=required(interrupt,"id")?;
        if self.interrupt_ids.contains(id) {return Err(error("duplicate_interrupt_id",id));}
        let block=&message["blocks"][self.block_index(required(interrupt,"blockId")?)?];
        if !matches!(block["type"].as_str(),Some("choice"|"confirmation"|"form_intent"))
            || block.pointer("/data/state/status").and_then(Value::as_str).unwrap_or("open")!="open" {
            return Err(error("invalid_interrupt","interrupt needs an open interaction block"));
        }
        if !self.legacy_steps {
            let index=self.step_index(required(interrupt,"stepId")?)?;
            let steps=message["steps"].as_array().expect("steps");
            if steps[index]["state"]!="running" {return Err(error("invalid_interrupt","interrupt step must be running"));}
            let mut ancestors=BTreeSet::new();
            let mut current=&steps[index];
            ancestors.insert(required(current,"id")?.to_owned());
            while let Some(parent)=current["parentStepId"].as_str() {
                ancestors.insert(parent.to_owned());
                current=&steps[self.step_index(parent)?];
            }
            if steps.iter().any(|s|active(&s["state"])&&!ancestors.contains(s["id"].as_str().unwrap_or(""))) {
                return Err(error("pause_other_step","unrelated steps still running"));
            }
            let message=self.message.as_mut().expect("started");
            message["steps"][index]["state"]="awaiting_user".into();
            message["steps"][index]["blockId"]=interrupt["blockId"].clone();
        }
        let message=self.message.as_mut().expect("started");
        message["status"]="paused".into();
        message["interrupt"]=interrupt.clone();
        message["fallbackText"]=e["fallbackText"].clone();
        self.interrupt_ids.insert(id.to_owned());
        Ok(())
    }
    fn check_paused_event(&self,e:&Value)->Result<()> {
        let message=self.message.as_ref().expect("started");
        let interrupt=&message["interrupt"];
        let block=&message["blocks"][self.block_index(required(interrupt,"blockId")?)?];
        match e["type"].as_str().unwrap_or("") {
            "block.patch" if e["blockId"]==interrupt["blockId"] && e.get("rev").is_none() => {
                if block.pointer("/data/state/status").and_then(Value::as_str).unwrap_or("open") != "open" {
                    return Err(error("paused_event", "interrupt already closed"));
                }
                let state=e.pointer("/patch/data/state/status").and_then(Value::as_str).unwrap_or("");
                if !matches!(state,"resolved"|"cancelled"|"expired") {return Err(error("paused_event","invalid interrupt transition"));}
            }
            "message.resumed" if block.pointer("/data/state/status")==Some(&json!("resolved")) => (),
            "step.finished" if e["state"]=="cancelled"
                && matches!(block.pointer("/data/state/status").and_then(Value::as_str),Some("cancelled"|"expired")) => {
                let index=self.step_index(required(e,"stepId")?)?;
                let step=&message["steps"][index];
                if !active(&step["state"]) {return Err(error("paused_event","step no longer active"));}
            }
            "message.end" if e["status"]=="interrupted"
                && matches!(block.pointer("/data/state/status").and_then(Value::as_str),Some("cancelled"|"expired")) => (),
            _ => return Err(error("paused_event","event not allowed while paused")),
        }
        Ok(())
    }
}
fn is_known(ty:&str)->bool {
    matches!(ty,"message.start"|"block.start"|"block.delta"|"block.data"|"block.patch"|"block.end"|
        "message.end"|"message.paused"|"message.resumed"|"message.snapshot"|"message.activity"|
        "step.started"|"step.finished"|"error")
}
pub fn fold(events:impl IntoIterator<Item=StreamEvent>)->Result<Message> {
    let mut state=FoldState::new();
    for event in events {state.apply(event)?;}
    state.message()
}
