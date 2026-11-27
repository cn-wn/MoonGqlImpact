///|
fn site_analysis(
  before : String,
  after : String,
  operation : String,
  samples : Array[(String, String)],
) -> @moongqlimpact.AnalyzedUpgrade raise {
  let clients : Array[@moongqlimpact.Client] = [
    { name: "web", sources: [{ path: "find.graphql", text: operation, }], },
  ]
  @moongqlimpact.analyze_upgrade_with_samples(
    { path: "old", text: before, },
    { path: "new", text: after, },
    clients,
    samples.map(sample => @moongqlimpact.VariableSample::{
      client: "web",
      operation: "Find",
      id: sample.0,
      variables: @json.parse(sample.1),
    }),
  )
}

///|
test "field argument rejects explicit null but accepts omitted and concrete values" {
  let old = "type Query { lookup(id: ID = \"guest\"): String }"
  let new = old.replace(old="id: ID", new="id: ID!")
  let query = "query Find($id: ID) { result: lookup(id: $id) }"
  let samples = [
    ("null", "{\"id\":null}"),
    ("missing", "{}"),
    ("present", "{\"id\":\"private-id\"}"),
  ]
  let report = site_analysis(old, new, query, samples)
  assert_eq(report.proposed_rejections, Some([]))
  assert_eq(report.sample_assessments.map(row => row.status), [
    VariableRejected,
    Unchanged,
    Unchanged,
  ])
  let rejection = report.sample_assessments[0]
  assert_eq(rejection.path, Some("/id"))
  assert_eq(rejection.argument_coordinate, Some("Query.lookup(id:)"))
  assert_eq(rejection.response_path, Some(["result"]))
  assert_eq(
    rejection.selection,
    Some({ path: "find.graphql", line: 1, column: 23, }),
  )
  assert_true(
    report.blocks(observed_only=true, reason_codes=[VariableSampleRejected]),
  )
  assert_false(report.to_json().stringify().contains("private-id"))
  assert_false(report.to_markdown().contains("private-id"))
  let decoded : @moongqlimpact.AnalyzedUpgrade = @json.from_json(
    report.to_json(),
  )
  assert_eq(decoded, report)
  assert_eq(
    site_analysis(old, new, query, samples).to_json().stringify(),
    report.to_json().stringify(),
  )
}

///|
test "nested field defaults and missing list elements keep their GraphQL meanings" {
  let old = "input Filter { tag: String = \"before\" terms: [ID] } type Query { search(filter: Filter!): String }"
  let new = old.replace(
    old="tag: String = \"before\"",
    new="tag: String! = \"after\"",
  )
  let query = "query Find($tag: String, $term: ID) { hits: search(filter: {tag:$tag, terms:[$term]}) }"
  let report = site_analysis(old, new, query, [
    ("omitted", "{}"),
    ("null-tag", "{\"tag\":null}"),
    ("tag-and-missing-term", "{\"tag\":\"fixed\"}"),
    ("tag-and-null-term", "{\"tag\":\"fixed\",\"term\":null}"),
  ])
  assert_eq(report.proposed_rejections, Some([]))
  assert_eq(report.sample_assessments.map(row => row.status), [
    CoercionChanged,
    VariableRejected,
    Unchanged,
    Unchanged,
  ])
  assert_eq(report.sample_assessments[0].path, Some("/filter/tag"))
  assert_eq(
    report.sample_assessments[1].argument_coordinate,
    Some("Query.search(filter:)"),
  )
}

///|
test "operation variable defaults precede location defaults and arguments can gain defaults" {
  let old = "type Query { lookup(id: ID = \"old\"): String }"
  let new = "type Query { lookup(id: ID = \"new\", order: Int = 2): String }"
  let report = site_analysis(
    old,
    new,
    "query Find($id: ID = \"operation\") { lookup(id: $id) }",
    [("operation-default", "{}")],
  )
  assert_eq(report.sample_assessments[0].status, CoercionChanged)
  assert_eq(report.sample_assessments[0].path, Some("/order"))
  assert_eq(
    report.sample_assessments[0].argument_coordinate,
    Some("Query.lookup(order:)"),
  )
}

///|
test "sample directives guard parent fields and fragment spreads" {
  let old = "type Query { page: Page ping: String } type Page { lookup(id: ID = \"guest\"): String }"
  let new = old.replace(old="id: ID", new="id: ID!")
  let operation = "query Find($on: Boolean!, $skip: Boolean!, $id: ID) { wrapper: page @include(if:$on) { ...Part @skip(if:$skip) } ping } " +
    "fragment Part on Page { result: lookup(id:$id) }"
  let report = site_analysis(old, new, operation, [
    ("parent-off", "{\"on\":false,\"skip\":false,\"id\":null}"),
    ("spread-off", "{\"on\":true,\"skip\":true,\"id\":null}"),
    ("enabled", "{\"on\":true,\"skip\":false,\"id\":null}"),
  ])
  assert_eq(report.sample_assessments.map(row => row.status), [
    Unchanged,
    Unchanged,
    VariableRejected,
  ])
  assert_eq(
    report.sample_assessments[2].response_path,
    Some(["wrapper", "result"]),
  )
}

///|
test "a baseline-invalid field argument is rejected as an input error" {
  let schema = "type Query { lookup(id: ID! = \"guest\"): String }"
  let query = "query Find($id: ID) { lookup(id: $id) }"
  let result = Ok(
    site_analysis(schema, schema, query, [("bad", "{\"id\":null}")]),
  ) catch {
    error => Err(error)
  }
  assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  assert_eq(
    site_analysis(schema, schema, query, [("omitted", "{}")]).sample_assessments[0].status,
    Unchanged,
  )
}

///|
test "field rejection takes priority over an earlier variable default change" {
  let old = "input Filter { title: String } type Query { lookup(id: ID = \"guest\", filter: Filter!): String }"
  let new = "input Filter { title: String limit: Int = 5 } type Query { lookup(id: ID! = \"guest\", filter: Filter!): String }"
  let report = site_analysis(
    old,
    new,
    "query Find($id: ID, $filter: Filter!) { lookup(id: $id, filter: $filter) }",
    [("both", "{\"id\":null,\"filter\":{}}")],
  )
  assert_eq(report.sample_assessments[0].status, VariableRejected)
  assert_eq(
    report.sample_assessments[0].argument_coordinate,
    Some("Query.lookup(id:)"),
  )
}

///|
test "version-one sample assessments with only a variable path still decode" {
  let json = @json.parse(
    "{\"argument_free\":true,\"format_version\":1,\"changes\":[],\"coverage\":[],\"sample_assessments\":[{\"client\":\"web\",\"operation\":\"Find\",\"id\":\"old\",\"status\":\"VariableRejected\",\"path\":\"/id\",\"reason\":{\"code\":\"VariableSampleRejected\",\"severity\":\"Breaking\"}}]}",
  )
  let report : @moongqlimpact.AnalyzedUpgrade = @json.from_json(json)
  assert_eq(report.sample_assessments[0].path, Some("/id"))
  assert_eq(report.sample_assessments[0].argument_coordinate, None)
  assert_true(
    report.blocks(observed_only=true, reason_codes=[VariableSampleRejected]),
  )
}
