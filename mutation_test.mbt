///|
test "default mutation roots and shared fragments coexist with read operations" {
  let baseline : @moongqlimpact.Source = {
    path: "old",
    text: "type Query { item: Item } type Mutation { update(limit: Int): Item } type Item { title: String }",
  }
  let proposed = {
    ..baseline,
    text: baseline.text.replace(old="limit: Int", new="limit: Int!"),
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        {
          path: "client.graphql",
          text: "fragment Title on Item { name: title } query Read { item { ...Title } } mutation Update { saved: update { ...Title } }",
        },
      ],
    },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_coverage(
    baseline, proposed, clients,
  )
  assert_eq(analysis.coverage[0].operations.map(operation => operation.name), [
    "Read", "Update",
  ])
  assert_eq(analysis.report.changes[0].coordinate, "Mutation.update(limit:)")
  assert_eq(analysis.report.changes[0].impacts[0].response_path, ["saved"])
  assert_true(
    analysis.proposed_rejections is Some([{ operation: "Update", .. }]),
  )
}

///|
test "removing a mutation root is a breaking schema change even when its type stays" {
  let fields = " type Query { item: Int } type Write { save: Int }"
  let baseline : @moongqlimpact.Source = {
    path: "old",
    text: "schema { query: Query mutation: Write }" + fields,
  }
  let proposed : @moongqlimpact.Source = {
    path: "new",
    text: "schema { query: Query }" + fields,
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        { path: "client", text: "query Read { item } mutation Save { save }", },
      ],
    },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_coverage(
    baseline, proposed, clients,
  )
  assert_eq(analysis.report.changes.length(), 1)
  assert_eq(analysis.report.changes[0].coordinate, "schema.mutation")
  assert_eq(
    analysis.report.changes[0].impacts[0].reason_codes,
    Some([MutationRootRemoved]),
  )
  assert_true(analysis.proposed_rejections is Some([{ operation: "Save", .. }]))
  assert_true(@moongqlimpact.analyze_upgrade(baseline, proposed, []).blocks())
}

///|
test "mutation root constraints and subscription exclusions remain explicit" {
  for
    text in [
      "schema { query: Root mutation: Root } type Root { a: Int }", "schema { query: Root mutation: Write } type Root { a: Int } interface Write { a: Int }",
      "type Query { a: Int } scalar Mutation",
    ] {
    let schema : @moongqlimpact.Source = { path: "invalid", text, }
    let result = Ok(@moongqlimpact.analyze_upgrade(schema, schema, [])) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  }
  let schema : @moongqlimpact.Source = {
    path: "schema",
    text: "type Query { a: Int }",
  }
  let result = Ok(
    @moongqlimpact.analyze_upgrade(schema, schema, [
      {
        name: "web",
        sources: [{ path: "client", text: "subscription Listen { a }", }],
      },
    ]),
  ) catch {
    error => Err(error)
  }
  assert_true(result is Err(@moongqlimpact.Unsupported(_, _)))
}
