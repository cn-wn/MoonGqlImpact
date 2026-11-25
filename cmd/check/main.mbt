///|
fn read_source(path : String) -> @impact.Source raise {
  let bytes = @fs.read_file_to_bytes(path)
  let text = @utf8.decode(bytes) catch {
    _ =>
      raise @impact.Invalid(
        { path, line: 1, column: 1, },
        "file must contain valid UTF-8",
      )
  }
  { path, text, }
}

///|
fn usage() -> Unit {
  println("Usage: check [--markdown] --config FILE.json")
  println(
    "Usage: check [--markdown] [--fail-on=LEVEL_OR_REASON,...] --schema-only OLD.graphql NEW.graphql",
  )
  println(
    "Usage: check [--markdown] [--fail-on=LEVEL_OR_REASON,...] [--observed-only] OLD.graphql NEW.graphql CLIENT QUERY.graphql [CLIENT QUERY.graphql ...]",
  )
  println(
    "Gate levels are breaking, risk, and notice. You can also select report reason codes.",
  )
  println(
    "Exit status: 0 passes the selected policy, 1 blocks the upgrade, 2 indicates an input error.",
  )
}

///|
fn run(args : Array[String]) -> Int32 raise {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    usage()
    return 0
  }
  let mut markdown = false
  let mut observed_only = false
  let mut schema_only = false
  let mut filtered = false
  let gate = Gate::new()
  let mut config_path = None
  let mut first = 1
  while args.get(first) is Some(option) && option.has_prefix("--") {
    first += 1
    match option {
      "--" => break
      "--markdown" if !markdown => markdown = true
      "--observed-only" if !observed_only && !schema_only =>
        observed_only = true
      "--schema-only" if !observed_only && !schema_only => schema_only = true
      "--config" if config_path is None => {
        guard args.get(first) is Some(path) && !path.has_prefix("--") else {
          println("--config requires a JSON file path")
          return 2
        }
        config_path = Some(path)
        first += 1
      }
      _ if option.has_prefix("--fail-on=") && !filtered => {
        filtered = true
        for item in option[10:].split(",") {
          if !gate.add_category(item.to_owned()) {
            println("Unknown gate category \{item}")
            return 2
          }
        }
      }
      _ => {
        println("Unknown, repeated, or conflicting option \{option}")
        return 2
      }
    }
  }
  let input_count = args.length() - first
  if config_path is Some(path) {
    if observed_only || schema_only || filtered || input_count != 0 {
      println(
        "--config cannot be combined with positional inputs or gate options",
      )
      return 2
    }
    return execute(read_config(read_source(path)), markdown)
  }
  let valid = if schema_only {
    input_count == 2
  } else {
    input_count >= 4 && input_count % 2 == 0
  }
  if !valid {
    usage()
    return 2
  }
  let baseline = read_source(args[first])
  let proposed = read_source(args[first + 1])
  let groups : Map[String, Array[@impact.Source]] = Map([])
  for i = first + 2; i < args.length(); i = i + 2 {
    let file = read_source(args[i + 1])
    match groups.get(args[i]) {
      Some(files) => files.push(file)
      None => groups[args[i]] = [file]
    }
  }
  let clients = []
  for name, sources in groups {
    clients.push(@impact.Client::{ name, sources, })
  }
  execute(
    {
      baseline,
      proposed,
      clients,
      observed_only,
      samples: [],
      scalar_inputs: Map([]),
      gate: if filtered {
        Some(gate)
      } else {
        None
      },
    },
    markdown,
  )
}

///|
priv struct Gate {
  severities : Array[@impact.Severity]
  reason_codes : Array[@impact.ReasonCode]
}

///|
fn Gate::new() -> Gate {
  { severities: [], reason_codes: [], }
}

///|
fn Gate::add_category(self : Gate, item : String) -> Bool {
  match item {
    "breaking" => self.severities.push(Breaking)
    "risk" => self.severities.push(Risk)
    "notice" => self.severities.push(Notice)
    _ => {
      let code : @impact.ReasonCode = @json.from_json(Json::string(item)) catch {
        _ => return false
      }
      self.reason_codes.push(code)
    }
  }
  true
}

///|
fn execute(
  input : CheckInput,
  markdown : Bool,
) -> Int32 raise @impact.AnalysisError {
  let {
    baseline,
    proposed,
    clients,
    observed_only,
    gate,
    samples,
    scalar_inputs,
  } = input
  let analysis = @impact.analyze_upgrade_with_samples(
    baseline,
    proposed,
    clients,
    samples,
    scalar_inputs~,
  )
  if markdown {
    println(analysis.to_markdown())
  } else {
    println(analysis.to_json().stringify())
  }
  let blocks = match gate {
    Some(gate) =>
      analysis.blocks(
        observed_only~,
        severities=gate.severities,
        reason_codes=gate.reason_codes,
      )
    None => analysis.blocks(observed_only~)
  }
  if blocks {
    1
  } else {
    0
  }
}

///|
fn main {
  let code = run(@env.args()) catch {
    @impact.Invalid(at, message) | @impact.Unsupported(at, message) => {
      println("\{at.path}:\{at.line}:\{at.column}: \{message}")
      2
    }
    error => {
      println("Cannot read input: \{error}")
      2
    }
  }
  @sys.exit(code)
}
