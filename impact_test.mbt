///|
fn source(path : String, text : String) -> @moongqlimpact.Source {
  { path, text, }
}

///|
test "list item nullability and unobserved removals retain independent evidence" {
  let old = source(
    "old", "type Query { people: [Person!]!, unused: String } type Person { name: String! }",
  )
  let new = source(
    "new", "type Query { people: [Person]!, added: String } type Person { name: String! }",
  )
  let clients = [
    @moongqlimpact.Client::{
      name: "web",
      sources: [
        source("web.graphql", "query Board { list: people { ...Names } }"),
        source("fragment.graphql", "fragment Names on Person { name }"),
      ],
    },
  ]
  let report = @moongqlimpact.analyze_upgrade(old, new, clients)
  let changes = report.changes
  assert_eq(changes.length(), 2)
  assert_eq(changes[0].previous_type, "[Person!]!")
  assert_eq(changes[0].proposed_type, Some("[Person]!"))
  assert_eq(changes[0].impacts[0].response_path, ["list"])
  assert_eq(changes[1].coordinate, "Query.unused")
  assert_true(changes[1].impacts.is_empty())
  let encoded = report.to_json().stringify()
  let decoded : @moongqlimpact.Report = @json.from_json(@json.parse(encoded))
  assert_eq(decoded, report)
  assert_eq(
    @moongqlimpact.analyze_upgrade(old, new, clients).to_json().stringify(),
    encoded,
  )
}

///|
test "shared fragment retains source location and aliases for each operation" {
  let old = source(
    "old", "type Query { user: Person } type Person { id: ID!, label: String }",
  )
  let new = source(
    "new", "type Query { user: Person } type Person { label: String }",
  )
  let shared = source("shared.graphql", "fragment Card on Person { key: id }")
  let report = @moongqlimpact.analyze_upgrade(old, new, [
    @moongqlimpact.Client::{
      name: "web",
      sources: [source("web", "query Web { user { ...Card ...Card } }"), shared],
    },
    @moongqlimpact.Client::{
      name: "mobile",
      sources: [
        source("mobile", "query Mobile { me: user { ...Card } }"),
        shared,
      ],
    },
  ])
  let impacts = report.changes[0].impacts
  assert_eq(impacts.length(), 2)
  assert_eq(impacts[0].response_path, ["user", "key"])
  assert_eq(impacts[1].response_path, ["me", "key"])
  assert_eq(impacts[1].selection.path, "shared.graphql")
}

///|
test "stronger output promises preserve behavior and malformed input does not poison retry" {
  let old = source("old", "type Query { data: [String] }")
  let next = source("new", "type Query { data: [String!]! }")
  let query = source("client", "query Read { data }")
  let client = @moongqlimpact.Client::{ name: "web", sources: [query], }
  let rejected = Ok(
    @moongqlimpact.analyze_upgrade(old, source("broken", "type Query {"), [
      client,
    ]),
  ) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Invalid(location, _)) else {
    fail("expected parse diagnostic")
  }
  assert_eq(location.path, "broken")
  assert_true(
    @moongqlimpact.analyze_upgrade(old, next, [client]).changes.is_empty(),
  )
}

///|
test "unsupported inputs and invalid baseline selections are rejected" {
  let old = source("old", "type Query { data: String }")
  let query = source("client", "query Read($id: ID) { data }")
  let rejected = Ok(
    @moongqlimpact.analyze_upgrade(old, old, [
      @moongqlimpact.Client::{ name: "web", sources: [query], },
    ]),
  ) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Unsupported(_, _)) else {
    fail("expected profile diagnostic")
  }
  let query = source("client", "query Read { missing }")
  let rejected = Ok(
    @moongqlimpact.analyze_upgrade(old, old, [
      @moongqlimpact.Client::{ name: "web", sources: [query], },
    ]),
  ) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Invalid(_, _)) else {
    fail("expected baseline diagnostic")
  }
}

///|
test "fragment cycles and conflicting aliases are rejected" {
  let old = source("old", "type Query { left: Int, right: Int }")
  let cyclic = source("q", "query Read { ...A } fragment A on Query { ...A }")
  let rejected = Ok(
    @moongqlimpact.analyze_upgrade(old, old, [
      @moongqlimpact.Client::{ name: "web", sources: [cyclic], },
    ]),
  ) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Invalid(_, _)) else {
    fail("expected cycle diagnostic")
  }
  let conflict = source("q", "query Read { item: left item: right }")
  let rejected = Ok(
    @moongqlimpact.analyze_upgrade(old, old, [
      @moongqlimpact.Client::{ name: "web", sources: [conflict], },
    ]),
  ) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Invalid(_, _)) else {
    fail("expected field merge diagnostic")
  }
}

