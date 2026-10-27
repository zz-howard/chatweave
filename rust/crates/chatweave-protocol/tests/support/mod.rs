use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use chatweave_protocol::{ActionRequest, ActionResult, ActionSpec, ClientCapabilities, GenerationResponse, Block, DocumentKind, FoldState, Limits, Message, SchemaRegistry, StreamEvent, Validator};
use serde_json::Value;

type CheckResult<T> = std::result::Result<T, String>;
fn read(path: &Path) -> CheckResult<Value> {
    let bytes = fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|e| format!("{}:{}:{}: {e}",path.display(),e.line(),e.column()))?;
    let text = serde_json::to_string(&value).map_err(|e|e.to_string())?;
    let decoded: Value = serde_json::from_str(&text).map_err(|e|e.to_string())?;
    if decoded != value { return Err(format!("{}: raw JSON roundtrip changed value", path.display())); }
    Ok(value)
}
fn file<'a>(case: &'a Value, key: &str) -> CheckResult<&'a str> {
    case[key].as_str().ok_or_else(|| format!("manifest case missing {key}: {case}"))
}
fn roundtrip(kind: DocumentKind, value: &Value) -> CheckResult<()> {
    let actual = match kind {
        DocumentKind::Message => serde_json::to_value(serde_json::from_value::<Message>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::Block => {
            let block: Block = serde_json::from_value(value.clone()).map_err(|e|e.to_string())?;
            if let Some(data) = block.typed_data().map_err(|e|e.to_string())?
                && data.to_value().map_err(|e|e.to_string())? != value["data"]
            {
                return Err("typed builtin data roundtrip changed JSON".into());
            }
            serde_json::to_value(block)
        }
        DocumentKind::Event => serde_json::to_value(serde_json::from_value::<StreamEvent>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::Action if value.get("actionId").is_some() => serde_json::to_value(serde_json::from_value::<ActionResult>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::Action | DocumentKind::ActionRequest => serde_json::to_value(serde_json::from_value::<ActionRequest>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::ActionSpec => serde_json::to_value(serde_json::from_value::<ActionSpec>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::ActionResult => serde_json::to_value(serde_json::from_value::<ActionResult>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::Generation => serde_json::to_value(serde_json::from_value::<GenerationResponse>(value.clone()).map_err(|e|e.to_string())?),
        DocumentKind::Capabilities => serde_json::to_value(serde_json::from_value::<ClientCapabilities>(value.clone()).map_err(|e|e.to_string())?),
    }.map_err(|e: serde_json::Error|e.to_string())?;
    if &actual != value { return Err("JSON roundtrip changed a wire value".into()); }
    Ok(())
}
fn events(path: &Path) -> CheckResult<Vec<StreamEvent>> {
    let text = fs::read_to_string(path).map_err(|e|format!("{}: {e}",path.display()))?;
    text.lines().enumerate().filter(|(_,line)|!line.trim().is_empty()).map(|(i,line)| {
        serde_json::from_str(line).map_err(|e|format!("{}:{}: {e}",path.display(),i+1))
    }).collect()
}
fn register(registry: &mut SchemaRegistry, list: &Value) -> CheckResult<()> {
    if let Some(list) = list.as_array() {
        for entry in list {
            registry.register(file(entry,"blockType")?,entry["schemaVersion"].as_u64().unwrap_or(1) as u32,entry["schema"].clone())
                .map_err(|e|e.to_string())?;
        }
    }
    Ok(())
}
fn all_files(path: &Path, root: &Path, result: &mut BTreeSet<String>) -> CheckResult<()> {
    for entry in fs::read_dir(path).map_err(|e|format!("{}: {e}",path.display()))? {
        let path = entry.map_err(|e|e.to_string())?.path();
        if path.is_dir() { all_files(&path,root,result)?; }
        else if matches!(path.extension().and_then(|v|v.to_str()),Some("json"|"jsonl")) {
            result.insert(path.strip_prefix(root).map_err(|e|e.to_string())?.to_string_lossy().replace('\\',"/"));
        }
    }
    Ok(())
}
pub fn run(repository: &Path) -> CheckResult<usize> {
    let root = repository.join("fixtures/conformance");
    let manifest = read(&root.join("manifest.json"))?;
    let cases = manifest["cases"].as_array().filter(|v|!v.is_empty()).ok_or("manifest has zero cases")?;
    let mut registry = SchemaRegistry::default();
    register(&mut registry,&manifest["customSchemas"])?;
    let mut tracked = BTreeSet::from(["manifest.json".to_owned()]);
    // Scenario drivers are executed by server tests, not standalone schemas.
    if let Some(path) = manifest["actionScenarios"].as_str() {
        read(&root.join(path))?;
        tracked.insert(path.to_owned());
    } else if root.join("action-scenarios.json").exists() {
        read(&root.join("action-scenarios.json"))?;
        tracked.insert("action-scenarios.json".into());
    }
    let base_validator = Validator::new(Limits::default(),registry.clone()).map_err(|e|e.to_string())?;
    let mut count=0;
    for case in cases {
        let name=case["name"].as_str().unwrap_or("unnamed");
        let case_validator = if case.get("customSchemas").is_some() {
            let mut case_registry = registry.clone();
            register(&mut case_registry, &case["customSchemas"])?;
            Some(Validator::new(Limits::default(), case_registry).map_err(|e| format!("{name}: {e}"))?)
        } else { None };
        let validator = case_validator.as_ref().unwrap_or(&base_validator);
        let rejected=case["rejectAt"].as_str();
        let check:CheckResult<()>=if case["kind"]=="events" || case.get("events").is_some() {
            let path=file(case,"events")?;
            tracked.insert(path.into());
            let stream=events(&root.join(path))?;
            if stream.is_empty() {return Err(format!("{path}: zero events"));}
            for event in &stream {
                let encoded=serde_json::to_value(event).map_err(|e|e.to_string())?;
                if encoded!=event.0 {return Err(format!("{path}: event roundtrip changed JSON"));}
            }
            let schema_result=stream.iter().try_for_each(|e|validator.validate_schema_only(DocumentKind::Event,&e.0));
            let limits_result=stream.iter().try_for_each(|e|validator.check_limits(DocumentKind::Event,&e.0));
            let mut state=if case["legacySteps"]==true {FoldState::with_legacy_steps()}else{FoldState::new()};
            let folded=stream.iter().try_for_each(|e|state.apply(e.clone())).and_then(|()|state.message());
            let strict=if case["mode"]=="consumer" || case["legacySteps"]==true {
                folded.clone()
            } else {validator.validate_stream(&stream)};
            match rejected {
                Some("schema") => if schema_result.is_err() {Ok(())}else{Err("expected Schema rejection".into())},
                Some("limits") => if (schema_result.is_ok() || case["mode"] == "consumer")
                    && (limits_result.is_err() || strict.as_ref().is_err_and(|e|e.code=="limit_exceeded")) {Ok(())}else{Err("expected Limits rejection after valid structure".into())},
                Some("semantic") => if schema_result.is_ok() && limits_result.is_ok() && strict.is_err() {Ok(())}else{Err(format!("expected semantic rejection after valid structure: {schema_result:?}, {limits_result:?}, {strict:?}"))},
                Some(other) => Err(format!("unknown rejectAt {other}")),
                None => {
                    let actual=strict.map_err(|e|e.to_string())?;
                    let path=file(case,"expected")?;
                    tracked.insert(path.into());
                    let expected=read(&root.join(path))?;
                    base_validator.validate_schema_only(DocumentKind::Message,&expected).map_err(|e|format!("{path}: {e}"))?;
                    if actual.0!=expected {Err(format!("fold mismatch\nactual: {}\nexpected: {}",actual.0,expected))} else {roundtrip(DocumentKind::Message,&expected)}
                }
            }
        } else {
            let path=file(case,"file")?;
            tracked.insert(path.into());
            let value=read(&root.join(path))?;
            let schema=case["schema"].as_str().or_else(||case["kind"].as_str()).ok_or("case missing schema")?;
            let kind=DocumentKind::from_schema(schema).ok_or_else(||format!("unsupported schema {schema}"))?;
            let result=validator.validate(kind,&value);
            match rejected {
                Some("schema") => if validator.validate_schema_only(kind,&value).is_err() {Ok(())}else{Err("expected Schema rejection".into())},
                Some("limits") => if validator.validate_schema_only(kind,&value).is_ok() && validator.check_limits(kind,&value).is_err() {Ok(())}else{Err("expected Limits rejection after valid structure".into())},
                Some("semantic") => if validator.validate_schema_only(kind,&value).is_ok() && validator.check_limits(kind,&value).is_ok() && result.is_err() {Ok(())}else{Err("expected semantic rejection".into())},
                Some(other) => Err(format!("unknown rejectAt {other}")),
                None => {result.map_err(|e|e.to_string())?;roundtrip(kind,&value)}
            }
        };
        check.map_err(|e|format!("manifest case {name}: {e}"))?;
        for key in ["expectedError","expected-error"] {
            if let Some(path) = case[key].as_str() {
                let expected_error = read(&root.join(path))?;
                if expected_error["rejectAt"].as_str() != rejected {
                    return Err(format!("{path}: expected-error layer differs from manifest"));
                }
                tracked.insert(path.into());
            }
        }
        count+=1;
    }
    let mut found=BTreeSet::new();
    all_files(&root,&root,&mut found)?;
    let missing:Vec<_>=found.difference(&tracked).collect();
    if !missing.is_empty() {return Err(format!("unregistered fixture files: {missing:?}"));}
    Ok(count)
}
pub fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}
