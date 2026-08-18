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
  experimentIntegrationVersion: 3,
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

Helper 从 `rest-api/src/index.ts` 导出：

- `GameAlgoRestClient`
- `GameAlgoApiError`
- `GameAlgoEventTracker`
- `GameAlgoExperimentExecutor`
- `GameAlgoConfigReader`
- `createEvent`
- Protocol v1 TypeScript 类型

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取，不要提交占位 key 后声称接入完成。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`，表示当前构建已经实现的实验参数能力。它必须固定在构建配置中，不能在运行时查询 latest；没有接入实验时默认是 `0`。

`new GameAlgoRestClient(...)` 会在后台刷新 `/v1/config` 并预加载配置文件。它也会创建或复用 SDK 匿名 `userId`；如果希望 helper 跨启动持久化这个 ID，初始化时需要传入 `storage`。`executor` 和 `config` 读取的是最新本地快照，所以玩法逻辑读取实验分组或调参值时不需要直接调用远端 API。

`baseUrl` 可以包含服务路径前缀，例如 `https://dirichlet.ai/algo_sdk`。Helper 会在该前缀后追加 `/v1/*`，不会把请求发送到域名根路径。

GameAlgo 控制台 Configs 页面创建的文件也可以在需要时直接拉取：

```ts
const gameplay = await client.fetchConfigFile("gameplay.json");
```

helper 默认会把 user id、配置拉取、实验分组、配置文件和脚本预加载状态输出到 `console.log`。传入 `logger: false` 可以关闭日志，也可以传入自定义 logger 函数。

异步取得设备标识后可以分别上报，不需要等待三个值同时返回：

```ts
await client.setAdjustAdid(adjustAdid);
await client.setFirebaseAppInstanceId(appInstanceId);
await client.setGoogleAdvertisingId(gaid);
```

Helper 会自动关联当前 `contextId` 和 GameAlgo `userId`，并按标识类型分别做 ACK 去重。`userId` 本身就是 GameAlgo 设备标识，不需要再传一个 `gamealgoDeviceId`。用户撤回授权或标识不可用时传 `null`，用于清除旧映射。

如果实验分组包含 `script`，`executor.execute(state)` 会通过统一的 Rust + QuickJS 进程沙箱执行配置里精确引用的不可变脚本版本。Helper 使用 `script.url` 下载、按 `versionId` 隔离缓存，并在执行前校验 SHA-256；脚本下载后会先预解析，Rust worker 会复用已准备好的脚本上下文，并只保留有限数量的最近脚本。默认从 `GAMEALGO_SCRIPT_RUNTIME_BIN` 或已知构建路径定位 `gamealgo-script-runtime`，也可通过 `scriptRuntimeBinaryPath` 显式指定。脚本源码上限为 10 MiB，输入和输出仍分别受 256 KiB 限制。脚本只能读取传入的 JSON，不能访问网络、文件、系统环境、时钟或随机数，并受执行时间、内存、栈及输入输出大小限制。单次脚本执行默认最多 1 秒，超时会被 runtime 中断，游戏不能关闭这个安全限制。只有 config 的实验会直接把 config 作为 execution payload 返回。

策略脚本请按无状态函数编写：顶层数据使用 `const` 定义，不要使用顶层 `let`/`var`、计数器或修改顶层数组和对象；`execute(input)` 内部可以使用局部 `let`/`const`。由于脚本会预解析并复用执行上下文，必须遵守该约束；SDK 不会通过 AST 校验强制检查。

## DDA 行为窗口

关卡类游戏可以使用 SDK 的本地 DDA controller。行为类型由游戏定义，数据默认只保存在本地：

```ts
const dda = client.dda("level_dda", { recentWindowSize: 10 });

await dda.recordBehavior("item_used");
await dda.recordBehavior("level_failed");
await dda.completeStep("level-42");

const decision = await dda.decide({ mode: "normal", progressionNo: 43 });
// decision.adjustment: increase | keep | decrease
```

