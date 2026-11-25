///|
test "defaulted additions affect omitted arguments and nested inputs without invalidating operations" {
  let baseline : @moongqlimpact.Source = {
    path: "old.graphql",
    text: "input Filter { title: String } type Query { books(filter: Filter): String }",
  }
  let proposed : @moongqlimpact.Source = {
    path: "new.graphql",
    text: "input Filter { title: String limit: Int = 10 } type Query { books(filter: Filter, sort: String! = \"date\"): String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        {
          path: "web.graphql",
          text: "query Literal { books(filter: {}) } query Runtime($value: Filter) { books(filter: $value) } query ExplicitNull { books(filter: null) }",
        },
      ],
    },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_coverage(
    baseline, proposed, clients,
  )
  assert_eq(analysis.proposed_rejections, Some([]))
  let changes = analysis.report.changes
  assert_eq(changes.map(change => change.coordinate), [
    "Query.books(sort:)", "Filter.limit",
  ])
  assert_eq(changes[0].impacts.map(impact => impact.operation), [
    "Literal", "Runtime", "ExplicitNull",
  ])
  assert_eq(changes[1].impacts.map(impact => impact.operation), [
    "Literal", "Runtime",
  ])
  assert_eq(
    changes[1].impacts[1].reason_codes,
    Some([InputFieldDefaultChanged]),
  )
  assert_true(analysis.blocks(observed_only=true, severities=[Risk]))
  assert_false(analysis.blocks(observed_only=true, severities=[Breaking]))
}

///|
test "proposed rejection is distinct from an output contract change and participates in the gate" {
  let baseline : @moongqlimpact.Source = {
    path: "old",
    text: "type Query { ping: String! search(id: ID): String }",
  }
  let proposed : @moongqlimpact.Source = {
    path: "new",
    text: "type Query { ping: String search(id: ID!): String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web<beta>",
      sources: [
        {
          path: "web.graphql",
          text: "query Valid { ping }\nquery Rejected { search }",
        },
      ],
    },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_coverage(
    baseline, proposed, clients,
  )
  guard analysis.proposed_rejections is Some([rejection]) else {
    fail("expected one rejection")
  }
  assert_eq(rejection.operation, "Rejected")
  assert_eq(rejection.location, { path: "web.graphql", line: 2, column: 18, })
  assert_eq(rejection.reason.code, ProposedOperationRejected)
  assert_true(
    analysis.blocks(observed_only=true, reason_codes=[ProposedOperationRejected]),
  )
  assert_false(analysis.blocks(observed_only=true, severities=[Risk]))
  assert_eq(
    analysis.report,
    @moongqlimpact.analyze_upgrade(baseline, proposed, clients),
  )
  assert_true(analysis.to_markdown().contains("web&lt;beta&gt;"))
  let decoded : @moongqlimpact.AnalyzedUpgrade = @json.from_json(
    analysis.to_json(),
  )
  assert_eq(decoded, analysis)
}

///|
test "earlier version-1 reports have unknown proposed validation evidence" {
  let prior = @json.parse(
    "{\"format_version\":1,\"changes\":[],\"coverage\":[]}",
  )
  let decoded : @moongqlimpact.AnalyzedUpgrade = @json.from_json(prior)
  assert_eq(decoded.proposed_rejections, None)
  assert_eq(decoded.to_json(), prior)
}
