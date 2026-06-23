# GameAlgo Protocol v1

## 1. 目标

Protocol v1 的目标是把服务端和客户端边界固定下来，让 iOS、Android、REST API 都按同一套协议实现。

v1 只解决最核心的接入问题：

- 游戏身份识别
- 配置和实验拉取
- 配置文件拉取
- 事件批量上报
- 国内 / 国外服务端部署差异抽象

v1 不做复杂权限、审批流、外部 SaaS、多租户计费或高级防刷。

## 2. 游戏鉴权

每个游戏由服务端生成一个或多个 `gameKey`。

示例：

```text
ga_test_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

客户端每个请求都带：

```http
X-GameAlgo-Key: ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

服务端通过 key 反查：

- `gameId`
- 环境：`test` / `live`
- 状态：`active` / `revoked`
- 所属区域：`cn` / `global`

客户端请求里的 `gameId` 不能作为可信来源。如果某些集成额外传了 `gameId`，服务端也必须校验它和 key 对应的游戏一致。

建议服务端只保存 key hash：

```text
game_api_keys
- id
- game_id
- key_prefix
- key_hash
- environment
- status
- created_at
- revoked_at
```

说明：移动端 key 不能被视为强机密，它主要用于识别游戏、防止不同游戏串数据、支持禁用和限流。

## 3. 通用约定

Base URL 由部署环境决定：

```text
https://game-algo-sdk.dictapis.cn
```

所有客户端接口使用 `/v1` 前缀。

通用请求头：

```http
X-GameAlgo-Key: ga_live_xxx
Content-Type: application/json
```

通用错误响应：

```json
{
  "error": "invalid_game_key",
  "message": "Unknown or revoked game key"
}
```

常用错误码：

| HTTP | error | 说明 |
|------|-------|------|
| 400 | `invalid_request` | 请求字段不合法 |
| 401 | `missing_game_key` | 缺少 `X-GameAlgo-Key` |
| 403 | `invalid_game_key` | key 不存在或已禁用 |
| 404 | `not_found` | 配置或文件不存在 |
| 429 | `rate_limited` | 请求过多 |
| 500 | `server_error` | 服务端错误 |

## 4. 拉取配置

```http
POST /v1/config
X-GameAlgo-Key: ga_live_xxx
Content-Type: application/json
```

请求体：

```json
{
  "userId": "user-001",
  "userCreatedAt": "2026-05-27T12:23:10Z",
  "sessionId": "session-001",
  "platform": "ios",
  "sdkVersion": "1.0.0",
  "appVersion": "1.2.3",
  "timezone": "Asia/Shanghai",
  "device": {
    "deviceId": "debug-device-id",
    "os": "iOS 18.0",
    "model": "iPhone"
  }
}
```

请求字段：

| 字段 | 必填 | 说明 |
|------|------|------|
| `userId` | 是 | 游戏用户 ID；没有账号体系时由 SDK 生成并持久化 |
| `userCreatedAt` | 否 | `userId` 首次生成或绑定的时间；官方 SDK 会自动生成并持久化，用于 SDK context 分析 |
| `sessionId` | 是 | SDK 生成或游戏指定的会话 ID |
| `platform` | 是 | `ios` / `android` / `rest` |
| `sdkVersion` | 是 | SDK 版本 |
| `appVersion` | 否 | 游戏 App 版本 |
| `timezone` | 否 | 客户端本地时区 |
| `device` | 否 | 设备上下文；官方 SDK 会自动补基础设备信息，接入方可覆盖或追加字段；调试或排查用，不作为强身份 |

服务端收到配置请求后会生成一条 SDK context 日志，记录可信 `gameId`、`userId`、`userCreatedAt`、`sessionId`、设备上下文和本次实验分配。后续事件只需要引用返回的 `contextId`，不再把设备信息复制到每条事件。