脚本没有准备好或返回非法动作时，`decide` 会返回 `keep` 且 `isFallback=true`。

`fetchConfig` 仍可用于底层调用，并会在内存里缓存上一次成功配置直到 `ttlSeconds` 过期。传入 `forceRefresh: true` 可以绕过缓存。

helper 会在 `/v1/config` 请求里自动带上 `userCreatedAt` 和基础 `device` context。接入方可以在 `new GameAlgoRestClient(...)` 或 `fetchConfig` 中传入 `device` / `deviceId`，用于追加 App 自定义字段或覆盖默认值。

`tracker` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并保留失败批次等待下次重试。连续 3 次上传失败后，Helper 会把完整未发送队列按 JSON Lines 写入传入的 `storage`，并按完整 Game Key 的 SHA-256 和匿名用户隔离；下次启动自动恢复，服务端 ACK 后删除持久化副本。未传 `storage` 时只能提供进程内 best-effort 队列。正常运行不会每条事件落盘，强制终止前的未失败内存事件仍可能丢失。事件入队时即固定 `sessionId` 和已有的 `contextId`；同一 session 刷新 context 不会重绑旧事件，切换 session 只会丢弃上一 session 尚未绑定 context 的事件。事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

`userId` 始终是 GameAlgo 生成并持久化的匿名设备标识，用于现有实验分流和报表。游戏已经登录的业务用户可以在 client options 或 `fetchConfig` 中额外传入 `accountUserId`，已知注册时间时再传 `accountUserCreatedAt`；两者不会覆盖匿名 `userId`。context 保存完整账号身份，后续事件自动携带 `accountUserId`。

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
    "isDebug": false,
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

## 5. 上报异步设备标识

无法使用 helper 时，可在 `/v1/config` 已返回 `contextId` 后直接调用：

```bash
curl -s -X POST "https://gamealgo.example.com/v1/context-identifiers" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "user-001",
    "sessionId": "session-001",
    "contextId": "ctx-001",
    "platform": "android",
    "identifierType": "firebase_app_instance_id",
    "identifierValue": "firebase-instance-id",
    "observedAt": "2026-08-13T10:00:00Z"
  }'
```

`identifierType` 只允许 `adjust_adid`、`firebase_app_instance_id`、`gaid`。传 `identifierValue: null` 表示清除该类型的旧映射。不要把这些标识放入普通事件 payload；只在用户授权且符合应用隐私政策时采集。

## 6. 标准事件

推荐事件类型：

```text
session_end
level_start
level_end
ad_view
purchase
```

广告变现使用 `trackAd`。它会上报 `ad_view`。`ad_view` 只表示广告 SDK 确认实际产生收入的有效曝光；用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该上报。广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要上报到 `ad_view`。必填字段为 `placement`、`adType`、`revenue` 和 `currency`；`network` 可选。国内游戏、TapTap Maker / TapTap 小游戏接入时，`currency` 统一使用 `CNY`，不要默认使用 `USD`：

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

## 7. 错误响应

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

## 8. 接入检查清单

- 已配置有效 `gameKey`。
- `/v1/config` 能返回实验和配置文件。
- 配置响应会缓存在本地。
- 配置文件可以拉取并缓存。
- 会话结束时会上报带时长的 `session_end`。
- 有关卡的游戏会上报 `level_start` 和 `level_end`。
- 有广告的游戏会上报带 `placement`、`adType`、`revenue` 和 `currency` 的 `ad_view`。
- QA 包设置 `isDebug=true`。
- 客户端运行时只使用 `ga_live_*`。QA/测试环境如需区分，可以创建单独命名的 Client Game Key，并设置 `isDebug=true`。

## 9. Node 示例

```bash
GAMEALGO_BASE_URL=https://gamealgo.example.com \
GAMEALGO_KEY=ga_live_xxx \
node rest-api/examples/node/basic.ts
```
