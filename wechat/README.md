# GamePropel WeChat Minigame SDK

`@gamepropel/sdk-wechat` is the native **WeChat minigame** adapter for GamePropel
(formerly GameAlgo). It uses `wx.request`,
native local storage, `wx.onHide/onShow` and rewarded-video APIs. It fixes
`platform=wechat`; iOS/Android/desktop are separate `device.os` values.

Version 1.0.0 supports events, durable offline queues, foreground time,
configuration files in JSON and parameter-based A/B experiments. It does not
execute remote JavaScript/WASM, provide multiplayer or retrieve individual ad
revenue. The TapTap H5 package is a different SDK.

The `GameAlgoWechatClient`, `initGameAlgoWechat`, and `GAMEALGO_WECHAT_*` names
remain aliases for existing integrations. Storage keys and the wire protocol
retain their historical names.

## Install and initialize

```bash
npm install @gamepropel/sdk-wechat
```

Use the engine's npm integration or WeChat Developer Tools' Build npm step.
The package has ESM and CommonJS entries and no runtime dependencies.
For a plain JavaScript project, copy `dist/commonjs/index.js` from the built
package into the game as `libs/gamepropel-wechat.js`; that one file is standalone:

```js
const { GamePropelWechatClient } = require('./libs/gamepropel-wechat.js');

const gamePropel = GamePropelWechatClient.init({
  baseUrl: 'https://game-algo-sdk.dictapis.cn',
  gameKey: 'ga_live_your_game_key',
  appVersion: '1.0.0',
  experimentIntegrationVersion: 0,
  // accountUserId: existingOpenId, // Optional; reuse the game's login identity.
});

// Do not block the first screen. Failed config uses local defaults/cached data.
void gamePropel.waitForReady(1500);

function startLevel(levelId) {
  gamePropel.tracker.trackLevelStart({ level_id: levelId });
}

function difficulty() {
  return gamePropel.executor('difficulty').number('difficulty', 1);
}
```

Configure the actual SDK hostname as a request legal domain in the WeChat
console (`game-algo-sdk.dictapis.cn` above). Overseas deployments use the full
`https://dirichlet.ai/algo_sdk` prefix. The server must support `wechat` before
using this SDK; never change it to `web` to bypass a platform error.
Only `ga_live_*` belongs in game code. No AppSecret or management key is needed
in the game. Anonymous user identity and creation time are persisted; an existing
OpenID can be linked as `accountUserId` without replacing the anonymous ID.

## Events, storage and lifecycle

Ordinary events flush every five seconds by default, at most 20 per batch;
`ad_view` and `session_end` also use the urgent lane. Queued events persist on
enqueue using the shared incremental, copy-on-write chunk queue. A blocked
ordinary request does not suppress a later lifecycle snapshot or its urgent
upload. Storage errors remain errors; memory is never called durable storage.
Native storage is written only when data changes, not every frame or timer tick.
The default queue limit is 500 events. WeChat's local-storage limits still apply;
storage full/cleared by the host and process termination before persistence
finishes cannot be guaranteed recoverable.

On hide, including a fullscreen-ad hide, the SDK generates a `session_end`
snapshot and attempts upload. On show it keeps the same session, resumes
sampling, refreshes config and retries uploads. Repeated show callbacks do not
create sessions. Only initialization or explicit
`gamePropel.tracker.newSession()` creates a new session; explicit rotation closes
the old session using its original context.

Time uses in-memory one-second sampling and never catches up a suspended
interval. Hide/show control visibility; hide captures a short tail. Background
time is excluded and suspended/hidden ad time may be omitted. No storage or
network runs in the sampling callback. Read `gamePropel.getForegroundTimeMs()`
twice and subtract to measure foreground elapsed time. This lifetime counter
survives session rotation; session snapshots use the counter since that session
started. Multiple snapshots of one session use the maximum duration, not a sum.

`autoLifecycle: false` disables host subscriptions; `autoSessionLifecycle: false`
disables automatic end snapshots. Games opting out own the corresponding
lifecycle behavior. Before permanently disposing a client, await `flush()` when
possible, then `close()`. Close cancels requests and subscriptions; it does not
claim delivery. Reopening restores previously persisted event IDs, timestamps,
sessions and contexts. A force kill without a hide callback does not manufacture
an end event that was never generated.

## Rewarded video

Reuse the real WeChat `adUnitId` already configured by this game. It differs from
the registered GameAlgo `gap_*` placement ID. TapTap IDs and MCP ad tools do not
apply. Register the GameAlgo reward placement/currency before reporting.

```js
const reviveAd = gamePropel.createAdSpace({ adUnitId: existingWechatAdUnitId });

async function reviveClicked() {
  try {
    await reviveAd.show(revivePlacementId, {
      onClose(result) {
        if (result && result.isEnded === true) revivePlayer();
        // Restore UI/audio here; the SDK already reported the exposure.
      },
      onError(error) { showAdUnavailable(error); },
    });
  } catch (error) {
    showAdUnavailable(error);
  }
}
```

The shared controller preloads, reuses the native instance, prevents concurrent
playback, retries one failed show after reloading and reports once on the first
real close after show starts, including early close. Preload, load failure or
a native error alone is not an exposure. Business callbacks retain the native
arguments. Promise completion means load/show was requested, not that the user
finished or earned a reward. Closed clients' retained callbacks are inert.

The documented WeChat close callback has `isEnded`, without TapTap's `trackId`
or individual revenue. These automatic `ad_view` records therefore carry
`network=wechat`, **`revenueStatus=unavailable`**, and `revenue=0` as a protocol
placeholder. It is not real zero income or verified revenue. Do not interpret
these records as per-user settled income, CPM or ROAS, and do not fabricate a
track ID. Revenue/report reconciliation requires a separate WeChat integration.
When another provider supplies real revenue, use the normal
`tracker.trackAdPlacement(id, revenue, network, payload)` at its real callback;
do not report that same exposure through both paths.

## Configuration and compatibility

`refresh()` preloads JSON files by default. `preloadConfigFiles: false` disables
it; a string array selects names. Remote strategy scripts are not preloaded or
executed. Their executor returns no result until supported; gameplay must use
local defaults. `GAMEPROPEL_WECHAT_CAPABILITIES` exposes this limit. Arbitrary
`eval`, `new Function`, browser Workers and native Node processes are not used.

Optional device APIs are best-effort. Runtime AppID is observed only from
`wx.getAccountInfoSync()` into `device.wechatAppId`, never guessed or taken from
game options. Host OS/version comes from `wx.getDeviceInfo()`; no deprecated
permission-sensitive system-info calls or TapDB linking are made.

Local tests cover the native callback shapes, a restricted JS context without
browser/Node globals, real HTTP loopback and isolated ESM/CommonJS/type installs.
On 2026-11-11, iOS WeChat on iPhone 16 Pro Max (iOS 26.5) verified initialization,
level events, background/lock session snapshots, foreground counting, anonymous
identity/config restoration and offline-queue recovery after force closing
WeChat. These device tests used an independent test game and a **probe-only**
translation to the existing `web` receiving platform because the live server
rejected `wechat`. The shipped SDK always sends `wechat` and contains no such
translation. Native WeChat platform acceptance must be verified after the server
update. Android WeChat, Developer Tools and real rewarded ads remain unverified.

Server integration requirements and the exact validation boundary are in
[SERVER_HANDOFF.md](./SERVER_HANDOFF.md).
