///|
test "versioned coverage records successful operations and fragment-only files" {
  let schema : @moongqlimpact.Source = {
    path: "schema.graphql",
    text: "type Query { name: String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        { path: "fragment.graphql", text: "fragment Names on Query { name }", },
        { path: "web.graphql", text: "query Z { ...Names }\nquery A { name }", },
      ],
    },
    { name: "app", sources: [{ path: "app.graphql", text: "{ name }", }], },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_coverage(
    schema, schema, clients,
  )
  assert_eq(
    analysis.report,
    @moongqlimpact.analyze_upgrade(schema, schema, clients),
  )
  assert_eq(analysis.coverage.map(client => client.name), ["web", "app"])
  let web = analysis.coverage[0]
  assert_eq(web.sources, ["fragment.graphql", "web.graphql"])
  assert_eq(web.operations.map(operation => operation.name), ["Z", "A"])
  assert_eq(web.operations[1].location, {
    path: "web.graphql",
    line: 2,
    column: 1,
  })
  assert_eq(analysis.coverage[1].operations[0].name, "<anonymous>")
  let json = analysis.to_json()
  assert_true(
    json is { "format_version": 1, "changes": [], "coverage": [_, _], .. },
  )
  let decoded : @moongqlimpact.AnalyzedUpgrade = @json.from_json(json)
  let old_reader : @moongqlimpact.Report = @json.from_json(json)
  assert_eq(decoded, analysis)
  assert_eq(old_reader, analysis.report)
  assert_eq(
    @moongqlimpact.analyze_upgrade_with_coverage(schema, schema, clients)
    .to_json()
    .stringify(),
    json.stringify(),
  )
}

///|
test "versioned coverage distinguishes schema-only and rejects unsupported report formats" {
  let schema : @moongqlimpact.Source = {
    path: "schema.graphql",
    text: "type Query { name: String }",
  }
  let schema_only = @moongqlimpact.analyze_upgrade_with_coverage(
    schema,
    schema,
    [],
  )
  assert_true(
    schema_only.to_json()
    is { "format_version": 1, "changes": [], "coverage": [], .. },
  )
  for
    text in [
      "{\"changes\":[]}", "{\"format_version\":2,\"changes\":[],\"coverage\":[]}",
      "{\"format_version\":\"1\",\"changes\":[],\"coverage\":[]}", "{\"format_version\":1,\"changes\":[]}",
      "{\"format_version\":1,\"changes\":[],\"coverage\":null}",
    ] {
    let json = @json.parse(text)
    let result : Result[@moongqlimpact.AnalyzedUpgrade, @json.JsonDecodeError] = Ok(
      @json.from_json(json),
    ) catch {
      error => Err(error)
    }
    assert_true(result is Err(_))
  }
}
