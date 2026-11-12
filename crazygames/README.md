# GamePropel CrazyGames SDK

Independent HTML5 v3 adapter, package `@gamepropel/sdk-crazygames`, entry
`GamePropelCrazyGamesClient`.

```sh
npm install @gamepropel/sdk-crazygames
```

## Initialize

Load the official portal SDK before your game code:

```html
<script src="https://sdk.crazygames.com/crazygames-sdk-v3.js"></script>
```

```ts
import { GamePropelCrazyGamesClient } from "@gamepropel/sdk-crazygames";

const gamePropel = await GamePropelCrazyGamesClient.init({
  baseUrl: yourGamePropelBaseUrl,
  gameKey: yourExistingClientGameKey,
  appVersion: "1.0.0",
});
await gamePropel.waitForReady(5000);
gamePropel.tracker.trackLevelStart({ levelId: "1" });
const difficulty = gamePropel.executor("difficulty").number("difficulty", 1);
```

`init()` waits for the official SDK initialization (10 seconds by default).
An unavailable/disabled portal SDK rejects explicitly. `waitForReady()` then
waits for GamePropel identity, queue recovery and configuration. Parameter
experiments and JSON configuration files work; this first version does not
download/execute remote scripts or include QuickJS/WASM or multiplayer.
The wire platform is always `crazygames`; the server must accept this platform
before production use. See [server handoff](./SERVER_HANDOFF.md).

The caller remains responsible for CrazyGames' `gameplayStart/Stop`, loading,
mute settings and any account/progress integration. SDK initialization cannot
infer whether the player has entered gameplay, opened a menu or paused a level.

## Video ads

CrazyGames has one shared video slot and does not require a TapTap-style ad unit
ID. Register separate GamePropel placements with the correct static ad type.

```ts
const revive = gamePropel.createAdSpace({ adType: "rewarded" });
pauseGameAndMute(); // Also block gameplay while the ad request is pending.
try {
  await revive.show(yourRegisteredRewardPlacementId, {
    onStarted() { pauseGameAndMute(); },
    onFinished() { grantRevive(); resumeGameAndAudio(); },
    onError(error) { resumeGameAndAudio(); console.log(error.code); },
  });
} catch (error) {
  // Handles unavailable ads, native rejections, busy slots and timeouts.
  resumeGameAndAudio(); // Also handles validation or a busy video slot.
  // Ensure the game can continue without a rewarded ad.
}

const betweenLevels = gamePropel.createAdSpace({ adType: "midgame" });
```

`show()` resolves on native `adFinished` and rejects on `adError`, native Promise
rejection, cancellation or timeout (default 180 seconds). It never retries ads.
Mute/pause the game while requesting as required by CrazyGames, and restore it
on failure as well as completion. Business callbacks cannot prevent telemetry.

* Native `adStarted` records one `ad_view` and immediately flushes it. Repeated
  callbacks are ignored. An error before start does not create an impression.
* There is no documented per-impression revenue or ad track ID. Events use
  `network=crazygames`, `revenue=0`, `revenueStatus=unavailable`, and
  `hostAdType=rewarded|midgame`. Zero is a compatibility placeholder, not settled
  income. No caller-supplied `trackId` is forwarded.
* Both ad types and all GamePropel instances share a host lock, avoiding callback
  replacement by overlapping requests. Only ads requested through these handles
  are captured automatically; arbitrary direct portal calls are not intercepted.
* Local portal test ads force `isDebug=true`. They must not count as production
  impressions/revenue. Basic Launch does not enable production ads.

## Sessions, time and persistence

* Ordinary batches flush every 5 seconds, up to 20 events / 48 KiB per request;
  queue limit defaults to 500. `ad_view` and `session_end` have urgent delivery.
* `visibilitychange(hidden)` and `pagehide` enqueue a durable `session_end`
  snapshot and attempt `fetch(..., {keepalive:true})`. Repeated hide callbacks
  within the same hidden period are deduplicated. `blur` is not treated as exit.
* Returning keeps the existing session. Only initialization or explicit
  `tracker.newSession()` creates a new session; `newSession()` closes the old
  unfinished session first. Multiple end snapshots report cumulative time;
  aggregate by the maximum per session/context, not the sum.
* `getForegroundTimeMs()` is a pure memory read of a one-second sampled clock.
  Each sample contributes at most one second. Background and suspended gaps
  are excluded, including gaps during ads; no exact full ad duration is claimed.
* Queue chunks commit before their directory. Offline tails, IDs, timestamps
  and original contexts recover on the next start. A process kill before a
  browser storage transaction commits can still lose that final uncommitted
  tail. Neither callbacks nor last-moment HTTP completion are guaranteed.
* Default storage uses a separate IndexedDB database `gamepropel-crazygames`,
  store `telemetry`. It does not use `CrazyGames.SDK.data` or localStorage
  fallback. It rejects failed persistent operations rather than acknowledging
  an in-memory queue as durable. If IndexedDB is disabled, provide a durable
  device-local `storage` adapter; initialization otherwise fails observably.
  Portal cloud-save/APS behavior must still be verified in Preview; the SDK
  does not claim that a dedicated database alone guarantees APS exclusion.

Optional options include `crazyGames` (host injection), `fetchImpl`, `storage`,
`browserStorage.indexedDB`, `autoLifecycle`, `autoSessionLifecycle`,
`requestTimeoutMs` and `hostInitTimeoutMs`. Device OS/version, browser, locale,
device type and application type come from the portal's `user.systemInfo`.
No login prompt is shown and no unverified portal user ID is auto-linked.

## Validation

```sh
npm run check:crazygames
npm run check:crazygames:pack
npm run check:crazygames:probe
```

The probe serves a local test endpoint and loads the official v3 SDK. It creates
no production game and sends no events to GamePropel's live services. Use the
developer portal's Preview to validate real ads, desktop/mobile lifecycle,
iframe storage and cloud-save behavior before shipping. Browser integration
tests run locally, outside CI.

Official references: [initialization](https://docs.crazygames.com/sdk/intro/),
[video ads](https://docs.crazygames.com/sdk/video-ads/),
[device info](https://docs.crazygames.com/sdk/user/#system-info),
[data](https://docs.crazygames.com/sdk/data/).
