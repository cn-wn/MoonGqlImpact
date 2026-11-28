///|
fn decimal_string(value : Json, fixed_two~ : Bool = false) -> Bool {
  guard value is String(text) else { return false }
  let unsigned = if text.has_prefix("-") { text[1:] } else { text[:] }
  let parts = unsigned.split(".").collect()
  (if fixed_two {
    parts is [_, fraction] && fraction.length() == 2
  } else {
    parts.length() == 1 || parts.length() == 2
  }) &&
  parts.all(part => {
    !part.is_empty() && part.iter().all(ch => ch >= '0' && ch <= '9')
  })
}

///|
fn config_scalar_rules(
  value : Json?,
  path : String,
) -> Map[String, (Json) -> Bool] raise @impact.AnalysisError {
  guard value is Some(value) else { return Map([]) }
  guard value is Object(entries) else {
    raise config_error(path, "scalar_inputs must be an object")
  }
  let rules : Map[String, (Json) -> Bool] = Map([])
  for name, kind in entries {
    rules[name] = match kind {
      String("string") => value => value is String(_)
      String("boolean") => value => value is (True | False)
      String("number") => value => value is Number(n, ..) && n.is_finite()
      String("decimal-string") => value => decimal_string(value)
      String("decimal-fixed-2") =>
        value => decimal_string(value, fixed_two=true)
      _ => raise config_error(path, "unknown scalar input profile for \{name}")
    }
  }
  rules
}

///|
fn config_scalar_contracts(
  value : Json?,
  path : String,
) -> (Map[String, (Json) -> Bool], Map[String, (Json) -> Bool])? raise @impact.AnalysisError {
  guard value is Some(value) else { return None }
  let fields = config_object(value, path, "scalar_contracts", [
    "baseline", "proposed",
  ])
  guard fields.get("baseline") is Some(baseline) &&
    fields.get("proposed") is Some(proposed) else {
    raise config_error(
      path, "scalar_contracts requires baseline and proposed rule maps",
    )
  }
  Some(
    (
      config_scalar_rules(Some(baseline), path),
      config_scalar_rules(Some(proposed), path),
    ),
  )
}

///|
fn read_variable_samples(
  value : Json?,
  config : String,
  root : String,
) -> Array[@impact.VariableSample] raise {
  guard value is Some(value) else { return [] }
  guard value is String(relative) else {
    raise config_error(config, "variable_samples must name a JSON file")
  }
  let _ = config_path_parts(relative, config)
  let path = config_file(root, relative, config)
  let file = read_source(path)
  if file.text.length() > 1_000_000 {
    raise config_error(
      path, "variable sample file exceeds 1,000,000 string code units",
    )
  }
  let json = @json.parse(file.text, reject_duplicate_keys=true) catch {
    _ => raise config_error(path, "invalid variable sample JSON")
  }
  guard json is Array(items) else {
    raise config_error(path, "expected a JSON array of variable samples")
  }
  items.mapi((index, row) => {
    let label = "samples[\{index}]"
    let fields = config_object(row, path, label, [
      "client", "operation", "id", "variables",
    ])
    guard fields.get("client") is Some(String(client)) &&
      fields.get("operation") is Some(String(operation)) &&
      fields.get("id") is Some(String(id)) &&
      fields.get("variables") is Some(Object(_) as variables) else {
      raise config_error(
        path,
        "\{label} requires client, operation, id, and a variables object",
      )
    }
    @impact.VariableSample::{ client, operation, id, variables, }
  })
}
