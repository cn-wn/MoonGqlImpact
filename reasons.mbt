///|
/// The policy category of a change, independent of catalog coverage.
#derive(Eq, Debug, ToJson(style="flat"), FromJson(style="flat"))
pub(all) enum Severity {
  Breaking
  Risk
  Notice
}

///|
pub extend Severity with Eq::{equal, not_equal}

///|
pub extend Severity with @debug.Debug::{to_repr}

///|
/// Stable identifiers for the rules that detected a change.
#derive(Eq, Debug, ToJson(style="flat"), FromJson(style="flat"))
pub(all) enum ReasonCode {
  FieldRemoved
  OutputTypeChanged
  OutputNullabilityWeakened
  OutputEnumValueAdded
  OutputEnumValueRemoved
  AbstractTypeRemoved
  AbstractMemberAdded
  AbstractMemberRemoved
  FragmentNoLongerPossible
  ScalarSpecificationChanged
  ArgumentRemoved
  RequiredArgumentAdded
  ArgumentBecameRequired
  ArgumentTypeChanged
  InputEnumValueRemoved
  ArgumentDefaultChanged
  InputFieldRemoved
  RequiredInputFieldAdded
  InputFieldBecameRequired
  InputFieldTypeChanged
  InputFieldDefaultChanged
  InputVariableValueMayBreak
  ProposedOperationRejected
}

///|
pub extend ReasonCode with Eq::{equal, not_equal}

///|
pub extend ReasonCode with @debug.Debug::{to_repr}

///|
#derive(Eq, Debug, ToJson, FromJson)
pub struct ChangeReason {
  code : ReasonCode
  severity : Severity
}

///|
pub extend ChangeReason with Eq::{equal, not_equal}

///|
pub extend ChangeReason with @debug.Debug::{to_repr}

///|
fn ReasonCode::reason(self : ReasonCode) -> ChangeReason {
  let severity = match self {
    FieldRemoved
    | OutputTypeChanged
    | OutputNullabilityWeakened
    | ArgumentRemoved
    | RequiredArgumentAdded
    | ArgumentBecameRequired
    | ArgumentTypeChanged
    | InputEnumValueRemoved
    | AbstractTypeRemoved
    | AbstractMemberRemoved
    | FragmentNoLongerPossible
    | InputFieldRemoved
    | RequiredInputFieldAdded
    | InputFieldBecameRequired
    | InputFieldTypeChanged
    | ProposedOperationRejected => Breaking
    OutputEnumValueAdded
    | OutputEnumValueRemoved
    | ArgumentDefaultChanged
    | AbstractMemberAdded
    | InputFieldDefaultChanged
    | InputVariableValueMayBreak => Risk
    ScalarSpecificationChanged => Notice
  }
  { code: self, severity, }
}

///|
/// Decide whether to block using the full report or observed operations.
/// Missing reason metadata from older JSON reports is treated conservatively.
pub fn Report::blocks(
  self : Report,
  observed_only~ : Bool = false,
  severities? : Array[Severity],
  reason_codes? : Array[ReasonCode],
) -> Bool {
  for change in self.changes {
    if observed_only && change.impacts.is_empty() {
      continue
    }
    if severities is None && reason_codes is None {
      return true
    }
    let levels = severities.unwrap_or([])
    let codes = reason_codes.unwrap_or([])
    guard change.reasons is Some(reasons) else { return true }
    for reason in reasons {
      if !levels.contains(reason.severity) && !codes.contains(reason.code) {
        continue
      }
      if !observed_only ||
        change.impacts.any(impact => {
          match impact.reason_codes {
            Some(codes) => codes.contains(reason.code)
            None => true
          }
        }) {
        return true
      }
    }
  }
  false
}

///|
fn same_output_shape(a : @gql.GqlType, b : @gql.GqlType) -> Bool {
  match (nullable(a), nullable(b)) {
    (NamedType(a), NamedType(b)) => a == b
    (ListType(a), ListType(b)) => same_output_shape(a, b)
    _ => false
  }
}

///|
fn output_reasons(
  old : Schema,
  next : Schema,
  field : IndexedField,
  candidate : IndexedField?,
) -> Array[ReasonCode] {
  guard candidate is Some(proposed) else { return [FieldRemoved] }
  let reasons = []
  let name = named(field.kind)
  if !same_output_shape(field.kind, proposed.kind) ||
    old.is_object(name) != next.is_object(name) ||
    old.interfaces.contains(name) != next.interfaces.contains(name) ||
    old.unions.contains(name) != next.unions.contains(name) ||
    old.enums.contains(name) != next.enums.contains(name) {
    reasons.push(OutputTypeChanged)
  } else if !preserves(field.kind, proposed.kind) {
    reasons.push(OutputNullabilityWeakened)
  }
  if name == named(proposed.kind) {
    if old.enum_narrowed(next, field.kind) {
      reasons.push(OutputEnumValueRemoved)
    }
    if next.enum_narrowed(old, proposed.kind) {
      reasons.push(OutputEnumValueAdded)
    }
    if old.scalars.get(name) != next.scalars.get(name) &&
      old.scalars.contains(name) &&
      next.scalars.contains(name) {
      reasons.push(ScalarSpecificationChanged)
    }
  }
  reasons
}

///|
/// Apply the gate to schema changes and baseline-valid operations that now fail validation.
pub fn AnalyzedUpgrade::blocks(
  self : AnalyzedUpgrade,
  observed_only~ : Bool = false,
  severities? : Array[Severity],
  reason_codes? : Array[ReasonCode],
) -> Bool {
  self.report.blocks(observed_only~, severities?, reason_codes?) ||
  (
    self.proposed_rejections is Some([_, ..]) &&
    (
      (severities is None && reason_codes is None) ||
      severities.unwrap_or([]).contains(Breaking) ||
      reason_codes.unwrap_or([]).contains(ProposedOperationRejected)
    )
  )
}
