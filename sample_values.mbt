///|
/// A caller-supplied, preferably synthetic or scrubbed JSON variables object.
pub(all) struct VariableSample {
  client : String
  operation : String
  id : String
  variables : Json
}

///|
/// Evidence from coercing a sample. Reports never contain its raw values.
#derive(Eq, Debug, ToJson, FromJson)
pub struct SampleAssessment {
  client : String
  operation : String
  id : String
  status : SampleStatus
  path : String?
  diagnostic : String?
  reason : ChangeReason?
  argument_coordinate : String?
  response_path : Array[String]?
  selection : Location?
}

///|
#derive(Eq, Debug, ToJson(style="flat"), FromJson(style="flat"))
pub(all) enum SampleStatus {
  Unchanged
  CoercionChanged
  VariableRejected
  OperationRejected
}

///|
priv suberror SampleInputError {
  ValueRejected(String, String)
  ValueLimit(String)
}

///|
priv struct Coercion {
  schema : Schema
  mut budget : Int32
}

///|
fn literal_json(value : @gql.Value) -> Json {
  match value {
    IntValue(number) =>
      Json::number(number.value.to_double(), repr=number.value.to_string())
    FloatValue(number) => Json::number(number)
    StringValue(text) | EnumValue(text) => Json::string(text)
    BooleanValue(flag) => ToJson::to_json(flag)
    NullValue => Json::null()
    ListValue(items) => Json::array(items.map(literal_json))
    ObjectValue(entries) =>
      Json::object(Map(entries.map(entry => (entry.0, literal_json(entry.1)))))
    Variable(_) => abort("constant input value required")
  }
}

///|
fn Coercion::default_value(
  self : Coercion,
  kind : @gql.GqlType,
  value : @gql.Value,
  path : String,
  depth : Int32,
) -> Json raise SampleInputError {
  self.value(
    kind,
    literal_json(self.schema.coerce_literal(kind, value)),
    path,
    depth,
  )
}

///|
fn check_one_of_values(
  object : InputObject,
  values : Map[String, Json],
  path : String,
) -> Unit raise SampleInputError {
  if !object.one_of {
    return
  }
  if values.length() != 1 {
    raise ValueRejected(path, "@oneOf requires exactly one input field")
  }
  for name, value in values {
    if value is Null {
      raise ValueRejected(
        path + "/" + name,
        "@oneOf requires a non-null input field",
      )
    }
  }
}

///|
fn Coercion::object(
  self : Coercion,
  object : InputObject,
  value : Json,
  path : String,
  depth : Int32,
) -> Json raise SampleInputError {
  guard value is Object(provided) else {
    raise ValueRejected(path, "expected an input object")
  }
  for name, _ in provided {
    if !object.fields.contains(name) {
      raise ValueRejected(path, "unknown input field")
    }
  }
  check_one_of_values(object, provided, path)
  let result = Map([])
  for name, field in object.fields {
    let nested = path + "/" + name
    match (provided.get(name), field.default_value) {
      (Some(value), _) =>
        result[name] = self.value(field.kind, value, nested, depth + 1)
      (None, Some(value)) =>
        result[name] = self.default_value(field.kind, value, nested, depth + 1)
      (None, None) =>
        if field.required() {
          raise ValueRejected(nested, "missing required input field")
        }
    }
  }
  Json::object(result)
}

///|
fn Coercion::step(
  self : Coercion,
  path : String,
  depth : Int32,
) -> Unit raise SampleInputError {
  self.budget -= 1
  if depth > 128 || self.budget < 0 {
    raise ValueLimit(path)
  }
}

///|
fn Coercion::value(
  self : Coercion,
  kind : @gql.GqlType,
  value : Json,
  path : String,
  depth : Int32,
) -> Json raise SampleInputError {
  self.step(path, depth)
  if value is Null {
    if kind is NonNullType(_) {
      raise ValueRejected(path, "null is not allowed")
    }
    return value
  }
  match nullable(kind) {
    ListType(inner) => {
      let items = match value {
        Array(items) => items
        _ => [value]
      }
      Json::array(
        items.mapi((i, item) => {
          self.value(inner, item, "\{path}/\{i}", depth + 1)
        }),
      )
    }
    NamedType(name) => {
      if self.schema.input_objects.get(name) is Some(object) {
        return self.object(object, value, path, depth)
      }
      if self.schema.enums.get(name) is Some(values) {
        if value is String(text) && values.contains(text) {
          return value
        }
        raise ValueRejected(path, "expected a value of enum \{name}")
      }
      if self.schema.scalar_inputs.get(name) is Some(accepts) {
        if accepts(value) {
          return value
        }
        raise ValueRejected(path, "value rejected by rule for \{name}")
      }
      match (name, value) {
        ("String" | "ID", String(_)) | ("Boolean", True | False) => value
        ("Int", Number(n, ..)) if n >= -2147483648.0 &&
          n <= 2147483647.0 &&
          n == n.floor() => Json::number(n)
        ("Float", Number(n, ..)) if n.is_finite() => Json::number(n)
        ("ID", Number(n, ..)) if n >= -9007199254740991.0 &&
          n <= 9007199254740991.0 &&
          n == n.floor() => Json::string(n.to_int64().to_string())
        _ => raise ValueRejected(path, "expected a valid \{name} value")
      }
    }
    NonNullType(_) => abort("nested non-null input type")
  }
}

