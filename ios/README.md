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

await sdk.start(userId: "user-001")

let variant = levelGenerator.variant(default: "control")
let difficulty = levelGenerator.string("difficulty", default: "normal")
let result = levelGenerator.execute(.object(["turn": .number(7)]))
let adsEnabled = sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json")

let result = try await sdk.uploadEvents([
    GameAlgoEvent(
        userId: "user-001",
        sessionId: "session-001",
        eventType: "session_start",
        payload: .object([:])
    )
])
```

`start` refreshes `/v1/config` and preloads config files in the background. `executor` and `config` read the latest local snapshot, so gameplay code does not need to call remote APIs when checking variants or tuning values.

If an experiment assignment includes `script`, `executor.execute(state)` runs the preloaded JavaScript file through JSCore. Config-only experiments return their config as the execution payload.

Lower-level methods are still available when needed:

```swift
let config = try await sdk.fetchConfig(userId: "user-001")
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
```

The SDK sends `X-GameAlgo-Key` on every request, caches `/v1/config` by `ttlSeconds`, and fills default event fields for `platform`, `sdkVersion`, `appVersion`, `timestamp`, and `isDebug`.

## Check

```bash
swift test
```
