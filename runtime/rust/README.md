# GameAlgo Rust script runtime

This crate is the canonical JavaScript strategy runtime for REST/Server, iOS,
and Android. Every invocation creates an isolated QuickJS context owned by
Rust. It exposes no
network, filesystem, process, environment, module loader, host callbacks,
clock, random source, or dynamic code generation. Input and output are JSON.

The host enforces script/input/output byte limits plus memory, stack, execution
time, and interrupt-poll budgets. Native clients use the C ABI in
`include/gamealgo_runtime.h`;
Node and Server use the stdin/stdout binary adapter.

```bash
cargo test --manifest-path runtime/rust/Cargo.toml
printf '%s' '{"script":"function execute(i){return i}","input":{"ok":true}}' \
  | cargo run --quiet --manifest-path runtime/rust/Cargo.toml
```

Rebuild the checked-in Apple binary after every runtime change:

```bash
runtime/rust/build-apple-xcframework.sh
swift test --package-path ios
```

The script builds iOS device, iOS simulator, and macOS slices from this crate.
Android Gradle builds its ABI-specific shared libraries from the same source.
