# GamePropel Unity SDK

Unity 2022.3 or later; Android API 24+ and iOS 15+. Install the prepared
`com.gamepropel.sdk-1.1.0.tgz` with **Package Manager → Add package from tarball**.
A source checkout can also be added as a local package after building its native
artifacts. JSON uses the SDK's small, dependency-free data parser; no Newtonsoft
or System.Text.Json assembly is required. The SDK initializes only in Android/iOS players;
initialization in the Editor throws `PlatformNotSupportedException`.

The repository includes prepared Android AARs and iOS XCFrameworks. The **Unity
bindings** GitHub Actions workflow tests the sources, rebuilds matching native
SDKs and bridges, and publishes the downloadable `gamepropel-unity-upm` artifact.
SDK maintainers refresh the checked-in native artifacts from that validated
package when releasing native SDK or bridge changes. Local rebuilding uses
`Tools~/build_native.py`; player and size checks remain separate.
Games importing the prepared package do not compile the SDK's Rust/Swift/Java
sources themselves.

This is a C# binding to the existing Android/iOS SDKs. Native code owns anonymous
identity, queued events, persistence, retries, foreground timing and lifecycle
notifications. The Unity layer does not keep another telemetry queue, run a
flush timer or report duplicate `OnApplicationPause` / `OnApplicationQuit` ends.
Protocol `platform` remains `android` or `ios`; `device.runtime=unity`,
`device.unityVersion` and `device.unitySdkVersion` identify the engine/binding.
`sdkVersion` remains the native SDK version.

## Start

```csharp
using GamePropel;

var sdk = GamePropel.GamePropelSDK.Initialize(new GamePropel.GamePropelOptions {
    GameKey = clientKey,       // ga_live_* only
    AppVersion = "1.0.0",
    IsDebug = true,            // set false for production
    ExperimentIntegrationVersion = 1 // required positive integer (>= 1)
});

// This yields to Unity; gameplay can keep reading local defaults while it runs.
bool ready = await sdk.WaitForReadyAsync(5000);
int difficulty = sdk.GetConfig("difficulty", 1, "gameplay.json");
```

Initialize once, on the Unity main thread, and use
`GamePropel.GamePropelSDK.Client` across scenes. The Unity wrapper does not cache
a readiness timeout: later `WaitForReadyAsync` calls ask native code again.
`RefreshConfigAsync()` uses the native cache/TTL policy; pass
`forceRefresh: true` to force a network refresh. Missing config values
return the supplied fallback. Native callbacks are delivered through a persistent
Unity synchronization context; call this API on the main thread as well.
Optional `AccountUserId` / `AccountUserCreatedAt` initialization fields associate
the game's account with the independent native anonymous identity.

## Existing or new players

Optional initialization option `IsOldUser` classifies pre-existing game progress: true for an existing player, false for a confirmed new player, and omitted when unknown. Read the necessary progress before initialization. The SDK persists the first explicit value per game/player; restarting or creating a new save does not overwrite it. Only the `new_user` standard milestone funnel excludes existing players from both its denominator and node counts. Other milestones, SDK registration dates, retention and LTV keep their existing definitions. Set the nullable `GamePropelOptions.IsOldUser`; null omits the field.

## Events and sessions

```csharp
string attemptId = System.Guid.NewGuid().ToString();
await sdk.TrackLevelStartAsync(new JsonObject {
    ["level_id"] = "level-1", ["level_attempt_id"] = attemptId
});
await sdk.TrackMilestoneAsync("new_user", "entered_first_level");
await sdk.TrackLevelEndAsync(new JsonObject {
    ["level_id"] = "level-1", ["level_attempt_id"] = attemptId, ["result"] = "win"
});
await sdk.TrackEventAsync("inventory_summary", new JsonObject { ["items"] = 12 });
await sdk.TrackPurchaseAsync("starter_pack", 4.99, "CNY");
```

