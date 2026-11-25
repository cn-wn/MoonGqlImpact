///|
priv struct Argument {
  kind : @gql.GqlType
  default_value : @gql.Value?
  at : Location
}

///|
fn Argument::required(self : Argument) -> Bool {
  self.kind is NonNullType(_) && self.default_value is None
}

///|
fn Schema::check_input_type(
  self : Schema,
  kind : @gql.GqlType,
  at : Location,
) -> Unit raise AnalysisError {
  let name = named(kind)
  if !builtin(name) && !self.enums.contains(name) {
    raise Unsupported(
      at,
      "unsupported input type: \{name}; use built-in scalars, enums or lists",
    )
  }
}

///|
fn nullable(kind : @gql.GqlType) -> @gql.GqlType {
  match kind {
    NonNullType(inner) => inner
    _ => kind
  }
}

///|
fn variable_fits(
  definition : @gql.VariableDefinition,
  location : @gql.GqlType,
  location_default : Bool,
) -> Bool {
  let has_nonnull_default = match definition.default_value {
    None | Some(NullValue) => false
    Some(_) => true
  }
  let expected = if definition.var_type is NonNullType(_) ||
    !(has_nonnull_default || location_default) {
    location
  } else {
    nullable(location)
  }
  preserves(expected, definition.var_type)
}

///|
fn Schema::value_fits(
  self : Schema,
  kind : @gql.GqlType,
  value : @gql.Value,
  variables : Map[String, @gql.VariableDefinition],
  location_default~ : Bool = false,
) -> Bool {
  if value is Variable(name) {
    return match variables.get(name) {
      Some(definition) => variable_fits(definition, kind, location_default)
      None => false
    }
  }
  if value is NullValue {
    return !(kind is NonNullType(_))
  }
  match nullable(kind) {
    ListType(inner) =>
      match value {
        ListValue(items) =>
          items.all(item => self.value_fits(inner, item, variables))
        _ => self.value_fits(inner, value, variables)
      }
    NamedType(name) =>
      match value {
        IntValue(number) =>
          name == "Float" ||
          name == "ID" ||
          (
            name == "Int" &&
            number.value >= -2147483648L &&
            number.value <= 2147483647L
          )
        FloatValue(number) => name == "Float" && number.is_finite()
        StringValue(_) => name == "String" || name == "ID"
        BooleanValue(_) => name == "Boolean"
        EnumValue(value) =>
          match self.enums.get(name) {
            Some(values) => values.contains(value)
            None => false
          }
        _ => false
      }
    NonNullType(_) => false
  }
}

///|
fn input_text(value : @gql.Value) -> String {
  match value {
    IntValue(number) => number.value.to_string()
    FloatValue(number) => number.to_string()
    StringValue(text) => Json::string(text).stringify()
    BooleanValue(flag) => flag.to_string()
    NullValue => "null"
    EnumValue(name) => name
    ListValue(values) => "[" + values.map(input_text).join(", ") + "]"
    // Only validated constant scalar, enum and list values reach this formatter.
    Variable(_) | ObjectValue(_) => abort("invalid argument default")
  }
}

///|
fn Schema::argument_text(self : Schema, argument : Argument) -> String {
  let kind = self.type_text(argument.kind)
  match argument.default_value {
    Some(value) => kind + " = " + input_text(value)
    None => kind
  }
}

///|
fn Schema::enum_narrowed(
  self : Schema,
  next : Schema,
  kind : @gql.GqlType,
) -> Bool {
  let name = named(kind)
  match (self.enums.get(name), next.enums.get(name)) {
    (Some(old), Some(new_values)) =>
      old.any(value => !new_values.contains(value))
    _ => false
  }
}

///|
fn coerce_literal(kind : @gql.GqlType, value : @gql.Value) -> @gql.Value {
  if value is (NullValue | Variable(_)) {
    return value
  }
  match (nullable(kind), value) {
    (ListType(inner), ListValue(items)) =>
      ListValue(items.map(item => coerce_literal(inner, item)))
    (ListType(inner), _) => ListValue([coerce_literal(inner, value)])
    (NamedType("ID"), IntValue(number)) => StringValue(number.value.to_string())
    (NamedType("Float"), IntValue(number)) =>
      FloatValue(number.value.to_double())
    _ => value
  }
}

