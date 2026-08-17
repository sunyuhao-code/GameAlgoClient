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

关于何时创建新版本、Strategy 最低版本和托管实验覆盖率门槛，运行 `gamealgo docs experiments --host <admin-host>` 查看当前平台规则。

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

如果实验分组包含 `script`，`executor.execute(state)` 会通过 SDK 内置的 Rust + QuickJS 沙箱执行配置里精确引用的不可变脚本版本。SDK 使用 `script.url` 下载、按 `versionId` 隔离缓存，并在执行前校验 SHA-256；不会按文件名回退到最新脚本，也不需要 App 注入 WebView 或 JSR-223 runtime。脚本只能读取传入的 JSON，不能访问网络、文件、系统环境、时钟或随机数，并受执行时间、内存、栈及输入输出大小限制。只有 config 的实验会直接返回 config-only 结果。

## DDA 行为窗口

```kotlin
val dda = sdk.dda("level_dda", 10)
dda.recordBehavior("item_used")
dda.recordBehavior("level_failed")
dda.completeStep("level-42")

val decision = dda.decide(
    mapOf("mode" to "normal", "progressionNo" to 43)
)
// decision.adjustment: INCREASE / KEEP / DECREASE
```

行为窗口按 strategy 存在本地，不会自动上传。脚本未准备好或返回非法动作时会安全返回 `KEEP`。

需要底层能力时，也可以直接使用这些阻塞方法：

```kotlin
val config = sdk.fetchConfig()
val gameplay = sdk.fetchConfigFile("gameplay.json")
```

SDK 会在每个请求里发送 `X-GameAlgo-Key`，按 `ttlSeconds` 缓存 `/v1/config`，并在事件产生时自动补充 `eventId`、UTC `timestamp`、本地 `createdLocalAt` 和 `isDebug`。批量上传或重试不会改写事件发生时间。

SDK 会在 `/v1/config` 请求里自动带上 UTC `userCreatedAt`、本地 `userCreatedLocalAt`、context 本地时间 `createdLocalAt` 和基础 `device` context。两个本地时间都包含 UTC offset；接入方不需要手工维护。接入方可以在完整 `GameAlgoClient` 构造函数或 `fetchConfig` 里通过 `GameAlgoFetchConfigRequest` 传入 `device` 或 `deviceId`，用于追加 App 自定义字段或覆盖默认值。

`tracker()` 会把事件排入内存队列，每批最多上传 100 条，每 30 秒 flush 一次，并保留失败批次等待下次重试。配置 `GameAlgoCacheStorage` 后，连续 3 次上传失败会把完整未发送队列按 JSON Lines 写入当前 Game Key 和匿名用户隔离的本地存储；下次启动自动恢复，服务端 ACK 后删除持久化副本。未配置 storage 时只能提供进程内 best-effort 队列。正常运行不会每条事件落盘，强制终止前的未失败内存事件仍可能丢失。事件入队时即固定 `sessionId` 和已有的 `contextId`；同一 session 刷新 context 不会重绑旧事件，切换 session 只会丢弃上一 session 尚未绑定 context 的事件。`fetchConfig`、`fetchConfigFile` 和 `uploadEvents` 在这个 core 包里是阻塞方法；Android App 应该在自己的后台 executor 或 coroutine 层调用这些底层方法。

`userId` 始终是 GameAlgo 生成并持久化的匿名设备标识，用于现有实验分流和报表。游戏已经登录的业务用户可以在 `GameAlgoFetchConfigRequest` 中额外传入 `accountUserId`，已知注册时间时再传 `accountUserCreatedAt`；两者不会覆盖匿名 `userId`。context 保存完整账号身份，后续事件自动携带 `accountUserId`。

`trackAd` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `trackAd`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `trackAd`。

国内游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果接入 Adjust 等归因 SDK，在每次归因 callback 返回后都可以调用 `setAttribution`。SDK 会自动带上 `platform=android`，并保存服务端返回的 `attributionHash`；同一份归因已经成功 ack 后不会重复上传，归因变化或上次失败时会重试。开发者不需要自己维护重试状态或 `attributionHash`。

Adjust ADID、Firebase App Instance ID 和 Google Advertising ID 通常会在不同时间异步返回。谁先返回就单独调用对应 setter：

```kotlin
sdk.setAdjustAdid(adjustAdid)
sdk.setFirebaseAppInstanceId(appInstanceId)
sdk.setGoogleAdvertisingId(gaid)
```

这三个无依赖 core API 会等待配置 context 并执行网络请求，Android App 应从自己的后台 executor 或 coroutine 调用，不要阻塞主线程。SDK 会自动关联当前 `contextId` 和 GameAlgo `userId`，并按标识类型分别做 ACK 去重；不需要额外传 `gamealgoDeviceId`，因为 `userId` 本身就是 GameAlgo 设备标识。用户撤回授权、标识不可用或 GAID 为全零值时传 `null`，服务端会记录清除操作。只在取得用户授权且符合应用隐私政策时采集这些标识。

事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些 payload 字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

## 检查

```bash
mkdir -p /tmp/gamealgo-android-classes
javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```
