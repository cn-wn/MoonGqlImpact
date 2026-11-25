# Build and verify MoonGqlImpact 0.2.0

From a checkout of the desired revision, run the following with MoonBit installed. Install dependencies with `moon update` if they are missing.

```sh
moon build cmd/check --target native --release --deny-warn
moon package
```

The package archive is written to `_build/publish/cn-wn-moongqlimpact-0.2.0.zip`. On Linux, these two scripts verify the archive and the representative workload:

```sh
moon run --deny-warn scripts/release_check.mbtx
moon run --deny-warn scripts/scale.mbtx
```

The first script unpacks the archive in a fresh temporary workspace, runs its native CLI on the offline variable-sample catalog, and compiles and runs a separate JavaScript consumer of the public API. The consumer uses a local `moon.work` dependency and Node. Registry publication is independent of this check. See the [MoonBit workspace dependency guide](https://docs.moonbitlang.com/en/stable/toolchain/moon/module.html#dependency-management).

The scale workload derives 512 queries and 512 mutations from the authored [read/write case](../examples/mutations/README.md). All operations share fragments. A simulated output nullability change produces 2,048 source-level impacts while all operations remain statically valid. The script checks byte-for-byte repeatability, the fragment expansion limit, and a successful small analysis after the rejected run. It prints wall time and peak RSS for one invocation of the optimized native binary. One local Linux-on-WSL run measured **0.08 s** and **9,880 KiB**. This is a workload observation without a comparison baseline or cross-platform performance claim.

CI additionally runs the regular tests on Wasm, Wasm-GC, JavaScript, and native Linux, macOS, and Windows. GraphQL.js remains a verification dependency for the Linux differential checks.
