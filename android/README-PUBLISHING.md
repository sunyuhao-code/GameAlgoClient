# Android release

The Android SDK is a standard Gradle Android Library with Maven coordinates:

```text
ai.dirichlet.gamealgo:gamealgo-android:<version>
```

The AAR embeds the canonical Rust + QuickJS runtime for `armeabi-v7a`,
`arm64-v8a`, and `x86_64`. Building requires Rust, `cargo-ndk`, and Android NDK
`27.2.12479018`.

Build all release artifacts with the checked-in wrapper:

```bash
cd android
./gradlew clean releaseArtifacts
```

Override the release version with `-PGAMEALGO_ANDROID_VERSION=1.2.3`. The AAR is
written to `build/outputs/aar/` and the test Maven repository to `build/repo/`.
The `sample` application is compiled against the project AAR API on every CI
run. CI also writes `build/SHA256SUMS` for the AAR and local Maven repository,
then verifies every checksum before uploading the release artifact. Publishing
to a remote repository is intentionally performed by release CI so credentials
never live in this repository.

Supported baseline:

- minSdk 24
- compileSdk 35
- Java 8 bytecode
- no transitive Android runtime dependency

The packaged runtime accepts and returns JSON only. It exposes no network,
filesystem, process, environment, module-loading, clock, random-number, or
dynamic-code API to strategy scripts. Runtime memory, stack, input, output, and
execution-time limits fail closed with a `GameAlgoException`.
