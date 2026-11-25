///|
test "output findings carry distinct reasons without losing simultaneous changes" {
  let old : @moongqlimpact.Source = {
    path: "old",
    text: "scalar Date @specifiedBy(url: \"https://example.test/v1\") " +
    "enum State { READY WAITING } type Query { gone: Int state: [State!]! date: Date other: String }",
  }
  let next : @moongqlimpact.Source = {
    path: "next",
    text: "scalar Date @specifiedBy(url: \"https://example.test/v2\") " +
    "enum State { READY DONE } type Query { state: [State]! date: Date other: Int }",
  }
  let client : @moongqlimpact.Client = {
    name: "web",
    sources: [{ path: "web.graphql", text: "{ state date other }", }],
  }
  let report = @moongqlimpact.analyze_upgrade(old, next, [client])
  assert_eq(report.changes.map(change => change.coordinate), [
    "Query.gone", "Query.state", "Query.date", "Query.other",
  ])
  let codes = report.changes.map(change => {
    change.reasons.unwrap().map(reason => reason.code)
  })
  assert_eq(codes, [
    [FieldRemoved],
    [OutputNullabilityWeakened, OutputEnumValueRemoved, OutputEnumValueAdded],
    [ScalarSpecificationChanged],
    [OutputTypeChanged],
  ])
  assert_eq(report.changes[1].impacts[0].reason_codes, Some(codes[1]))
  assert_true(report.blocks(reason_codes=[FieldRemoved]))
  assert_false(report.blocks(observed_only=true, reason_codes=[FieldRemoved]))
  assert_true(report.blocks(observed_only=true, severities=[Risk]))
  assert_true(report.blocks(observed_only=true, severities=[Notice]))
  let rendered = report.to_markdown()
  assert_true(
    rendered.contains("<code>Risk</code> <code>OutputEnumValueAdded</code>"),
  )
  assert_true(
    rendered.contains(
      "<code>Notice</code> <code>ScalarSpecificationChanged</code>",
    ),
  )
  let encoded = report.to_json()
  let decoded : @moongqlimpact.Report = @json.from_json(encoded)
  assert_eq(decoded, report)
  assert_eq(
    @moongqlimpact.analyze_upgrade(old, next, [client]).to_json().stringify(),
    encoded.stringify(),
  )
}

///|
test "observed gate applies only reasons proven at the selection" {
  let old : @moongqlimpact.Source = {
    path: "old",
    text: "type Query { item(id: Int = 1): String }",
  }
  let next : @moongqlimpact.Source = {
    path: "next",
    text: "type Query { item(id: ID = \"2\"): String }",
  }
  let omitted : @moongqlimpact.Client = {
    name: "web",
    sources: [{ path: "web.graphql", text: "{ item }", }],
  }
  let explicit : @moongqlimpact.Client = {
    name: "mobile",
    sources: [{ path: "mobile.graphql", text: "{ item(id: 1) }", }],
  }
  let report = @moongqlimpact.analyze_upgrade(old, next, [omitted])
  assert_true(report.blocks())
  assert_true(report.blocks(severities=[Breaking]))
  assert_false(report.blocks(observed_only=true, severities=[Breaking]))
  assert_true(
    report.blocks(observed_only=true, reason_codes=[ArgumentDefaultChanged]),
  )
  assert_eq(
    report.changes[0].impacts[0].reason_codes,
    Some([ArgumentDefaultChanged]),
  )
  let report = @moongqlimpact.analyze_upgrade(old, next, [omitted, explicit])
  assert_true(report.blocks(observed_only=true, severities=[Breaking]))
  assert_eq(
    report.changes[0].impacts[1].reason_codes,
    Some([ArgumentTypeChanged]),
  )
}

///|
test "legacy JSON reports remain readable and block conservatively" {
  let original = @json.parse(
    (
      #|{"changes":[{"coordinate":"Query.gone","previous_type":"String","baseline":{"path":"old","line":1,"column":10},"impacts":[{"client":"web","operation":"View","response_path":["gone"],"selection":{"path":"web","line":1,"column":4}}]}]}
    ),
  )
  let report : @moongqlimpact.Report = @json.from_json(original)
  assert_true(report.changes[0].reasons is None)
  assert_true(report.changes[0].impacts[0].reason_codes is None)
  assert_true(report.blocks(observed_only=true, severities=[Breaking]))
  assert_eq(report.to_json(), original)
}
