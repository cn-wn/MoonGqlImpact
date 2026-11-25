# Verify scrubbed variable samples offline

Run the project-authored search example from the repository root:

```sh
moon run cmd/check --target native -- --config examples/variables/check.json
```

The configured gate exits **1**. Both operations still pass static validation. The sample named `missing-status` now fails coercion at `/filter/status`. The `ready` sample still works and picks up the new default at `/filter/maxCount`. The `health-check` sample is unchanged.

Use a JSON array of samples, each with a registered client name, operation name, sample ID, and variables object. Use synthetic or scrubbed values and keep confidential files outside version control. Reports carry sample IDs, statuses, paths and type diagnostics. They contain no variable values. A baseline-invalid sample is an input error.

This fixture uses a string transport rule for `DateTime` and a plain decimal string rule for `Decimal`. The string rule checks JSON shape. Applications can supply an exact validator through the library API. The fixture and samples are distributed under the repository's Apache-2.0 license.
