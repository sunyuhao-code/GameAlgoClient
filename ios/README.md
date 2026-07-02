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
    device: country.map { ["country": .string($0)] } ?? [:]
)
```

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

`GameAlgoSDK(...)` 会在后台刷新 `/v1/config` 并预加载配置文件。它也会在本地持久化存储中创建或复用 SDK 匿名 `userId`，因此老玩家更新后仍能保持稳定实验分组。`executor` 和 `config` 读取的是最新本地快照，所以玩法代码读取实验分组或调参值时不需要直接调用远端 API。

GameAlgo 控制台 Configs 页面创建的文件也可以在需要时直接拉取：

```swift
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
```

SDK 默认会把 user id、配置拉取、实验分组、配置文件和脚本预加载状态输出到控制台。传入 `logger: nil` 可以关闭日志，也可以传入自定义 `GameAlgoLogHandler`。

如果实验分组包含 `script`，`executor.execute(state)` 会通过 JSCore 执行预加载 JavaScript 文件。只有 config 的实验会直接把 config 作为 execution payload 返回。

`tracker` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并在 App 进入后台或退出时主动 flush；失败批次会保留到下次重试。如果配置 context 还没准备好，事件会继续留在本地，`flush` 会在上传前填入当前 `contextId`。关键事件后可以调用 `await sdk.tracker.flush()` 手动 flush；`trackSessionEnd` 入队 `session_end` 后也会立即触发一次 flush。

`trackAd` 上报的是 `ad_view`，只用于广告成功曝光并产生一次有效展示。广告加载失败、未填充、播放失败、用户取消或关闭但没有完成有效曝光时，不要调用 `trackAd`。

国内游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果接入 Adjust 等归因 SDK，在归因 callback 返回后调用 `setAttribution`。SDK 会自动带上 `platform=ios`，并保存服务端返回的 `attributionHash`；同一份归因已经成功 ack 后不会重复上传，归因变化或上次失败时会重试。

SDK 会在 `/v1/config` 请求里自动带上 `userCreatedAt` 和基础 `device` context。接入方可以在 `GameAlgoSDK(...)` 或 `fetchConfig` 中传入 `device` / `deviceId`，用于追加 App 自定义字段或覆盖默认值。

事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些 payload 字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

需要底层能力时，也可以直接使用这些方法：

```swift
let config = try await sdk.fetchConfig()
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
let response = try await sdk.uploadEvents([
    GameAlgoEvent(contextId: config.contextId, userId: sdk.userId, sessionId: "session-001", eventType: "session_end", payload: .object(["sessionDurationMs": .number(125000)]))
])
```

SDK 会在每个请求里发送 `X-GameAlgo-Key`，按 `ttlSeconds` 缓存 `/v1/config`，并自动补充事件默认字段 `eventId`、`timestamp` 和 `isDebug`。

## 检查

```bash
swift test
```
