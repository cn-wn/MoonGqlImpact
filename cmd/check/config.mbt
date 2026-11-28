///|
priv struct CheckInput {
  baseline : @impact.Source
  proposed : @impact.Source
  clients : Array[@impact.Client]
  observed_only : Bool
  gate : Gate?
  samples : Array[@impact.VariableSample]
  scalar_inputs : Map[String, (Json) -> Bool]
  scalar_contracts : (Map[String, (Json) -> Bool], Map[String, (Json) -> Bool])?
}

///|
fn config_error(path : String, message : String) -> @impact.AnalysisError {
  @impact.Invalid({ path, line: 1, column: 1, }, message)
}

///|
fn config_object(
  value : Json,
  path : String,
  label : String,
  allowed : Array[String],
) -> Map[String, Json] raise @impact.AnalysisError {
  guard value is Object(fields) else {
    raise config_error(path, "\{label} must be an object")
  }
  for key, _ in fields {
    if !allowed.contains(key) {
      raise config_error(path, "\{label}: unknown key \{key}")
    }
  }
  fields
}

///|
fn config_paths(
  value : Json?,
  path : String,
  label : String,
) -> Array[String] raise @impact.AnalysisError {
  guard value is Some(Array(items)) && !items.is_empty() else {
    raise config_error(path, "\{label} must be a nonempty string array")
  }
  items.mapi((index, item) => {
    guard item is String(text) && !text.trim().is_empty() else {
      raise config_error(path, "\{label}[\{index}] must be a nonempty string")
    }
    text
  })
}

///|
fn config_path_parts(
  relative : String,
  path : String,
  glob~ : Bool = false,
) -> (Array[String], String) raise @impact.AnalysisError {
  let parts = relative.split("/").map(part => part.to_owned()).collect()
  let filename = parts.pop().unwrap_or("")
  let invalid_part = fn(part : String) {
    part.trim().is_empty() ||
    part == "." ||
    part == ".." ||
    part.contains("\\") ||
    part.contains(":") ||
    part.contains("\u0000") ||
    part.contains("?") ||
    part.contains("[") ||
    part.contains("]") ||
    part.contains("{") ||
    part.contains("}")
  }
  if invalid_part(filename) ||
    parts.any(part => invalid_part(part) || part.contains("*")) ||
    (filename.contains("*") && (!glob || filename.split("*").count() != 2)) {
    raise config_error(
      path,
      "invalid path \{relative}; use a relative path with / and at most one * in a query filename",
    )
  }
  (parts, filename)
}

///|
fn config_join(base : String, path : String) -> String {
  @path.Path(base).join(@path.Path(path)).to_string()
}

///|
fn config_file(
  root : String,
  relative : String,
  config : String,
) -> String raise {
  let full = config_join(root, relative)
  if !@fs.path_exists(full) || !@fs.is_file(full) {
    raise config_error(config, "expected a file at \{relative}")
  }
  full
}

///|
fn expand_query_path(
  root : String,
  relative : String,
  config : String,
) -> Array[String] raise {
  let (parts, filename) = config_path_parts(relative, config, glob=true)
  let pattern = filename.split("*").map(part => part.to_owned()).collect()
  guard pattern is [prefix, suffix] else {
    return [config_file(root, relative, config)]
  }
  let base = if parts.is_empty() {
    root
  } else {
    config_join(root, parts.join("/"))
  }
  if !@fs.path_exists(base) || !@fs.is_dir(base) {
    raise config_error(
      config,
      "query pattern \{relative}: directory does not exist",
    )
  }
  let matches = []
  for name in @fs.read_dir(base) {
    if name.length() >= prefix.length() + suffix.length() &&
      name.has_prefix(prefix) &&
      name.has_suffix(suffix) {
      let full = config_join(base, name)
      if @fs.is_file(full) {
        matches.push(full)
      }
    }
  }
  if matches.is_empty() {
    raise config_error(config, "query pattern \{relative} matched no files")
  }
  matches.sort_by((a, b) => a.compare(b))
  matches
}

///|
fn config_clients(
  value : Json?,
  path : String,
  root : String,
) -> Array[@impact.Client] raise {
  guard value is Some(Array(entries)) && !entries.is_empty() else {
    raise config_error(path, "clients must be a nonempty array")
  }
  let names = Set([])
  let clients = []
  for index, entry in entries {
    let label = "clients[\{index}]"
    let fields = config_object(entry, path, label, ["name", "queries"])
    guard fields.get("name") is Some(String(name)) && !name.trim().is_empty() else {
      raise config_error(path, "\{label}.name must be a nonempty string")
    }
    if !names.insert_and_check(name) {
      raise config_error(path, "duplicate client name \{name}")
    }
    let query_paths = config_paths(
      fields.get("queries"),
      path,
      label + ".queries",
    )
    let seen = Set([])
    let sources = []
    for relative in query_paths {
      for full in expand_query_path(root, relative, path) {
        let key = if @path.sep == '\\' { full.to_lower() } else { full }
        if !seen.insert_and_check(key) {
          raise config_error(
            path,
            "duplicate query path \{full} for client \{name}",
          )
        }
        sources.push(read_source(full))
      }
    }
    clients.push(@impact.Client::{ name, sources, })
  }
  clients
}

///|
fn read_config(file : @impact.Source) -> CheckInput raise {
  let path = file.path
  if file.text.length() > 1_000_000 {
    raise config_error(path, "config exceeds 1,000,000 string code units")
  }
  let json = @json.parse(file.text, reject_duplicate_keys=true) catch {
    error => raise config_error(path, "invalid JSON: \{error}")
  }
  let fields = config_object(json, path, "config", [
    "baseline", "proposed", "clients", "policy", "variable_samples", "scalar_inputs",
    "scalar_contracts",
  ])
  guard fields.get("baseline") is Some(String(baseline)) &&
    fields.get("proposed") is Some(String(proposed)) else {
    raise config_error(path, "baseline and proposed must be file paths")
  }
  let _ = config_path_parts(baseline, path)
  let _ = config_path_parts(proposed, path)
  let mut observed_only = false
  let mut gate = None
  if fields.get("policy") is Some(value) {
    let policy = config_object(value, path, "policy", [
      "observed_only", "fail_on",
    ])
    match policy.get("observed_only") {
      None => ()
      Some(True) => observed_only = true
      Some(False) => ()
      _ => raise config_error(path, "policy.observed_only must be a boolean")
    }
    if policy.contains("fail_on") {
      let parsed = Gate::new()
      let seen = Set([])
      for item in config_paths(policy.get("fail_on"), path, "policy.fail_on") {
        if !seen.insert_and_check(item) {
          raise config_error(path, "duplicate gate category \{item}")
        }
        if !parsed.add_category(item) {
          raise config_error(path, "unknown gate category \{item}")
        }
      }
      gate = Some(parsed)
    }
  }
  let root = @path.Path(path).dirname().to_string()
  if fields.contains("scalar_inputs") && fields.contains("scalar_contracts") {
    raise config_error(
      path, "scalar_inputs and scalar_contracts cannot be combined",
    )
  }
  {
    baseline: read_source(config_file(root, baseline, path)),
    proposed: read_source(config_file(root, proposed, path)),
    clients: config_clients(fields.get("clients"), path, root),
    observed_only,
    gate,
    samples: read_variable_samples(fields.get("variable_samples"), path, root),
    scalar_inputs: config_scalar_rules(fields.get("scalar_inputs"), path),
    scalar_contracts: config_scalar_contracts(
      fields.get("scalar_contracts"),
      path,
    ),
  }
}
