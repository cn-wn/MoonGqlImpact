///|
priv struct InputObject {
  at : Location
  fields : Map[String, Argument]
}

///|
fn index_input_fields(
  source : Source,
  object : InputObject,
  fields : Array[@gql.InputValue],
) -> Unit raise AnalysisError {
  for field in fields {
    let at = source.at(field.position)
    if field.name.has_prefix("__") || object.fields.contains(field.name) {
      raise Invalid(at, "duplicate or reserved input field \{field.name}")
    }
    if !field.directives.is_empty() {
      raise Unsupported(
        at, "input field directives are outside the input profile",
      )
    }
    object.fields[field.name] = {
      kind: field.value_type,
      default_value: field.default_value,
      at,
    }
  }
}

///|
fn Schema::validate_input_objects(self : Schema) -> Unit raise AnalysisError {
  let pending = Map([])
  let dependents : Map[String, Array[String]] = Map([])
  let ready = []
  let no_variables = Map([])
  for name, object in self.input_objects {
    let mut required_edges = 0
    for field_name, field in object.fields {
      self.check_input_type(field.kind, field.at)
      if field.default_value is Some(value) &&
        !self.value_fits(field.kind, value, no_variables) {
        raise Invalid(
          field.at,
          "invalid default for input field \{name}.\{field_name}",
        )
      }
      if field.kind is NonNullType(NamedType(child)) &&
        self.input_objects.contains(child) {
        required_edges += 1
        match dependents.get(child) {
          Some(users) => users.push(name)
          None => dependents[child] = [name]
        }
      }
    }
    pending[name] = required_edges
    if required_edges == 0 {
      ready.push(name)
    }
  }
  while ready.pop() is Some(name) {
    if dependents.get(name) is Some(users) {
      for user in users {
        let count = pending[user] - 1
        pending[user] = count
        if count == 0 {
          ready.push(user)
        }
      }
    }
  }
  for name, count in pending {
    if count != 0 {
      raise Invalid(
        self.input_objects[name].at,
        "non-null singular input fields form a cycle involving \{name}",
      )
    }
  }
  let checked = Set([])
  let active = Set([])
  for name, object in self.input_objects {
    for field_name, field in object.fields {
      self.validate_field_default(
        "\{name}.\{field_name}",
        field,
        checked,
        active,
        0,
      )
    }
  }
}

///|
fn Schema::object_literal_fits(
  self : Schema,
  object : InputObject,
  entries : Array[(String, @gql.Value)],
  variables : Map[String, @gql.VariableDefinition],
) -> Bool {
  let seen = Set([])
  for (name, value) in entries {
    guard object.fields.get(name) is Some(field) &&
      seen.add_and_check(name) &&
      self.value_fits(
        field.kind,
        value,
        variables,
        location_default=field.default_value is Some(_),
      ) else {
      return false
    }
  }
  for name, field in object.fields {
    if field.required() && !seen.contains(name) {
      return false
    }
  }
  true
}

///|
fn sorted_input_entries(
  entries : Array[(String, @gql.Value)],
) -> Array[(String, @gql.Value)] {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => a.0.compare(b.0))
  sorted
}

///|
fn same_value(old : @gql.Value, next : @gql.Value) -> Bool {
  match (old, next) {
    (ObjectValue(a), ObjectValue(b)) => {
      if a.length() != b.length() {
        return false
      }
      let a = sorted_input_entries(a)
      let b = sorted_input_entries(b)
      for index in 0..<a.length() {
        if a[index].0 != b[index].0 || !same_value(a[index].1, b[index].1) {
          return false
        }
      }
      true
    }
    (ListValue(a), ListValue(b)) => {
      if a.length() != b.length() {
        return false
      }
      for index in 0..<a.length() {
        if !same_value(a[index], b[index]) {
          return false
        }
      }
      true
    }
    _ => old == next
  }
}

///|
fn input_field_code(code : ReasonCode) -> ReasonCode {
  match code {
    ArgumentRemoved => InputFieldRemoved
    RequiredArgumentAdded => RequiredInputFieldAdded
    ArgumentBecameRequired => InputFieldBecameRequired
    ArgumentTypeChanged => InputFieldTypeChanged
    ArgumentDefaultChanged => InputFieldDefaultChanged
    _ => code
  }
}