`TrackEventAsync` is the custom-event API and uses the native `_` prefix.
Use the dedicated milestone and standard-event methods for their respective
semantics. A true track result means native enqueue success, not server storage.
An event can return false before native identity is available or when rejected
by the native event guard. `FlushAsync` awaits the native flush attempt; verify
real receipt using GamePropel's CLI/reporting tools.

The native SDK automatically reports lifecycle `session_end` snapshots and keeps
the session on foreground restoration. Use `TrackSessionEndAsync` only for an
explicit business boundary. When ownership changes, **await**
`NewSessionAsync()` before tracking events for the new session; this also obtains
the new configuration Context. Independent asynchronous operations need not
complete in invocation order. Do not add game-side retries to track calls.
The bridge does not add a second request timeout or telemetry queue limit.
Passing the current session ID is a no-op, and a blank ID asks native code to
generate the new ID, matching the existing SDKs.
If the subsequent config fetch fails, the native session switch has already
occurred; the exception does not roll it back. Retry configuration rather than
creating another session to retry the request.

Native defaults are retained: ordinary flush interval 30 seconds, maximum batch
100 events and queue limit 1000 events. Lifecycle ends and explicit flushes use
the native SDK's existing send paths. Unity does not add
another sampling clock, flush loop, persistence layer or event retry policy.
Manual `TrackSessionEndAsync` retains the platform API's behavior: Android
enqueues the event; iOS also awaits a flush attempt. Call `FlushAsync` explicitly
when the caller needs a manual send attempt on either platform.

```csharp
long start = sdk.GetForegroundTimeMs();
// ... gameplay, including possible session changes ...
long foregroundElapsed = sdk.GetForegroundTimeMs() - start;
```

The clock reads native accumulated foreground milliseconds without advancing
time, writing storage or uploading events. It resets when the SDK/process is
reinitialized, not on config or session changes.

## Ads, attribution and device identifiers

Connect an ad SDK's confirmed impression/revenue callback to:

```csharp
await sdk.TrackAdAsync(registeredAdPlacementId, revenue, network,
    new JsonObject { ["trackId"] = actualTrackId });
```

The placement is the real registered `gap_*` ID. This binding does not load ads,
create synthetic impressions, or depend on an ad provider. Supply only the
provider's actual revenue and track ID.

`SetAttributionAsync(provider, JsonObject)` delegates attribution to native code.
Before initializing Adjust, use `await sdk.ConfigureAdjustCallbackParamsAsync(setter)`
to pass the native `gamealgo_user_id` and `gamealgo_user_created_at` parameters
to the Adjust Unity SDK's callback-parameter setter.
`SetIdentifierAsync` supports Adjust ADID, Firebase App Instance ID and Google
Advertising ID; OAID is Android-only and IDFA/IDFV are iOS-only. `SetCaidAsync`
accepts externally obtained `CaidValue(caid, version)` pairs on iOS. Native code
handles the CAID wire representation. Unsupported platform identifiers fail
explicitly. The binding does not acquire OAID/CAID, request ATT permission or
initialize Adjust on the game's behalf.

The iOS export processor embeds the native bridge/runtime and weak-links
`AdServices.framework`. Existing native iOS attribution behavior is retained.

## Strategies and DDA

```csharp
int limit = sdk.GetStrategyConfig("difficulty", "move_limit", 20);
var decision = await sdk.ExecuteAsync("difficulty", new JsonObject { ["level"] = 4 });
await sdk.RecordBehaviorAsync("difficulty", "failed");
await sdk.CompleteStepAsync("difficulty", "level-4");
var dda = await sdk.DecideAsync("difficulty", new JsonObject { ["level"] = 5 });
```

Execution uses the native bundled Rust runtime. Missing strategies return the
native fallback/null result; DDA preserves native `keep` fallback semantics.
`GetAssignment` exposes diagnostic metadata. Gameplay differences should read
configuration or script results rather than branch on variant/run IDs.

## JSON values

Use `GamePropel.JsonObject`, `JsonArray` and `JsonValue` for dynamic configuration,
event payloads and script inputs/results. String, boolean and numeric values
convert implicitly when constructing a JSON object or array. `JsonValue.Parse`
accepts existing JSON; `ToString()` produces compact JSON for another library.

