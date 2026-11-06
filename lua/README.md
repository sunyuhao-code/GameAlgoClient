# GameAlgo TapTap Maker / 小游戏 Lua SDK

TapTap Maker 客户端支持直接访问 GameAlgo HTTPS API。接入时把以下文件放入客户端脚本，不需要开启多人模式，也不需要部署服务端代理：

- `GameAlgo.lua`
- `HttpTransport.lua`
- `LuaScriptRuntime.lua`
- `Sha256.lua`
- `DDA.lua`
- `MakerAutoStorage.lua`

`client_main.lua` 是可直接参考的初始化示例。

新接入推荐将六个模块一起放在 `scripts/sdk/`，入口写 `require("sdk.GameAlgo")`。Maker 的 `scripts/` 是脚本资源根，模块路径不带 `scripts.` 前缀。SDK 内部先尝试 `sdk.<模块名>`，再尝试根模块名；已有把文件直接放在 `scripts/`、使用 `require("GameAlgo")` 的项目可以保留原约定。

新增模块或入口脚本后，先通过项目现有 Maker 构建流程使文件进入资源 manifest，再运行宿主；源码目录中的文件存在不代表旧构建产物能加载它。缺少资源时检查资源根、构建产物及现有资源分组，不连续试造 require 路径。运行工具的入口参数以当前 Maker 文档为准。

Maker 运行时支持直接访问 GameAlgo，使用官方 SDK HTTP 通道即可联网。**Maker Web 预览就是有效宿主**：日志中的 `Web(MacIntel)`、预览目录中的 `index.html` / `__preview-bridge.js` 不表示还缺另一种“真实宿主”，不要求新建原生或 WASM 构建，也不改变 SDK 的 Maker 平台。

先查本次预览的已有初始化、配置和 Flush 日志；网页环境提供 `/opt/log/dev/user_script.log` 时先 `grep -n 'GameAlgoSDK' /opt/log/dev/user_script.log`。事件接收可由 ACK 的 `stored>0` 确认，也可由同次运行的成功配置/Flush 日志，加上对应业务事件实时计数增长及 `lastReceivedAt` 时间匹配确认。单独 `accepted` 可能包含过滤，历史总量非零也不证明本次接收；非 debug 标记从本次配置/请求核对。

证据通过后，标记 SDK 网络通过并结束网络排查，继续剩余字段、广告和报表定义检查。独立 headless 的代理/DNS失败、渲染预热或截图时机不能推翻这一结果；不搭 relay、改 transport、curl 重放或另造 WASM。计数延迟时按 `refreshIntervalMs` 最多连续查 3 次，不足则记录具体缺证，不重复切换环境试联网。只有采集相关代码/配置变化或新的宿主错误才重开检查。详细验收顺序以 Server 的 Maker 接入小节为准。

### 运行时游戏身份（仅采集观察）

SDK 每次创建 Context 请求时读取宿主 `GetAppArgv("miniapp_id")`，
仅将有效的 `tapmc...` 小游戏 ID 写入 `device.runtimeMiniappId`，
与 H5 SDK 使用相同字段。不采集项目 ID、数字 App ID 或来源字段。
只保存宿主实际返回的标识，不从业务配置或名称推断，业务 `device` 不能覆盖此字段。
没有宿主接口、接口抛错或 ID 无效时省略字段，不会阻塞初始化或事件上报。

这些信息沿用现有 Context `device_json` 落库，不重复放进每条业务事件，
不新增埋点，也不启用绑定校验或过滤；后续先确认正式环境的返回值与覆盖率。

SDK 会先同步读取 Maker `lobby:GetMyUserId()` 并暂存为 `accountUserId`，再开始 `clientCloud:Get`，因此云读取卡住时仍然能标识受影响账号。首次启动没有本地快照时，SDK 会等待云端恢复身份；若云读取在 5 秒内没有任何回调，SDK 会自动降级到本地/内存存储继续初始化，不会阻塞本次会话。`/v1/config` 遇到网络错误、限流或服务端暂时不可用时，会进行最多 3 次、间隔 1 秒和 2 秒的受控重试；鉴权等不可重试的 4xx 错误会直接返回。

