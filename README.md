# MoonGqlImpact

MoonGqlImpact is an offline MoonBit library and CI tool for GraphQL query output upgrades. Compare two SDL snapshots and see which registered client operations rely on a removed field or a weakened output type. A query can remain valid after `[Mission!]!` becomes `[Mission]!`, while generated clients may still assume every item is non-null.

## Try the Apollo 11 example

Install [MoonBit](https://www.moonbitlang.com/download/) (verified with moon 0.1.20261102), clone this repository, and run from its root:

```sh
moon update
moon run cmd/check --target native -- examples/apollo/old.graphql examples/apollo/new.graphql flight-board examples/apollo/flight-board.graphql flight-board examples/apollo/launch-date.graphql crew-roster examples/apollo/crew-roster.graphql
```

The JSON report identifies `Mission.launchDate` at the flight board's fragment and `Mission.crew` in the roster query. The recorded Apollo 11 crew and launch date illustrate the data being consumed. The proposed schema is an example upgrade, and the checker reads the SDL and query files directly. After dependencies are installed, the example runs offline.

Exit status **0** means no regression within the supported profile. **1** means the report contains regressions, including regressions with no registered consumer. **2** means input is invalid, unsupported, or unreadable. Pass multiple files under the same client name to resolve shared fragments across files.

For a rollout gated on known consumers, pass `--observed-only` before the two schema paths. The CLI still emits the full report and returns **1** only if a registered operation has an impact. Invalid or unsupported inputs still return **2**. A report with no observed impact only describes the supplied catalog.

## Where to use it

- **Server release gate.** Export the current and proposed SDL in a pull request. Check them with queries from the web and mobile clients. Use the reported locations to restore the old field contract or coordinate a client release.
- **Shared fragment migration.** Supply each client's query files and their shared fragment files. Locate operations affected by a changed field inside the fragment, including the response keys they actually consume.
- **Vendor upgrade review.** Save the old and new SDL for a supported vendor API and check them against locally stored queries. Separate observed client impact from global regressions with no catalog evidence.

## Library

Call `analyze_upgrade(baseline, proposed, clients)` with named `Source` values and client-grouped query files. The report carries old and proposed field types and locations, plus client, operation, aliased response path and query location for each observed impact. It is JSON-serializable. Files are visited in input and declaration order. Repeated spreads of the same fragment at the same response path produce one impact per source selection. Other aliases and separately written selections retain their own evidence.

## Supported profile

Query-only SDL with object types, a default or explicit query root, built-in and declared custom scalar leaves, and nested list/non-null wrappers. The query root must keep its name. Custom scalars are opaque by name, so their serializer behavior is outside the analysis. Scalar directives are rejected. Executable documents support named queries or a sole anonymous query per client (reported as `<anonymous>`), aliases, the `__typename` meta-field, and named and inline fragments on the matching object type. The core is portable. The CLI reads local UTF-8 files on native targets.

Use `extend type` to add fields to an existing object within the same SDL snapshot. Extended fields retain their declaration locations. An output field may carry `@deprecated` with an optional reason. Deprecation metadata alone does not change the output contract. A later field removal still reports affected queries.

Selections may use `@include(if: true)` or `@skip(if: false)` with either literal boolean. The report retains dependencies in every branch because GraphQL validates fields before evaluating execution directives.

The checker rejects parameters and variables, other directives, interfaces and unions, enums, mutations, subscriptions, schema introspection (`__schema` and `__type`), and extensions other than object field additions. Each source is capped at 1,000,000 string code units. The parser limits syntax nesting to 50, and each operation has separate limits for expanded depth and selection count. The tool reports output contract changes for the supplied snapshots. It does not establish compatibility of an entire production schema or infer usage by clients outside the catalog.

## Sources and roadmap

The [moonbit-community/graphql parser](https://github.com/moonbit-community/graphql.mbt) (Apache-2.0, 0.1.1) provides GraphQL syntax and positions. The output comparison and operation tracing are implemented here. The [GraphQL October 2021 specification](https://spec.graphql.org/October2021/) is the semantic reference. [NASA Apollo 11](https://www.nasa.gov/mission/apollo-11/) is the factual source for the launch date and crew names. The example schemas and queries are authored for this repository. The native CLI uses [moonbitlang/x](https://github.com/moonbitlang/x) (Apache-2.0). The [MoonBit async package](https://github.com/moonbitlang/async) (Apache-2.0) runs the end-to-end check with `moon run --deny-warn scripts/demo.mbtx`.

Next capabilities are input compatibility, then enum and abstract output impact. Project license is Apache-2.0.
