# Compare scalar contracts with identical SDL

Run `moon run cmd/check --target native -- --config examples/scalar-contracts/check.json`. A billing service changes its accepted Decimal representation to require two decimal places. The SDL stays identical. The short sample is rejected and the explicit two-place sample passes. The report also rejects the registered legacy literal during proposed static validation.

The fixtures use synthetic values and are covered by this repository's Apache-2.0 license.
