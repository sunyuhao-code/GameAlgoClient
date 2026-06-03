# GameAlgo REST API v1

This guide is for teams that cannot use the official iOS or Android SDK.

All REST requests use the same Protocol v1 endpoints as SDKs.

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
- send stable `userId/sessionId` and useful `device` context when calling REST directly; official helpers fill basic device fields automatically

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
        "dimensions": {
          "result": "win"
        },
        "metrics": [
          { "key": "level", "value": 1 }
        ]
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
- send `contextId` from the latest `/v1/config` response
- put grouping fields in `dimensions` and aggregatable values in `metrics`

`dimensions` are categorical labels for filtering and group by in analytics reports. The platform stores them as `dimensions_json`, then offline jobs expand them by `eventType + key`; values are treated as labels even when the JSON value is a number. Do not put timestamps, random ids, full user ids, free text, email, phone, device info, or experiment assignments in `dimensions`.

`metrics` are the numeric values the platform can aggregate, such as sum, average, percentiles, min, or max. Put values like `durationMs`, `revenue`, `score`, and `clearRate` in `metrics`, not `dimensions`.

The TypeScript helper exposes `client.tracker` for this behavior. Direct `uploadEvents` is intended for teams that already have their own event queue and retry layer.

## 5. Standard Events

Recommended event types:

```text
session_start
session_end
config_loaded
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

SDK trackers do not attach experiment variants to custom events by default. Opt in per event when attribution is needed.

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
- `session_start` and `session_end` are uploaded.
- `level_start` and `level_end` are uploaded if the game has levels.
- `ad_view` is uploaded if the game has ads.
- QA builds set `isDebug=true`.
- Production builds use `ga_live_*`, not `ga_test_*`.
