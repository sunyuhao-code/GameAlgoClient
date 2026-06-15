# GameAlgo REST API v1

这份文档面向无法使用官方 iOS / Android SDK 的团队。

REST 请求和 SDK 使用同一套 Protocol v1 接口。

## 1. 鉴权

每个请求都必须带上：

```http
X-GameAlgo-Key: ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

服务端会通过这个 key 解析 `gameId`。不要把客户端传入的 `gameId` 当作可信身份字段。

## 2. 拉取配置

```bash
curl -s -X POST "https://gamealgo.example.com/v1/config" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "user-001",
    "userCreatedAt": "2026-05-27T12:23:10Z",
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

响应：

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

客户端要求：

- 按 `ttlSeconds` 缓存响应
- 保留上一次成功配置
- 服务不可用时使用本地默认值
- 直接调用 REST 时，需要发送稳定的 `userId/sessionId`、持久化的 `userCreatedAt` 和有排查价值的 `device` context；官方 helper 会自动补这些字段

## 3. 拉取配置文件

```bash
curl -s "https://gamealgo.example.com/v1/config-files/gameplay.json" \
  -H "X-GameAlgo-Key: ga_live_xxx"
```

配置文件通常是 JSON。服务端返回 `ETag` 或 hash 时，客户端应该按它们缓存。

## 4. 上传事件

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

响应：

```json
{
  "ok": true,
  "accepted": 1
}
```

批量上传要求：

- 每个请求最多发送 100 条事件
- 网络失败时使用退避重试
- 上传不能阻塞游戏主流程
- 测试设备或 QA 包设置 `isDebug=true`
- 使用最近一次 `/v1/config` 响应里的 `contextId`
- 业务字段放在扁平的 `payload` object 中

GameAlgo 会把 `payload` 作为事件业务数据保存，不要求所有自定义字段在写入前预定义。后续由游戏自己的 report pack 声明哪些 payload 字段会被解析成报表维度或指标。

第一版建议 payload 保持扁平结构，字段值只使用 string、number、boolean 或 null。不要把密钥、邮箱、手机号、设备 context、实验分组或重复身份字段放进 `payload`。

TypeScript helper 提供 `client.tracker` 来处理这些行为。只有已经有自研事件队列和重试层的团队，才建议直接调用 `uploadEvents`。

## 5. 标准事件

推荐事件类型：

```text
session_end
level_start
level_end
ad_view
purchase
```

`ad_view` payload 必须包含 `placement`、`adType`、`revenue` 和 `currency`。`adType` 表示广告位类型，例如 `reward`、`banner` 或 `interstitial`。`network` 可选：

```json
{
  "placement": "rewarded_level_end",
  "adType": "reward",
  "revenue": 0.018,
  "currency": "USD",
  "network": "admob"
}
```

`purchase` payload 建议在有条件时包含 `productId`、`revenue` 和 `currency`：

```json
{
  "productId": "starter_pack",
  "revenue": 4.99,
  "currency": "USD"
}
```

自定义事件名必须以 `_` 开头，例如：

```text
_button_click
_tutorial_skip
```

SDK tracker 默认不会给自定义事件附加实验分组。需要做实验归因时，可以按事件显式开启。

## 6. 错误响应

```json
{
  "error": "invalid_game_key",
  "message": "Unknown or revoked game key"
}
```

常见错误：

| HTTP | error |
|------|-------|
| 400 | `invalid_request` |
| 401 | `missing_game_key` |
| 403 | `invalid_game_key` |
| 404 | `not_found` |
| 429 | `rate_limited` |
| 500 | `server_error` |

## 7. 接入检查清单

- 已配置有效 `gameKey`。
- `/v1/config` 能返回实验和配置文件。
- 配置响应会缓存在本地。
- 配置文件可以拉取并缓存。
- 会话结束时会上报带时长的 `session_end`。
- 有关卡的游戏会上报 `level_start` 和 `level_end`。
- 有广告的游戏会上报带 `placement`、`adType`、`revenue` 和 `currency` 的 `ad_view`。
- QA 包设置 `isDebug=true`。
- 生产包使用 `ga_live_*`，不要使用 `ga_test_*`。
