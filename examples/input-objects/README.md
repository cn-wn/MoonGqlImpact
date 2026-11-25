# Exercise a nested input contract upgrade

This catalog models a book search that starts requiring a status on each filter rule. The proposed schema also weakens the result nullability and removes one possible union member. Run from the repository root:

```sh
moon run cmd/check --target native -- --observed-only --markdown examples/input-objects/old.graphql examples/input-objects/new.graphql web examples/input-objects/queries.graphql
```

Expect status **1** and findings for four coordinates:

| Coordinate | Expected evidence |
| --- | --- |
| `Rule.status` | `Missing`, `Null`, and `Default` use values the proposed schema rejects. `Runtime` is still valid and may receive a rejected value. `Safe` and `Merge` supply a compatible status. |
| `BookFilter.maxCount` | Adding an optional field with a default changes the coerced inputs for clients that supply a filter without that field. The finding is a risk and does not invalidate their query. |
| `Query.books` | Its proposed output can be null. This weakens the response contract even for `Safe` and `Merge`. |
| `Result` | `BookResult` spreads an impossible fragment. `FilmResult` can keep its fragment. |

The conflicting aliases in `invalid-merge.graphql` exercise the CLI's input-error exit **2**. To run the same differential check as CI:

```sh
npm install --prefix _build/graphql-oracle --no-package-lock --ignore-scripts --no-audit --no-fund graphql@16.11.0
moon run --deny-warn scripts/graphql_oracle.mbtx -- _build/graphql-oracle/node_modules/graphql
```

In JSON, the four newly rejected operations also appear in the proposed_rejections array. The script compares static validity with [GraphQL.js 16.11.0](https://github.com/graphql/graphql-js/releases/tag/v16.11.0) and checks concrete variable coercion with the reference library. It separately checks the CLI's weaker output guarantee and runtime input risk. The fixtures are authored for this repository. GraphQL.js is a test dependency under [MIT](https://github.com/graphql/graphql-js/blob/v16.11.0/LICENSE).
