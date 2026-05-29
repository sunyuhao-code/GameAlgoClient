# GameAlgo Client Integration Guide

This guide is the minimum integration path for game teams.

## 1. Get A Game Key

The GameAlgo platform team provides one key per game environment:

```text
ga_test_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Use `ga_test_*` for QA builds and `ga_live_*` for production builds.

## 2. Choose An Integration

- iOS SDK: use `../ios/`.
- Android SDK: use `../android/`.
- REST API: use `../rest-api/` when a native SDK cannot be used.

All integrations call the same `/v1/*` endpoints and send `X-GameAlgo-Key` on every request.

## 3. Required Runtime Behavior

- Fetch `/v1/config` at startup or before config-dependent gameplay starts.
- Cache config for `ttlSeconds`.
- Cache config files by hash or `ETag`.
- Use the SDK tracker for events. It batches in memory, flushes periodically, and retries the failed batch.
- Do not block gameplay on GameAlgo network calls.
- Fall back to local defaults when GameAlgo is unavailable.

## 4. Required Events

Minimum recommended events:

```text
session_start
session_end
config_loaded
experiment_exposed
level_start
level_end
```

Games with ads or IAP should also send:

```text
ad_view
purchase
```

## 5. Acceptance Checklist

- The build contains the correct `gameKey`.
- `/v1/config` succeeds with the configured key.
- Config is cached locally.
- Config files are fetched and cached.
- Debug or QA events set `isDebug=true`.
- Production builds use `ga_live_*`.
- Events continue retrying after temporary network failures.
