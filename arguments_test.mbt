///|
fn argument_source(path : String, text : String) -> @moongqlimpact.Source {
  { path, text, }
}

///|
fn query_client(text : String) -> @moongqlimpact.Client {
  { name: "web", sources: [argument_source("client.graphql", text)], }
}

///|
test "argument tightening only affects clients that can send null or omit it" {
  let old = argument_source(
    "old.graphql", "type Query { user(id: ID): String }",
  )
  let next = argument_source(
    "new.graphql", "type Query { user(id: ID!): String }",
  )
  let clients = [
    query_client(
      "query Safe($id: ID!) { user(id: $id) } " +
      "query Nullable($id: ID) { account: user(id: $id) } " +
      "query Omitted { user } query Null { user(id: null) } " +
      "query Literal { user(id: \"42\") } " +
      "query Defaulted($id: ID = \"42\") { user(id: $id) }",
    ),
  ]
  let report = @moongqlimpact.analyze_upgrade(old, next, clients)
  assert_eq(report.changes.length(), 1)
  let change = report.changes[0]
  assert_eq(change.coordinate, "Query.user(id:)")
  assert_eq(change.previous_type, "ID")
  assert_eq(change.proposed_type, Some("ID!"))
  assert_eq(change.proposed.unwrap().path, "new.graphql")
  assert_eq(change.baseline.column, 19)
  assert_eq(change.impacts.map(impact => impact.operation), [
    "Nullable", "Omitted", "Null", "Defaulted",
  ])
  assert_eq(change.impacts[0].response_path, ["account"])
  assert_eq(change.impacts[0].selection.path, "client.graphql")
  let json = report.to_json().stringify()
  let decoded : @moongqlimpact.Report = @json.from_json(@json.parse(json))
  assert_eq(decoded, report)
  assert_eq(
    @moongqlimpact.analyze_upgrade(old, next, clients).to_json().stringify(),
    json,
  )
}

///|
test "argument defaults affect only uses that rely on them" {
  let old = argument_source(
    "old", "type Query { results(take: Int! = 10): String }",
  )
  let next = argument_source(
    "next", "type Query { results(take: Int! = 20): String }",
  )
  let client = query_client(
    "query Omit { results } " +
    "query Optional($take: Int) { results(take: $take) } " +
    "query WithDefault($take: Int = 10) { results(take: $take) } " +
    "query Provided($take: Int!) { results(take: $take) } " +
    "query Literal { results(take: 10) }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [client])
  let change = report.changes[0]
  assert_eq(change.previous_type, "Int! = 10")
  assert_eq(change.proposed_type, Some("Int! = 20"))
  assert_eq(change.impacts.map(impact => impact.operation), ["Omit", "Optional"])
  let a = argument_source(
    "old", "type Query { results(ids: [ID!]! = 42): String }",
  )
  let b = argument_source(
    "new", "type Query { results(ids: [ID!]! = [\"42\"]): String }",
  )
  assert_true(
    @moongqlimpact.analyze_upgrade(a, b, [query_client("{ results }")]).changes.is_empty(),
  )
}

///|
test "enum and list narrowing reference variable uses and relevant literals" {
  let old = argument_source(
    "old", "enum State { READY WAITING } type Query { item(state: [State]): String }",
  )
  let next = argument_source(
    "next", "enum State { READY } type Query { item(state: [State!]): String }",
  )
  let client = query_client(
    "query Variable($state: [State!]!) { item(state: $state) } " +
    "query Removed { item(state: WAITING) } " +
    "query List($state: State!) { item(state: [$state]) } " +
    "query Safe { item(state: READY) } query Empty { item(state: []) } " +
    "query NullItem { item(state: [null]) }",
  )
  let change = @moongqlimpact.analyze_upgrade(old, next, [client]).changes[0]
  assert_eq(change.impacts.map(impact => impact.operation), [
    "Variable", "Removed", "List", "NullItem",
  ])
}

///|
test "required additions and removals report distinct coordinates on the same selection" {
  let old = argument_source("old", "type Query { item(legacy: Int): String }")
  let next = argument_source(
    "next", "type Query { item(id: ID!, limit: Int): String }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    query_client("query Used { item(legacy: 7) } query Omitted { item }"),
  ])
  assert_eq(report.changes.map(change => change.coordinate), [
    "Query.item(legacy:)", "Query.item(id:)",
  ])
  assert_eq(report.changes[0].impacts.map(impact => impact.operation), ["Used"])
  assert_eq(report.changes[1].previous_type, "<absent>")
  assert_eq(report.changes[1].impacts.map(impact => impact.operation), [
    "Used", "Omitted",
  ])
  assert_true(report.to_markdown().contains("Argument removed"))
}

///|
test "argument validation checks baseline coercion and merged aliases" {
  let old = argument_source(
    "old", "type Query { item(id: ID!, count: Int, flags: [Boolean!]): String }",
  )
  for
    text in [
      "{ item }", "{ item(id: \"1\", id: \"2\") }", "{ item(id: \"1\", unknown: null) }",
      "{ item(id: \"1\", count: 2147483648) }", "{ item(id: \"1\", flags: [null]) }",
      "query Read($id: ID) { item(id: $id) }", "query Read($id: ID! = null) { item(id: $id) }",
      "query Read { item(id: $undefined) }", "{ x: item(id: \"1\") x: item(id: \"2\") }",
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade(old, old, [query_client(text)]),
    ) catch {
      error => Err(error)
    }
    guard result is Err(@moongqlimpact.Invalid(at, _)) else {
      fail("expected baseline argument diagnostic for " + text)
    }
    assert_eq(at.path, "client.graphql")
  }
  let valid = query_client(
    "{ x: item(id: \"1\", count: -2147483648) x: item(count: -2147483648, id: \"1\") }",
  )
  assert_true(
    @moongqlimpact.analyze_upgrade(old, old, [valid]).changes.is_empty(),
  )
  let bad = argument_source(
    "bad", "type Query { item(id: ID! = null): String }",
  )
  let result = Ok(@moongqlimpact.analyze_upgrade(old, bad, [])) catch {
    error => Err(error)
  }
  assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
}

///|
test "a valid literal is affected when its coerced value changes" {
  let old = argument_source("old", "type Query { item(id: Int): String }")
  let next = argument_source("next", "type Query { item(id: ID): String }")
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    query_client("query Number { item(id: 42) } query Omitted { item }"),
  ])
  assert_eq(report.changes[0].impacts.map(impact => impact.operation), [
    "Number",
  ])
}