///|
fn input_object_diffs(
  old : Schema,
  next : Schema,
  ordered : Array[Change],
) -> Map[String, Array[ArgumentDiff]] {
  let result = Map([])
  for name, object in old.input_objects {
    guard next.input_objects.get(name) is Some(candidate) else { continue }
    let field_names = Set([])
    for field, _ in object.fields {
      field_names.add(field)
    }
    for field, _ in candidate.fields {
      field_names.add(field)
    }
    let diffs = []
    for field in field_names {
      let previous = object.fields.get(field)
      let proposed = candidate.fields.get(field)
      let reasons = argument_reasons(old, next, previous, proposed).map(
        input_field_code,
      )
      if !reasons.is_empty() {
        let change = {
          coordinate: "\{name}.\{field}",
          previous_type: previous
          .map(value => old.argument_text(value))
          .unwrap_or("<absent>"),
          proposed_type: proposed.map(value => next.argument_text(value)),
          baseline: previous.map(value => value.at).unwrap_or(object.at),
          proposed: proposed.map(value => value.at),
          impacts: [],
          reasons: Some(reasons.map(code => code.reason())),
        }
        ordered.push(change)
        diffs.push({ name: field, old: previous, proposed, change, reasons, })
      }
    }
    if !diffs.is_empty() {
      result[name] = diffs
    }
  }
  result
}

///|
priv struct InputSite {
  key : String
  path : Array[String]
  at : Location
}

///|
fn Walk::input_step(self : Walk, site : InputSite) -> Unit raise AnalysisError {
  self.budget -= 1
  if self.budget < 0 {
    raise Unsupported(
      site.at,
      "operation exceeds the selection analysis budget",
    )
  }
}

///|
fn add_input_runtime_reason(change : Change) -> Unit {
  let reasons = change.reasons.unwrap()
  if !reasons.any(reason => reason.code == InputVariableValueMayBreak) {
    reasons.push(InputVariableValueMayBreak.reason())
  }
}

///|
fn Walk::affected_input_field_reasons(
  self : Walk,
  diff : ArgumentDiff,
  value : @gql.Value?,
) -> Array[ReasonCode] {
  let codes = self.affected_argument_reasons(diff, value)
  guard value is Some(Variable(name)) &&
    diff.proposed is Some(field) &&
    self.proposed.value_fits(
      field.kind,
      Variable(name),
      self.variables,
      location_default=field.default_value is Some(_),
    ) else {
    return codes
  }
  let declaration = self.variables[name]
  if declaration.default_value is Some(default) &&
    !self.proposed.value_fits(declaration.var_type, default, Map([])) {
    return codes
  }
  if !codes.any(code => code.reason().severity == Breaking) {
    return codes
  }
  add_input_runtime_reason(diff.change)
  let risks = codes.filter(code => code.reason().severity != Breaking)
  risks.push(InputVariableValueMayBreak)
  risks
}

///|
fn Walk::observe_input_variable(
  self : Walk,
  kind : @gql.GqlType,
  site : InputSite,
) -> Unit raise AnalysisError {
  let visited = Set([])
  let pending = [named(kind)]
  while pending.pop() is Some(name) {
    guard visited.add_and_check(name) &&
      self.schema.input_objects.get(name) is Some(object) &&
      self.proposed.input_objects.get(name) is Some(candidate) else {
      continue
    }
    self.input_step(site)
    if self.changes.inputs.get(name) is Some(diffs) {
      for diff in diffs {
        let codes = []
        if diff.reasons.contains(InputFieldDefaultChanged) &&
          !(diff.old is Some(field) && field.required()) {
          codes.push(InputFieldDefaultChanged)
        }
        if diff.reasons.any(code => code.reason().severity == Breaking) {
          codes.push(InputVariableValueMayBreak)
          add_input_runtime_reason(diff.change)
        }
        if !codes.is_empty() {
          self.record_impact(diff.change, site.key, site.path, site.at, codes)
        }
      }
    }
    for field_name, field in object.fields {
      if candidate.fields.get(field_name) is Some(proposed) &&
        named(field.kind) == named(proposed.kind) {
        pending.push(named(field.kind))
      }
    }
  }
}

