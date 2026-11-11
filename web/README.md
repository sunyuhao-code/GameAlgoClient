# GameAlgo H5 SDK

Browser and ordinary WebView SDK for H5 games. The SDK always reports
`platform=web`; application code cannot override it.

Configuration requests include the operating system in `device.os` (`ios`,
`android`, `windows`, `macos`, `linux`, or `harmonyos`). In TapTap, the SDK reads
`tap.getDeviceInfo()` for the host platform and `device.osVersion`, including
numeric versions such as `26.5` or prefixed values such as `iOS 26.5`. When the
API is unavailable or fails, browser information provides the OS type. Browser
UA versions can be frozen, so they are not used as OS versions. The SDK does
not invoke the older permission-sensitive system-info APIs. Information is
refreshed for each config request, and explicit `device` fields take precedence.

### Runtime game identity (observation only)

On each config request the SDK probes `tap.getAccountInfoSync()` when the host
provides it. A valid Tap miniapp ID (`tapmc...`) from `miniProgram.appId` is sent
in `device.runtimeMiniappId`, the same field used by the Maker SDK. Project IDs,
numeric App IDs and identity-source fields are not collected. If the API is
missing, unsupported, throws, or returns invalid data, the field is omitted.
Tap H5 support must be checked on real devices; the SDK does not assume every
WebView supports the Tap minigame API.

The miniapp ID is collected by the SDK, never taken from game options,
plugin/container IDs, URLs, or copied configuration. No name or ID is guessed.
It is stored with the Context's `device` data, not repeated in event payloads.
Later config requests can discover a late-injected bridge. Missing identity
does not delay initialization, retry collection, or suppress events. This phase
only records observations; it adds no server-side binding check or filtering.

```ts
import { GameAlgoWebClient } from "@gamealgo/web";

const gameAlgo = GameAlgoWebClient.init({
  baseUrl: "https://game-algo-sdk.dictapis.cn",
  gameKey: "ga_live_xxx",
  appVersion: "1.0.0",
  isDebug: false, // Production telemetry; use true only in intentional test builds.
  experimentIntegrationVersion: 0,
});

// Do not block first paint on this. Local defaults remain available.
await gameAlgo.waitForReady(1500);

gameAlgo.tracker.trackLevelStart({ levelId: "level_1" });
gameAlgo.tracker.trackMilestone("new_user", "进入第一关");

const decision = await gameAlgo.executor("level_dda").execute({ level: 12 });
```

### TapDB identity linking in TapTap

TapDB identity linking is disabled by default. Only a fresh successful server
config response with a valid `contextId` and boolean `tapdbContextLinkEnabled: true`
authorizes linking. Missing, false or malformed flags cause no TapDB calls or
bridge discovery. A restored offline snapshot never grants startup permission.
A later successful disabled response clears pending linking and stops discovery;
this takes effect before snapshot persistence, even if browser storage is slow or fails.
re-enabling does not reset the once-per-client guard. Calls already made to the
host cannot be undone. This controls only GameAlgo's automatic identity link,
not the game's own TapDB calls or GameAlgo telemetry. Older SDKs must be upgraded
to honor this server switch.

On the first enabled server config response, each
H5 client instance makes one best-effort `gamealgo_context_link` report through
the host's `tap.logEvent({ name, properties, success, fail, complete })`. Games
do not need to call this themselves. The event and flat properties match Maker:

| Property | Value |
| --- | --- |
| `gamealgo_context_id` | The successful config response's `contextId` |
| `gamealgo_device_id` | That config request's `userId`: the persistent GameAlgo anonymous identity, or an explicitly supplied `userId` |
| `gamealgo_is_debug` | That config request's `isDebug` flag |

Use this event to join GameAlgo contexts to identities enriched by TapDB in DW.
`gamealgo_device_id` is not the TapDB device ID, account ID, OAID, or CAID. The
SDK does not read those identifiers from the sandbox or send game keys to TapDB.
The game needs TapDB enabled and a formally published build for the tested
TapTap ingestion path; a preview/test build or an accepted native callback alone
does not prove that data reached TapDB storage.