///|
fn same_default(old : Argument, next : Argument) -> Bool {
  old.default_value.map(value => coerce_literal(old.kind, value)) ==
  next.default_value.map(value => coerce_literal(next.kind, value))
}

///|
/// A variable that still validates can nevertheless carry an explicit null
/// or an enum value that the proposed schema no longer accepts.
fn nullable_input_narrowed(
  old : @gql.GqlType,
  proposed : @gql.GqlType,
  variable : @gql.GqlType,
) -> Bool {
  if proposed is NonNullType(_) &&
    !(old is NonNullType(_)) &&
    !(variable is NonNullType(_)) {
    return true
  }
  match (nullable(old), nullable(proposed), nullable(variable)) {
    (ListType(a), ListType(b), ListType(v)) => nullable_input_narrowed(a, b, v)
    _ => false
  }
}

///|
fn Walk::check_argument_variables(
  self : Walk,
  at : Location,
  value : @gql.Value,
) -> Unit raise AnalysisError {
  match value {
    Variable(name) => {
      if !self.variables.contains(name) {
        raise Invalid(at, "undefined variable \{name}")
      }
      self.used_variables.add(name)
    }
    ListValue(items) =>
      for item in items {
        self.check_argument_variables(at, item)
      }
    ObjectValue(_) =>
      raise Unsupported(
        at, "input object literals are outside the argument profile",
      )
    _ => ()
  }
}

///|
fn Walk::argument_type_affects(
  self : Walk,
  old : Argument,
  proposed : Argument,
  value : @gql.Value?,
) -> Bool {
  guard value is Some(value) else { return proposed.required() }
  // When the named type stays the same, hold the enum domain constant to
  // evaluate the type change independently of removed input enum values.
  let schema = if named(old.kind) == named(proposed.kind) {
    self.schema
  } else {
    self.proposed
  }
  !schema.value_fits(
    proposed.kind,
    value,
    self.variables,
    location_default=old.default_value is Some(_),
  ) ||
  coerce_literal(old.kind, value) != coerce_literal(proposed.kind, value) ||
  self.variable_nullability_affects(old.kind, proposed.kind, value)
}

///|
fn Walk::variable_nullability_affects(
  self : Walk,
  old : @gql.GqlType,
  proposed : @gql.GqlType,
  value : @gql.Value,
) -> Bool {
  if value is Variable(name) {
    return nullable_input_narrowed(old, proposed, self.variables[name].var_type)
  }
  match (nullable(old), nullable(proposed), value) {
    (ListType(a), ListType(b), ListValue(items)) =>
      items.any(item => self.variable_nullability_affects(a, b, item))
    (ListType(a), ListType(b), _) =>
      self.variable_nullability_affects(a, b, value)
    _ => false
  }
}

///|
fn uses_removed_enum(value : @gql.Value, accepted : Array[String]) -> Bool {
  match value {
    Variable(_) => true
    EnumValue(name) => !accepted.contains(name)
    ListValue(items) => items.any(item => uses_removed_enum(item, accepted))
    _ => false
  }
}

///|
fn Walk::may_use_argument_default(self : Walk, value : @gql.Value?) -> Bool {
  match value {
    None => true
    Some(Variable(name)) => {
      let definition = self.variables[name]
      !(definition.var_type is NonNullType(_)) &&
      definition.default_value is None
    }
    Some(_) => false
  }
}

///|
fn Walk::affected_argument_reasons(
  self : Walk,
  diff : ArgumentDiff,
  value : @gql.Value?,
) -> Array[ReasonCode] {
  diff.reasons.filter(code => {
    match (code, diff.old, diff.proposed) {
      (ArgumentRemoved, _, _) => value is Some(_)
      (RequiredArgumentAdded, _, _) => true
      (ArgumentDefaultChanged, _, _) => self.may_use_argument_default(value)
      (ArgumentBecameRequired, _, Some(next)) =>
        match value {
          None => true
          Some(Variable(name)) =>
            !variable_fits(self.variables[name], next.kind, false)
          Some(_) => false
        }
      (InputEnumValueRemoved, _, Some(next)) =>
        value is Some(input) &&
        uses_removed_enum(input, self.proposed.enums[named(next.kind)])
      (ArgumentTypeChanged, Some(old), Some(next)) =>
        self.argument_type_affects(old, next, value)
      _ => false
    }
  })
}

