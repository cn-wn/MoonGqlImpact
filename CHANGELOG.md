# Changelog

## Unreleased

- Compare independent custom scalar input rules on the baseline and proposed schemas.
- Check sample values at field arguments, including omitted variables, explicit nulls, and nested defaults.

## 0.2.0

- Verify the release archive with an unpacked native CLI, an independent downstream consumer, and a 1,024-operation workload in CI.
- Compare offline variable samples between snapshots and support explicit input rules for custom scalars.
- Analyze query and mutation operations together, including changed write inputs and mutation-root removal.
- Validate registered queries against both snapshots and report changes from new argument and input field defaults.
- Version the CLI JSON report and record the analyzed client, source, and operation coverage.
- Load client catalogs and gate policy from a checked-in JSON configuration.
- Analyze nested input objects and extensions, with field-level evidence for validation failures, runtime variable risks, and changed defaults.
- Cross-check nested coercion, alias merging, and fragment validity with GraphQL.js 16.11.0 in CI.

- Verify compatible, affected, and unsupported queries in CI against a pinned public SWAPI schema.

- Analyze interfaces and unions, report changes in possible object types, and pinpoint fragments that become impossible.

- Add structured reason codes and severity levels to JSON and Markdown reports. CI can use `--fail-on` to block selected findings.

- Analyze field arguments and operation variables for built-in scalar, enum and list inputs. Reports trace input regressions and default changes to affected operations.

- Include values from enum extensions and track custom scalar specification URL changes through client queries.
- Generate escaped Markdown reports from the library and native CLI with `--markdown`.
- Reject repeated or empty operation source paths within a client to preserve unambiguous impact evidence.
- Refresh generated interfaces against MoonBit 0.1.20261119.

## 0.1.0

- Compare two local GraphQL SDL snapshots and trace output regressions to clients, operations, response paths and source positions.
- Detect field removal, output type changes, weaker nullability and changes to output enum values. Enum additions and removals both trigger the conservative gate.
- Check local files from CI with strict, observed-only or schema-only policies. The [Apollo example](README.md#try-the-apollo-11-example) exercises all three.
- Use the portable MoonBit library on Wasm, Wasm-GC, JavaScript or native. The CLI runs on native Linux, macOS and Windows.

The [supported profile](README.md#supported-profile) describes which SDL and query constructs the analyzer accepts. Field arguments, input compatibility, interfaces, unions and mutation operations remain outside this release.
