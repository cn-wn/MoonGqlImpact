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
fn run(args : Array[String]) -> Int32 raise {
  let observed_only = args.get(1) == Some("--observed-only")
  let first = if observed_only { 2 } else { 1 }
  let input_count = args.length() - first
  if input_count < 4 || input_count % 2 != 0 {
    println(
      "Usage: check [--observed-only] OLD.graphql NEW.graphql CLIENT QUERY.graphql [CLIENT QUERY.graphql ...]",
    )
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