`/v1/config` 对同一个 `gameId + userId + sessionId` 做 5 分钟幂等缓存。5 分钟内重复请求会返回同一个 `contextId` 和同一份配置响应，不重复写 SDK context 日志；超过 5 分钟会重新计算配置和实验分组。

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
      "config": {},
      "script": {
        "name": "level-generator.js",
        "url": "https://game-algo-sdk.dictapis.cn/v1/config-files/level-generator.js",
        "hash": "sha256:..."
      }
    }
  ],
  "configFiles": [
    {
      "name": "gameplay.json",
      "url": "https://game-algo-sdk.dictapis.cn/v1/config-files/gameplay.json",
      "hash": "sha256:..."
    }
  ]
}
```

客户端行为：

- SDK 初始化时先加载上一次成功缓存，让 `executor` / `config` 立即可用。
- 每次 App 新启动都必须请求最新配置；不能因为本地缓存还在 TTL 内就跳过启动刷新。
- 新配置和配置文件拉取成功后，原子覆盖本地 snapshot 和持久化缓存。
- App 运行中可按 `ttlSeconds` 周期刷新。
- 拉取失败时继续使用上一次成功缓存。
- 没有缓存时使用游戏本地默认配置。
- 配置拉取不能阻塞游戏主流程。
- `script` 是可选字段；没有 script 的实验按 config-only 处理。

## 5. 拉取配置文件

```http
GET /v1/config-files/{fileName}
X-GameAlgo-Key: ga_live_xxx
```

示例：

```http
GET /v1/config-files/gameplay.json
```

响应：

- JSON 文件返回 `application/json; charset=utf-8`
- 文本文件返回 `text/plain; charset=utf-8`
- 服务端返回 `ETag` 或 `hash` 方便客户端判断是否更新

客户端行为：

- 文件名来自 `/v1/config` 的 `configFiles` 列表。
- 实验里的 `script.name` 也通过同一个 `/v1/config-files/{fileName}` 接口拉取。
- 客户端可以按 hash 缓存配置文件。
- 拉取失败时使用本地缓存或游戏默认值。

## 6. 批量上报事件

```http
POST /v1/events/batch
X-GameAlgo-Key: ga_live_xxx
Content-Type: application/json
```

请求：

```json
{
  "events": [
    {
      "eventId": "uuid",
      "contextId": "ctx-001",
      "userId": "user-001",
      "sessionId": "session-001",
      "eventType": "level_end",
      "isDebug": false,
      "timestamp": "2026-05-28T10:00:00Z",
      "payload": {
        "level_id": "level_12",
        "result": "success",
        "duration_ms": 12500,
        "clear_rate": 0.93
      }
    }
  ]
}
```

响应：

```json
{
  "ok": true,
  "accepted": 1
}
```

服务端行为：

- 根据 `X-GameAlgo-Key` 补充可信 `gameId`。
- 事件不能携带客户端自填 `gameId` 或 `experiments`。
- `contextId` 必须来自本 session 的 `/v1/config` 响应。
- `isDebug=true` 数据默认入库，但分析看板默认过滤。
- 单批事件建议最多 100 条。
- 重复 `eventId` 后续可用于去重，v1 可先不强制。
- `payload` 是 flat object；字段值只允许 string / number / boolean / null。
- 服务端写入时不要求提前定义所有 `payload` 字段。
- 报表配置文件负责声明哪些 payload 字段是维度、哪些是指标。

### `payload` 和报表配置

`payload` 是事件上的原始业务属性，用来描述“这条事件发生时游戏侧知道的状态”。SDK 和服务端不会在上报链路里提前区分维度和指标，也不会把所有 payload key/value 展开成宽表或明细维度。

GameAlgo 会把 `payload` 作为事件业务数据保存。后续每个游戏可以提交 report pack，声明某个报表需要读取哪些事件、哪些 payload 字段、字段类型、聚合方式和图表展示方式。

第一版 `payload` 建议保持 flat object。复杂对象或数组如果确实需要保留，官方 SDK 会序列化成字符串，但这类字段不适合作为稳定报表字段。不要把密钥、手机号、邮箱等敏感信息放进 `payload`。`gameId`、`userId`、`sessionId`、实验分组、设备信息已经由协议字段或 SDK context 提供，不要重复塞进 `payload`。

直接调用 REST API 时，即使事件没有业务字段，也应该传 `payload: {}`。官方 SDK 的 `track...` 便捷接口会自动补空 payload。

推荐标准事件：

| eventType | 说明 |
|-----------|------|
| `session_end` | 会话结束 |
| `level_start` | 关卡开始 |
| `level_end` | 关卡结束 |
| `ad_view` | 广告展示和收入 |
| `purchase` | 付费 |

`ad_view` 只表示广告已经成功曝光并产生一次有效展示；广告加载失败、未填充、播放失败、用户取消或关闭但没有完成有效曝光时，不要上报到 `ad_view`。

`ad_view` 的标准 payload 必须包含 `placement`、`adType`、`revenue`、`currency`，可以额外包含 `network`。`adType` 表示广告位类型，例如 `reward`、`banner`、`interstitial`。国内游戏、TapTap Maker / TapTap 小游戏接入时，`currency` 统一使用 `CNY`，不要默认使用 `USD`：

```json
{
  "placement": "rewarded_level_end",
  "adType": "reward",
  "revenue": 0.018,
  "currency": "CNY",
  "network": "admob"
}
```

`purchase` 的标准 payload 建议包含 `productId`、`revenue`、`currency`。国内游戏同样使用 `CNY`：

```json
{
  "productId": "starter_pack",
  "revenue": 4.99,
  "currency": "CNY"
}
```

自定义事件使用 `_` 前缀，例如 `_button_click`。

实验分组不再复制到每条事件里；服务端在 SDK context 日志中保存 `strategy_name -> variant_name`，离线统计通过 `contextId/sessionId` 关联。

## 7. 客户端 API 形态

### iOS

```swift
let sdk = GameAlgoSDK(
    gameKey: "ga_live_xxx",
    baseURL: URL(string: "https://game-algo-sdk.dictapis.cn")!
)
```

### Android

```kotlin
GameAlgo.init(
    context = context,
    gameKey = "ga_live_xxx",
    baseUrl = "https://game-algo-sdk.dictapis.cn"
)
```

### REST API

没有官方 SDK 的团队直接按 HTTP 协议接入，必须传 `X-GameAlgo-Key`。

## 8. 部署差异

GameAlgo 可以提供不同区域的服务地址。接入方只需要使用平台分配的 `baseUrl` 和 `gameKey`：

- 客户端接口始终使用 `/v1/*`。
- 客户端协议不因部署区域变化。
- 不同区域的 `gameKey` 不应混用。
