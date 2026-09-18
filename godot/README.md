# GameAlgo Godot SDK

这是符合 Protocol v1 的 Godot 4 SDK，用 GDScript 直接访问 GameAlgo HTTPS API，**不桥接** iOS / Android SDK。

支持 `android` 和 `ios` 两个导出目标。桌面导出（macOS / Windows / Linux）不支持：GameAlgo 服务端只接受 `ios`、`android`、`maker`、`web` 四个平台值，桌面构建会在 `configure` 时以 `invalid_platform` 拒绝，不会发出请求。

## 安装

把 `addons/gamealgo/` 整个目录复制到游戏项目的 `res://addons/gamealgo/`，包含 `runtime/` 下的 GDExtension 及其二进制。本目录下的 `project.godot` 和 `tests/` 只用于本仓库跑测试，游戏不需要。

二进制是构建产物，不入库。从源码构建：

```bash
npm run build:godot-runtime -- ios android   # 发布目标
npm run build:godot-runtime                  # 当前主机（macOS），仅用于跑测试
```

发布目标是 **iOS 和 Android**（三个 ABI）。iOS 部署目标 13.0，Android 走 cargo-ndk，与 iOS / Android SDK 的下限一致。

macOS 构建只是本仓库跑运行时契约测试用的宿主产物，不随游戏发布。

## 最小接入

```gdscript
const GameAlgoClient := preload("res://addons/gamealgo/gamealgo_client.gd")

var client := GameAlgoClient.new()
add_child(client)

client.configure({
    "game_key": "ga_live_xxx",
    "base_url": "https://game-algo-sdk.dictapis.cn",
    "platform": OS.get_name().to_lower(),
    "experiment_integration_version": 28,
    "storage": MyJsonStore.new(),
    "measurement_allowed": true,
})
await client.start()
```

`ga_live_xxx` 只是占位。实际接入必须使用真实 `ga_live_*`；没有真实 key 时，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取。`ga_admin_*` 不能放进客户端。

`experiment_integration_version` 来自 `gamealgo experiment integration-version create`，必须固定在发布代码里，不能运行时查 latest。

### 读实验和配置

```gdscript
var dda := client.executor("level_dda")

var group := dda.variant("control")
var pacing := dda.string("pacing", "flat")
var rows := dda.integer("tray.initialRows", 2)
var enabled := dda.boolean("enabled", false)

var decision: Dictionary = await dda.execute({"turn": 7})
```

未分组的 key 一律返回本地默认值，绝不编造分组或配置。

### 埋点

```gdscript
client.tracker.track_level_start({"levelId": "level_1"})
client.tracker.track_level_end({"level": 3, "result": "win"})
client.tracker.track_ad("rewarded_level_end", "reward", 0.018, "CNY", "admob")
client.tracker.track_purchase("starter_pack", 4.99, "CNY", {})
client.tracker.track_session_end()
await client.tracker.flush()
```

事件入队时即固定 `eventId`、UTC `timestamp`、本地 `createdLocalAt` 和当前 `sessionId`，延迟上传或重试不会改写发生时间。默认每批最多 100 条、每 30 秒 flush 一次。

国内游戏的广告和付费事件统一使用 `CNY`，不要默认 `USD`。

### Milestone 去重

```gdscript
client.tracker.track("milestone", {
    "milestoneType": "new_user",
    "milestonePoint": "进入第一关",
})
```

同一个 `milestoneType` + `milestonePoint` 组合只会上报一次，重复调用返回 `false`。已绑定 context 的里程碑会持久化，重启后不会再报；还没拿到 context 时到达的里程碑先记在本次 session，事件绑定 context 后转为持久，切换 session 则随未绑定事件一起释放。调试和正式构建的记录互相隔离。

`elapsedSinceRegistrationMs` 由 SDK 依据持久化的注册时间计算并覆写，接入方传入的值会被丢弃。两个字段缺任意一个时不做去重，事件照常上报。

### 自定义事件配额

自定义事件有固定的本地配额：单 `context × eventType` 1,000 条、单 context 合计 5,000 条、单 context 最多 100 种。达到阈值后 `track` 返回 `false`、事件不入队，并异步采样上报一条 SDK 诊断。标准语义事件（`level_start`、`level_end`、`ad_view`、`purchase`、`session_end`、`milestone`）不占用这组配额。

不要重试或改名绕过拒绝。配置还没返回 context 时产生的事件先记在本次 session 的暂挂额度上，context 到达后连同事件一起并入该 context；切换 session 会丢弃未绑定 context 的事件，对应的暂挂额度也一起释放。

