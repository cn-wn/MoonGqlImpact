# SWAPI upgrade check

This scenario uses the complete public SWAPI GraphQL schema at revision
`8c0bf5868f11fe84942548180751fceeb36bd606`. The runner reads the upstream SDL
and example queries from a local checkout. It prepares a proposed schema in a
temporary directory by removing `implements Node` from `Starship`.

Run from MoonGqlImpact on Linux or WSL. The first checkout needs public GitHub
access. The check reads local files once the checkout and MoonBit dependencies
are available.

```sh
git clone https://github.com/graphql/swapi-graphql.git ../swapi-graphql
git -C ../swapi-graphql checkout --detach 8c0bf5868f11fe84942548180751fceeb36bd606
moon run --deny-warn scripts/swapi.mbtx -- ../swapi-graphql
```

The runner verifies that comparing the baseline to itself passes. It then
checks three outcomes against the proposed schema.

| Operation | Expected result under `--observed-only` |
| --- | --- |
| Upstream `07_fragments.graphql` | Exit **0**. Its `Starship` fragment selects a concrete object reached through `allStarships`. The report still lists the global `Node` membership change. |
| `StarshipDetails` | Exit **1**. `Root.node` returns `Node`, so `... on Starship` can no longer match. The single impact points to that spread. |
| Upstream `08_introspection.graphql` | Exit **2**. The diagnostic identifies the introspection selection as outside the supported query profile. |

The proposed version is a simulated upgrade. The example's authored
`node-starship.graphql` query and the runner use this repository's Apache-2.0
license. The upstream files are read from their original checkout with the
upstream [MIT examples notice][upstream-license].

[Upstream schema][schema] · [Fragments query][fragments] · [Introspection query][introspection]

[schema]: https://github.com/graphql/swapi-graphql/blob/8c0bf5868f11fe84942548180751fceeb36bd606/schema.graphql
[fragments]: https://github.com/graphql/swapi-graphql/blob/8c0bf5868f11fe84942548180751fceeb36bd606/doc/example_queries/07_fragments.graphql
[introspection]: https://github.com/graphql/swapi-graphql/blob/8c0bf5868f11fe84942548180751fceeb36bd606/doc/example_queries/08_introspection.graphql
[upstream-license]: https://github.com/graphql/swapi-graphql/blob/8c0bf5868f11fe84942548180751fceeb36bd606/LICENSE-examples
