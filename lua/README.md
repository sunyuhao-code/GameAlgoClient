# GameAlgo TapTap Maker / 小游戏 Lua SDK

TapTap Maker 客户端支持直接访问 GameAlgo HTTPS API。接入时把以下文件放入客户端脚本，不需要开启多人模式，也不需要部署服务端代理：

- `GameAlgo.lua`
- `HttpTransport.lua`
- `LuaScriptRuntime.lua`
- `Sha256.lua`
- `DDA.lua`
- `MakerAutoStorage.lua`
- `Multiplayer.lua`
- `MultiplayerProtocol.lua`
- `MultiplayerWire.lua`

`client_main.lua` 是可直接参考的初始化示例。

SDK 会先同步读取 Maker `lobby:GetMyUserId()` 并暂存为 `accountUserId`，再开始 `clientCloud:Get`，因此云读取卡住时仍然能标识受影响账号。首次启动没有本地快照时，SDK 会等待云端恢复身份；若云读取在 5 秒内没有任何回调，SDK 会自动降级到本地/内存存储继续初始化，不会阻塞本次会话。`/v1/config` 遇到网络错误、限流或服务端暂时不可用时，会进行最多 3 次、间隔 1 秒和 2 秒的受控重试；鉴权等不可重试的 4xx 错误会直接返回。

## 客户端配置

```lua
local GameAlgo = require("GameAlgo")

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

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取。`ga_admin_*` 只能给 CLI 使用，不能放入客户端。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`，表示当前小游戏版本支持的实验参数能力。它需要固定在发布代码中，不能在运行时查询 latest；没有接入实验时可省略，默认是 `0`。

关于何时创建新版本、Strategy 最低版本和托管实验覆盖率门槛，运行 `gamealgo docs experiments --host <admin-host>` 查看当前平台规则。

## 轻实时联机

Maker SDK 提供和 `@gamealgo/web` 相同的匹配、Lobby、房间、房主迁移、状态同步与输入聚合协议。Lua 使用回调而不是 Promise，方法名遵循现有 Maker SDK 的 PascalCase 约定。

Maker Lua 运行时没有浏览器原生 `WebSocket` 对象；引擎的 `TRANSPORT_WEBSOCKET` 又是 UrhoX Network 协议，不能直接替代 GameAlgo 的原生 WebSocket 帧。因此宿主必须在 `Init` 时注入一个原生 Socket 适配器，SDK 不会误用引擎 Network 连接：

```lua
GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    gameKey = "ga_live_xxx",
    appVersion = "1.0.0",
    multiplayerSocketFactory = makerWebSocketFactory,
})
```

`makerWebSocketFactory(url, handlers)` 返回一个连接对象。连接对象实现：

- `SendText(text)`：发送 UTF-8 文本帧；
- `SendBinary(bytes)`：发送二进制帧，`bytes` 是 Lua string；
- `Close(code, reason)`：关闭连接。

适配器在对应网络事件发生时调用 `handlers.open()`、`handlers.text(text)`、`handlers.binary(bytes)`、`handlers.error(reason)` 和 `handlers.close(code, reason)`。SDK 会把同步触发的连接事件延迟到工厂返回以后处理。测试或特殊容器也可以在单次 `Join` / `ConnectRoom` 的 options 中传 `socketFactory` 覆盖全局适配器。

### 静态协议

字段使用有序 `{ name, schema }` 列表声明；这个顺序同时决定二进制布局和 `protocol.hash`，可与 H5 客户端直接互通：

```lua
local Protocol = GameAlgo.DefineMultiplayerProtocol({
    id = "counter-duel",
    version = 1,
    roomInit = {
        { "seed", "u32" },
        { "mapId", { type = "enum", values = { "small", "large" } } },
    },
    sharedState = {
        { "tick", "u32" },
        { "scores", { type = "array", items = "u16", maxLength = 2 } },
    },
    seatState = {
        { "hand", { type = "array", items = "u8", maxLength = 16 } },
    },
    hostState = {
        { "tick", "u32" },
        { "scores", { type = "array", items = "u16", maxLength = 2 } },
        { "deck", { type = "array", items = "u8", maxLength = 64 } },
    },
    input = {
        { "action", { type = "enum", values = { "tap", "pass" } } },
        { "value", "u8" },
    },
    events = {
        { "winner", { { "seat", "u8" } } },
    },
})
```

可用类型和 H5 一致：`bool/u8/i8/u16/i16/u32/i32/f32`、有界 `string` / `bytes`、`enum`、`array` 和 `struct`。Lua 的 `bytes` 值使用 string。不要把顶层字段写成无序 map，否则不同运行时无法保证二进制布局一致。

