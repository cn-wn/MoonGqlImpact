///|
test "oneOf members require nullable declarations without defaults" {
  for
    declaration in [
      "input Match @oneOf { id: ID! }", "input Match @oneOf { id: ID = null }", "input Match @oneOf @oneOf { id: ID }",
      "input Match @oneOf(key: 1) { id: ID }", "input Match { id: ID } extend input Match @oneOf { name: String }",
      "input Match @oneOf { id: ID } extend input Match { name: String! }",
    ] {
    let schema : @moongqlimpact.Source = {
      path: "invalid",
      text: declaration + " type Query { find(by: Match): String }",
    }
    let result = Ok(@moongqlimpact.analyze_upgrade(schema, schema, [])) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)), msg=declaration)
  }
}

///|
test "adding oneOf distinguishes schema changes, invalid literals and sample rejection" {
  let old : @moongqlimpact.Source = {
    path: "old",
    text: "input Match { id: ID user: String } type Query { find(by: [Match!]!): String }",
  }
  let next : @moongqlimpact.Source = {
    path: "next",
    text: old.text.replace(old="input Match", new="input Match @oneOf"),
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        {
          path: "find.graphql",
          text: "query Single { find(by:{id:7}) } query Multiple { find(by:[{id:7,user:\"x\"}]) } query Optional($id:ID = \"known\") { find(by:{id:$id}) } query Runtime($by:[Match!]!) { find(by:$by) }",
        },
      ],
    },
  ]
  let samples : Array[@moongqlimpact.VariableSample] = [
    {
      client: "web",
      operation: "Runtime",
      id: "null",
      variables: @json.parse("{\"by\":[{\"id\":null}]}"),
    },
    {
      client: "web",
      operation: "Runtime",
      id: "single",
      variables: @json.parse("{\"by\":{\"id\":7}}"),
    },
  ]
  let report = @moongqlimpact.analyze_upgrade_with_samples(
    old, next, clients, samples,
  )
  assert_eq(report.report.changes[0].coordinate, "Match")
  assert_eq(report.report.changes[0].impacts.map(hit => hit.operation), [
    "Multiple", "Optional", "Runtime",
  ])
  assert_eq(
    report.report.changes[0].impacts[2].reason_codes,
    Some([InputVariableValueMayBreak]),
  )
  assert_true(
    report.proposed_rejections
    is Some([{ operation: "Multiple", .. }, { operation: "Optional", .. }]),
  )
  assert_eq(report.sample_assessments.map(row => row.status), [
    VariableRejected,
    Unchanged,
  ])
  assert_eq(report.sample_assessments[0].path, Some("/by/0/id"))
  let diff = @moongqlimpact.analyze_upgrade(old, next, [])
  assert_true(diff.blocks(reason_codes=[InputObjectBecameOneOf]))
  assert_false(
    diff.blocks(observed_only=true, reason_codes=[InputObjectBecameOneOf]),
  )
}

///|
test "oneOf supports nullable outer values, extensions and non-null member variables" {
  let schema : @moongqlimpact.Source = {
    path: "schema",
    text: "input Key @oneOf { id: ID } extend input Key { username: String } type Query { find(by: Key): String }",
  }
  let report = @moongqlimpact.analyze_upgrade_with_coverage(schema, schema, [
    {
      name: "web",
      sources: [
        {
          path: "query",
          text: "query Empty { find(by:null) } query Named($name:String!) { find(by:{username:$name}) }",
        },
      ],
    },
  ])
  assert_eq(report.proposed_rejections, Some([]))
}
