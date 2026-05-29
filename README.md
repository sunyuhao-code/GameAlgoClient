# GameAlgo Client

Future repository for game teams integrating GameAlgo.

## Audience

This project should be safe to share with game teams. Keep it focused on client integration and public protocol behavior.

## Layout

```text
protocol/   Public copy of Protocol v1
ios/        iOS SDK
android/    Android SDK
rest-api/   REST API integration guide and examples
examples/   Runnable integration examples
docs/       Client-facing docs
```

## Current Implementation

Implemented client surfaces:

- TypeScript REST helper under `rest-api/src/`
- Swift Package iOS SDK under `ios/`
- Dependency-free Java Android core under `android/`

Run checks:

```bash
npm run check
cd ios && swift test
cd android && javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
cd android && java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```

## Client Model

Client SDKs expose a local snapshot model:

- `start` / `startAsync` refreshes `/v1/config` and preloads config files.
- `executor(key)` reads experiment variant and experiment config from memory.
- `executor(key).execute(state)` executes preloaded script experiments or returns config-only payloads.
- `config` / `config()` reads preloaded config files from memory.
- startup first restores the last successful snapshot, then always refreshes remote config and overwrites the snapshot on success.
- lower-level `fetchConfig` and `fetchConfigFile` remain available for manual control.

## Rules

- Use `X-GameAlgo-Key` for game authentication.
- iOS, Android, and REST API must use the same `/v1/*` protocol.
- Do not include server implementation, dashboard admin code, internal SQL, deploy scripts, credentials, or production key values.

Initial implementation should migrate from `../legacy/gamealgo-sdk-current/` after the Protocol v1 server behavior is stable.

## Release Boundary

Anything in this project may be exposed to integration teams. Keep internal implementation details in `../gamealgo-server/`.
