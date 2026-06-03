# GameAlgo Android SDK

Android-compatible SDK core for Protocol v1.

This implementation is dependency-free Java so it can be wrapped by an Android AAR or Kotlin facade later without changing the client/server protocol.

## Minimum API

```kotlin
val sdk = GameAlgo.init("ga_live_xxx", "https://gamealgo.example.com")
```

## Usage

```kotlin
val levelGenerator = sdk.executor("level_generator")

sdk.startAsync()

val variant = levelGenerator.variant("control")
val difficulty = levelGenerator.string("difficulty", "normal")
val result = levelGenerator.execute(mapOf("turn" to 7))
val adsEnabled = sdk.config().bool("ads.rewarded.enabled", true, "gameplay.json")

sdk.tracker().trackLevelEnd(mapOf("level" to 3, "result" to "win"))
sdk.tracker().trackSessionEnd()
sdk.tracker().flushAsync()
```

`startAsync` refreshes `/v1/config` and preloads config files on a background executor. It also creates or reuses the SDK anonymous `userId`; pass a `GameAlgoCacheStorage` when initializing if the app wants the dependency-free core to persist that ID. `executor` and `config()` read the latest local snapshot, so gameplay code does not need to call remote APIs when checking variants or tuning values.

Files created under the admin Configs page can be fetched directly when needed:

```kotlin
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

The SDK logs user id, config fetch, experiment assignment, config file, and script preload status to `System.out` by default. Pass `null` as the full constructor's `GameAlgoLogger` argument to silence logs, or provide a custom logger.

If an experiment assignment includes `script`, `executor.execute(state)` runs the preloaded script through the configured `GameAlgoScriptRuntime`. The dependency-free core includes a JSR-223 runtime for Java environments; Android app packages should inject a QuickJS/WebView runtime.

Lower-level blocking methods are still available when needed:

```kotlin
val config = sdk.fetchConfig()
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

The SDK sends `X-GameAlgo-Key` on every request, caches `/v1/config` by `ttlSeconds`, and fills default event fields for `eventId`, `timestamp`, and `isDebug`.

The SDK sends `userCreatedAt` and basic `device` context with `/v1/config` automatically. Pass `device` or `deviceId` to `startAsync`/`fetchConfig` to add app-specific fields or override defaults.

`tracker()` queues events in memory, uploads at most 100 events per batch, flushes every 30 seconds, and keeps the failed batch for the next retry. `fetchConfig`, `fetchConfigFile`, and `uploadEvents` are blocking in this core package; Android apps should call those lower-level methods from their own background executor/coroutine layer.

Event payload fields are sent as `payload` and stored raw. Analytics does not interpret payload fields during ingestion; a game-specific report pack later declares which fields become report dimensions or metrics. Experiment assignments are stored in the SDK context created by `/v1/config`, not copied onto each event.

## Check

```bash
mkdir -p /tmp/gamealgo-android-classes
javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```
