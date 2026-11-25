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
/// An analysis result that keeps the original report and the catalog coverage.
/// Its JSON representation adds format_version and coverage alongside changes.
#derive(Eq, Debug)
pub struct AnalyzedUpgrade {
  report : Report
  coverage : Array[ClientCoverage]
}

///|
let report_format_version : Int32 = 1

///|
pub impl ToJson for AnalyzedUpgrade with fn to_json(self) {
  Json::object(
    Map([
      ("format_version", ToJson::to_json(report_format_version)),
      ("changes", ToJson::to_json(self.report.changes)),
      ("coverage", ToJson::to_json(self.coverage)),
    ]),
  )
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
  { report, coverage, }
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