///|
test "syntactic depth accepts the limit and rejects deeper types" {
  let near = "[".repeat(49) + "String" + "]".repeat(49)
  let old = source("old", "type Query { field: " + near + " }")
  assert_true(@moongqlimpact.analyze_upgrade(old, old, []).changes.is_empty())
  let deep = source("deep", "type Query { field: [" + near + "] }")
  let rejected = Ok(@moongqlimpact.analyze_upgrade(old, deep, [])) catch {
    error => Err(error)
  }
  guard rejected is Err(@moongqlimpact.Invalid(at, _)) else {
    fail("expected depth diagnostic")
  }
  assert_eq(at.path, "deep")
}

///|
test "repeated fragments deduplicate per path and keep distinct source sites" {
  let old = source(
    "old", "type Query { person: Person } type Person { name: String! }",
  )
  let next = source(
    "next", "type Query { person: Person } type Person { name: String }",
  )
  let query = source(
    "client", "query Read { a: person { ...Name ...Name name } b: person { ...Name } } fragment Name on Person { name }",
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    @moongqlimpact.Client::{ name: "web", sources: [query], },
  ])
  let impacts = report.changes[0].impacts
  assert_eq(impacts.length(), 3)
  assert_eq(impacts[0].response_path, ["a", "name"])
  assert_eq(impacts[1].response_path, ["a", "name"])
  assert_true(impacts[0].selection.column != impacts[1].selection.column)
  assert_eq(impacts[2].response_path, ["b", "name"])
  assert_eq(impacts[2].selection, impacts[0].selection)
}

///|
test "__typename can be aliased but cannot shadow another field at the same response path" {
  let old = source("old", "type Query { name: String! }")
  let next = source("next", "type Query { name: String }")
  let query = source("query", "query Read { kind: __typename name }")
  let report = @moongqlimpact.analyze_upgrade(old, next, [
    @moongqlimpact.Client::{ name: "web", sources: [query], },
  ])
  assert_eq(report.changes[0].impacts[0].response_path, ["name"])
  for
    text in [
      "query Read { kind: __typename kind: name }", "query Read { __typename { name } }",
    ] {
    let rejected = Ok(
      @moongqlimpact.analyze_upgrade(old, next, [
        @moongqlimpact.Client::{
          name: "web",
          sources: [source("query", text)],
        },
      ]),
    ) catch {
      error => Err(error)
    }
    assert_true(rejected is Err(@moongqlimpact.Invalid(_, _)))
  }
}

///|
test "deprecated fields remain selectable until removed" {
  let old = source(
    "old", "type Query { legacy: String! @deprecated(reason: \"Use name\") name: String }",
  )
  let marked = source(
    "marked", "type Query { legacy: String! @deprecated name: String }",
  )
  let next = source("next", "type Query { name: String }")
  let clients = [
    @moongqlimpact.Client::{
      name: "web",
      sources: [source("client", "query Read { legacy }")],
    },
  ]
  assert_true(
    @moongqlimpact.analyze_upgrade(old, marked, clients).changes.is_empty(),
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, clients)
  assert_eq(report.changes[0].coordinate, "Query.legacy")
  assert_eq(report.changes[0].impacts[0].operation, "Read")
  for directive in ["@deprecated(reason: 123)", "@deprecated @deprecated"] {
    let invalid = source(
      "invalid",
      "type Query { legacy: String! " + directive + " }",
    )
    let rejected = Ok(@moongqlimpact.analyze_upgrade(old, invalid, clients)) catch {
      error => Err(error)
    }
    assert_true(rejected is Err(@moongqlimpact.Invalid(_, _)))
  }
  let custom = source("custom", "type Query { legacy: String! @custom }")
  let rejected = Ok(@moongqlimpact.analyze_upgrade(old, custom, clients)) catch {
    error => Err(error)
  }
  assert_true(rejected is Err(@moongqlimpact.Unsupported(_, _)))
}
