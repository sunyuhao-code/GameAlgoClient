# GameAlgo H5 SDK

Browser and ordinary WebView SDK for H5 games. The SDK always reports
`platform=web`; application code cannot override it.

```ts
import { GameAlgoWebClient } from "@gamealgo/web";

const gameAlgo = GameAlgoWebClient.init({
  baseUrl: "https://game-algo-sdk.dictapis.cn",
  gameKey: "ga_live_xxx",
  appVersion: "1.0.0",
  experimentIntegrationVersion: 0,
});

// Do not block first paint on this. Local defaults remain available.
await gameAlgo.waitForReady(1500);

gameAlgo.tracker.trackLevelStart({ levelId: "level_1" });
gameAlgo.tracker.track("milestone", {
  milestoneType: "new_user",
  milestonePoint: "进入第一关",
});
```

The SDK uses IndexedDB for stable anonymous identity, config snapshots,
milestone de-duplication, and its durable event queue. `localStorage` and then
in-memory storage are used as fallbacks. Events flush periodically, when a
batch fills, when the page is hidden or left, and when the browser returns
online. Event batches use `fetch(..., { keepalive: true })` and are capped at 20
events to stay below browser keepalive limits.

`ga_live_*` is a browser client identifier and is visible to end users. Never
embed a `ga_admin_*` key, persist the raw Client Key, or write it to logs.

Config-only strategies are supported. Remote script execution is deliberately
disabled in this first release; a later sandboxed Web Worker/WASM runtime can
add it without running untrusted code on the main thread.
