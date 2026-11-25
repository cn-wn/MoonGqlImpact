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
  let severities : Array[@impact.Severity] = []
  let reason_codes : Array[@impact.ReasonCode] = []
  let mut first = 1
  while args.get(first) is Some(option) && option.has_prefix("--") {
    first += 1
    match option {
      "--" => break
      "--markdown" if !markdown => markdown = true
      "--observed-only" if !observed_only && !schema_only =>
        observed_only = true
      "--schema-only" if !observed_only && !schema_only => schema_only = true
      _ if option.has_prefix("--fail-on=") && !filtered => {
        filtered = true
        for item in option[10:].split(",") {
          match item {
            "breaking" => severities.push(Breaking)
            "risk" => severities.push(Risk)
            "notice" => severities.push(Notice)
            _ => {
              let code : @impact.ReasonCode = @json.from_json(
                Json::string(item.to_owned()),
              ) catch {
                _ => {
                  println("Unknown gate category \{item}")
                  return 2
                }
              }
              reason_codes.push(code)
            }
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
  let report = @impact.analyze_upgrade(baseline, proposed, clients)
  if markdown {
    println(report.to_markdown())
  } else {
    println(report.to_json().stringify())
  }
  let blocks = if filtered {
    report.blocks(observed_only~, severities~, reason_codes~)
  } else {
    report.blocks(observed_only~)
  }
  if !blocks {
    0
  } else {
    1
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
