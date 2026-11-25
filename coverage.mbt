///|
/// A query that was checked against the baseline schema.
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct OperationCoverage {
  name : String
  location : Location
}

///|
/// Sources and operations actually analyzed under one client identity.
#derive(ToJson, FromJson, Eq, Debug)
pub(all) struct ClientCoverage {
  name : String
  sources : Array[String]
  operations : Array[OperationCoverage]
}

///|
/// A baseline-valid operation rejected by the proposed schema's static rules.
#derive(ToJson, FromJson, Eq, Debug)
pub struct OperationRejection {
  client : String
  operation : String
  location : Location
  message : String
  reason : ChangeReason
}

///|
/// The schema changes and catalog evidence for an upgrade.
/// Its JSON representation adds format_version and coverage alongside changes.
#derive(Eq, Debug)
pub struct AnalyzedUpgrade {
  report : Report
  coverage : Array[ClientCoverage]
  proposed_rejections : Array[OperationRejection]?
}

///|
let report_format_version : Int32 = 1

///|
pub impl ToJson for AnalyzedUpgrade with fn to_json(self) {
  let fields = Map([
    ("format_version", ToJson::to_json(report_format_version)),
    ("changes", ToJson::to_json(self.report.changes)),
    ("coverage", ToJson::to_json(self.coverage)),
  ])
  if self.proposed_rejections is Some(rejections) {
    fields["proposed_rejections"] = ToJson::to_json(rejections)
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for AnalyzedUpgrade with fn from_json(value, context) {
  guard value is { "format_version": Number(version, ..), .. } &&
    version == report_format_version.to_double() else {
    raise context
      .add_key("format_version")
      .error("expected report format version 1")
  }
  let report : Report = @json.from_json(value, path=context)
  guard value is { "coverage": entries, .. } else {
    raise context.add_key("coverage").error("expected client coverage array")
  }
  let coverage : Array[ClientCoverage] = @json.from_json(
    entries,
    path=context.add_key("coverage"),
  )
  let proposed_rejections : Array[OperationRejection]? = if value
    is { "proposed_rejections": rejections, .. } {
    Some(
      @json.from_json(rejections, path=context.add_key("proposed_rejections")),
    )
  } else {
    None
  }
  { report, coverage, proposed_rejections, }
}

///|
pub extend OperationCoverage with ToJson::{to_json}

///|
pub extend OperationCoverage with @json.FromJson::{from_json}

///|
pub extend OperationCoverage with Eq::{equal, not_equal}

///|
pub extend OperationCoverage with @debug.Debug::{to_repr}

///|
pub extend ClientCoverage with ToJson::{to_json}

///|
pub extend ClientCoverage with @json.FromJson::{from_json}

///|
pub extend ClientCoverage with Eq::{equal, not_equal}

///|
pub extend ClientCoverage with @debug.Debug::{to_repr}

///|
pub extend AnalyzedUpgrade with ToJson::{to_json}

///|
pub extend AnalyzedUpgrade with @json.FromJson::{from_json}

///|
pub extend AnalyzedUpgrade with Eq::{equal, not_equal}

///|
pub extend AnalyzedUpgrade with @debug.Debug::{to_repr}

///|
pub extend OperationRejection with ToJson::{to_json}

///|
pub extend OperationRejection with @json.FromJson::{from_json}

///|
pub extend OperationRejection with Eq::{equal, not_equal}

///|
pub extend OperationRejection with @debug.Debug::{to_repr}
