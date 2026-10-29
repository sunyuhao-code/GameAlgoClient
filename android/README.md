# GameAlgo Android SDK

这是符合 Protocol v1 的 Android SDK core。

当前实现发布为无第三方运行时依赖的 Android AAR，最低支持 Android API 24。每个 Git tag 对应的 AAR 可从该版本的 GitHub Release 下载。

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
sdk.tracker().trackMilestone("new_user", "进入第一关")
// Registered placement: ID comes from CLI; payload can contain the callback trackId.
sdk.tracker().trackAdPlacement(adPlacementId, 0.018, "admob", payload)
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

里程碑必须使用 `trackMilestone`。`trackEvent("milestone", ...)` 是自定义事件入口，
会实际发送 `_milestone`，不能用于标准里程碑漏斗。

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

如果实验分组包含 `script`，SDK 会使用 `script.url` 下载配置里精确引用的不可变版本，按 `versionId` 隔离缓存，并在执行前校验 SHA-256；不会按文件名回退到最新脚本。AAR 已内置受限 Rust 脚本 runtime，`executor.execute(state)` 无需接入方配置即可执行预加载脚本。AAR 包含 `armeabi-v7a`、`arm64-v8a` 和 `x86_64` 三种 ABI，native library 支持 Android 16 KB page size。仍可在高级构造函数中注入自定义 `GameAlgoScriptRuntime`。

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

`tracker()` 每批最多上传 100 条，普通事件每 30 秒 flush 一次。通过 Android AAR 接入时，SDK 默认使用 App 的 no-backup 文件目录，事件入队即同步持久化，完整记录包含在途事件、未关闭会话和待恢复的原配置请求；成功 ACK 后才移除对应事件。旧版 JSON Lines 队列在首次启用生命周期记录时迁移，仍按 Game Key、服务地址和匿名用户隔离。自定义 `GameAlgoCacheStorage` 继续受支持，持久化保证取决于该实现；纯 JVM 环境不安装 Android 监听，未配置存储时仍为进程内 best-effort。事件入队时固定 `sessionId` 和已有的 `contextId`，刷新配置不会重绑旧事件。`fetchConfig`、`fetchConfigFile` 和 `uploadEvents` 仍是阻塞方法，App 应从自己的后台 executor 或 coroutine 调用。

Android AAR 内置的非导出 ContentProvider 在 Application 启动时安装进程级监听，无需修改游戏 Activity。所有 Activity（包括广告 Activity）都停止持续 100ms 后，立即生成并保存 `reason=background` 的 `session_end`，再异步 Flush；同时监听 `onTrimMemory(TRIM_MEMORY_UI_HIDDEN)` 和 `SCREEN_OFF`，这两种明确后台信号不等待 100ms。正常广告 Activity 切换不结束会话；从广告页回桌面会结束。配置变更重建 Activity、单纯的其他内存压力通知不作为后台结束；亮屏留在桌面或锁屏界面不恢复前台。恢复前台不更换 `sessionId`，后续再次退后台可再次上报。

前台每 10 秒保存最后观察时间，广告 Activity 显示期间也更新。进程被直接杀死且没有后台通知时，下次初始化为未关闭旧会话补 `reason=process_restart`、`recovered=true`、`endTimeEstimated=true` 的结束事件。时间和时长采用上次最后观察值，不包含重启间隔；保留旧用户、session、context 和预留 eventId。恢复事件与新会话标记一起提交，重复启动不会为同一旧会话不断生成新 ID。未取得 context 的旧事件使用已保存的原 `/v1/config` 请求补取，只绑定原 session。存储不可用时保留内存状态供后续重试。`tracker().close()` 会解除该 tracker 的生命周期订阅。

`tracker().newSession()` 自动为尚未结束的旧会话生成 `reason=new_session` 的 `session_end`，保留旧用户、session 和 context，时长截止本次切换；尝试持久化完整未发送队列（含在途事件）后立即调度 `flushAsync()`，不等待网络成功才切换。无需先手动调用 `trackSessionEnd()`。旧会话已入队过结束事件时不再补报，也不延长原时长；`newSession(currentSessionId)` 为无操作。存储不可用时仍保留内存队列，持久化能力仍取决于配置的 storage。

切换不再丢弃未绑定的旧事件；它们等待原会话的真实 context，不能使用新会话的 context，也不会阻塞已绑定事件上传。迟到的配置响应只为原会话补 context，不会覆盖新会话快照；自定义配置接入可通过 `bindSessionContext(sessionId, contextId)` 补绑定。