## 客户端配置

```lua
local GameAlgo = require("sdk.GameAlgo")

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    gameKey = "ga_live_xxx",
    appVersion = "1.0.0",
    experimentIntegrationVersion = 3,
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
    },
})
```

Lua SDK 会自动上报 `platform=maker`，接入代码不需要也不能选择运行平台。

每次拉配置时，SDK 优先调用 `GetNativePlatform()`，失败或无法识别时再尝试 `GetPlatform()`，在 `device.os` 中填入 `ios`、`android`、`windows`、`macos`、`linux` 或 `harmonyos`。无法识别时省略此字段。Maker 的 `GetOSVersion()` 在 iPhone 上也可能返回 macOS/Darwin 描述，因此 SDK 不自动采集版本；游戏可以在 `device.osVersion` 中显式传入可信版本。`device` 的显式字段优先于自动检测，SDK 不修改传入的表。

Maker / Lua SDK 不提供匹配、Lobby、房间连接或实时状态同步；需要这些能力的 H5 游戏请使用 [`@gamealgo/web`](../web/README.md)。

`ga_live_xxx` 只是示例占位。实际接入必须通过 CLI 取得真实 `ga_live_*`。首次 Maker 接入可用真实小游戏 ID 领取临时接入凭据；已有游戏优先复用有效绑定，需要正式管理时再走 TapTap 授权或使用管理 Key。具体流程以 [Server SDK 接入文档](https://game-algo-admin.dictapis.cn/dashboard/docs/index.html?topic=sdk-integration)为准；`ga_org_*`、`ga_admin_*`、`ga_setup_*` 只给 CLI 使用，不放入客户端。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`，表示当前小游戏版本支持的实验参数能力。它需要固定在发布代码中，不能在运行时查询 latest；没有接入实验时可省略，默认是 `0`。

关于何时创建新版本、Strategy 最低版本和托管实验覆盖率门槛，运行 `gamealgo docs experiments --host <admin-host>` 查看当前平台规则。

### 持久化存储

Lua SDK 自动管理持久化，不允许传入 `storage`：

首次本地运行前，把以下相对文件名模式加入 `.gitignore`，并按项目现有格式追加到 Maker 的 `asset_ignores`，防止打包或自动同步设备状态，保留其他已有忽略规则：

```gitignore
gamealgo_sdk_storage_v1.json
gamealgo_sdk_storage_v1.backup.json
gaq_*.json
```

这些文件包含设备身份、配置缓存和待上传事件，在开发宿主中可能落到工程目录。已被跟踪的文件不会因为新增 ignore 自动退出版本控制，需要核对后另外排除；保留本地设备需要的存档，不把它作为工程资源分发。

- 优先读取 Maker `File` 本地快照，启动时同步恢复身份、脚本缓存和 DDA 状态。
- 本地快照不存在或当前运行模式不能读文件时，自动从 `clientCloud` 恢复。
- 首次云端读取完成前，SDK 会暂存埋点和 DDA 操作，不会使用空 DDA 状态提前决策。
- 身份、配置和 DDA 继续使用 SDK 快照；快照和事件目录本地采用两份交替写入的文件，启动时选择版本最新且完整可读的一份，避免目录覆盖写中断后找不到旧事件。事件队列独立分块存储，每块最多 100 条，各块同样交替写入两份文件，云端按块同步。新增事件、context 绑定和上传确认只保存受影响块，不重新编码或覆盖整个队列。云端先同步事件块，再发布块目录。
- `File` 和 `clientCloud` 都暂时不可用时，Maker 运行时使用内存兜底，不阻塞游戏主流程，并在后续 flush 时重试云端。

接入代码不要自行探测单机/联网模式，不要实现 GameAlgo 专用存档适配器，也不要给 `GameAlgo.Init` 传 `storage`。如果传入，SDK 会直接报错，避免本地存档和云端存档出现两套冲突语义。

`Init` 会从客户端发起非阻塞的 `/v1/config` 请求。游戏逻辑应该保留本地默认值，只在远端配置可用时读取远端值。

SDK 从 `GameAlgo.Init` 开始设置一个固定 10 秒的初始化看门狗。10 秒内拿到有效 `contextId` 就取消检查；届时仍未成功，则只通过独立的 `/v1/diagnostics/init` 接口上报一条 `initialization_timeout`，本次 Init 不重复上报，也不补发恢复事件。该接口不依赖 `contextId`，不会生成虚假 Context 或计入 DAU。显式配置 `autoFetch=false` 时不会启动看门狗。

### TapDB 身份关联

TapDB 身份关联默认关闭。仅在本次 `GameAlgo.Init` 取得新鲜、有效的 `/v1/config` 响应，且 `tapdbContextLinkEnabled` 为布尔值 `true` 时，SDK 才通过 Maker 宿主的 `sdk:LogEvent(name, properties)` 尝试上报一次 `gamealgo_context_link`，用于 DW 关联 GameAlgo Context 与 TapDB 身份。游戏无需另行调用，也不要自行补报该事件。

字段缺失、为 `false` 或类型异常时，不调用或探测宿主 TapDB 接口。旧的本地配置快照不能开启本次初始化的关联；首次配置失败时保持关闭。后续成功的配置响应关闭开关时，立即丢弃待发关联并停止探测；重新开启不会重置“每次 Init 最多尝试一次”的限制。已调用宿主后，SDK 无法撤回其内部处理。此开关不控制游戏自己调用的 TapDB 上报，也不影响 GameAlgo 配置与事件采集。旧版 SDK 不识别此开关，需更新游戏内的 SDK 模块才能生效。

| 自定义属性 | 含义 |
| --- | --- |
| `gamealgo_context_id` | 本次成功配置响应的 `contextId` |
| `gamealgo_device_id` | 对应配置请求的 `userId`，默认是 GameAlgo 生成并持久化的匿名设备标识；显式传入 `userId` 时使用该值 |
| `gamealgo_is_debug` | 对应配置请求的 `isDebug`，用于区分调试数据 |

属性均为扁平值。TapDB 落库时可按 `dataname=gamealgo_context_link` 定位事件，从 `_preset.gamealgo_context_id`、`_preset.gamealgo_device_id` 读取关联键，并结合 TapDB 的 `deviceid`、`userid` 等字段处理。`gamealgo_device_id` 不等同于 TapDB `deviceid`、OAID 或 CAID。

显式 `autoFetch=false` 时，在手动 `FetchConfig` 成功且开关明确开启后上报；配置请求失败或缺少有效 `contextId` 时不上报，恢复成功并获得开启许可后再尝试。一次 Init 内的配置刷新、`NewSession` 和重复响应不会重复上报，重新 Init 后需重新获取开启许可。

该事件直接走宿主 TapDB 通道，不进入 GameAlgo 事件队列、不占用普通事件额度。宿主缺少接口、抛错或返回 `false` 都不影响配置读取和游戏初始化；不在 SDK 内重试该事件，不传额外回调参数。宿主受理不代表最终落库成功，后续仍以 TapDB 数据为准。

如果配置成功且开关开启时宿主接口尚未就绪，SDK 保留该次 Context 和身份，在更新循环中每 500ms 检查接口，持续最多 10 秒，不阻塞初始化。后续成功且开启的配置响应也会再次检查接口，但不会覆盖待发的首次身份；关闭会清除该身份，之后重新开启使用新响应的身份。只有真正调用宿主前才设置“已尝试”；调用被拒绝或抛错后不再重试。重新 Init 会清除旧的待发关联。

Lua SDK 会同时记录 UTC 时间和带 UTC offset 的客户端本地时间：通过内部自动存储持久化 `userCreatedAt` / `userCreatedLocalAt`，context 上报 `createdLocalAt`，事件上报 `timestamp` / `createdLocalAt`。这些字段由 SDK 自动维护；事件进入队列时即固定发生时间，延迟上传或重试不会改写。

## 读取前台耗时

```lua
local start = GameAlgo.GetForegroundTimeMs()
-- 结束业务时读取；期间允许切换 session
local elapsedMs = GameAlgo.GetForegroundTimeMs() - start
```

返回本次 `Init` 以来累计的前台运行毫秒数；`NewSession`、配置刷新和上报 `session_end` 不清零。沿用 Maker `Update.TimeStep` 计时，广告或后台暂停时允许少计。读取只访问内存，不推进计时、不写盘、不上报。SDK 自动计算的 session 时长使用同一时钟减去 session 起点；显式传入的 `sessionDurationMs` 仍遵循原覆盖规则。再次初始化或重启从零开始，读数不要跨初始化保存后相减。

## 实验

```lua
local levelGenerator = GameAlgo.Executor("level_generator")

local variant = levelGenerator.Variant("control")
local difficulty = levelGenerator.Value("difficulty", "normal")
local result = levelGenerator.Execute({ turn = 7 })
```

实验可以绑定通过 CLI 发布的不可变 `.lua` 脚本版本：

```bash
gamealgo script publish scripts/level-dda.lua --message "level DDA v1" --json
```

Lua SDK 会根据配置中的 `script.url` 下载脚本，校验 `script.hash` 后缓存在本地，并在受限环境执行。脚本无法访问 `require`、网络、文件、`os`、`debug` 或游戏全局对象，只能读取 JSON 兼容的 `input` 并返回 JSON 兼容结果。

脚本执行兼容 Lua 5.1 的 `loadstring/setfenv` 和 Lua 5.2+ 的 `load`。如果宿主运行时关闭了动态编译能力，SDK 不会执行远端脚本，游戏继续使用本地默认逻辑。

```lua
-- level-dda.lua
return function(input)
    local failures = tonumber(input.state.failures or 0) or 0
    return {
        payload = {
            adjustment = failures >= 2 and "easier" or "keep",
        },
        diagnostics = {
            reason = failures >= 2 and "repeated_failures" or "stable",
        },
    }
end
```

脚本下载是异步的。执行前可检查：

```lua
if levelGenerator.IsReady() then
    local result = levelGenerator.Execute({ failures = 2 })
    if result then print(result.payload.adjustment) end
end
```

脚本没有准备好、hash 不一致、编译失败或执行失败时，`Execute` 返回 `nil`，游戏必须继续使用本地默认逻辑。没有绑定脚本的实验仍然返回 config-only 结果。

## DDA 行为窗口

```lua
local dda = GameAlgo.DDA("level_dda", { recentWindowSize = 10 })

dda.RecordBehavior("item_used")
dda.RecordBehavior("level_failed")
dda.CompleteStep("level-42")

local decision = dda.Decide({
    mode = "normal",
    progressionNo = 43,
})
-- decision.adjustment: increase / keep / decrease
```

行为窗口按 strategy 存在本地，不会自动上传。脚本未准备好、执行失败或返回非法动作时会安全返回 `keep`，并设置 `isFallback=true`。

## 配置文件

`/v1/config` 返回的配置文件会在配置拉取成功后预加载。

```lua
GameAlgo.FetchConfigFile("gameplay.json", function(err, file)
    if not err then
        print(file.content)
    end
end)

local enabled = GameAlgo.ConfigValue("ads.rewarded.enabled", true, "gameplay.json")
```

## 事件

事件会先进入队列。如果配置还没准备好，`Flush` 会等待拿到 `contextId` 后再上传。普通事件默认每 5 秒批量 Flush；队列达到一个 batch 时也会立即发送。SDK 在 `Init` 内部创建独立的 Maker `LuaScriptObject` Update 接收器，用它驱动定时 Flush、15 秒请求 watchdog 和失败后的退避重试；接入方不需要自己开发定时器，也不需要修改游戏 Update 或周期调用 `GameAlgo.Update()` / `GameAlgo.Flush()`。`Flush()` 仍可用于广告关闭、会话结束、进入后台等希望立即提交的边界。自定义运行时如果不提供 Maker 事件系统，后续的 Track/Flush 仍会检查批量阈值和超时并尝试自愈，也可在测试中手动调用 `GameAlgo.Update()`。

主动调用 `Flush()` 时，即使上一批 HTTP 尚未完成或事件还没有 context，也会在返回前把 inflight batch 和剩余队列一起写入本地自动存储，并触发自动存储 Flush；不会等下一帧、定时器或上一批回调才保存退出时追加的事件。已有请求继续串行发送；写入本地不代表上传成功，callback 沿用原有上传结果／错误语义。

在途请求或失败积压期间，新增变化的定时补存间隔同样为 5 秒；累计 100 个事件变化也会提前保存。发送前、上传确认后、主动 Flush 和生命周期边界仍立即保存对应变化；没有变化不写盘。

旧版本保存的 JSON Lines 队列会自动迁移；所有事件块成功写入前保留旧队列，迁移中断仍可恢复。事件的 ID、session、context 和发生时间保持原值。

`GameAlgo.TrackAdPlacement` 在广告事件入队后会立即 Flush。发送前，SDK 会把 inflight batch 和剩余队列中尚未落盘的变化写入独立事件块；下次启动自动恢复，按下述批次完成策略确认后才删除持久化副本。请求超过 15 秒没有终态回调时，watchdog 会释放请求、把 inflight batch 放回队首，并按退避间隔重试。迟到或重复回调由 request token 忽略；成功后 SDK 会连续发送，直到所有已有 context 的事件全部排空。事件入队时即固定 `sessionId` 和已有的 `contextId`；同一 session 刷新 context 不会重绑旧事件。

SDK 自动监听 Maker 的 `AppWillEnterBackground`、`AppTerminating`、`ExitRequested`，收到通知时生成标准 `session_end`，立即保存队列中尚未落盘的变化并触发 Flush。对应 `reason` 为 `app_background`、`app_terminating`、`exit_requested`，payload 同时记录 `lifecycleEvent`。该结束事件不占用普通事件额度，仍受队列容量上限约束。Maker 打开全屏广告也会触发后台通知，SDK 同样上报；同一会话后续再次退后台、退出或终止可以重复上报。不会自动切换 `sessionId`。

默认 `sessionDurationMs` 为当前会话累计的引擎运行时长：在已有的 Update 接收器中直接累加有效的 `TimeStep × 1000`，以整数毫秒生成快照。计时不维护依赖生命周期通知恢复的暂停标记；引擎在后台或全屏广告期间停止 Update 时不补算墙钟间隔。累计值只在 `Init` 或切换到不同 session 时归零，刷新 context、生命周期快照和相同 ID 的 `NewSession` 不清零。每帧计时只更新内存，不触发额外写盘或上报。自定义运行时没有 Maker Update / TimeStep 时不会凭墙钟推算游玩时长；`TrackSessionEnd` 显式提供的时长仍保留。

生命周期上报是会话时长快照，不作为游戏显式结束会话的标记；广告后继续游戏再调用 `NewSession`，仍会为旧会话生成截至切换时的结束事件。监听使用 SDK 自己的 `LuaScriptObject`，不会替换游戏的 Update 或生命周期回调。初始化存储尚未就绪时先暂存通知时刻的事件，存储就绪后保存，取得 context 后 Flush。直接杀进程而没有宿主通知时无法新建结束事件；已成功保存的队列会在下次启动恢复。

`GameAlgo.NewSession(sessionId, callback)` 自动为尚未结束的旧会话入队 `reason=new_session` 的 `session_end`，保留旧用户、session 和 context，时长截止切换；主动保存队列变化并立即触发 Flush，再取新会话配置，无需游戏先调用 `TrackSessionEnd()`。上传失败留队重试，不阻止本地切换；旧会话已手动结束时不再补报或延长时长，相同 ID 为无操作。初始化存储尚未就绪或队列全在途、无法接纳结束事件时，返回 `nil, error` 并回调错误，保留旧会话。

未绑定的旧事件不再随切换丢弃。重叠的配置请求按各自原会话排队，响应只绑定其原会话事件；旧响应不会发布为新会话的配置。已绑定事件可先发送，不被未绑定旧事件阻塞。

队列默认最多保留 500 个事件，包含 inflight batch；达到上限时新的 Track 调用会返回 `false, "event queue is full ..."`，避免断网或宿主异常造成无界内存增长。可通过 `maxQueueSize` 显式调整；升级时已有的更大队列不会被截断，会继续发送，积压未降到上限以下前不接纳新事件。payload 会在入队前做快照和 JSON 可序列化校验，非法结构不会污染整个发送队列。

事件上传采用不阻塞优先策略：有效成功响应中只要 `accepted > 0`，整批就出队，不再要求 `accepted + rejected.length` 等于发送数。其余未接收或未说明结果的事件不重试，允许丢弃；`accepted` 仍报告服务端实际接收数，不把整批出队算作全部接收成功。`rejected` 明细仅作日志和 `rejectedCount` 诊断，缺失或格式错误不会阻塞已有接收的批次。`accepted = 0` 时，只有整批都有明确的拒绝记录才出队；否则保留重试。网络错误、请求失败、无法解析的响应或非法接收数仍保留重试。日志中的 `notAccepted` 包含明确拒绝及未说明结果的事件。

自定义事件另有固定本地配额：单 `context × eventType` 1,000 条、单 context 合计 5,000 条、单 context 最多 100 种。达到阈值后 `Track` 返回 `false` 和原因、事件不入队，并通过独立 SDK 诊断接口采样报告；标准语义事件不占用这组配额。不要重试或改名绕过拒绝。

SDK 初始化从 `/v1/config` 获取当前普通事件额度，并把它作为单 Context 的本地安全上限；达到上限后新的普通事件会返回 `false` 且不入队，`purchase`、`ad_view` 不受该上限影响。该保护用于阻止错误埋点循环持续请求，服务端的每用户每日额度仍是最终判定。

测试或特殊运行环境可在 `Init` 中覆盖 `flushIntervalMs`、`flushTimeoutMs`、`maxBatchSize` 和 `maxQueueSize`。业务代码通常保持默认值即可。

`userId` 始终是 GameAlgo 生成并持久化的匿名设备标识，用于现有实验分流和报表。Maker 可用的 `getUserId()` 会自动写入独立的 `accountUserId`，不会替换匿名 `userId`；已知账号注册时间时也可以在 `GameAlgo.Init` 传 `accountUserCreatedAt`。context 保存完整账号身份，后续事件自动携带 `accountUserId`。

```lua
-- 业务 payload 使用扁平字段；不要嵌套 table 或数组，方便事件词典和报表直接读取。
GameAlgo.TrackEvent("level_item_used", {
    level = 3,
    itemName = "炸弹",
    remainingCount = 2,
})

GameAlgo.TrackLevelEnd({
    level = 3,
    result = "win",
})

GameAlgo.TrackMilestone("new_user", "进入第一关")

GameAlgo.TrackAdPlacement(AD_PLACEMENTS.rewarded_level_end, 0.018, "admob")

GameAlgo.TrackSessionEnd()
GameAlgo.Flush()
```

里程碑必须使用 `GameAlgo.TrackMilestone`。`GameAlgo.TrackEvent("milestone", ...)`
是自定义事件入口，会实际发送 `_milestone`，不能用于标准里程碑漏斗。

Lua SDK 为存量版本保留嵌套 JSON 的传输兼容，但新接入和新增字段一律使用上面的扁平 payload。需要描述多个属性时，把它们拆成稳定、含义明确的顶层字段，不要把业务对象或数组直接塞入事件。

已通过 CLI 注册广告位时，优先用 `GameAlgo.TrackAdPlacement(adPlacementId, revenue, network?, payload?)`，不再传名称、广告类型和币种，由服务端补齐。第三个参数可直接传 payload；调用仍发送标准 `ad_view`，入队后立即触发 Flush。ID 必须是注册返回的 `gap_` 加 32 位小写十六进制字符，revenue 必须有限；非法输入返回 false，不入队。SDK 不查询广告位目录。

```lua
GameAlgo.TrackAdPlacement(AD_PLACEMENTS.revive, 0, {
    trackId = GameAlgo.ExtractAdTrackId(result),
    round = round,
})
```

新版只提供 `GameAlgo.TrackAdPlacement`，已移除旧 `TrackAd`。已有游戏升级前先注册广告位并迁移调用；服务端仍兼容已经发布的旧 SDK。每次有效曝光只上报一次。

`GameAlgo.TrackAdPlacement` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `TrackAdPlacement`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `TrackAdPlacement`。

TapTap Maker 的 `ShowRewardVideoAd` 关闭回调必须和“是否获得奖励”分开处理：**只要进入 `onClose` 回调，就调用一次 `GameAlgo.TrackAdPlacement`，不能放在 `if result.success then` 里面。** `result.success` 只表示用户是否完整看完广告、游戏是否应该发放奖励；用户提前关闭时通常仍然已经形成有效曝光和收入，也必须上报。加载失败、无填充或播放失败发生在展示前，不属于 `onClose` 有效曝光，只记录诊断事件。

TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

TapTap Maker 的广告回调 `result.extra` 中通常会包含内部广告 `trackId`。这是 GameAlgo 把 Maker 游戏埋点和内部广告收入数据串起来的关键字段。Maker 游戏上报 `ad_view` 时必须尽量把 `trackId` 放进 payload；广告收入可以先填 `0`，后续平台通过 `trackId` 回补真实收入。

Lua SDK 提供 `GameAlgo.ExtractAdTrackId(result)`，用于从 `result.trackId`、`result.track_id`、`result.extra` JSON、`result.msg` JSON 中解析 `trackId`。广告位 ID 来自 CLI 注册结果，业务字段和 trackId 仍来自当前回调：

```lua
sdk:ShowRewardVideoAd(function(result)
    result = result or {}
    local trackId = GameAlgo.ExtractAdTrackId(result)

    -- 这是广告关闭回调：无论 result.success 是否为 true，都上报本次曝光。
    GameAlgo.TrackAdPlacement(AD_PLACEMENTS.classic_revive, 0, "taptap", {
        round = round,
        wave = wave,
        score = score,
        kills = totalKills,
        reviveCount = reviveCount,
        action = result.success and "completed" or "skipped",
        trackId = trackId,
    })

    if not trackId then
        GameAlgo.TrackEvent("ad_no_track_id", {
            placement = "classic_revive",
            adType = "reward",
            network = "taptap",
            message = tostring(result.msg),
        })
    end
end)
```

客户端 HTTP 请求由 `HttpTransport.lua` 异步执行，不依赖 update loop 轮询网络进度。SDK 会通过独立 `LuaScriptObject` 自行驱动定时 Flush、watchdog 和失败重试，开发者不需要自己开发定时 Flush，也不需要新增 Update 调用。Transport 会持有活动请求对象直到终态回调，创建、参数设置或 `Send` 的同步异常会转换成普通请求错误，同一请求只允许结算一次。

### Maker HTTP 全局变量兼容性

TapTap Maker / UrhoX 的 `http` 可能由 Lua 全局环境的元表动态提供。普通的 `http` 访问可以正常触发元表查找，但 `rawget(_G, "http")` 会绕过元表并错误返回 `nil`，最终导致 SDK 报 `http client unavailable in this runtime`。

**禁止使用下面的方式检测 HTTP 能力：**

```lua
if rawget(_G, "http") == nil then
    -- 错误：Maker 中可能把可用的 http 判断为不存在。
end
```

如果自定义 HTTP transport，必须通过普通全局访问并用 `pcall` 安全探测：

```lua
local okHttp, httpManager = pcall(function()
    return http
end)

if not okHttp or httpManager == nil then
    callback("http client unavailable in this runtime", nil)
    return nil
end

local client = httpManager:Create()
```

官方 `HttpTransport.lua` 已包含这一兼容处理。接入游戏时应整体使用官方文件，不要额外添加基于 `rawget(_G, "http")` 的本地兜底补丁。
