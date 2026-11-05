# MoonGqlImpact library quickstart

Import `cn-wn/moongqlimpact` from a local checkout to compare two SDL sources and
trace regressions to the operations a client ships. This example checks a query
that still selects a valid field after the schema upgrade. Its previous non-null
guarantee is lost, so the report points to the aliased response key.

```mbt check
///|
test {
  let baseline : @moongqlimpact.Source = {
    path: "baseline.graphql",
    text: "type Query { title: String! }",
  }
  let proposed : @moongqlimpact.Source = {
    path: "proposed.graphql",
    text: "type Query { title: String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        { path: "screen.graphql", text: "query Screen { heading: title }", },
      ],
    },
  ]
  let report = @moongqlimpact.analyze_upgrade(baseline, proposed, clients)
  assert_eq(report.changes.length(), 1)
  let change = report.changes[0]
  assert_eq(change.coordinate, "Query.title")
  assert_eq(change.previous_type, "String!")
  assert_eq(change.proposed_type, Some("String"))
  assert_eq(change.impacts[0].response_path, ["heading"])
}
```