### 匹配、取消和进房

```lua
local match = GameAlgo.Matchmaking.Join({
    queueId = "casual_1v1",
    protocolHash = Protocol.hash,
    rating = 1200,
    canHost = true,
})

match:OnError(function(err)
    print(err.code, err.phase, err.retryable)
end)

match:WaitForMatched(function(err, matched)
    if err then
        if err.code ~= "match_cancelled" then print("match failed", err.code) end
        return
    end
    GameAlgo.ConnectRoom(matched.relayUrl, matched.ticket, Protocol, function(roomErr, room)
        if roomErr then print("room failed", roomErr.code) return end
        -- 保存 room，继续下面的初始化和对局流程。
    end)
end)

-- 玩家在排队 UI 点击取消；调用幂等，主动取消不会触发 OnError。
match:Cancel()
```

匹配凭证默认由 SDK 使用当前 Maker 匿名 `userId/sessionId` 调用 `/v1/multiplayer/access-token` 获取。`Init` 的身份存储尚未恢复时，匹配会在连接超时窗口内等待，不会临时生成第二个用户身份。

### 房间与输入

```lua
room:OnInitialized(function(init)
    LoadMap(init.mapId, init.seed)
    room:Ready()
end)

room:OnBecomeHost(function(hostState)
    if hostState then RestoreCompleteState(hostState) end
end)

room:OnInput(function(message)
    if not room.isHost or room.phase ~= "active" then return end
    ApplyInput(message.seat, message.input)
    room:PublishState({
        sharedState = BuildSharedState(),
        seatStates = { [message.seat] = BuildPrivateState(message.seat) },
    })
    room:CommitHostState(BuildCompleteRecoveryState())
end)

if room.isHost and room.phase == "initializing" then
    room:Initialize({ seed = CreateSeed(), mapId = "small" })
end

local inputs = room:CreateInputQueue({
    delivery = "reliable",
    intervalMs = 50,
    aggregate = function(items)
        return { action = "tap", value = math.min(255, #items) }
    end,
})
inputs:Push({ action = "tap", value = 1 })
```

房间还提供 `SendEvent`、`YieldHost`、`SetForeground`、`Disconnect` 和仅房主可用的 `Close`。`PublishState` 最多 10 Hz，`CommitHostState` 最多 1 Hz；等待中的状态只保留最新完整快照。`delivery="reliable"` 的输入会自动 ACK、去重和重发，每个房间只能有一个可靠输入队列，销毁对局时调用 `inputs:Close()`。

Lobby 接口为 `GameAlgo.Matchmaking.ListLobbies(options, callback)`、`CreateLobby(options)` 和 `JoinLobby(options)`；返回的 LobbyHandle 提供 `WaitForLobby`、`OnChanged`、`Start`、`CancelMatchmaking`、`Kick`、`Leave`、`CloseLobby` 和 `WaitForMatched`。字段、错误码、包大小限制和 H5 文档一致。

联机 SDK 不自动写入 GameAlgo 事件。对局开始、结束和业务行为仍由游戏按自己的口径调用 `Track*`。

Lua SDK 会自动调用 Maker 环境的 `lobby:GetMyUserId()` 作为稳定的 `accountUserId`，游戏接入代码不需要读取或传入该值。GameAlgo 自己的匿名 `userId` 仍从内部持久化快照读取，首次使用时才生成。不要使用昵称、头像、手机号等可识别信息作为 `userId`。

### 持久化存储

Lua SDK 自动管理持久化，不允许传入 `storage`：

- 优先读取 Maker `File` 本地快照，启动时同步恢复身份、脚本缓存和 DDA 状态。
- 本地快照不存在或当前运行模式不能读文件时，自动从 `clientCloud` 恢复。
- 首次云端读取完成前，SDK 会暂存埋点和 DDA 操作，不会使用空 DDA 状态提前决策。
- 写入先更新内存并尝试保存本地文件；云端写入按快照合并，在 SDK flush 时提交，避免每次行为计数都请求云端。
- `File` 和 `clientCloud` 都暂时不可用时，Maker 运行时使用内存兜底，不阻塞游戏主流程，并在后续 flush 时重试云端。

接入代码不要自行探测单机/联网模式，不要实现 GameAlgo 专用存档适配器，也不要给 `GameAlgo.Init` 传 `storage`。如果传入，SDK 会直接报错，避免本地存档和云端存档出现两套冲突语义。

`Init` 会从客户端发起非阻塞的 `/v1/config` 请求。游戏逻辑应该保留本地默认值，只在远端配置可用时读取远端值。

