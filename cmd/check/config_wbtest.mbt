///|
test "config resolves the Apollo catalog and policy relative to the config file" {
  let source = read_source("examples/apollo/check.json")
  let input = read_config(source)
  assert_eq(@path.Path(input.baseline.path).basename(), "old.graphql")
  assert_eq(@path.Path(input.proposed.path).basename(), "new.graphql")
  assert_eq(input.clients.map(client => client.name), [
    "flight-board", "crew-roster",
  ])
  assert_eq(
    input.clients[0].sources.map(file => {
      @path.Path(file.path).basename().to_owned()
    }),
    ["flight-board.graphql", "launch-date.graphql"],
  )
  assert_true(input.observed_only)
  assert_true(input.gate is Some({ severities: [Breaking], reason_codes: [], }))
}

///|
test "config file patterns expand in a deterministic order" {
  let found = expand_query_path("examples/apollo", "*.graphql", "check.json")
  let names = found.map(path => @path.Path(path).basename().to_owned())
  let sorted = names.copy()
  sorted.sort_by((a, b) => a.compare(b))
  assert_eq(names, sorted)
  assert_true(names.contains("old.graphql") && names.contains("new.graphql"))
}

///|
fn check_config_error(body : String, expected : String) -> Unit raise {
  let path = "examples/apollo/check.json"
  let text = "{\"baseline\":\"old.graphql\",\"proposed\":\"new.graphql\"," +
    body +
    "}"
  let result = Ok(read_config({ path, text, })) catch { error => Err(error) }
  guard result is Err(@impact.Invalid(at, message)) else {
    fail("expected a config error")
  }
  assert_eq(at.path, path)
  assert_true(message.contains(expected), msg=message)
}

///|
test "configuration errors identify missing files, empty matches and duplicate entries" {
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["missing.graphql"]}]
    ),
    "expected a file at missing.graphql",
  )
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["missing-*.graphql"]}]
    ),
    "matched no files",
  )
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["missing-dir/*.graphql"]}]
    ),
    "directory does not exist",
  )
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["flight-*.graphql","flight-board.graphql"]}]
    ),
    "duplicate query path",
  )
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["flight-board.graphql"]},{"name":"web","queries":["crew-roster.graphql"]}]
    ),
    "duplicate client name",
  )
}

///|
test "configuration errors reject unknown policy keys and ambiguous syntax" {
  let clients =
    #|"clients":[{"name":"web","queries":["flight-board.graphql"]}]
  check_config_error(
    clients + ",\"policy\":{\"observed_ony\":true}",
    "unknown key observed_ony",
  )
  check_config_error(
    clients + ",\"policy\":{\"observed_only\":\"true\"}",
    "must be a boolean",
  )
  check_config_error(
    clients + ",\"policy\":{\"fail_on\":[\"typo\"]}",
    "unknown gate category",
  )
  check_config_error(
    clients + ",\"policy\":{\"fail_on\":[]}",
    "must be a nonempty string array",
  )
  check_config_error(clients + ",\"baseline\":\"new.graphql\"", "invalid JSON")
  check_config_error(
    (
      #|"clients":[{"name":"web","queries":["../*.graphql"]}]
    ),
    "invalid path",
  )
}
