# Changelog

## 0.1.0

- Compare two local GraphQL SDL snapshots and trace output regressions to clients, operations, response paths and source positions.
- Detect field removal, output type changes, weaker nullability and changes to output enum values. Enum additions and removals both trigger the conservative gate.
- Check local files from CI with strict, observed-only or schema-only policies. The [Apollo example](README.md#try-the-apollo-11-example) exercises all three.
- Use the portable MoonBit library on Wasm, Wasm-GC, JavaScript or native. The CLI runs on native Linux, macOS and Windows.

The [supported profile](README.md#supported-profile) describes which SDL and query constructs the analyzer accepts. Field arguments, input compatibility, interfaces, unions and mutation operations remain outside this release.
