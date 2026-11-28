///|
test "scalar rules apply independently to samples and literals" {
  let schema : @moongqlimpact.Source = {
    path: "schema",
    text: "scalar Decimal type Query { estimate(amount: Decimal!): String }",
  }
  let clients : Array[@moongqlimpact.Client] = [
    {
      name: "billing",
      sources: [
        {
          path: "query",
          text: "query Estimate($value: Decimal!) { estimate(amount:$value) } query Literal { estimate(amount:\"12.5\") }",
        },
      ],
    },
  ]
  let old : Map[String, (Json) -> Bool] = Map([
    ("Decimal", value => value is String(_)),
  ])
  let next : Map[String, (Json) -> Bool] = Map([
    ("Decimal", value => value is String("12.50")),
  ])
  let samples : Array[@moongqlimpact.VariableSample] = [
    {
      client: "billing",
      operation: "Estimate",
      id: "short",
      variables: @json.parse("{\"value\":\"12.5\"}"),
    },
    {
      client: "billing",
      operation: "Estimate",
      id: "fixed",
      variables: @json.parse("{\"value\":\"12.50\"}"),
    },
  ]
  let analysis = @moongqlimpact.analyze_upgrade_with_scalar_contracts(
    schema,
    schema,
    clients,
    samples,
    baseline_scalar_inputs=old,
    proposed_scalar_inputs=next,
  )
  assert_true(
    analysis.proposed_rejections is Some([{ operation: "Literal", .. }]),
  )
  assert_eq(analysis.sample_assessments.map(row => row.status), [
    VariableRejected,
    Unchanged,
  ])
  assert_eq(analysis.sample_assessments[0].path, Some("/value"))
  assert_true(
    analysis.blocks(observed_only=true, reason_codes=[VariableSampleRejected]),
  )
  let shared = @moongqlimpact.analyze_upgrade_with_samples(
    schema,
    schema,
    clients,
    samples,
    scalar_inputs=old,
  )
  assert_eq(shared.proposed_rejections, Some([]))
  assert_eq(shared.sample_assessments.map(row => row.status), [
    Unchanged,
    Unchanged,
  ])
}

///|
test "a scalar rule must name a declaration in its own snapshot" {
  let old : @moongqlimpact.Source = {
    path: "old",
    text: "scalar Date type Query { stamp: Date }",
  }
  let next : @moongqlimpact.Source = {
    path: "new",
    text: "type Query { stamp: String }",
  }
  let rules : Map[String, (Json) -> Bool] = Map([
    ("Date", value => value is String(_)),
  ])
  let accepted = @moongqlimpact.analyze_upgrade_with_scalar_contracts(
    old,
    next,
    [],
    [],
    baseline_scalar_inputs=rules,
    proposed_scalar_inputs=Map([]),
  )
  assert_eq(accepted.report.changes.length(), 1)
  let wrong = Ok(
    @moongqlimpact.analyze_upgrade_with_scalar_contracts(
      old,
      next,
      [],
      [],
      baseline_scalar_inputs=rules,
      proposed_scalar_inputs=rules,
    ),
  ) catch {
    error => Err(error)
  }
  assert_true(wrong is Err(@moongqlimpact.Invalid({ path: "new", .. }, _)))
}