Config refreshes, returning to the foreground and explicit session changes do
not repeat the event. A new client instance may send once again. Failed requests,
invalid contexts and a persisted offline snapshot do not trigger it; a later
successful server response can. Closing a client suppresses late responses.
Missing host APIs, native errors and callback failures do not block initialization
or ordinary event uploads. The SDK does not retry this event, wait for callbacks,
or treat the normal `undefined` return value as confirmation of delivery.
If the bridge is not ready at the first enabled config response, the SDK
retains that response's context and identity, checking for the bridge every
500 ms for up to 10 seconds without blocking initialization. Later successful
enabled config responses also check for availability without replacing the pending
first identity. The one-call guard is set only immediately before the native
call; native rejection or failure is not retried. Closing the client cancels
discovery and discards its pending link. This event bypasses the GameAlgo event
queue and ordinary-event quota. Failures use the optional SDK logger; success
does not produce an extra log.

### TapTap H5 rewarded ads

Since `@gamealgo/web@2.1.7`, use an ad-space handle for TapTap H5 rewarded ads:

First inspect this game's existing ad integration. If it already has a real
`adUnitId`, reuse its variable, configuration or lookup without calling MCP or
asking the developer for it again. Route rewarded-ad playback through
`client.createAdSpace({ adUnitId }).show(...)`, reusing that ID and the game reward/cleanup callbacks. The
wrapper reports automatically; do not report the same exposure again in its `onClose`.

