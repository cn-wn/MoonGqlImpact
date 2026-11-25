# MoonGqlImpact

MoonGqlImpact is an offline MoonBit library and CI tool for GraphQL query contract upgrades. Compare two SDL snapshots and see which registered client operations rely on a removed field or a weakened output type. A query can remain valid after `[Mission!]!` becomes `[Mission]!`, while generated clients may still assume every item is non-null.

See the [0.1.0 release notes](CHANGELOG.md) and the [checked library example](README.mbt.md).

## Try the Apollo 11 example

Install [MoonBit](https://www.moonbitlang.com/download/) (verified with moon 0.1.20261119), clone this repository, and run from its root:

```sh
moon update
moon run cmd/check --target native -- examples/apollo/old.graphql examples/apollo/new.graphql flight-board examples/apollo/flight-board.graphql flight-board examples/apollo/launch-date.graphql crew-roster examples/apollo/crew-roster.graphql
```

The JSON report identifies `Mission.launchDate` at the flight board's fragment and `Mission.crew` in the roster query. The recorded Apollo 11 crew and launch date illustrate the data being consumed. The proposed schema is an example upgrade, and the checker reads the SDL and query files directly. After dependencies are installed, the example runs offline.

Exit status **0** means the check passes the selected gate. **1** means a finding blocks the upgrade. By default, every finding counts, including findings without a registered consumer. **2** means input is invalid, unsupported, or unreadable. Pass multiple files under the same client name to resolve shared fragments across files.

For a rollout gated on known consumers, pass `--observed-only` before the two schema paths. The CLI still emits the full report and returns **1** only if a registered operation has an impact. Invalid or unsupported inputs still return **2**. A report with no observed impact only describes the supplied catalog.

For an initial rollout without a client catalog, run `moon run cmd/check --target native -- --schema-only OLD.graphql NEW.graphql`. The report shows global regressions with empty impact lists, and any regression returns **1**. This mode takes only the two schema paths.

Run `moon run cmd/check --target native -- --help` to see the accepted command forms and exit codes.

Place `--markdown` before the schema paths to produce a readable report for a CI job summary. For example, run `moon run cmd/check --target native -- --markdown --schema-only examples/apollo/old.graphql examples/apollo/new.graphql`. Its exit status follows the selected policy, and the report includes every change.

## Choose what blocks CI

Use `--fail-on=breaking` to block on query or contract incompatibilities while keeping other findings in the report. The option accepts a comma-separated list of levels and exact reason codes, such as `--fail-on=breaking,OutputEnumValueAdded`. Supply options before the schema paths.

| Level | Reason codes |
| --- | --- |
| `breaking` | `FieldRemoved`, `OutputTypeChanged`, `OutputNullabilityWeakened`, `ArgumentRemoved`, `RequiredArgumentAdded`, `ArgumentBecameRequired`, `ArgumentTypeChanged`, `InputEnumValueRemoved` |
| `risk` | `OutputEnumValueAdded`, `OutputEnumValueRemoved`, `ArgumentDefaultChanged` |
| `notice` | `ScalarSpecificationChanged` |

`FieldRemoved` describes a selection that fails validation. `OutputNullabilityWeakened` describes a weaker response guarantee, even when the query remains valid. An enum addition can affect consumers that handle every known value explicitly. A scalar specification URL change records a change in the declaration.

Without a filter, the gate considers every reported change. With `--observed-only`, a selected reason must apply to at least one registered selection. An invalid category or input returns **2**. JSON includes `reasons` with a code and severity for each change, plus `reason_codes` for each impact. Markdown displays the same breakdown. Library callers can use `Report::blocks` with severity or reason-code filters. Older reports without reason metadata remain readable and are treated conservatively by the gate.

## Check an argument upgrade

The example changes `user(id: ID)` to `user(id: ID!)` with no change to the return type.

```sh
moon run cmd/check --target native -- --observed-only examples/arguments/old.graphql examples/arguments/new.graphql desktop examples/arguments/desktop.graphql mobile examples/arguments/mobile.graphql
```

The report identifies `Query.user(id:)`. The mobile operations `EditProfile` and `CurrentUser` are affected because one supplies a nullable variable and the other omits the argument. The desktop operation uses a non-null variable and can keep its query. Run with the desktop operation alone to pass `--observed-only` while still seeing the global change.

## Where to use it

- **Server release gate.** Export the current and proposed SDL in a pull request. Check them with queries from the web and mobile clients. Use the reported locations to restore the old field contract or coordinate a client release.
- **Shared fragment migration.** Supply each client's query files and their shared fragment files. Locate operations affected by a changed field inside the fragment, including the response keys they actually consume.
- **Vendor upgrade review.** Save the old and new SDL for a supported vendor API and check them against locally stored queries. Separate observed client impact from global regressions with no catalog evidence.

## Library

Call `analyze_upgrade(baseline, proposed, clients)` with named `Source` values and client-grouped query files. The report carries old and proposed field types and locations, plus client, operation, aliased response path and query location for each observed impact. It is JSON-serializable. Use `report.to_markdown()` for a review report containing every change and client impact, with escaped catalog labels and source paths. Each client must supply unique, nonempty source paths so diagnostics and evidence can identify a file unambiguously. The same path may be used by different clients. Files are visited in input and declaration order. Repeated spreads of the same fragment at the same response path produce one impact per source selection. Other aliases and separately written selections retain their own evidence.

## Supported profile

Query-only SDL with object types, a default or explicit query root, built-in and declared custom scalar leaves, and nested list/non-null wrappers. The query root must keep its name. Custom scalars are opaque by name, so their serializer behavior is outside the analysis. Custom scalar `@specifiedBy(url: "...")` declarations are preserved in reports. Adding, removing or changing their URL is reported as a notice for fields returning that scalar. URLs are compared as text and are never fetched. Other scalar directives are rejected. Executable documents support named queries or a sole anonymous query per client (reported as `<anonymous>`), aliases, the `__typename` meta-field, and named and inline fragments on the matching object type. The core is portable. The CLI reads local UTF-8 files on native targets.

Use `extend type` to add fields to an existing object within the same SDL snapshot. Extended fields retain their declaration locations. An output field may carry `@deprecated` with an optional reason. Deprecation metadata alone does not change the output contract. A later field removal still reports affected queries.

Selections may use `@include(if: true)` or `@skip(if: false)` with either literal boolean or a Boolean variable declared by the operation. Use `Boolean!` or `Boolean` with a non-null boolean default. The report retains dependencies in every branch because GraphQL validates fields before evaluating execution directives.

Output enums are checked by value set, including values added through `extend enum`. Extensions can precede the enum definition. Duplicate values and missing base enums are rejected. Adding or removing a value flags affected fields and registered queries. Additions can affect exhaustive client code, and removals change the documented result domain. Both are classified as risks and count toward the default gate. Reports render enum domains as `Status{READY, WAITING}` inside their original list and nullability wrappers.

Field arguments and variables support built-in scalars, enums, and nested lists. The checker reports removed arguments, new required arguments, type changes that can affect existing values, input enum narrowing, and changes in defaults on existing arguments. It validates baseline uses and attributes changes to the affected operation. Variables declared nullable can still carry an explicit null even if their default lets the query pass validation. Arguments appear as coordinates such as `Query.user(id:)` with their type and default in the existing JSON shape. Schema locations point to argument declarations, and operation locations point to the field selection. For a new required argument, the previous type is `<absent>` and the baseline location points to the field.

The checker rejects input objects, custom scalar inputs, argument directives, interfaces and unions, mutations, subscriptions, schema introspection (`__schema` and `__type`), and extensions other than object field and enum value additions. Each source is capped at 1,000,000 string code units. The parser limits syntax nesting to 50, and each operation has separate limits for expanded depth and selection count. The tool reports supported input and output contract changes for the supplied snapshots. It does not establish compatibility of an entire production schema or infer usage by clients outside the catalog.

## Sources and roadmap

The [moonbit-community/graphql parser](https://github.com/moonbit-community/graphql.mbt) (Apache-2.0, 0.1.1) provides GraphQL syntax and positions. The output comparison and operation tracing are implemented here. The [GraphQL October 2021 specification](https://spec.graphql.org/October2021/) is the semantic reference. [NASA Apollo 11](https://www.nasa.gov/mission/apollo-11/) is the factual source for the launch date and crew names. The example schemas and queries are authored for this repository. The native CLI uses [moonbitlang/x](https://github.com/moonbitlang/x) (Apache-2.0). The [MoonBit async package](https://github.com/moonbitlang/async) (Apache-2.0) runs the end-to-end check with `moon run --deny-warn scripts/demo.mbtx`.

Next capabilities are input object compatibility and abstract output impact. Project license is Apache-2.0.
