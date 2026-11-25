///|
let filter_base : @moongqlimpact.Source = {
  path: "old.graphql",
  text: "enum State { READY } input Filter { state: State ids: [ID!] } type Query { search(filter: Filter!): String }",
}

///|
let filter_clients : Array[@moongqlimpact.Client] = [
  {
    name: "web",
    sources: [
      {
        path: "search.graphql",
        text: "query Search($filter: Filter!) { search(filter: $filter) }",
      },
    ],
  },
]

///|
fn variable_sample(
  id : String,
  variables : Json,
) -> @moongqlimpact.VariableSample {
  { client: "web", operation: "Search", id, variables, }
}

///|
test "samples separate missing and explicit null, paths and raw values" {
  let next : @moongqlimpact.Source = {
    path: "new.graphql",
    text: filter_base.text.replace(
      old="state: State",
      new="state: State! = READY max: Int = 5",
    ),
  }
  let analysis = @moongqlimpact.analyze_upgrade_with_samples(
    filter_base,
    next,
    filter_clients,
    [
      variable_sample(
        "missing",
        @json.parse("{\"filter\":{\"ids\":\"redact-me\"}}"),
      ),
      variable_sample("null", @json.parse("{\"filter\":{\"state\":null}}")),
    ],
  )
  assert_eq(analysis.proposed_rejections, Some([]))
  assert_eq(analysis.sample_assessments.map(row => row.status), [
    CoercionChanged,
    VariableRejected,
  ])
  assert_eq(analysis.sample_assessments.map(row => row.path), [
    Some("/filter/state"),
    Some("/filter/state"),
  ])
  assert_true(
    analysis.blocks(observed_only=true, reason_codes=[VariableSampleRejected]),
  )
  assert_true(
    analysis.blocks(observed_only=true, reason_codes=[
      VariableSampleCoercionChanged,
    ]),
  )
  assert_false(analysis.to_json().stringify().contains("redact-me"))
  assert_false(analysis.to_markdown().contains("redact-me"))
  let decoded : @moongqlimpact.AnalyzedUpgrade = @json.from_json(
    analysis.to_json(),
  )
  assert_eq(decoded, analysis)
}

///|
test "sample coercion handles list singleton, numeric ID and field order" {
  let next = {
    ..filter_base,
    text: filter_base.text.replace(
      old="state: State ids: [ID!]",
      new="ids: [ID!] state: State",
    ),
  }
  let samples = [
    variable_sample(
      "singleton",
      @json.parse("{\"filter\":{\"state\":\"READY\",\"ids\":17}}"),
    ),
    variable_sample(
      "array",
      @json.parse("{\"filter\":{\"ids\":[\"17\"],\"state\":\"READY\"}}"),
    ),
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_samples(
    filter_base, next, filter_clients, samples,
  )
  assert_eq(analysis.sample_assessments.map(row => row.status), [
    Unchanged,
    Unchanged,
  ])
  assert_eq(analysis.sample_assessments.map(row => row.id), [
    "singleton", "array",
  ])
  assert_false(analysis.blocks())
}

///|
test "malformed, unmatched and duplicate samples fail before a usable report" {
  let valid = variable_sample("sample", @json.parse("{\"filter\":{}}"))
  for
    samples in [
      [variable_sample("not-object", @json.parse("[]"))],
      [variable_sample("extra", @json.parse("{\"filter\":{},\"typo\":1}"))],
      [{ ..valid, operation: "Typo", }],
      [valid, valid],
      [
        variable_sample(
          "range",
          @json.parse("{\"filter\":{\"ids\":9007199254740992}}"),
        ),
      ],
    ] {
    let result = Ok(
      @moongqlimpact.analyze_upgrade_with_samples(
        filter_base, filter_base, filter_clients, samples,
      ),
    ) catch {
      error => Err(error)
    }
    assert_true(result is Err(@moongqlimpact.Invalid(_, _)))
  }
  let report = @moongqlimpact.analyze_upgrade_with_samples(
    filter_base,
    filter_base,
    filter_clients,
    [valid],
  )
  assert_eq(report.sample_assessments[0].status, Unchanged)
}

///|
test "custom scalar profiles validate constants and runtime inputs" {
  let schema : @moongqlimpact.Source = {
    path: "schema",
    text: "scalar DateTime type Query { search(since: DateTime = \"utc\"): String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "web",
      sources: [
        {
          path: "client",
          text: "query Search($date: DateTime) { search(since: $date) }",
        },
      ],
    },
  ]
  let rules : Map[String, (Json) -> Bool] = Map([
    ("DateTime", value => value is String("utc")),
  ])
  let analysis = @moongqlimpact.analyze_upgrade_with_samples(
    schema,
    schema,
    clients,
    [variable_sample("valid", @json.parse("{\"date\":\"utc\"}"))],
    scalar_inputs=rules,
  )
  assert_eq(analysis.sample_assessments[0].status, Unchanged)
  let unsupported = Ok(
    @moongqlimpact.analyze_upgrade_with_samples(schema, schema, clients, []),
  ) catch {
    error => Err(error)
  }
  assert_true(unsupported is Err(@moongqlimpact.Unsupported(_, _)))
  let bad = Ok(
    @moongqlimpact.analyze_upgrade_with_samples(
      schema,
      schema,
      clients,
      [variable_sample("bad", @json.parse("{\"date\":\"local\"}"))],
      scalar_inputs=rules,
    ),
  ) catch {
    error => Err(error)
  }
  assert_true(bad is Err(@moongqlimpact.Invalid(_, _)))
}