```csharp
var payload = JsonObject.Parse(existingJson);
var rewards = new JsonArray { "coins", "gems" };
payload["rewards"] = rewards;
var result = await sdk.ExecuteAsync("difficulty", payload);
int limit = result["payload"].Value<int>("move_limit");
```

`GetConfig<T>` / `GetStrategyConfig<T>` support JSON nodes and primitive C#
strings, booleans and numeric values, including nullable primitives. For
structured data use `JsonObject` / `JsonArray` / `JsonValue`; arbitrary C# class
conversion is not included. A game can explicitly convert a node's JSON string
with Unity `JsonUtility` or its own serializer. The early, unpublished wrapper's
`JObject` / `JToken` parameters are replaced by these SDK types.

The parser preserves numeric text so 64-bit integers do not pass through double
precision. It rejects invalid JSON, nonfinite values supplied from C#, and
nesting beyond 64 containers. Explicit JSON null is `JsonValue.Null`; an absent
object member returns a C# null reference. Scalar reads require matching JSON
types and throw on integer overflow or fractional-to-integer conversion.
Duplicate object keys keep their final value. Payloads are copied before native
dispatch; the native SDK continues to own validation and reporting semantics.

## Editor and validation

The package targets native Android/iOS players. Editor initialization fails
explicitly; it does not return simulated readiness, accepted events or device
data. Games that run in the Editor should guard their SDK integration with
`Application.isEditor` and use gameplay defaults there. Validate SDK behavior
in a mobile player, including when running on an Android/iOS simulator.

Import **Getting Started** from the Package Manager's Samples section and attach
`GamePropelExample` to a GameObject. Fill a client key for a mobile debug build.
Register any new business fields/events through the current server CLI docs.

## Build from source

Run from the client repository root. Android requires JDK 17, Android SDK 35,
NDK, Rust Android targets and `cargo-ndk`; iOS requires full Xcode. Set
`ANDROID_HOME`, `ANDROID_NDK_HOME`, `JAVA_HOME` and, if needed, `DEVELOPER_DIR`.

```sh
python3 unity/Tools~/build_native.py --android --ios
python3 unity/Tools~/package.py
dotnet run --project unity/Tests~/GamePropel.ManagedTests.csproj -p:DefineConstants=UNITY_EDITOR
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path unity/Native~/iOS
```

Builds use the native sources in the same checkout, with isolated Android build
outputs. Package generation verifies required binaries and assigns stable Unity
asset GUIDs. The managed harness uses Unity type stubs for compiler/protocol
checks; it does not replace Unity Editor, IL2CPP, exported-player or device tests.
See [VALIDATION.md](VALIDATION.md) for the completed checks and remaining player
validation before production use.

For the real player validation fixture, install Unity with Android/iOS build
support and an activated license, then run `Tools~/test_player.py --editor
<Unity-executable> --platform android` (or `ios`). Android uses the configured
JDK/SDK/NDK, including CMake 3.22.1 for the tested Editor. iOS requires a booted
simulator and the Ruby `xcodeproj` gem for its foreground-activation XCTest.
The script builds matching baseline and SDK players, validates native behavior
against localhost and records artifact size differences. Run Android builds
before starting the runtime checks; Editor shutdown can restart the shared ADB
server. Do not add the test-only HTTP permissions to a production project.

The compressed single-platform package budget is **less than 1,000,000 bytes**
of additional APK/IPA payload. The validation script enforces this limit by
default against a matching baseline (`--variant both`); an over-budget result
fails the run. For iOS size measurements use
`--platform ios --ios-device-size`, which builds unsigned ARM64 device Release
apps and compares ZIP-compressed IPA payloads; it does not execute on a device.
Simulator app directory sizes are not used for this budget. Apple signing,
encryption and App Store processing can change delivered sizes; repeat the
comparison with the game's actual release pipeline before publishing.
