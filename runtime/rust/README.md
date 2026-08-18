# GameAlgo Rust script runtime

This crate is the canonical JavaScript strategy runtime for REST/Server and
iOS. It also exposes JNI bindings that an Android integration may package,
but the current lightweight Android AAR intentionally does not embed a native
JavaScript engine and requires the app to inject `GameAlgoScriptRuntime`.
A script is parsed once when it is preloaded and its prepared GameAlgo runtime
context is reused for subsequent executions. It exposes no
network, filesystem, process, environment, module loader, host callbacks,
clock, random source, or dynamic code generation. Input and output are JSON.

The host enforces a 10 MiB script-source limit, a 256 KiB input limit, and a
256 KiB output limit, plus memory, stack, execution-time, and interrupt-poll
budgets. The 10 MiB limit is for the script source only; it does not increase
the input limit. Native clients use the C ABI in
`include/gamealgo_runtime.h`; Node and Server use the persistent line-based
stdin/stdout adapter, which keeps a bounded LRU cache of prepared scripts.

Script preparation has a separate load timeout. It is intentionally longer
than the per-execution budget because parsing a large script is not gameplay
execution. The default execution budget is 1 second per call. It remains a
hard runtime safety limit and cannot be disabled by a game.

Strategy scripts should be written as stateless functions. Keep top-level data
in `const` bindings and do not use top-level `let`/`var`, counters, or mutate
top-level arrays and objects. Local `let`/`const` variables inside
`execute(input)` are fine. Since prepared contexts are reused across calls,
this is a script author contract; the runtime does not enforce it with an AST
validator.

```bash
cargo test --manifest-path runtime/rust/Cargo.toml
printf '%s' '{"script":"function execute(i){return i}","input":{"ok":true}}' \
  | cargo run --quiet --manifest-path runtime/rust/Cargo.toml
```

Rebuild the checked-in Apple binary after every runtime change:

```bash
runtime/rust/build-apple-dynamic-xcframework.sh
swift test --package-path ios
```

For iOS-only distribution, build an XCFramework without the macOS slice:

```bash
runtime/rust/build-ios-xcframework.sh
```

The full Apple build keeps the macOS slice for local macOS Swift tests. The
iOS-only artifact is the smaller distribution package for iOS consumers.

The checked-in Apple package uses a dynamic framework so the final iOS app can
link the size-optimized runtime without carrying the full static archive.

For an iOS-only dynamic distribution package, use:

```bash
runtime/rust/build-ios-dynamic-xcframework.sh
```

The dynamic package links the size-optimized runtime as an iOS framework
instead of distributing a static archive. It is substantially smaller, but
the consuming app must embed and sign the dynamic framework. Xcode and Swift
Package Manager normally handle this for an app target; framework-to-framework
consumers must ensure the final app embeds it.

The old `build-apple-xcframework.sh` and `build-ios-xcframework.sh` scripts
remain available for static-library builds and compatibility experiments.

The release profile uses size-oriented optimization, fat LTO, symbol stripping,
and abort-on-panic. The consuming Xcode target should also enable dead-code
stripping for the final app; the size of a static archive is not the same as
the runtime size added to the IPA.

The Apple build scripts produce iOS device, iOS simulator, and macOS slices
from this crate.
