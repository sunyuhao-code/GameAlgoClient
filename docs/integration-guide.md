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
- Use the SDK-generated anonymous `userId` by default. iOS reuses the old SDK's `gamealgo_user_id`, so existing players keep stable assignments after updating. Android core and REST helper need `cacheStorage` / `storage` configured to persist that ID across launches.
- Cache config for `ttlSeconds`.
- Cache config files by hash or `ETag`.
- SDK users can manually fetch an admin Configs file when needed:
  - iOS: `try await sdk.fetchConfigFile("gameplay.json")`
  - Android: `sdk.fetchConfigFile("gameplay.json")`
  - REST: `await client.fetchConfigFile("gameplay.json")`
- Use the SDK tracker for events. It batches in memory, flushes periodically, and retries the failed batch.
- Experiment assignments are stored in the SDK context created during config fetch; events do not copy experiment fields.
- Do not block gameplay on GameAlgo network calls.
- Fall back to local defaults when GameAlgo is unavailable.

## 4. Required Events

Minimum recommended events:

```text
session_end
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
- Reinstall/update behavior keeps the same SDK anonymous `userId` where platform storage is preserved.
- Debug or QA events set `isDebug=true`.
- Production builds use `ga_live_*`.
- Events continue retrying after temporary network failures.
