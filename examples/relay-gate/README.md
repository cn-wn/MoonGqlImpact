# Rehearse a CI gate with Relay Todo

The gate reads the full public Relay Todo SDL and two actual Relay compiler operations, `TodoAppQuery` and `ChangeTodoStatusMutation`. The script extracts their GraphQL text without executing TypeScript. It builds the versioned MoonGqlImpact archive in a clean temporary directory and uses one [checked-in policy](check.json) for all cases.

```sh
git clone https://github.com/relayjs/relay-examples.git ../relay-examples-gate
git -C ../relay-examples-gate checkout --detach 2aa07233ab23e96bf9ccc98de435db069a32b7eb
moon package
moon run --deny-warn scripts/relay_gate.mbtx -- _build/publish/cn-wn-moongqlimpact-0.2.0.zip ../relay-examples-gate
```

The three simulated pull requests exercise an additive mutation rollout, removal of the API still used by the write client, and restoration with deprecation. Expected exit statuses are **0**, **1**, and **0**. The breaking report names the write operation and its source selection while the original read operation still validates.

The upstream files are fetched at the pinned revision and remain under the upstream [MIT license](https://github.com/relayjs/relay-examples/blob/2aa07233ab23e96bf9ccc98de435db069a32b7eb/LICENSE). Source files are the [SDL](https://github.com/relayjs/relay-examples/blob/2aa07233ab23e96bf9ccc98de435db069a32b7eb/todo/schema.graphql), [read operation](https://github.com/relayjs/relay-examples/blob/2aa07233ab23e96bf9ccc98de435db069a32b7eb/todo/src/__generated__/TodoAppQuery.graphql.ts), and [write operation](https://github.com/relayjs/relay-examples/blob/2aa07233ab23e96bf9ccc98de435db069a32b7eb/todo/src/__generated__/ChangeTodoStatusMutation.graphql.ts).
