///|
/// Escape report values before placing them in Markdown inline HTML.
fn report_text(value : String) -> String {
  value
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="`", new="&#96;")
  .replace_all(old="*", new="&#42;")
  .replace_all(old="_", new="&#95;")
  .replace_all(old="[", new="&#91;")
  .replace_all(old="]", new="&#93;")
  .replace_all(old="\\", new="&#92;")
  .replace_all(old="|", new="&#124;")
  .replace_all(old="~", new="&#126;")
  .replace_all(old="\r", new="&#13;")
  .replace_all(old="\n", new="&#10;")
}

///|
fn Location::report_text(self : Location) -> String {
  report_text("\{self.path}:\{self.line}:\{self.column}")
}

///|
/// Render every change and impact as an escaped, deterministic Markdown report.
/// Ordering follows the report. Unobserved changes are included.
pub fn Report::to_markdown(self : Report) -> String {
  self.render_markdown([])
}

///|
/// Render the change report and any proposed-schema validation diagnostics.
pub fn AnalyzedUpgrade::to_markdown(self : AnalyzedUpgrade) -> String {
  self.report.render_markdown(self.proposed_rejections.unwrap_or([]))
}

///|
fn Report::render_markdown(
  self : Report,
  rejections : Array[OperationRejection],
) -> String {
  let lines = ["# GraphQL upgrade impact", ""]
  if self.changes.is_empty() && rejections.is_empty() {
    lines.push("No contract regressions in the supported profile.")
  }
  for change in self.changes {
    lines.push("## <code>" + report_text(change.coordinate) + "</code>")
    lines.push("")
    lines.push(
      "- Previous type <code>" + report_text(change.previous_type) + "</code>",
    )
    match change.proposed_type {
      Some(kind) =>
        lines.push("- Proposed type <code>" + report_text(kind) + "</code>")
      None =>
        if change.coordinate == "schema.mutation" {
          lines.push("- Mutation root removed")
        } else if change.coordinate.has_suffix(":)") {
          lines.push("- Argument removed")
        } else if change.coordinate.contains(".") {
          lines.push("- Field removed")
        } else {
          lines.push("- Type removed")
        }
    }
    if change.reasons is Some(reasons) {
      for reason in reasons {
        lines.push("- " + reason_label(reason))
      }
    }
    lines.push("- Baseline <code>" + change.baseline.report_text() + "</code>")
    if change.proposed is Some(at) {
      lines.push("- Proposed location <code>" + at.report_text() + "</code>")
    }
    lines.push("")
    if change.impacts.is_empty() {
      lines.push("No registered operation observes this change.")
    }
    for impact in change.impacts {
      lines.push(
        "- Client <code>" +
        report_text(impact.client) +
        "</code>, operation <code>" +
        report_text(impact.operation) +
        "</code>, response path <code>" +
        report_text(impact.response_path.join(".")) +
        "</code>, selection <code>" +
        impact.selection.report_text() +
        "</code>" +
        impact_reason_label(impact),
      )
    }
    lines.push("")
  }
  if !rejections.is_empty() {
    lines.push("## Operations rejected by the proposed schema")
    lines.push("")
    for rejection in rejections {
      lines.push(
        "- <code>\{report_text(rejection.client)}</code> / <code>\{report_text(rejection.operation)}</code> at <code>\{rejection.location.report_text()}</code> — \{report_text(rejection.message)} (\{reason_label(rejection.reason)})",
      )
    }
    lines.push("")
  }
  lines.join("\n") + "\n"
}

///|
fn json_label(value : Json) -> String {
  let text = match value {
    String(label) => label
    _ => value.stringify()
  }
  "<code>" + report_text(text) + "</code>"
}

///|
fn reason_label(reason : ChangeReason) -> String {
  json_label(ToJson::to_json(reason.severity)) +
  " " +
  json_label(ToJson::to_json(reason.code))
}

///|
fn impact_reason_label(impact : Impact) -> String {
  guard impact.reason_codes is Some(codes) && !codes.is_empty() else {
    return ""
  }
  ", reasons " + codes.map(code => json_label(ToJson::to_json(code))).join(", ")
}
