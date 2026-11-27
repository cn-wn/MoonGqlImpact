# Check sample values at field arguments

Run from the repository root:

```sh
moon run cmd/check --target native -- --config examples/argument-samples/check.json
```

Both operations pass static validation against both schemas. The sample-only gate exits **1** because explicit null reaches a newly non-null input location in two samples. An omitted variable still uses a location default. The analyzer reports an effective argument change if that default differs between snapshots.

| Sample | Outcome | Evidence |
| --- | --- | --- |
| `null-id` | `VariableRejected` | `Query.lookup(id:)`, response path `result`, input path `/id` |
| `missing-id` | `Unchanged` | Both snapshots apply the same argument default. |
| `present-id` | `Unchanged` | Both snapshots use the supplied ID. |
| `new-default` | `CoercionChanged` | `Query.search(filter:)`, response path `hits`, input path `/filter/tag` |
| `null-tag` | `VariableRejected` | `Query.search(filter:)`, response path `hits`, input path `/filter/tag` |
| `filtered` | `Unchanged` | The sample's `@include` condition disables the field. |
| `missing-item` | `Unchanged` | A missing variable inside the nullable list item is coerced to null. |

The fixtures were authored for this project under Apache-2.0. The CI differential check uses in-memory GraphQL.js 16.11.0 resolvers to observe argument coercion. The MoonBit analyzer uses no resolvers or network calls. [GraphQL field argument rules](https://spec.graphql.org/October2021/#sec-Coercing-Field-Arguments).
