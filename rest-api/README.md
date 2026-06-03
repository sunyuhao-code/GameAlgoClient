# GameAlgo REST API v1

This guide is for teams that cannot use the official iOS or Android SDK.

All REST requests use the same Protocol v1 endpoints as SDKs.

## TypeScript Helper

This repository includes a small dependency-free REST helper:

```ts
import { GameAlgoRestClient } from "./src/index.ts";

const client = new GameAlgoRestClient({
  baseUrl: "https://gamealgo.example.com",
  gameKey: "ga_live_xxx",
  sdkVersion: "1.0.0",
  appVersion: "1.2.3",
});

const levelGenerator = client.executor("level_generator");

const variant = levelGenerator.variant("control");
const difficulty = levelGenerator.string("difficulty", "normal");
const result = await levelGenerator.execute({ turn: 7 });
const adsEnabled = client.config.bool("ads.rewarded.enabled", true, "gameplay.json");

client.tracker.trackLevelEnd({ level: 3, result: "win" });
client.tracker.trackSessionEnd();
await client.tracker.flush();
```

`new GameAlgoRestClient(...)` refreshes `/v1/config` and preloads config files in the background. It also creates or reuses the SDK anonymous `userId`; pass `storage` when initializing if the helper should persist that ID across app launches. `executor` and `config` read the latest local snapshot, so game logic does not need to call remote APIs when checking variants or tuning values.

Files created under the admin Configs page can be fetched directly when needed:

```ts
const gameplay = await client.fetchConfigFile("gameplay.json");
```

The helper logs user id, config fetch, experiment assignment, config file, and script preload status to `console.log` by default. Pass `logger: false` to silence logs, or provide a custom logger function.

If an experiment assignment includes `script`, `executor.execute(state)` runs the preloaded script. Config-only experiments return their config as the execution payload.

`fetchConfig` remains available for lower-level usage and caches the last successful config in memory until `ttlSeconds` expires. Use `forceRefresh: true` to bypass the cache.

The helper sends `userCreatedAt` and basic `device` context with `/v1/config` automatically. Pass `device` or `deviceId` to `new GameAlgoRestClient(...)` or `fetchConfig` to add app-specific fields or override defaults.

`tracker` queues events in memory, uploads at most 100 events per batch, flushes every 30 seconds, and keeps the failed batch for the next retry. If config context is not ready yet, queued events stay local and `flush` fills the current `contextId` before upload. Event payload fields are sent as `payload` and stored raw. Analytics does not interpret payload fields during ingestion; a game-specific report pack later declares which fields become report dimensions or metrics. Experiment assignments are stored in the SDK context created by `/v1/config`, not copied onto each event.

## 1. Auth

Every request must include:

```http
X-GameAlgo-Key: ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The server resolves `gameId` from this key. Do not send `gameId` as a trusted identity field.

## 2. Fetch Config

```bash
curl -s -X POST "https://gamealgo.example.com/v1/config" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "user-001",
    "sessionId": "session-001",
    "platform": "rest",
    "sdkVersion": "1.0.0",
    "appVersion": "1.2.3",
    "timezone": "Asia/Shanghai",
    "device": {
      "runtime": "rest",
      "locale": "zh-CN",
      "deviceId": "debug-device-id"
    }
  }'
```

Response:

```json
{
  "contextId": "ctx-001",
  "gameId": "Mahjong",
  "environment": "live",
  "configVersion": "2026-05-28-001",
  "ttlSeconds": 300,
  "serverTime": "2026-05-28T10:00:00Z",
  "experiments": [
    {
      "key": "level_generator",
      "experimentId": "exp-level-generator-001",
      "variant": "variant-a",
      "config": {}
    }
  ],
  "configFiles": [
    {
      "name": "gameplay.json",
      "url": "https://gamealgo.example.com/v1/config-files/gameplay.json",
      "hash": "sha256:..."
    }
  ]
}
```

Client requirements:

- cache response for `ttlSeconds`
- keep last successful config
- use local defaults if the server is unavailable

## 3. Fetch Config File

```bash
curl -s "https://gamealgo.example.com/v1/config-files/gameplay.json" \
  -H "X-GameAlgo-Key: ga_live_xxx"
```

Config files are usually JSON. Cache them by `ETag` or hash when available.

## 4. Upload Events

```bash
curl -s -X POST "https://gamealgo.example.com/v1/events/batch" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {
        "eventId": "00000000-0000-0000-0000-000000000001",
        "contextId": "ctx-001",
        "userId": "user-001",
        "sessionId": "session-001",
        "eventType": "level_end",
        "isDebug": false,
        "timestamp": "2026-05-28T10:00:00Z",
        "payload": {
          "level_id": "level_1",
          "result": "win",
          "duration_ms": 12500
        }
      }
    ]
  }'
```

Response:

```json
{
  "ok": true,
  "accepted": 1
}
```

Batch requirements:

- send at most 100 events per request
- retry with backoff on network failure
- do not block gameplay on upload
- set `isDebug=true` for test devices or QA builds
- send business fields in a flat `payload` object

## 5. Standard Events

Recommended event types:

```text
session_end
level_start
level_end
ad_view
purchase
```

Custom event names must start with `_`, for example:

```text
_button_click
_tutorial_skip
```

## 6. Error Response

```json
{
  "error": "invalid_game_key",
  "message": "Unknown or revoked game key"
}
```

Common errors:

| HTTP | error |
|------|-------|
| 400 | `invalid_request` |
| 401 | `missing_game_key` |
| 403 | `invalid_game_key` |
| 404 | `not_found` |
| 429 | `rate_limited` |
| 500 | `server_error` |

## 7. Integration Checklist

- A valid `gameKey` is configured.
- `/v1/config` returns experiments and config files.
- Config response is cached locally.
- Config files can be fetched and cached.
- `session_end` is uploaded with duration when the session finishes.
- `level_start` and `level_end` are uploaded if the game has levels.
- `ad_view` is uploaded if the game has ads.
- QA builds set `isDebug=true`.
- Production builds use `ga_live_*`, not `ga_test_*`.

## 8. Node Example

```bash
GAMEALGO_BASE_URL=https://gamealgo.example.com \
GAMEALGO_KEY=ga_live_xxx \
node rest-api/examples/node/basic.ts
```