///|
priv struct ArgumentDiff {
  name : String
  old : Argument?
  proposed : Argument?
  change : Change
  reasons : Array[ReasonCode]
}

///|
fn argument_reasons(
  old : Schema,
  next : Schema,
  previous : Argument?,
  proposed : Argument?,
) -> Array[ReasonCode] {
  let reasons = []
  match (previous, proposed) {
    (Some(a), Some(b)) => {
      if !preserves(b.kind, a.kind) {
        reasons.push(ArgumentTypeChanged)
      }
      if named(a.kind) == named(b.kind) && old.enum_narrowed(next, a.kind) {
        reasons.push(InputEnumValueRemoved)
      }
      if !same_default(a, b) {
        if a.default_value is Some(_) && b.required() {
          reasons.push(ArgumentBecameRequired)
        }
        reasons.push(ArgumentDefaultChanged)
      }
    }
    (Some(a), None) => {
      reasons.push(ArgumentRemoved)
      if a.default_value is Some(_) {
        reasons.push(ArgumentDefaultChanged)
      }
    }
    (None, Some(b)) => if b.required() { reasons.push(RequiredArgumentAdded) }
    (None, None) => ()
  }
  reasons
}

///|
fn argument_diffs(
  old : Schema,
  next : Schema,
  coordinate : String,
  field : IndexedField,
  candidate : IndexedField,
) -> Array[ArgumentDiff] {
  let diffs = []
  let names = Set([])
  for name, _ in field.arguments {
    names.add(name)
  }
  for name, _ in candidate.arguments {
    names.add(name)
  }
  for name in names {
    let previous = field.arguments.get(name)
    let proposed = candidate.arguments.get(name)
    let reasons = argument_reasons(old, next, previous, proposed)
    if !reasons.is_empty() {
      let change = {
        coordinate: "\{coordinate}(\{name}:)",
        previous_type: previous
        .map(a => old.argument_text(a))
        .unwrap_or("<absent>"),
        proposed_type: proposed.map(b => next.argument_text(b)),
        baseline: previous.map(a => a.at).unwrap_or(field.at),
        proposed: proposed.map(b => b.at),
        impacts: [],
        reasons: Some(reasons.map(code => code.reason())),
      }
      diffs.push({ name, old: previous, proposed, change, reasons, })
    }
  }
  diffs
}

///|
fn same_arguments(
  left : Map[String, @gql.Value],
  right : Map[String, @gql.Value],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for name, value in left {
    if right.get(name) != Some(value) {
      return false
    }
  }
  true
}

///|
fn Walk::validate_arguments(
  self : Walk,
  field : IndexedField,
  values : Map[String, @gql.Value],
  at : Location,
) -> Unit raise AnalysisError {
  for name, value in values {
    guard field.arguments.get(name) is Some(argument) else {
      raise Invalid(at, "unknown baseline argument \{name}")
    }
    self.check_argument_variables(at, value)
    if !self.schema.value_fits(
        argument.kind,
        value,
        self.variables,
        location_default=argument.default_value is Some(_),
      ) {
      raise Invalid(
        at,
        "value or variable type does not satisfy baseline argument \{name}",
      )
    }
  }
  for name, argument in field.arguments {
    if argument.required() && !values.contains(name) {
      raise Invalid(at, "missing required baseline argument \{name}")
    }
  }
}

///|
fn Walk::record_impact(
  self : Walk,
  change : Change,
  key : String,
  path : Array[String],
  at : Location,
  reasons : Array[ReasonCode],
) -> Unit {
  if self.reported.add_and_check(
      (change.coordinate, key, at.path, at.line, at.column),
    ) {
    change.impacts.push({
      client: self.client,
      operation: self.operation,
      response_path: path,
      selection: at,
      reason_codes: Some(reasons),
    })
  }
}