///|
fn coerce_variables(
  schema : Schema,
  definitions : Map[String, @gql.VariableDefinition],
  variables : Json,
) -> Map[String, Json] raise SampleInputError {
  guard variables is Object(values) else {
    raise ValueRejected("", "expected a JSON variables object")
  }
  for name, _ in values {
    if !definitions.contains(name) {
      raise ValueRejected("", "sample has an undeclared variable")
    }
  }
  let state : Coercion = { schema, budget: 100000, }
  let output = Map([])
  for name, definition in definitions {
    let path = "/" + name
    match (values.get(name), definition.default_value) {
      (Some(value), _) =>
        output[name] = state.value(definition.var_type, value, path, 0)
      (None, Some(default)) =>
        output[name] = state.default_value(
          definition.var_type,
          default,
          path,
          0,
        )
      (None, None) =>
        if definition.var_type is NonNullType(_) {
          raise ValueRejected(path, "missing required variable")
        }
    }
  }
  output
}

///|
fn first_coercion_difference(
  left : Json,
  right : Json,
  path : String,
) -> String? {
  match (left, right) {
    (Object(a), Object(b)) => {
      for name, value in a {
        let child = path + "/" + name
        guard b.get(name) is Some(after) else { return Some(child) }
        if first_coercion_difference(value, after, child) is Some(changed) {
          return Some(changed)
        }
      }
      for name, _ in b {
        if !a.contains(name) {
          return Some(path + "/" + name)
        }
      }
      None
    }
    (Array(a), Array(b)) => {
      if a.length() != b.length() {
        return Some(path)
      }
      for index, value in a {
        if first_coercion_difference(value, b[index], "\{path}/\{index}")
          is Some(changed) {
          return Some(changed)
        }
      }
      None
    }
    (Number(a, ..), Number(b, ..)) if a == b => None
    _ => if left == right { None } else { Some(path) }
  }
}

///|
fn VariableSample::assessment(
  self : VariableSample,
  status : SampleStatus,
  path? : String,
  diagnostic? : String,
  reason? : ReasonCode,
  site? : SampleArgumentSite,
) -> SampleAssessment {
  {
    client: self.client,
    operation: self.operation,
    id: self.id,
    status,
    path,
    diagnostic,
    reason: reason.map(code => code.reason()),
    argument_coordinate: if site is Some(selected) &&
      path is Some(path) &&
      path.has_prefix("/") &&
      !path.has_prefix("/@") &&
      path[1:].split("/").next() is Some(name) {
      Some("\{selected.coordinate}(\{name}:)")
    } else {
      None
    },
    response_path: site.map(selected => selected.response_path),
    selection: site.map(selected => selected.location),
  }
}

///|
fn assess_sample(
  sample : VariableSample,
  baseline : Walk,
  proposed : Walk?,
  at : Location,
) -> SampleAssessment raise AnalysisError {
  let before = coerce_variables(
    baseline.schema,
    baseline.variables,
    sample.variables,
  ) catch {
    ValueRejected(path, message) =>
      raise Invalid(
        at,
        "sample \{sample.id} failed baseline coercion at \{path}: \{message}",
      )
    ValueLimit(path) =>
      raise Unsupported(
        at,
        "sample \{sample.id} exceeds coercion limits at \{path}",
      )
  }
  let baseline_arguments = baseline.sample_arguments(before) catch {
    ArgumentRejected(site, path, message) =>
      raise Invalid(
        site.location,
        "sample \{sample.id} failed baseline field input at \{path}: \{message}",
      )
    ArgumentLimit(site, path) =>
      raise Unsupported(
        site.location,
        "sample \{sample.id} exceeds field input coercion limits at \{path}",
      )
  }
  guard proposed is Some(proposed) else {
    return sample.assessment(OperationRejected)
  }
  let after = coerce_variables(
    proposed.schema,
    proposed.variables,
    sample.variables,
  ) catch {
    ValueRejected(path, message) =>
      return sample.assessment(
        VariableRejected,
        path~,
        diagnostic=message,
        reason=VariableSampleRejected,
      )
    ValueLimit(path) =>
      raise Unsupported(
        at,
        "sample \{sample.id} exceeds coercion limits at \{path}",
      )
  }
  let proposed_arguments = proposed.sample_arguments(after) catch {
    ArgumentRejected(site, path, message) =>
      return sample.assessment(
        VariableRejected,
        path~,
        diagnostic=message,
        reason=VariableSampleRejected,
        site~,
      )
    ArgumentLimit(site, path) =>
      raise Unsupported(
        site.location,
        "sample \{sample.id} exceeds field input coercion limits at \{path}",
      )
  }
  if first_coercion_difference(Json::object(before), Json::object(after), "")
    is Some(path) {
    return sample.assessment(
      CoercionChanged,
      path~,
      reason=VariableSampleCoercionChanged,
    )
  }
  // Both walks traverse the same validated selections in document order.
  let sites = proposed.sample_sites.unwrap_or([])
  for index, old_arguments in baseline_arguments {
    if old_arguments is Some(old) &&
      proposed_arguments[index] is Some(next) &&
      first_coercion_difference(old, next, "") is Some(path) {
      return sample.assessment(
        CoercionChanged,
        path~,
        reason=VariableSampleCoercionChanged,
        site=sites[index],
      )
    }
  }
  sample.assessment(Unchanged)
}
