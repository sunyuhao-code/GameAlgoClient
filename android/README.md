# GameAlgo Android SDK

这是符合 Protocol v1 的 Android SDK core。

当前实现是无第三方依赖的 Java core，后续可以在不改客户端/服务端协议的前提下封装成 Android AAR 或 Kotlin facade。

## 最小 API

```kotlin
val sdk = GameAlgo.init(
    "ga_live_xxx",
    "https://gamealgo.example.com",
    "1.0.0",
    "1.2.3",
    3
)
```

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取，不要提交占位 key 后声称接入完成。

最后一个整数来自 `gamealgo experiment integration-version create`，表示这个 App 构建已经实现的实验参数能力。不要在运行时查询 latest；没有接入实验时可以继续使用两参数 `GameAlgo.init`，其版本为 `0`。

## 使用方式

```kotlin
val levelGenerator = sdk.executor("level_generator")

val variant = levelGenerator.variant("control")
val difficulty = levelGenerator.string("difficulty", "normal")
val result = levelGenerator.execute(mapOf("turn" to 7))
val adsEnabled = sdk.config().bool("ads.rewarded.enabled", true, "gameplay.json")

sdk.tracker().trackLevelEnd(mapOf("level" to 3, "result" to "win"))
sdk.tracker().trackAd("rewarded_level_end", "reward", 0.018, "CNY", "admob")
sdk.tracker().trackPurchase("starter_pack", 4.99, "CNY", mapOf())
sdk.tracker().trackSessionEnd()
sdk.tracker().flushAsync()

sdk.setAttribution(
    "adjust",
    mapOf(
        "network" to "facebook",
        "campaign" to "launch_us",
        "adgroup" to "creative_a"
    )
)
```

如果游戏启用 Adjust Server Callback，在初始化 Adjust SDK 前配置 GameAlgo 自定义 callback 参数：

```kotlin
sdk.configureAdjustServerCallbackParams { key, value ->
    Adjust.addGlobalCallbackParameter(key, value)
}
```

`gamealgo_user_id` 和 `gamealgo_user_created_at` 不是 Adjust 内置参数，SDK 会从 GameAlgo 本地 identity 中取值并写入 Adjust global callback parameters。接入方不要手写这两个字段。

`GameAlgo.init(...)` 会在后台 executor 里刷新 `/v1/config` 并预加载配置文件。它也会创建或复用 SDK 匿名 `userId`；如果 App 希望无依赖 core 持久化这个 ID，初始化时需要传入 `GameAlgoCacheStorage`。`executor` 和 `config()` 读取的是最新本地快照，所以玩法代码读取实验分组或调参值时不需要直接调用远端 API。

GameAlgo 控制台 Configs 页面创建的文件也可以在需要时直接拉取：

```kotlin
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

SDK 默认会把 user id、配置拉取、实验分组、配置文件和脚本预加载状态输出到 `System.out`。如果要关闭日志，可以在完整构造函数里把 `GameAlgoLogger` 参数传 `null`，也可以传入自定义 logger。

如果实验分组包含 `script`，`executor.execute(state)` 会通过配置的 `GameAlgoScriptRuntime` 执行预加载脚本。无依赖 core 内置了 Java 环境可用的 JSR-223 runtime；Android App 包建议注入 QuickJS 或 WebView runtime。

需要底层能力时，也可以直接使用这些阻塞方法：

```kotlin
val config = sdk.fetchConfig()
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

SDK 会在每个请求里发送 `X-GameAlgo-Key`，按 `ttlSeconds` 缓存 `/v1/config`，并自动补充事件默认字段 `eventId`、`timestamp` 和 `isDebug`。

SDK 会在 `/v1/config` 请求里自动带上 `userCreatedAt` 和基础 `device` context。接入方可以在完整 `GameAlgoClient` 构造函数或 `fetchConfig` 里通过 `GameAlgoFetchConfigRequest` 传入 `device` 或 `deviceId`，用于追加 App 自定义字段或覆盖默认值。

`tracker()` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并保留失败批次等待下次重试。如果配置 context 还没准备好，事件会继续留在本地，`flush` 会在上传前填入当前 `contextId`。`fetchConfig`、`fetchConfigFile` 和 `uploadEvents` 在这个 core 包里是阻塞方法；Android App 应该在自己的后台 executor 或 coroutine 层调用这些底层方法。

`trackAd` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `trackAd`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `trackAd`。

国内游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果接入 Adjust 等归因 SDK，在每次归因 callback 返回后都可以调用 `setAttribution`。SDK 会自动带上 `platform=android`，并保存服务端返回的 `attributionHash`；同一份归因已经成功 ack 后不会重复上传，归因变化或上次失败时会重试。开发者不需要自己维护重试状态或 `attributionHash`。

事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些 payload 字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

## 检查

```bash
mkdir -p /tmp/gamealgo-android-classes
javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```
