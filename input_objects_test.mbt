///|
fn input_source(path : String, text : String) -> @moongqlimpact.Source {
  { path, text, }
}

///|
fn input_client(text : String) -> @moongqlimpact.Client {
  { name: "web", sources: [input_source("web.graphql", text)], }
}

///|
test "nested input fields distinguish literal failures and runtime variable risks" {
  let old = input_source(
    "old",
    "enum Status { READY WAITING } input Rule { status: Status } " +
    "input BookFilter { rules: [Rule!] } type Query { books(filter: BookFilter): String }",
  )
  let next = input_source(
    "next",
    old.text.replace(old="status: Status", new="status: Status!"),
  )
  let client = input_client(
    "query Safe { books(filter: {rules: [{status: READY}]}) } " +
    "query Missing { books(filter: {rules: [{}]}) } " +
    "query Null { books(filter: {rules: [{status: null}]}) } " +
    "query Variable($f: BookFilter!) { books(filter: $f) } " +
    "query Default($f: BookFilter = {rules: [{}]}) { books(filter: $f) }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [client])
  assert_eq(report.changes.length(), 1)
  let change = report.changes[0]
  assert_eq(change.coordinate, "Rule.status")
  assert_eq(change.previous_type, "Status{READY, WAITING}")
  assert_eq(change.impacts.map(impact => impact.operation), [
    "Missing", "Null", "Variable", "Default",
  ])
  assert_eq(change.impacts[2].reason_codes, Some([InputVariableValueMayBreak]))
  assert_eq(
    change.impacts[3].reason_codes,
    Some([InputFieldTypeChanged, InputVariableValueMayBreak]),
  )
  let variable_report = @moongqlimpact.analyze_upgrade(old, next, [
    input_client("query Opaque($f: BookFilter) { books(filter: $f) }"),
  ])
  assert_false(
    variable_report.blocks(observed_only=true, severities=[Breaking]),
  )
  assert_true(variable_report.blocks(observed_only=true, severities=[Risk]))
  let restored : @moongqlimpact.Report = @json.from_json(report.to_json())
  assert_eq(restored, report)
}

///|
test "input literals can reorder object members and distinguish omitted defaults from null" {
  let old = input_source(
    "old", "input Rule { take: Int = 10 id: ID } type Query { books(filter: Rule): String }",
  )
  let next = input_source("next", old.text.replace(old="10", new="20"))
  let query = input_client(
    "query Omitted { books(filter: {id: \"1\"}) } " +
    "query Explicit { x: books(filter: {id: \"1\", take: null}) x: books(filter: {take: null, id: \"1\"}) } " +
    "query Absent { books }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [query])
  assert_eq(report.changes[0].impacts.map(impact => impact.operation), [
    "Omitted",
  ])
  assert_eq(
    report.changes[0].impacts[0].reason_codes,
    Some([InputFieldDefaultChanged]),
  )
}

///|
test "extending recursive input objects terminates and tracks new required fields" {
  let old = input_source(
    "old", "input Filter { nested: [Filter!] } type Query { books(filter: Filter): String }",
  )
  let next = input_source(
    "next",
    "extend input Filter { minimum: Int! } " + old.text,
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    input_client(
      "query Nested { books(filter: {nested: [{}]}) } query Opaque($f: Filter) { books(filter: $f) }",
    ),
  ])
  assert_eq(report.changes[0].coordinate, "Filter.minimum")
  assert_eq(
    report.changes[0].impacts[0].reason_codes,
    Some([RequiredInputFieldAdded]),
  )
  assert_eq(
    report.changes[0].impacts[1].reason_codes,
    Some([InputVariableValueMayBreak]),
  )
}

///|
test "invalid input objects and old input literals produce diagnostics" {
  let old = input_source(
    "old", "input Rule { limit: Int! } type Query { books(filter: Rule): String }",
  )
  for
    text in [
      "{ books(filter: {}) }", "{ books(filter: {limit: null}) }", "{ books(filter: {limit: 1, limit: 2}) }",
      "{ books(filter: {limit: 1, unknown: 0}) }", "query Read($limit: Int) { books(filter: {limit: $limit}) }",
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade(old, old, [input_client(text)]),
    ) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  }
  for
    text in [
      "input Cycle { child: Cycle! } type Query { books(filter: Cycle): String }",
      "input Cycle { child: Cycle = {} } type Query { books(filter: Cycle): String }",
      "input A { b: B! } input B { a: A! } type Query { books(filter: A): String }",
      "input Rule { limit: Int! = null } type Query { books(filter: Rule): String }",
      "input Rule { name: String } type Rule { title: String } type Query { books: Rule }",
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade(old, input_source("bad", text), []),
    ) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  }
}

///|
test "nullable nested variable can still validate at a field with a non-null default" {
  let old = input_source(
    "old", "enum Status { READY } input Rule { status: Status } type Query { books(filter: Rule): String }",
  )
  let next = input_source(
    "next",
    old.text.replace(old="status: Status", new="status: Status! = READY"),
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    input_client("query Variable($s: Status) { books(filter: {status: $s}) }"),
  ])
  assert_eq(
    report.changes[0].impacts[0].reason_codes,
    Some([InputFieldDefaultChanged, InputVariableValueMayBreak]),
  )
  assert_false(report.blocks(observed_only=true, severities=[Breaking]))
  assert_true(report.blocks(observed_only=true, severities=[Risk]))
}

///|
test "removed fields retain separate evidence for explicit and defaulted inputs" {
  let old = input_source(
    "old", "enum Status { READY WAITING } input Rule { limit: Int = 10 status: Status } type Query { books(filter: Rule): String }",
  )
  let next = input_source(
    "next", "enum Status { READY } input Rule { status: Status } type Query { books(filter: Rule): String }",
  )
  let client = input_client(
    "query Omitted { books(filter: {}) } " +
    "query Explicit { books(filter: {limit: null, status: WAITING}) }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [client])
  let removed = report.changes[0]
  assert_eq(removed.coordinate, "Rule.limit")
  assert_eq(removed.impacts.map(impact => impact.reason_codes), [
    Some([InputFieldDefaultChanged]),
    Some([InputFieldRemoved]),
  ])
  assert_eq(report.changes[1].coordinate, "Rule.status")
  assert_eq(
    report.changes[1].impacts[0].reason_codes,
    Some([InputEnumValueRemoved]),
  )
  assert_eq(
    @moongqlimpact.analyze_upgrade(old, next, [client]).to_json(),
    report.to_json(),
  )
}