自定义事件有固定本地配额：单 `context × eventType` 1,000 条、单 context 合计 5,000 条、单 context 最多 100 种。达到阈值后 `track` 返回 `false`、事件不入队，并异步采样报告 SDK 诊断；标准语义事件不占用这组配额。不要重试或改名绕过拒绝。

SDK 初始化从 `/v1/config` 获取当前普通事件额度，并把它作为单 Context 的本地安全上限；达到上限后新的普通事件会返回 `false` 且不入队，`purchase`、`ad_view` 不受该上限影响。该保护用于阻止错误埋点循环持续请求，服务端的每用户每日额度仍是最终判定。

`userId` 始终是 GameAlgo 生成并持久化的匿名设备标识，用于现有实验分流和报表。游戏已经登录的业务用户可以在 `GameAlgoFetchConfigRequest` 中额外传入 `accountUserId`，已知注册时间时再传 `accountUserCreatedAt`；两者不会覆盖匿名 `userId`。context 保存完整账号身份，后续事件自动携带 `accountUserId`。

`trackAdPlacement` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `trackAdPlacement`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `trackAdPlacement`。

国内游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果接入 Adjust 等归因 SDK，在每次归因 callback 返回后都可以调用 `setAttribution`。SDK 会自动带上 `platform=android`，并保存服务端返回的 `attributionHash`；同一份归因已经成功 ack 后不会重复上传，归因变化或上次失败时会重试。开发者不需要自己维护重试状态或 `attributionHash`。

Adjust ADID、Firebase App Instance ID 和 Google Advertising ID 通常会在不同时间异步返回。谁先返回就单独调用对应 setter：

```kotlin
sdk.setAdjustAdid(adjustAdid)
sdk.setFirebaseAppInstanceId(appInstanceId)
sdk.setGoogleAdvertisingId(gaid)
sdk.setOaid(oaid)
```

这些无依赖 core API 会等待初始配置并执行网络请求，Android App 应从自己的后台 executor 或 coroutine 调用，不要阻塞主线程。SDK 会自动关联当前会话的 `sessionId`、`contextId` 和 GameAlgo `userId`；新会话的 context 尚未就绪时抛出异常，接入方可稍后重试。每次 setter 调用都会追加一条带时间的设备映射记录。用户撤回授权、标识不可用时传 `null`，全零的 GAID / OAID 也会记录为清除操作。只在取得用户授权且符合应用隐私政策时采集这些标识。

用于 Adjust S2S 回传时，`gaid` 会映射为 Adjust 参数 `gps_adid`，`adjust_adid` 会映射为 `adid`。`firebase_app_instance_id` 不发送给 Adjust，它用于后续 Firebase/Google 事件链路。GameAlgo Android core 不引入 Google Play Services、MSA 或 Adjust SDK，因此不会自行读取这些标识；接入方应从对应 SDK 的异步回调取得值后调用 setter。标识上报失败由接入方重试，不进入事件队列。

事件业务字段通过 `payload` 发送。后续由游戏自己的 report pack 声明哪些 payload 字段会成为报表维度或指标。实验分组存储在 `/v1/config` 创建的 SDK context 中，不会复制到每条事件。

## 检查

```bash
mkdir -p /tmp/gamealgo-android-classes
javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest

# 需要 JDK 17 和 Android SDK 35
./gradlew :assembleRelease
```

本地 AAR 输出到 `build/outputs/aar/`。向 GitHub 推送 `v1.2.3` 或 `1.2.3` 形式的 tag 时，Release workflow 会自动构建 `gamealgo-android-1.2.3.aar`，生成 SHA-256 校验文件并附加到 GitHub Release。

## AAR 集成 Demo

`demo/` 是一个最小 Android App。它只依赖构建后的 AAR，不直接依赖 SDK 源码模块，用来验证真实接入方能否编译并调用公开 API。

```bash
cd android
./test-aar-integration.sh
```

该命令会依次构建 release AAR、检查 AAR 类清单与原生库、编译只依赖 AAR 的 Demo APK，并检查 APK 的 16KB 对齐：

```text
demo/build/outputs/apk/debug/demo-debug.apk
```

Android CI 执行 SDK JVM 核心测试与上述构建／产物校验，上传 AAR 和 Demo APK，不启动模拟器。设备上的 API／原生运行时集成测试保留为本地命令：

```bash
# 先启动本地 API 24+ 模拟器或连接测试设备；在 android/ 下执行
./gradlew --no-daemon :demo:connectedDebugAndroidTest \
  -PgameAlgoAar="$PWD/build/outputs/aar/gamealgo-android-release.aar"
```