SDK 从 `GameAlgo.Init` 开始设置一个固定 10 秒的初始化看门狗。10 秒内拿到有效 `contextId` 就取消检查；届时仍未成功，则只通过独立的 `/v1/diagnostics/init` 接口上报一条 `initialization_timeout`，本次 Init 不重复上报，也不补发恢复事件。该接口不依赖 `contextId`，不会生成虚假 Context 或计入 DAU。显式配置 `autoFetch=false` 时不会启动看门狗。

Lua SDK 会同时记录 UTC 时间和带 UTC offset 的客户端本地时间：通过内部自动存储持久化 `userCreatedAt` / `userCreatedLocalAt`，context 上报 `createdLocalAt`，事件上报 `timestamp` / `createdLocalAt`。这些字段由 SDK 自动维护；事件进入队列时即固定发生时间，延迟上传或重试不会改写。

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

`GameAlgo.TrackAd` 在广告事件入队后会立即 Flush。发送前，SDK 会把 inflight batch 和剩余队列按 JSON Lines 写入内部自动存储；下次启动自动恢复，服务端完整 ACK 后才删除持久化副本。请求超过 15 秒没有终态回调时，watchdog 会释放请求、把 inflight batch 放回队首，并按退避间隔重试。迟到或重复回调由 request token 忽略；成功后 SDK 会连续发送，直到所有已有 context 的事件全部排空。事件入队时即固定 `sessionId` 和已有的 `contextId`；同一 session 刷新 context 不会重绑旧事件，切换 session 只会丢弃上一 session 尚未绑定 context 的事件。

队列默认最多保留 10,000 个事件，包含 inflight batch；达到上限时新的 Track 调用会返回 `false, "event queue is full ..."`，避免断网或宿主异常造成无界内存增长。payload 会在入队前做快照和 JSON 可序列化校验，非法结构不会污染整个发送队列。服务端响应必须用 `accepted + rejected.length` 说明整批每一条事件的终态；明确列入 `rejected` 的坏事件会记录日志但不重试，避免它阻塞同批和后续事件。旧服务端如果只返回无法解释的部分 `accepted`，SDK 仍保留整批并重试。

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

GameAlgo.TrackAd("rewarded_level_end", "reward", 0.018, "CNY", "admob")

GameAlgo.TrackSessionEnd()
GameAlgo.Flush()
```

里程碑必须使用 `GameAlgo.TrackMilestone`。`GameAlgo.TrackEvent("milestone", ...)`
是自定义事件入口，会实际发送 `_milestone`，不能用于标准里程碑漏斗。

Lua SDK 为存量版本保留嵌套 JSON 的传输兼容，但新接入和新增字段一律使用上面的扁平 payload。需要描述多个属性时，把它们拆成稳定、含义明确的顶层字段，不要把业务对象或数组直接塞入事件。

`GameAlgo.TrackAd` 上报的是 `ad_view`，只用于广告 SDK 确认实际产生收入的有效曝光。用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该调用 `TrackAd`；广告加载失败、未填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要调用 `TrackAd`。

TapTap Maker 的 `ShowRewardVideoAd` 关闭回调必须和“是否获得奖励”分开处理：**只要进入 `onClose` 回调，就调用一次 `GameAlgo.TrackAd`，不能放在 `if result.success then` 里面。** `result.success` 只表示用户是否完整看完广告、游戏是否应该发放奖励；用户提前关闭时通常仍然已经形成有效曝光和收入，也必须上报。加载失败、无填充或播放失败发生在展示前，不属于 `onClose` 有效曝光，只记录诊断事件。

TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

TapTap Maker 的广告回调 `result.extra` 中通常会包含内部广告 `trackId`。这是 GameAlgo 把 Maker 游戏埋点和内部广告收入数据串起来的关键字段。Maker 游戏上报 `ad_view` 时必须尽量把 `trackId` 放进 payload；广告收入可以先填 `0`，后续平台通过 `trackId` 回补真实收入。

Lua SDK 提供 `GameAlgo.ExtractAdTrackId(result)`，用于从 `result.trackId`、`result.track_id`、`result.extra` JSON、`result.msg` JSON 中解析 `trackId`。开发者仍然需要自己传入广告位、广告类型和业务字段：

```lua
sdk:ShowRewardVideoAd(function(result)
    result = result or {}
    local trackId = GameAlgo.ExtractAdTrackId(result)

    -- 这是广告关闭回调：无论 result.success 是否为 true，都上报本次曝光。
    GameAlgo.TrackAd("classic_revive", "reward", 0, "CNY", "taptap", {
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
