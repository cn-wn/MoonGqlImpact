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
  println("Usage: check --schema-only OLD.graphql NEW.graphql")
  println(
    "Usage: check [--observed-only] OLD.graphql NEW.graphql CLIENT QUERY.graphql [CLIENT QUERY.graphql ...]",
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
  let observed_only = args.get(1) == Some("--observed-only")
  let schema_only = args.get(1) == Some("--schema-only")
  let first = if observed_only || schema_only { 2 } else { 1 }
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
  println(report.to_json().stringify())
  let blocks = if observed_only {
    report.changes.any(fn(change) { !change.impacts.is_empty() })
  } else {
    !report.changes.is_empty()
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
