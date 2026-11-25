# Check a mixed read/write client

The authored fixture models GitHub's public `createIssue` API with a small SDL and a simulated release that makes `labelIds` required. It uses synthetic IDs and makes no network calls. Names and field semantics were checked against the [GitHub GraphQL Issues reference](https://docs.github.com/en/graphql/reference/issues#createissue). The fixture is distributed under this repository's Apache-2.0 license.

```sh
moon run cmd/check --target native -- --observed-only --fail-on=breaking examples/mutations/old.graphql examples/mutations/new.graphql issue-client examples/mutations/operations.graphql
```

Expect exit **1** and a breaking change at `CreateIssueInput.labelIds`. The versioned report lists all three operations. Only `OpenWithoutLabels` is rejected by the new schema. The input impact identifies the aliased response path `added`. Both compatible operations continue to resolve their shared fragment.
