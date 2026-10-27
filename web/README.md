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

### Wire ad reporting explicitly

Games with ads must report `ad_view`; the Web SDK does not automatically observe
the game's advertising API. For the TapTap / Dirichlet ad chain, report once in
the existing ad `onClose` callback, just like Maker. Keep reporting independent
of `success`, `isEnded`, reward granting, error codes, or whether the callback
contains a track ID. Preserve the original `trackId`, use `revenue=0` and
`currency=CNY`, and let the platform reconcile the actual revenue.

Since `@gamealgo/web@1.0.23`, the SDK exports `extractAdTrackId(result)` to read `trackId` / `track_id` from
the callback itself or from an object / JSON string in `extra`, `msg`, or
`message`. It preserves the original non-empty string and returns `undefined`
when no ID is available. The reporter below is a game-side adapter:

```ts
import { extractAdTrackId } from "@gamealgo/web";

function createAdCloseReporter(placement: string) {
  let reported = false;
  return function onClose(result: Record<string, unknown> = {}) {
    if (reported) return;
    reported = true;
    const trackId = extractAdTrackId(result);
    const queued = gameAlgo.tracker.trackAd(
      placement, "reward", 0, "CNY", trackId ? { trackId } : {},
    );
    if (!trackId) console.warn("Ad onClose is missing trackId; fix the callback adapter");
    if (!queued) console.warn("ad_view was not queued; check SDK identity and initialization");
  };
}

const reportAdClose = createAdCloseReporter("复活激励视频");
// At the start of this request's existing onClose(result), call reportAdClose(result).
// Run the game's existing reward-completion check separately afterward.
```

Create a new reporter for each ad request; a duplicate callback for that request
must not create a second event, and the next playback must still report. A missing
`trackId` still produces `ad_view` and a diagnostic; fix the callback adapter and
never invent an ID. Do not also report at request, load, show, or reward boundaries.
Pre-display load failures, no fill, and rejected requests that do not enter
`onClose` do not count as exposures. Other ad SDKs use their documented effective
impression / revenue callback and actual amount and currency.

Before completing integration, play an ad and verify that the server accepted a
new `ad_view` with the expected fields and original callback track ID. Cover early
close and duplicate close notifications as well. `trackAd` returning `true` only
confirms enqueueing. Use `gamealgo events count --event-type ad_view --json` for
the current UTC day's live ingress count; it includes debug and repeated requests,
and disabled/unavailable counts do not prove delivery or absence. Before publishing
a production game build, inspect that build's runtime logs and request flags to
confirm non-debug telemetry (`isDebug=false`), separately from console verbosity.

The SDK uses IndexedDB for stable anonymous identity, config snapshots,
milestone de-duplication, and its durable event queue. `localStorage` and then
in-memory storage are used as fallbacks. Ordinary events flush every 5 seconds
by default, when a batch fills, when the page is hidden or left, and when the
browser returns online. Override `eventFlushIntervalMs` to change the interval;
`0` disables periodic flushing without disabling immediate critical uploads.
Event batches use `fetch(..., { keepalive: true })` and are capped at 20 events
to stay below browser keepalive limits.

When TapTap sends `tap.onHide`, or the document becomes hidden, the SDK records
a `session_end` snapshot and starts uploading it immediately. `pagehide` is a
fallback. Repeated hide notifications during the same hidden period are coalesced.
When the page becomes visible again (including back-forward cache restoration),
the SDK retains the current session ID and duration origin, refreshes its context,
and preloads current config files. A later hide can report another `session_end`
for that same session, with duration measured from the original start. Only SDK
initialization or an explicit `tracker.newSession()` creates a new session. TapTap
`onShow` received while the document is still hidden does not resume the page.
Set `autoSessionLifecycle: false` only when the game owns those boundaries;
`autoLifecycle: false` disables all automatic browser lifecycle listeners.

`ad_view` starts an immediate upload after successful enqueue, whether it comes
from `tracker.trackAd(...)` or `tracker.track("ad_view", ...)`. It does not wait
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
reports its duration through the switch. Unbound old events
remain queued for their own context and cannot inherit the new session's context.
This explicit boundary also applies when automatic lifecycle handling is disabled.

### Fullscreen ads inside an App WebView

Fullscreen ads can hide the WebView, and going Home from the ad may produce no
second hide notification. The SDK therefore records and flushes a `session_end`
snapshot on the first hide, including during ads. These snapshots bypass gameplay
event quotas and request durable queue persistence. They keep the same session ID
and original duration start. `ad_view` still uploads immediately.

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

Config-only strategies and script-backed `executor(...).execute(...)` are both
supported. `dda(...)` uses the same sandbox and persists its rolling state in
the browser store.

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
