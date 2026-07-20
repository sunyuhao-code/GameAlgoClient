# GameAlgo iOS SDK

这是符合 Protocol v1 的 Swift Package SDK。

## 安装

通过 SwiftPM remote package 接入时，添加客户端仓库并选择 `GameAlgoSDK` product：

```text
https://github.com/sunyuhao-code/GameAlgoClient.git
```

预发布阶段可以使用 `main` branch；后续发布 tag 后再切到 `Up to Next Major Version` 规则。

如果要本地开发这个 package，也可以直接把 `ios/` 目录作为 Swift package 打开。

接入后导入库：

```swift
import GameAlgoSDK
```

## 最小 API

```swift
let country = Locale.current.region?.identifier

let sdk = GameAlgoSDK(
    gameKey: "ga_live_xxx",
    baseURL: URL(string: "https://gamealgo.example.com")!,
    experimentIntegrationVersion: 3,
    device: country.map { ["country": .string($0)] } ?? [:]
)
```

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取，不要提交占位 key 后声称接入完成。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`。它表示这个 App 构建已经实现的实验参数能力，必须固定在构建中；不要在运行时查询 latest。没有接入实验时可保持默认值 `0`。

关于何时创建新版本、Strategy 最低版本和旧客户端行为，见 [实验接入版本](../docs/experiment-integration-versions.md)。

如果需要使用按国家拆分的标准留存看板，iOS 推荐用 `Locale.current.region` 取得 ISO 国家码并写入 `device.country`。

## 使用方式

```swift
let levelGenerator = sdk.executor("level_generator")

let variant = levelGenerator.variant(default: "control")
let difficulty = levelGenerator.string("difficulty", default: "normal")
let result = levelGenerator.execute(.object(["turn": .number(7)]))
let adsEnabled = sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json")

await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3), "result": .string("win")]))
await sdk.tracker.trackAd(placement: "rewarded_level_end", adType: "reward", revenue: 0.018, currency: "CNY", network: "admob")
await sdk.tracker.trackPurchase(productId: "starter_pack", revenue: 4.99, currency: "CNY")
await sdk.tracker.trackSessionEnd()
await sdk.tracker.flush()

try await sdk.setAttribution(GameAlgoUserAttribution(
    provider: "adjust",
    attribution: [
        "network": .string("facebook"),
        "campaign": .string("launch_us"),
        "adgroup": .string("creative_a")
    ]
))
```

如果游戏启用 Adjust Server Callback，在初始化 Adjust SDK 前配置 GameAlgo 自定义 callback 参数：

```swift
sdk.configureAdjustServerCallbackParams { key, value in
    Adjust.addGlobalCallbackParameter(value, forKey: key)
}
```

`gamealgo_user_id` 和 `gamealgo_user_created_at` 不是 Adjust 内置参数，SDK 会从 GameAlgo 本地 identity 中取值并写入 Adjust global callback parameters。接入方不要手写这两个字段。

`GameAlgoSDK(...)` 会在后台刷新 `/v1/config` 并预加载配置文件。它也会在本地持久化存储中创建或复用 SDK 匿名 `userId`，因此老玩家更新后仍能保持稳定实验分组。`executor` 和 `config` 读取的是最新本地快照，所以玩法代码读取实验分组或调参值时不需要直接调用远端 API。

`baseURL` 可以包含服务路径前缀，例如 `https://dirichlet.ai/algo_sdk`。SDK 会在该前缀后追加 `/v1/*`，不会把请求发送到域名根路径。

GameAlgo 控制台 Configs 页面创建的文件也可以在需要时直接拉取：

```swift
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
```

SDK 默认会把 user id、配置拉取、实验分组、配置文件和脚本预加载状态输出到控制台。传入 `logger: nil` 可以关闭日志，也可以传入自定义 `GameAlgoLogHandler`。

如果实验分组包含 `script`，`executor.execute(state)` 会通过 JSCore 执行预加载 JavaScript 文件。只有 config 的实验会直接把 config 作为 execution payload 返回。

## DDA 行为窗口

```swift
let dda = sdk.dda("level_dda", recentWindowSize: 10)
try dda.recordBehavior("item_used")
try dda.recordBehavior("level_failed")
dda.completeStep("level-42")

let decision = dda.decide(context: .object([
    "mode": .string("normal"),
    "progressionNo": .number(43),
]))
// decision.adjustment: .increase / .keep / .decrease
```

行为窗口按 strategy 存在本地，不会自动上传。脚本未准备好或返回非法动作时会安全返回 `.keep`。

`tracker` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并在 App 进入后台或退出时主动 flush；失败批次会保留到下次重试。如果配置 context 还没准备好，事件会继续留在本地，`flush` 会在上传前填入当前 `contextId`。关键事件后可以调用 `await sdk.tracker.flush()` 手动 flush；`trackSessionEnd` 入队 `session_end` 后也会立即触发一次 flush。

`trackAd` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `trackAd`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `trackAd`。

国内游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果接入 Adjust 等归因 SDK，在每次归因 callback 返回后都可以调用 `setAttribution`。SDK 会自动带上 `platform=ios`，并保存服务端返回的 `attributionHash`；同一份归因已经成功 ack 后不会重复上传，归因变化或上次失败时会重试。开发者不需要自己维护重试状态或 `attributionHash`。

SDK 会在 `/v1/config` 请求里自动带上 UTC `userCreatedAt`、本地 `userCreatedLocalAt`、context 本地时间 `createdLocalAt` 和基础 `device` context。两个本地时间都包含 UTC offset；接入方不需要手工维护。接入方可以在 `GameAlgoSDK(...)` 或 `fetchConfig` 中传入 `device` / `deviceId`，用于追加 App 自定义字段或覆盖默认值。

事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些 payload 字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

需要底层能力时，也可以直接使用这些方法：

```swift
let config = try await sdk.fetchConfig()
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
let response = try await sdk.uploadEvents([
    GameAlgoEvent(contextId: config.contextId, userId: sdk.userId, sessionId: "session-001", eventType: "session_end", payload: .object(["sessionDurationMs": .number(125000)]))
])
```

SDK 会在每个请求里发送 `X-GameAlgo-Key`，按 `ttlSeconds` 缓存 `/v1/config`，并在事件产生时自动补充 `eventId`、UTC `timestamp`、本地 `createdLocalAt` 和 `isDebug`。批量上传或重试不会改写事件发生时间。

## 检查

```bash
swift test
```
