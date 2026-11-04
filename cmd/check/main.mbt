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
  if args.length() < 5 || args.length() % 2 == 0 {
    println(
      "Usage: check OLD.graphql NEW.graphql CLIENT QUERY.graphql [CLIENT QUERY.graphql ...]",
    )
    return 2
  }
  let baseline = read_source(args[1])
  let proposed = read_source(args[2])
  let groups : Map[String, Array[@impact.Source]] = Map([])
  for i = 3; i < args.length(); i = i + 2 {
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
  if report.changes.is_empty() {
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