## 归因

接了 Adjust 等归因 SDK 时，每次归因回调返回后都可以调用 `set_attribution`：

```gdscript
await client.set_attribution("adjust", {
    "network": "Google Ads",
    "campaign": "launch_cn",
    "adgroup": "creative_a",
})
```

SDK 会自动带上 `platform`，计算并保存服务端返回的 `attributionHash`。同一份归因成功 ack 后不会重复上传；归因变化或上次失败时会重试。接入方不需要自己维护重试状态或 hash。

Adjust 的 `organic` / `unknown` 在 `network`、`tracker_name`、`tracker_token` 上有多种拼法，SDK 会折叠成统一的 `status`，避免它们被当成真实渠道。

广告和分析标识通常在不同时间异步返回，谁先返回就单独调用对应 setter：

```gdscript
await client.set_adjust_adid(adjust_adid)
await client.set_firebase_app_instance_id(app_instance_id)
await client.set_google_advertising_id(gaid)
await client.set_idfa(idfa)
await client.set_idfv(idfv)
```

这些调用需要 context 已就绪，会自动关联当前 `contextId` 和 GameAlgo `userId`。用户撤回授权或标识不可用时传 `null`，服务端会记录清除操作；全零的 GAID / IDFA 会被自动识别为清除。只在取得用户授权且符合应用隐私政策时采集这些标识。

## platform 上报的是操作系统，不是引擎

`platform` 取运行的操作系统，只接受 `ios` 和 `android`。引擎信息走 `device` context 的 `runtime=godot` 和 `godotVersion`，不占用 `platform` 维度。

不要传 `"godot"`，那是引擎不是平台，SDK 会拒绝。取值大小写会被归一化，所以直接传 `OS.get_name().to_lower()` 在移动端是安全的；桌面端会得到 `invalid_platform`，游戏应据此跳过 GameAlgo 初始化。

## 持久化由游戏提供

`configure` 必须传 `storage`，一个实现了三个方法的对象：

```gdscript
func load_json_result(key: String) -> Dictionary   # {"status": "loaded"|"missing"|"error", "value": ...}
func save_json(key: String, value: Variant) -> bool
func remove(key: String) -> bool
```

SDK 用它持久化匿名身份、配置快照、脚本缓存和未上传的事件队列。连续 3 次上传失败后整个未发送队列会落盘，下次启动自动恢复，服务端 ACK 后删除。

## 脚本型策略失败关闭

分组里带 `script` 时，SDK 按 `script.url` 下载配置中精确引用的不可变版本，按 `versionId` 隔离缓存，执行前校验 SHA-256。

运行时缺失、脚本下载失败或哈希不匹配时，`execute()` 返回空字典，**不会编造决策**。同一分组的纯配置值仍然可读。跨源的脚本 URL 会在发请求之前就被拒绝。

## 策略运行时

`addons/gamealgo/runtime/` 是 `GameAlgoRuntime` GDExtension，注册为引擎单例。它是 `runtime/rust/`（同时服务 iOS、Android 和服务端的那份）的薄封装——沙箱预算、prelude 和执行语义全在那个 crate 里，这里不重复实现，所以不存在两份 QuickJS 需要人工对齐。

[`dirichlet-ai/pocket-native-plugins`](https://github.com/dirichlet-ai/pocket-native-plugins) 里另有一份独立的 C++ QuickJS 实现，供既有接入使用。新接入用本仓库这套。

## 检查

```bash
# 需要 Godot 4.7；或设置 GODOT_BIN 指向可执行文件
npm run build:godot-runtime
npm run check:godot
```

跑三个套件：`tests/parse_check.gd` 验证所有脚本能编译、依赖能解析；`tests/gamealgo_sdk_contracts.gd` 钉住 Protocol v1 的线上形状；`tests/gamealgo_runtime_contracts.gd` 用真实 GDExtension 跑 `protocol/fixtures/script-fixture.js`，断言的期望值和 `runtime/rust/src/lib.rs` 的单元测试逐条一致。没有当前主机的运行时二进制时，第三个套件会跳过并提示。

跨实现的漂移守卫在 Node 侧，`npm run check` 就会跑（`rest-api/src/godot-sdk-drift.test.ts`），不需要装 Godot：它直接读 GDScript 源码，校验 `ALLOWED_PLATFORMS` 没有超出 `protocol/openapi.yaml` 的 platform enum。
