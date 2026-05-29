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

sdk.tracker().trackSessionStart()
sdk.tracker().trackLevelEnd(mapOf("level" to 3, "result" to "win"))
sdk.tracker().flushAsync()
```

`startAsync` refreshes `/v1/config` and preloads config files on a background executor. It also creates or reuses the SDK anonymous `userId`; pass a `GameAlgoCacheStorage` when initializing if the app wants the dependency-free core to persist that ID. `executor` and `config()` read the latest local snapshot, so gameplay code does not need to call remote APIs when checking variants or tuning values.

If an experiment assignment includes `script`, `executor.execute(state)` runs the preloaded script through the configured `GameAlgoScriptRuntime`. The dependency-free core includes a JSR-223 runtime for Java environments; Android app packages should inject a QuickJS/WebView runtime.

Lower-level blocking methods are still available when needed:

```kotlin
val config = sdk.fetchConfig()
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

The SDK sends `X-GameAlgo-Key` on every request, caches `/v1/config` by `ttlSeconds`, and fills default event fields for `platform`, `sdkVersion`, `appVersion`, `timestamp`, and `isDebug`.

`tracker()` queues events in memory, uploads at most 100 events per batch, flushes every 30 seconds, and keeps the failed batch for the next retry. `fetchConfig`, `fetchConfigFile`, and `uploadEvents` are blocking in this core package; Android apps should call those lower-level methods from their own background executor/coroutine layer.

## Check

```bash
mkdir -p /tmp/gamealgo-android-classes
javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```