Only for new ads or missing configuration, obtain `adUnitId` through the official
**H5 Minigame MCP**, rather than asking the developer to apply for or type an ID.
Read `get_ads_integration_workflow`, verify
the intended app with `get_current_app_info`, then call `check_ads_status`. It
queries the server and matches `space_id` to the app's confirmed orientation.
Only status `1` plus a valid ID permits `get_ad_integration_guide`, whose generated
code contains the value to pass as `tapTapAdUnitId` below. A new MCP lookup must
use its current result without falling back to old query output. Do not use
another app's ID, a sample or a placeholder. If activation,
orientation or a valid ID is missing, follow the MCP recovery guidance without
guessing or polling. See the [official MCP setup guide](https://developer.taptap.cn/minigameapidoc/quick-start/mcp-guide/mcp-setup/) if it is not configured.

H5 games enable ads in TapTap Developer Center; they do not need to create media
or ad units in Dirichlet for this flow. Zip-based Tap Minigames use a separate
integration flow. Maker/UrhoX uses the Maker MCP's `get_ad_config` and Lua APIs;
do not mix its tools, app context or IDs with this H5 flow.

```ts
// Bind the unit at game startup. The SDK automatically preloads it.
const rewardAd = gameAlgo.createAdSpace({ adUnitId: tapTapAdUnitId });

async function onReviveClick() {
  try {
    // Show on click. The SDK loads first if its automatic preparation is not ready.
    await rewardAd.show(adPlacementIds.revive, {
      onClose(result) {
        if (result?.isEnded === true) revivePlayer();
        // Keep UI/audio cleanup here; do not report the same ad again.
      },
      onError(error) { showAdUnavailable(error); },
    }, { level_no: currentLevel });
  } catch (error) {
    showAdUnavailable(error);
  }
}
```

GameAlgo automatically preloads after the ad-space is created and prepares the
next ad after each real close, including early close. Developers do not call
`preload()` or native `load()`. Automatic preparation never displays an ad,
invokes reward callbacks or reports `ad_view`.

Register the GameAlgo placement as `reward` / `CNY` first. Its `gap_` ID and the
TapTap `adUnitId` are different IDs. This wrapper requires the TapTap H5 host;
it does not intercept external ad instances or support unrelated ad providers.

`client.createAdSpace({ adUnitId }): GameAlgoRewardAdSpace` synchronously returns
an ad handle and schedules automatic preparation without waiting for identity,
config or network readiness. It snapshots the unit ID and returns the same handle
for the same client/unit. It currently supports TapTap H5 rewarded video only.

`rewardAd.show(adPlacementId, callbacks?, payload?): Promise<void>` uses the
prepared ad, joins an automatic load already in progress, or loads on demand
after a previous failure. A ready instance calls native show in the caller's
click stack without an intervening await.
Its Promise follows load/show calls, does **not** wait for close, and does not
confirm completion, a reward or ingestion. If the first native show throws or
rejects before a real close, the SDK reloads and retries show once. A recovered
request does not invoke the business `onError`. Recovery keeps the playback lock;
callbacks retained from the failed attempt cannot complete the retry. Creation,
load and final show exceptions/rejections reject unchanged. A final native
`onError` is forwarded once with its original arguments, without an exposure or
a synthetic Promise rejection. An error after show has resolved, or a real close,
never replays the ad. Both callbacks are optional and
receive all original arguments. Only the game decides whether to grant rewards.

The default native singleton is shared, including its playback lock across
WebClients. Normal close keeps the instance and removes only this playback's
listeners/context. Different GameAlgo placements can reuse one native unit.
Changing native units is allowed only while idle; loading/playing conflicts
reject as busy, without queuing another ad. Automatic preparation keeps only the
current native unit warm and never switches away from another handle. A native
onLoad that already marked the next ad ready prevents a redundant SDK load. Hosts
without reliable listener removal retire the instance instead of accumulating
callbacks. `client.close()` stops automatic preparation, releases ownership, cancels pending
calls and makes that client's retained callbacks inert.

On the first real `onClose` after show has been called, the SDK extracts the
original track ID, reports `ad_view` with revenue `0` and network `taptap`, starts
the urgent keepalive upload, then invokes game code. Early close, failure codes,
`isEnded=false` and a missing ID still report. A stale `payload.trackId` is never
used. The payload and callbacks belong to that playback, not to preload. Each
playback ignores duplicate closes; recently reported track IDs also guard
against old closes redelivered to a later listener. A queued real close after a
native error retains its original context. Callback/cleanup exceptions cannot
undo reporting, and a reporting exception cannot block the game callback.

If a real ad closes before asynchronous identity restoration completes, its
exposure waits in a bounded in-memory buffer. After the real identity and session
context arrive, it uploads with the original close time, session and track ID;
the SDK does not invent a temporary identity or block the game callback. This
pre-identity buffer cannot survive page termination. Optional logger messages
show `identity restore started`, `identity ready`, `ad_view identity buffered`,
`ad_view identity released`, `context ready` and `ad_view upload ack`. Acceptance
into the local buffer (`queued=true`) is distinct from a server upload ACK.

For storage diagnosis only, pass `browserStorage: { logger: console.info }`
(or a logger to an explicitly created `GameAlgoBrowserStorage`). It records
operation stages, duration, result types and a pending notice after 3 seconds,
without printing storage keys or values. These notices do not cancel operations
or replace an existing identity. Storage diagnostics are off by default.

`client.showRewardVideoAd(id, { adUnitId, onClose, onError }, payload?)` remains
compatible. Startup preparation requires binding the native unit through
`createAdSpace`. Version 2.1.7 removes manual preload methods; remove those calls
when upgrading from 2.1.6 and call `show()` for playback.

Automatic preparation errors only use the optional SDK logger, without invoking
business `onError`, reporting an exposure or starting an infinite background retry
loop. A later `show()` can load on demand. Loading times out after 30 seconds and
retires the slot so the next explicit show can try again. A late host bridge is
discovered for up to 10 seconds after handle creation; show can still acquire it
on demand afterward.

Existing TapTap H5 rewarded-ad integrations should route playback through this
wrapper, reusing the game's real ad unit ID and reward/cleanup callbacks.
Other ad formats or providers use their documented impression/revenue callbacks
to report standard `ad_view` events with this game's registered `adPlacementId`,
actual `revenue` and optional `network` / `trackId`. Server supplies registered
name/type/currency; the registered currency must match the actual revenue unit.
The SDK does not observe external ad instances automatically. Report each valid
exposure once; requests, loads and reward grants are not additional exposures.

Wrapper branches are covered by SDK tests. For each game still play a real ad,
check placement, game rewards/UI, and confirm new non-debug `ad_view` reception
and the original track ID. Avoid repeatedly inserting generic SDK probes.
Manual adapters additionally need early/duplicate-close checks. Use
`gamealgo events count --event-type ad_view --json` for live ingress; enqueue
success or a mocked callback alone does not prove real ad delivery.

The SDK uses IndexedDB for stable anonymous identity, config snapshots,
milestone de-duplication, and its durable event queue. `localStorage` and then
in-memory storage are used as fallbacks. Ordinary events flush every 5 seconds
by default, when a batch fills, when the page is hidden or left, and when the
browser returns online. Override `eventFlushIntervalMs` to change the interval;
`0` disables periodic flushing without disabling immediate critical uploads.
Event batches use `fetch(..., { keepalive: true })` and are capped at 20 events
to stay below browser keepalive limits.

Queue persistence coalesces consecutive enqueue requests and stores events in
100-event chunks. It serializes new or rebound events and rewrites only changed
chunks, then commits a small directory last. Unchanged queues do not write storage.
Existing JSON Lines queues migrate automatically; a failed directory commit keeps
the previously committed queue readable. This changes storage work, not the flush
interval or the immediate upload behavior of critical events.

The built-in browser store requires an IndexedDB or localStorage commit for queue
chunks and their directory. A memory-only fallback does not advance the committed
queue; failed saves remain eligible for retry. Retries re-read the committed
directory before choosing chunk banks, including when a write committed but its
completion was interrupted. Identity/config caches retain their memory fallback,
and queue-cleanup failures after an HTTP acknowledgement do not resend that batch
in the current process. When the old queue cannot be read, the SDK retains it
untouched, continues uploading new events from memory, and retries restoration
before a later queue write.

When TapTap sends `tap.onHide`, or the document becomes hidden, the SDK records
a `session_end` snapshot and starts uploading it immediately. `pagehide` is a
fallback. Repeated hide notifications during the same hidden period are coalesced.
When the page becomes visible again (including back-forward cache restoration),
the SDK retains the current session ID and accumulated duration, refreshes its context,
and preloads current config files. A later hide can report another `session_end`
for that same session. `sessionDurationMs` accumulates running time with an in-memory
one-second sampler. Each observation adds at most one second; suspended intervals
are not caught up. Every sample reads current document visibility; hidden observations
do not continue accumulating. Lifecycle callbacks only observe boundaries: a missed
show callback cannot leave a persistent paused flag. A hide or explicit end includes the subsecond tail
(also capped at one second). Ads that hide or suspend the WebView can be excluded
from duration. Sampling performs no event upload or storage write. Only SDK
initialization or an explicit `tracker.newSession()` creates a new session. TapTap
`onShow` received while the document is still hidden does not resume the page.
Set `autoSessionLifecycle: false` only when the game owns those boundaries;
`autoLifecycle: false` disables all automatic browser lifecycle listeners.

`ad_view` starts an immediate upload after successful enqueue. It does not wait
for the 5-second timer or the 20-event threshold. H5 uses separate critical
upload lanes for `ad_view` and `session_end`: neither waits for ordinary uploads
or event-store writes, and a pending ad request cannot block a session end.
Ordinary batches exclude critical events already being uploaded. Failed requests
remain queued with their original event ID and occurrence time, and persisted
queues include ordinary in-flight rows until acknowledgement. Successful enqueue
does not mean server delivery; use `await gameAlgo.flush()` to await critical
uploads and their queue persistence when the page can remain active.

### Explicit session changes

Explicit `gameAlgo.tracker.newSession()` closes an unfinished old session with
`reason=new_session`, preserving its user/session/context and ending its duration
at the switch. It schedules persistence and immediately starts critical upload,
without waiting for the network before switching. A session already ended by the
game is not ended again; passing the current session ID is a no-op. Lifecycle
snapshots leave the session open, so an explicit switch after an ad/background
reports its accumulated running duration through the switch. Unbound old events
remain queued for their own context and cannot inherit the new session's context.
This explicit boundary also applies when automatic lifecycle handling is disabled.

### Fullscreen ads inside an App WebView

Fullscreen ads can hide the WebView, and going Home from the ad may produce no
second hide notification. The SDK therefore records and flushes a `session_end`
snapshot on the first hide, including during ads. These snapshots bypass gameplay
event quotas and request durable queue persistence. They keep the same session ID
and accumulated duration. `ad_view` still uploads immediately.

Games no longer need to call `setAdShowing`. That method remains as a deprecated
compatibility no-op, so existing integrations also report ad-related hides.

The SDK detects `tap.onHide/onShow` at runtime and subscribes without replacing
game callbacks. It checks for late host injection during the first 10 seconds and
on page/load events; ordinary browsers keep using DOM lifecycle listeners.
`close()` unregisters host listeners when the matching `offHide/offShow` methods
exist, and retained callbacks become inert if the host lacks those methods.

This is best-effort delivery within the current visit, not a guarantee that
JavaScript runs after native suspension or process death, or that an asynchronous
storage write finishes before termination. Generated and durably stored events
retry with their original ID, time and context on the next initialization. The
SDK does not invent an end event for an exit that supplied no callback.

## Remote strategies and DDA

Remote strategy scripts run in a dedicated Web Worker containing an isolated
QuickJS/WASM runtime. Scripts cannot access the page DOM, cookies, browser
storage, network APIs, clocks, randomness, dynamic code generation, or host
objects. Script source, input, output, memory, stack, and execution time are
bounded; a stuck worker is terminated without blocking the game page.

The runtime imports `quickjs-emscripten-core` with only
`@jitl/quickjs-wasmfile-release-sync`, sharing one lazily initialized WASM module.
It does not include debug or Asyncify variants. Avoid importing the
`quickjs-emscripten` root or `/variants` entry in integrations: those entries
can cause bundlers to emit unused WASM assets before tree-shaking.

Config-only strategies and script-backed `executor(...).execute(...)` are both
supported. `dda(...)` uses the same sandbox and persists its rolling state in
the browser store.

## 读取前台耗时

```ts
const start = client.getForegroundTimeMs();
// 业务结束；期间允许 newSession()
const elapsedMs = client.getForegroundTimeMs() - start;
```

`client.tracker.getForegroundTimeMs()` 返回同一读数。读数是本次 SDK 实例的累计前台运行毫秒数，配置刷新、`newSession()`、`session_end` 不会清零；新建实例或重启从零开始，不要跨初始化保存后相减。读取只访问内存，不推进采样、写盘或发送事件。精度沿用现有 1 秒采样口径，后台不累计，广告挂起可能少计；单位为毫秒不代表毫秒级采样精度。SDK 自动 session 时长是同一时钟减去该 session 的起始读数。

## Optional URL attribution

URL attribution is opt-in. It sends only an allow-list of campaign parameters
and the referrer host; it never uploads the full URL or full referrer.

```ts
const gameAlgo = GameAlgoWebClient.init({
  baseUrl: "https://game-algo-sdk.dictapis.cn",
  gameKey: "ga_live_xxx",
  autoUrlAttribution: true,
});

// Or call this after consent with a custom allow-list.
await gameAlgo.syncUrlAttribution({
  parameterNames: ["utm_source", "utm_campaign", "partner_click_id"],
});
```

`ga_live_*` is a browser client identifier and is visible to end users. Never
embed a `ga_admin_*` key, persist the raw Client Key, or write it to logs.

The npm package includes the worker entry and declares its QuickJS dependency.
Use a modern bundler that supports `new Worker(new URL(..., import.meta.url))`,
such as Vite, webpack, Rollup, Parcel, or an equivalent WebView build pipeline.
For Vite production builds, configure `worker: { format: "es" }` for the module
worker. `npm run check:web:pack` checks a minimal production build and asserts
that it contains exactly one referenced WASM file matching release-sync.

## Lightweight multiplayer

Define a static binary protocol once. Its field order and bounds produce the
`protocolHash` used by matchmaking, so incompatible builds never share a room.

```ts
import { connectRoom, defineMultiplayerProtocol, GameAlgoWebClient } from "@gamealgo/web";

const protocol = defineMultiplayerProtocol({
  id: "counter-duel",
  version: 1,
  roomInit: { seed: "u32" },
  sharedState: { scores: { type: "array", items: "u16", maxLength: 2 } },
  seatState: { ownScore: "u16" },
  hostState: { scores: { type: "array", items: "u16", maxLength: 2 } },
  input: { taps: "u8" },
});

const gameAlgo = GameAlgoWebClient.init({
  baseUrl: "https://game-algo-sdk.dictapis.cn",
  gameKey: "ga_live_xxx",
});

async function startMatch() {
  const match = gameAlgo.matchmaking.join({
    queueId: "casual_1v1",
    protocolHash: protocol.hash,
    canHost: true,
  });

  cancelButton.addEventListener("click", () => match.cancel(), { once: true });

  try {
    const matched = await match.waitForMatched();
    return await connectRoom(matched.relayUrl, matched.ticket, protocol);
  } catch (error) {
    if (error instanceof Error && error.message === "match_cancelled") return undefined;
    throw error;
  }
}
```

`MatchHandle.cancel()` is idempotent and cancels token acquisition or removes
the client from the active queue. It rejects `waitForMatched()` with
`match_cancelled` and intentionally does not call `onError`. Cancellation only
applies while queued: once the Controller has selected a group and started room
allocation, it does not roll that room back.

Queues configured for lobbies support public discovery, unlisted room codes,
leader-controlled start, direct custom rooms, and whole-party matchmaking.
Lobby queues do not accept the automatic `join()` API.

```ts
const page = await gameAlgo.matchmaking.listLobbies({
  queueId: "custom_duel",
  protocolHash: protocol.hash,
  limit: 20,
});

const lobby = page.items.length > 0
  ? gameAlgo.matchmaking.joinLobby({
      lobbyId: page.items[0].lobbyId,
      protocolHash: protocol.hash,
    })
  : gameAlgo.matchmaking.createLobby({
      queueId: "custom_duel",
      protocolHash: protocol.hash,
      visibility: "public",
      metadata: { map: "small", mode: "friendly" },
    });

const snapshot = await lobby.waitForLobby();
renderLobby(snapshot);
lobby.onChanged(renderLobby);

startButton.addEventListener("click", () => lobby.start());
kickButton.addEventListener("click", () => lobby.kick(selectedMemberId));
leaveButton.addEventListener("click", () => lobby.leave());

const matched = await lobby.waitForMatched();
const room = await connectRoom(matched.relayUrl, matched.ticket, protocol);
```

Create an unlisted lobby and share `snapshot.roomCode` for private rooms. Only
the current lobby leader may call `start()`, `cancelMatchmaking()`,
`kick(memberId)`, or `closeLobby()`. A leader cannot kick itself. Kicking a
member while a party is queued cancels that party's queue entry and restores
the lobby to `open`; members cannot be kicked once room creation has started.
Joining means ready; V1 has no separate ready toggle. A direct lobby creates a
Relay room from its current members. A matchmaking lobby freezes a complete
party and matches it only with other complete parties, with no solo backfill.
Rating-enabled queues anchor the longest-waiting player or party, then choose
the closest compatible rating within the queue's current expanding range.
Queues configured with `partialStartOnTimeout` may start with fewer complete
parties when their matchmaking deadline expires. For example, a two-player
party queue targeting six players starts with two, four, or six humans; the
game host owns any AI used to fill the remaining gameplay slots.
`matched.teamIndex`, `room.teamIndex`, and `room.roster`
expose the server-assigned teams. A member Lobby snapshot includes each
member's game-scoped `userId`; public listings do not expose member identity.
Lobby metadata is immutable, limited to 16 scalar fields and 512 encoded bytes.

Non-host players send only aggregated input. The host publishes complete
public and per-seat snapshots at up to 10 Hz and a self-contained recovery
snapshot at up to 1 Hz. The SDK handles `hostEpoch`, reconnect and migration
handshakes. Multiplayer does not emit analytics events automatically.

Use the default `latest` input delivery for transient controls where only the
newest aggregate matters. Turn-based actions that must survive a pause or a
short disconnect can opt into acknowledged, at-least-once delivery:

```ts
const actions = room.createInputQueue({
  delivery: "reliable",
  intervalMs: 50,
  maxQueuedInputs: 128,
  ackTimeoutMs: 3000,
  aggregate: (pending) => ({ actions: pending.length }),
  onError: reportNetworkError,
});
```

Reliable delivery allows one queue per room and keeps only one batch in flight.
Batches remain queued while the room is paused, are retried immediately when
the room becomes active again, and continue retrying until the host SDK
acknowledges them. Delivery is at least once across host migration. Games do
not need to add a transport-level `actionNo` by default; when duplicate or
stale actions can change the outcome, use a game-owned `turnId`, `roundId`,
`commandId`, or an equivalent idempotent state transition. Creating a second
reliable queue before closing the first throws `reliable_input_queue_exists`.

Matchmaking retries transient token/controller failures twice by default.
Initial Relay connection retries once, and established rooms reconnect for up
to 30 seconds with bounded backoff. Tune this with `connectionRetries`,
`connectionTimeoutMs`, `connectRetries`, `connectTimeoutMs`, and
`reconnectWindowMs`. Failures are `GameAlgoMultiplayerError` values with stable
`code`, `phase`, and `retryable` fields; `message` remains equal to `code` for
backward compatibility. `match_timeout` ends the current matchmaking attempt
and is not classified as retryable; the UI may let the player explicitly join
again or choose another queue.

Telemetry still uses the general 5-second batching interval. Explicitly call
`await gameAlgo.flush()` after a match result or another diagnostic boundary
that needs to be visible immediately.

Run `npm run check:web:multiplayer` for a real two-page Chrome E2E, or see
`examples/multiplayer-web-demo` for the full sample.

## Compatibility checks

`npm run check:web:e2e` runs the packaged SDK in Chrome. On macOS with Xcode
installed, `npm run check:web:webview` builds a minimal native iOS app and runs
the same fixture twice inside a real iPhone Simulator `WKWebView`. The WebView
check covers the QuickJS worker, DDA, IndexedDB identity persistence, session
lifecycle, event upload, and allow-listed URL attribution.
