use crate::{ProtocolError, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Number, Value};
use std::collections::BTreeMap;

// Optional wire fields are omitted rather than materialized with defaults.
macro_rules! data_struct {
    ($name:ident { $($field:ident: $ty:ty),* $(,)? }) => {
        #[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        pub struct $name {
            $(pub $field: $ty,)*
            #[serde(flatten)]
            pub extra: Map<String, Value>,
        }
    };
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Scalar { Number(Number), Text(String), Boolean(bool), Null }
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MetricValue { Number(Number), Text(String), Null }

// Most fields are required by their Schema; optional extensions stay in `extra`
// so round trips preserve absence, explicit nulls and future optional fields.
data_struct!(MarkdownData { text: String });
data_struct!(MetricData { label: String, value: MetricValue });
data_struct!(MetricGroupData { metrics: Vec<MetricData> });
data_struct!(Column { key: String, label: String, r#type: String });
data_struct!(DatasetData { columns: Vec<Column>, rows: Vec<BTreeMap<String, Scalar>> });
data_struct!(SeriesPoint { x: AxisValue, y: Option<Number> });
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AxisValue { Number(Number), Text(String) }
data_struct!(Series { key: String, label: String, points: Vec<SeriesPoint> });
data_struct!(TimeSeriesData { x_type: String, series: Vec<Series> });
data_struct!(Subject { id: String, label: String });
data_struct!(Attribute { key: String, label: String });
data_struct!(ComparisonValue { subject: String, attribute: String, value: Scalar });
data_struct!(ComparisonData { subjects: Vec<Subject>, attributes: Vec<Attribute>, values: Vec<ComparisonValue> });
data_struct!(StatusData { label: String, state: String });
data_struct!(ChoiceOption { id: String, label: String });
data_struct!(ActionDeclaration { r#type: String, target: String });
data_struct!(ChoiceData { prompt: String, options: Vec<ChoiceOption>, action: ActionDeclaration });
data_struct!(ConfirmationData { title: String, severity: String, action: ActionDeclaration });
data_struct!(FormField { key: String, label: String, r#type: String });
data_struct!(FormIntentData { fields: Vec<FormField>, action: ActionDeclaration });

#[derive(Debug, Clone, PartialEq)]
pub enum BlockData {
    Markdown(MarkdownData), Metric(MetricData), MetricGroup(MetricGroupData),
    Dataset(DatasetData), TimeSeries(TimeSeriesData), Comparison(ComparisonData),
    Status(StatusData), Choice(ChoiceData), Confirmation(ConfirmationData),
    FormIntent(FormIntentData), Custom(Value),
}
impl BlockData {
    pub fn parse(block_type: &str, value: Value) -> Result<Self> {
        macro_rules! parse {
            ($ty:ty, $variant:ident) => {
                serde_json::from_value::<$ty>(value).map(Self::$variant)
                    .map_err(|e| ProtocolError::new("invalid_data", "/data", e.to_string()))
            };
        }
        match block_type {
            "markdown" => parse!(MarkdownData, Markdown),
            "metric" => parse!(MetricData, Metric),
            "metric_group" => parse!(MetricGroupData, MetricGroup),
            "dataset" => parse!(DatasetData, Dataset),
            "time_series" => parse!(TimeSeriesData, TimeSeries),
            "comparison" => parse!(ComparisonData, Comparison),
            "status" => parse!(StatusData, Status),
            "choice" => parse!(ChoiceData, Choice),
            "confirmation" => parse!(ConfirmationData, Confirmation),
            "form_intent" => parse!(FormIntentData, FormIntent),
            _ => Ok(Self::Custom(value)),
        }
    }
    pub fn to_value(&self) -> Result<Value> {
        macro_rules! value { ($v:expr) => { serde_json::to_value($v).map_err(|e| ProtocolError::new("serialization", "/data", e.to_string())) }; }
        match self {
            Self::Markdown(v) => value!(v), Self::Metric(v) => value!(v),
            Self::MetricGroup(v) => value!(v), Self::Dataset(v) => value!(v),
            Self::TimeSeries(v) => value!(v), Self::Comparison(v) => value!(v),
            Self::Status(v) => value!(v), Self::Choice(v) => value!(v),
            Self::Confirmation(v) => value!(v), Self::FormIntent(v) => value!(v),
            Self::Custom(v) => Ok(v.clone()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role { Assistant, User, System }
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageStatus { Streaming, Paused, Complete, Interrupted, Error }
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockStatus { Pending, Complete, Error }
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepEndState { Succeeded, Failed, Cancelled }
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepState { Running, AwaitingUser, Succeeded, Failed, Cancelled }
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ActionType {
    #[serde(rename = "choice.select")]
    ChoiceSelect,
    #[serde(rename = "confirmation.respond")]
    ConfirmationRespond,
    #[serde(rename = "form.submit")]
    FormSubmit,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceStep {
    pub id: String,
    pub label: String,
    pub state: StepState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub block_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_step_id: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Interrupt {
    pub id: String,
    pub step_id: String,
    pub block_id: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other_input: Option<bool>,
}
