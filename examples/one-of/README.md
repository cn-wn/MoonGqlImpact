# Change an input object to @oneOf

Run `moon run cmd/check --target native -- --config examples/one-of/check.json`. A lookup accepts exactly one of `id` and `username`. The gate exits **1** and reports the schema change at `Match`. Four operations fail static validation. The whole-object variable remains statically valid, but three of its four sample values fail coercion.

The authored fixtures are covered by the repository's Apache-2.0 license. The [OneOf input rules](https://spec.graphql.org/September2025/#sec-OneOf-Input-Objects) define the input behavior.