///|
fn Walk::observe_input(
  self : Walk,
  kind : @gql.GqlType,
  value : @gql.Value,
  site : InputSite,
  active_defaults? : Set[String],
  depth~ : Int32 = 0,
) -> Unit raise AnalysisError {
  if depth > 128 {
    raise Unsupported(site.at, "input value expansion exceeds depth 128")
  }
  let defaults = active_defaults.unwrap_or(Set([]))
  self.input_step(site)
  if value is Variable(name) {
    let variable = self.variables[name]
    if variable.default_value is Some(default) {
      self.observe_input(
        kind,
        default,
        site,
        active_defaults=defaults,
        depth=depth + 1,
      )
    }
    self.observe_input_variable(kind, site)
    return
  }
  if value is NullValue {
    return
  }
  match (nullable(kind), value) {
    (ListType(inner), ListValue(items)) =>
      for item in items {
        self.observe_input(
          inner,
          item,
          site,
          active_defaults=defaults,
          depth=depth + 1,
        )
      }
    (ListType(inner), _) =>
      self.observe_input(
        inner,
        value,
        site,
        active_defaults=defaults,
        depth=depth + 1,
      )
    (NamedType(name), ObjectValue(entries)) => {
      guard self.schema.input_objects.get(name) is Some(object) &&
        self.proposed.input_objects.get(name) is Some(candidate) else {
        return
      }
      let supplied = Map(entries)
      if self.changes.inputs.get(name) is Some(diffs) {
        for diff in diffs {
          let reasons = self.affected_input_field_reasons(
            diff,
            supplied.get(diff.name),
          )
          if !reasons.is_empty() {
            self.record_impact(
              diff.change,
              site.key,
              site.path,
              site.at,
              reasons,
            )
          }
        }
      }
      for field_name, field in object.fields {
        if candidate.fields.get(field_name) is Some(proposed) &&
          named(field.kind) == named(proposed.kind) {
          match supplied.get(field_name) {
            Some(item) =>
              self.observe_input(
                field.kind,
                item,
                site,
                active_defaults=defaults,
                depth=depth + 1,
              )
            None =>
              if field.default_value is Some(item) {
                let coordinate = "\{name}.\{field_name}"
                if !defaults.add_and_check(coordinate) {
                  raise Unsupported(
                    site.at,
                    "cyclic input default expansion through \{coordinate}",
                  )
                }
                self.observe_input(
                  field.kind,
                  item,
                  site,
                  active_defaults=defaults,
                  depth=depth + 1,
                )
                defaults.remove(coordinate)
              }
          }
        }
      }
    }
    _ => ()
  }
}

///|
fn Schema::validate_field_default(
  self : Schema,
  coordinate : String,
  field : Argument,
  checked : Set[String],
  active : Set[String],
  depth : Int32,
) -> Unit raise AnalysisError {
  guard field.default_value is Some(value) && !checked.contains(coordinate) else {
    return
  }
  if !active.add_and_check(coordinate) {
    raise Invalid(field.at, "cyclic input field default through \{coordinate}")
  }
  self.validate_default_expansion(
    field.kind,
    value,
    field.at,
    checked,
    active,
    depth,
  )
  active.remove(coordinate)
  checked.add(coordinate)
}

///|
fn Schema::validate_default_expansion(
  self : Schema,
  kind : @gql.GqlType,
  value : @gql.Value,
  at : Location,
  checked : Set[String],
  active : Set[String],
  depth : Int32,
) -> Unit raise AnalysisError {
  if depth > 128 {
    raise Unsupported(at, "input default expansion exceeds depth 128")
  }
  if value is NullValue {
    return
  }
  match (nullable(kind), value) {
    (ListType(inner), ListValue(items)) =>
      for item in items {
        self.validate_default_expansion(
          inner,
          item,
          at,
          checked,
          active,
          depth + 1,
        )
      }
    (ListType(inner), _) =>
      self.validate_default_expansion(
        inner,
        value,
        at,
        checked,
        active,
        depth + 1,
      )
    (NamedType(name), ObjectValue(entries)) => {
      let supplied = Map(entries)
      for field_name, field in self.input_objects[name].fields {
        match supplied.get(field_name) {
          Some(item) =>
            self.validate_default_expansion(
              field.kind,
              item,
              at,
              checked,
              active,
              depth + 1,
            )
          None =>
            self.validate_field_default(
              "\{name}.\{field_name}",
              field,
              checked,
              active,
              depth + 1,
            )
        }
      }
    }
    _ => ()
  }
}
