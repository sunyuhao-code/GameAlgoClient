# GameAlgo REST API v1

这份文档面向无法使用官方 iOS / Android SDK 的团队。

REST 请求和 SDK 使用同一套 Protocol v1 接口。

## TypeScript Helper

仓库内提供了一个无第三方依赖的 REST helper：

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

`new GameAlgoRestClient(...)` 会在后台刷新 `/v1/config` 并预加载配置文件。它也会创建或复用 SDK 匿名 `userId`；如果希望 helper 跨启动持久化这个 ID，初始化时需要传入 `storage`。`executor` 和 `config` 读取的是最新本地快照，所以玩法逻辑读取实验分组或调参值时不需要直接调用远端 API。

GameAlgo 控制台 Configs 页面创建的文件也可以在需要时直接拉取：

```ts
const gameplay = await client.fetchConfigFile("gameplay.json");
```

helper 默认会把 user id、配置拉取、实验分组、配置文件和脚本预加载状态输出到 `console.log`。传入 `logger: false` 可以关闭日志，也可以传入自定义 logger 函数。

如果实验分组包含 `script`，`executor.execute(state)` 会执行预加载脚本。只有 config 的实验会直接把 config 作为 execution payload 返回。

`fetchConfig` 仍可用于底层调用，并会在内存里缓存上一次成功配置直到 `ttlSeconds` 过期。传入 `forceRefresh: true` 可以绕过缓存。

helper 会在 `/v1/config` 请求里自动带上 `userCreatedAt` 和基础 `device` context。接入方可以在 `new GameAlgoRestClient(...)` 或 `fetchConfig` 中传入 `device` / `deviceId`，用于追加 App 自定义字段或覆盖默认值。

`tracker` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并保留失败批次等待下次重试。如果配置 context 还没准备好，事件会继续留在本地，`flush` 会在上传前填入当前 `contextId`。事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

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
- 业务字段放在扁平的 `payload` object 中

## 5. 标准事件

推荐事件类型：

```text
session_end
level_start
level_end
ad_view
purchase
```

广告变现使用 `trackAd`。它会上报 `ad_view`。`ad_view` 只表示广告已经成功曝光并产生一次有效展示；广告加载失败、未填充、播放失败、用户取消或关闭但没有完成有效曝光时，不要上报到 `ad_view`。必填字段为 `placement`、`adType`、`revenue` 和 `currency`；`network` 可选。国内游戏、TapTap Maker / TapTap 小游戏接入时，`currency` 统一使用 `CNY`，不要默认使用 `USD`：

```ts
client.tracker.trackAd("rewarded_level_end", "reward", 0.018, "CNY", "admob");
```

内购或付费订单使用 `trackPurchase`。有条件时它会上报带 `productId`、`revenue` 和 `currency` 的 `purchase`。国内游戏同样使用 `CNY`：

```ts
client.tracker.trackPurchase("starter_pack", 4.99, "CNY");
```

自定义事件名必须以 `_` 开头，例如：

```text
_button_click
_tutorial_skip
```

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

## 8. Node 示例

```bash
GAMEALGO_BASE_URL=https://gamealgo.example.com \
GAMEALGO_KEY=ga_live_xxx \
node rest-api/examples/node/basic.ts
```
