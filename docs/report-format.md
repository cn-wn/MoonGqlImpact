# JSON report contract

The native CLI writes a versioned JSON report for exit **0** or **1**. Exit **2** reports an input error. A successful analysis with no findings can look like this:

```json
{
  "format_version": 1,
  "changes": [],
  "coverage": [
    {
      "name": "flight-board",
      "sources": ["examples/apollo/flight-board.graphql", "examples/apollo/launch-date.graphql"],
      "operations": [
        {
          "name": "FlightBoard",
          "location": {"path": "examples/apollo/flight-board.graphql", "line": 1, "column": 1}
        }
      ]
    }
  ]
}
```

`changes` keeps the existing change and impact representation. `coverage` lists analyzed clients in registration order. Each entry includes all supplied source paths, including fragment-only files, and every baseline query checked for that client, including queries without findings. Locations use one-based lines and columns. An anonymous query uses `<anonymous>`. Schema-only analysis produces an empty `coverage` array. Coverage describes the supplied catalog and does not include unregistered clients or runtime variable values.

Reports produced by the current checker include `proposed_rejections`. It lists baseline-valid operations rejected by the proposed schema, with client, operation, source location, first validation diagnostic, and the breaking reason `ProposedOperationRejected`. An empty array means every registered operation passed static validation of both snapshots. Earlier version-1 reports omit this field and carry no proposed validation result. A schema-only run checks no operations.

Use `AnalyzedUpgrade::blocks` to evaluate both schema changes and operation rejections. The original `Report::blocks` evaluates the schema changes. Static acceptance leaves input coercion changes and response contract findings in `changes`.

`sample_assessments` appears when variable samples are supplied. Statuses are `Unchanged`, `CoercionChanged`, `VariableRejected`, and `OperationRejected`. The last status refers to the separate static operation rejection. Changed or rejected variables carry an input path such as `/filter/rules/0/status`. Sample rows include the sample ID, client and operation. Variable values stay in the input catalog. A sample must pass baseline coercion before it contributes upgrade evidence.

Field-argument evidence also supplies `argument_coordinate` (for example `Query.lookup(id:)`), `response_path` (the aliased path), and `selection` (the source location). In those rows, `path` starts at the argument map. The checker first validates variable declarations, then evaluates argument expressions and applicable defaults at the field sites. A rejection takes priority over a changed value. Successful samples retain the first variable difference, followed by the first field-argument difference when variable values match.

The field check follows sample-driven `@skip` and `@include` conditions and statically reachable fragments. Evidence for a field depends on the service reaching that selection. The checker uses SDL field definitions and does not simulate resolver results or concrete runtime object types.

## Compatibility

- A report without `format_version` uses the legacy `changes` format. Its client coverage is unknown.
- Version 1 readers should ignore unfamiliar object fields. Incompatible changes to field meanings, names, or types require a new format version.
- Reason codes are case-sensitive identifiers. Established codes retain their meaning and severity for this format version. New reason codes can appear within version 1. Generic consumers should keep unfamiliar codes as opaque strings and use the accompanying severity when applying a severity-based policy.
- MoonBit callers can use `analyze_upgrade_with_coverage` for the same versioned output as the CLI. Its typed decoder accepts version 1 and rejects reason codes the installed library cannot interpret. The existing `analyze_upgrade` and `Report` JSON API remain available for callers using the original report.

The [Apollo configuration](../examples/apollo/check.json) can be used to reproduce a report with registered client coverage.
