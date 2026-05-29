# GameAlgo iOS SDK

Swift Package implementation for Protocol v1.

## Install

For remote SwiftPM integration, add the client repository and select the `GameAlgoSDK` product:

```text
https://github.com/dirichlet-ai/GameAlgoClient.git
```

During pre-release integration, use the `main` branch. After release tags are available, use an `Up to Next Major Version` rule.

If you are developing this package locally, this `ios/` directory can also be opened directly as a Swift package.

Then import the library product:

```swift
import GameAlgoSDK
```

## Minimum API

```swift
let sdk = GameAlgoSDK(
    gameKey: "ga_live_xxx",
    baseURL: URL(string: "https://gamealgo.example.com")!
)
```

## Usage

```swift
let levelGenerator = sdk.executor("level_generator")

sdk.start()

let variant = levelGenerator.variant(default: "control")
let difficulty = levelGenerator.string("difficulty", default: "normal")
let result = levelGenerator.execute(.object(["turn": .number(7)]))
let adsEnabled = sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json")

await sdk.tracker.trackSessionStart()
await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3), "result": .string("win")]))
await sdk.tracker.flush()
```

`start` refreshes `/v1/config` and preloads config files in the background. It also creates or reuses the SDK anonymous `userId`; iOS uses the same `gamealgo_user_id` key as the old SDK, so existing players keep stable experiment assignments after updating. `executor` and `config` read the latest local snapshot, so gameplay code does not need to call remote APIs when checking variants or tuning values.

Files created under the admin Configs page can be fetched directly when needed:

```swift
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
```

The SDK logs user id, config fetch, experiment assignment, config file, and script preload status to the console by default. Pass `logger: nil` to silence logs, or provide a custom `GameAlgoLogHandler`.

If an experiment assignment includes `script`, `executor.execute(state)` runs the preloaded JavaScript file through JSCore. Config-only experiments return their config as the execution payload.

`tracker` queues events in memory, uploads at most 100 events per batch, flushes every 30 seconds, flushes when the app enters background or terminates, and keeps the failed batch for the next retry. Call `await sdk.tracker.flush()` to manually flush critical events; `trackSessionEnd` also triggers an immediate flush after enqueueing `session_end`.

Standard events attach current experiment variants by default. Custom events do not; call `await sdk.tracker.trackEvent("button_click", includeExperiments: true)` when a custom event should include them.

Lower-level methods are still available when needed:

```swift
let config = try await sdk.fetchConfig()
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
let response = try await sdk.uploadEvents([
    GameAlgoEvent(userId: sdk.userId, sessionId: "session-001", eventType: "session_start")
])
```

The SDK sends `X-GameAlgo-Key` on every request, caches `/v1/config` by `ttlSeconds`, and fills default event fields for `platform`, `sdkVersion`, `appVersion`, `timezone`, `timestamp`, and `isDebug`.

## Check

```bash
swift test
```
