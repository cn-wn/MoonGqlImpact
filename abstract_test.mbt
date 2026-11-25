///|
fn abstract_source(path : String, text : String) -> @moongqlimpact.Source {
  { path, text, }
}

///|
fn abstract_client(name : String, text : String) -> @moongqlimpact.Client {
  { name, sources: [abstract_source(name + ".graphql", text)], }
}

///|
test "union removal identifies affected fragments and keeps sibling operations compatible" {
  let types = "type Book { title: String } type Film { title: String } type Query { search: [Result!]! } "
  let old = abstract_source(
    "before.graphql",
    types + "union Result = Book | Film",
  )
  let next = abstract_source("after.graphql", types + "union Result = Film")
  let clients = [
    abstract_client(
      "books", "query FindBooks { matches: search { ...BookCard } } fragment BookCard on Book { title }",
    ),
    abstract_client(
      "films", "query FindFilms { search { ... on Film { title } } }",
    ),
    abstract_client("names", "query Types { search { __typename } }"),
  ]
  let report = @moongqlimpact.analyze_upgrade(old, next, clients)
  assert_eq(report.changes.length(), 1)
  let change = report.changes[0]
  assert_eq(change.coordinate, "Result")
  assert_eq(change.previous_type, "Result{Book, Film}")
  assert_eq(change.proposed_type, Some("Result{Film}"))
  assert_eq(change.impacts.map(impact => impact.client), ["books"])
  assert_eq(change.impacts[0].response_path, ["matches"])
  assert_eq(change.impacts[0].selection.path, "books.graphql")
  assert_eq(
    change.impacts[0].reason_codes,
    Some([AbstractMemberRemoved, FragmentNoLongerPossible]),
  )
  let safe = @moongqlimpact.analyze_upgrade(old, next, [clients[1]])
  assert_false(safe.blocks(observed_only=true))
  assert_true(safe.blocks())
}

///|
test "interface changes narrow runtime scopes across nested fragment conditions" {
  let old = abstract_source(
    "old",
    "interface Node { id: ID! } interface Work implements Node { id: ID! } " +
    "type Book implements Work & Node { id: ID! title: String } " +
    "type Film implements Work & Node { id: ID! title: String } " +
    "union Result = Book | Film type Query { result: Result }",
  )
  let next = abstract_source(
    "next",
    old.text.replace(
      old="union Result = Book | Film",
      new="union Result = Film",
    ),
  )
  let client = abstract_client(
    "web", "query ResultCard { result { ... on Work { id ... on Book { title } } } }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [client])
  let impacts = report.changes[0].impacts
  assert_eq(impacts.length(), 2)
  assert_eq(impacts[0].reason_codes, Some([AbstractMemberRemoved]))
  assert_eq(
    impacts[1].reason_codes,
    Some([AbstractMemberRemoved, FragmentNoLongerPossible]),
  )
  assert_true(impacts[0].selection.column < impacts[1].selection.column)
  assert_true(
    report.blocks(observed_only=true, reason_codes=[FragmentNoLongerPossible]),
  )
}

///|
test "abstract extensions and an interface implementor addition have risk evidence" {
  let old = abstract_source(
    "old",
    "interface Node { id: ID } type Film implements Node { id: ID! } " +
    "type Book { id: ID! } union Result = Film type Query { node: Node result: Result }",
  )
  let next = abstract_source(
    "next",
    "extend union Result = Book extend type Book implements Node extend interface Node { code: Int } " +
    "interface Node { id: ID } type Film implements Node { id: ID! code: Int } " +
    "type Book { id: ID! code: Int } union Result = Film type Query { node: Node result: Result }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    abstract_client("web", "{ node { id } result { __typename } }"),
  ])
  assert_eq(report.changes.map(change => change.coordinate), ["Node", "Result"])
  assert_true(report.blocks(observed_only=true, severities=[Risk]))
  assert_false(report.blocks(observed_only=true, severities=[Breaking]))
  assert_eq(report.changes[0].impacts[0].response_path, ["node"])
}

///|
test "a removed interface is reported at a fragment even if the selected object's fields remain" {
  let old = abstract_source(
    "old", "interface Node { id: ID! } type Film implements Node { id: ID! } type Query { film: Film }",
  )
  let next = abstract_source(
    "next", "type Film { id: ID! } type Query { film: Film }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    abstract_client("web", "{ film { ... on Node { id } } }"),
  ])
  assert_true(
    report.blocks(observed_only=true, reason_codes=[AbstractTypeRemoved]),
  )
  assert_true(
    report.blocks(observed_only=true, reason_codes=[FragmentNoLongerPossible]),
  )
}

///|
test "object branches may reuse aliases with matching response shapes" {
  let schema = abstract_source(
    "schema",
    "type Book { title: String!, pages: Int } type Film { name: String!, minutes: Int } " +
    "union Result = Book | Film type Query { result: Result }",
  )
  let good = abstract_client(
    "web", "{ result { ... on Book { label: title } ... on Film { label: name } } }",
  )
  assert_true(
    @moongqlimpact.analyze_upgrade(schema, schema, [good]).changes.is_empty(),
  )
  for
    text in [
      "{ result { ... on Book { label: title } ... on Film { label: minutes } } }",
      "{ result { ... on Book { label: title label: pages } } }", "{ result { title } }",
      "{ result { ... on Query { __typename } } }",
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade(schema, schema, [
        abstract_client("web", text),
      ]),
    ) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  }
}

///|
test "malformed abstract schemas fail before operation analysis" {
  let valid = abstract_source("valid", "type Query { item: String }")
  for
    text in [
      "type Query { node: Node } interface Node { id: ID! } type Book implements Node { id: ID }",
      "type Query { node: Node } interface Node { id: ID } type Book implements Node { id(limit: Int!): ID }",
      "type Query { node: Node } interface Node implements Child { id: ID } interface Child implements Node { id: ID }",
      "type Query { item: Result } interface Node { id: ID } union Result = Node",
      "type Query { item: String } type Book { id: ID } union Result = Book extend union Result = Book",
      "type Query { item: String } interface Parent { id: ID } interface Child implements Parent { id: ID } type Book implements Child { id: ID }",
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade(valid, abstract_source("bad", text), []),
    ) catch {
      error => Err(error)
    }
    guard result is Err(@moongqlimpact.Invalid(at, _)) else { fail(text) }
    assert_eq(at.path, "bad")
  }
}

///|
test "an added implementor can widen a fragment on an otherwise unchanged union" {
  let old = abstract_source(
    "old",
    "interface Named { name: String } type Book implements Named { name: String } " +
    "type Film { name: String } union Result = Book | Film type Query { result: Result }",
  )
  let next = abstract_source(
    "next",
    old.text.replace(old="type Film {", new="type Film implements Named {"),
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    abstract_client("web", "{ result { ... on Named { name } } }"),
  ])
  assert_eq(report.changes[0].coordinate, "Named")
  assert_eq(
    report.changes[0].impacts[0].reason_codes,
    Some([AbstractMemberAdded]),
  )
  assert_true(report.blocks(observed_only=true, severities=[Risk]))
  let decoded : @moongqlimpact.Report = @json.from_json(report.to_json())
  assert_eq(decoded, report)
}
