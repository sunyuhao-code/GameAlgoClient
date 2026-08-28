# GameAlgo TapTap Maker / 小游戏 Lua SDK

TapTap Maker 客户端支持直接访问 GameAlgo HTTPS API。接入时把以下文件放入客户端脚本，不需要开启多人模式，也不需要部署服务端代理：

- `GameAlgo.lua`
- `HttpTransport.lua`
- `LuaScriptRuntime.lua`
- `Sha256.lua`
- `DDA.lua`
- `MakerAutoStorage.lua`

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
    platform = "rest",
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
    },
})
```

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取。`ga_admin_*` 只能给 CLI 使用，不能放入客户端。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`，表示当前小游戏版本支持的实验参数能力。它需要固定在发布代码中，不能在运行时查询 latest；没有接入实验时可省略，默认是 `0`。

关于何时创建新版本、Strategy 最低版本和托管实验覆盖率门槛，运行 `gamealgo docs experiments --host <admin-host>` 查看当前平台规则。

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

事件会先进入队列。如果配置还没准备好，`Flush` 会等待拿到 `contextId` 后再上传。普通事件默认每 5 秒批量 Flush；队列达到一个 batch 时也会立即发送。SDK 在 `Init` 内部自动订阅 Maker 的 `Update` 事件，用它驱动定时 Flush、15 秒请求 watchdog 和失败后的退避重试，接入方不需要修改游戏 Update。自定义运行时如果不提供 Maker `SubscribeToEvent`，后续的 Track/Flush 仍会检查批量阈值和超时并尝试自愈，也可在测试中手动调用 `GameAlgo.Update()`。

`GameAlgo.TrackAd` 在广告事件入队后会立即 Flush。发送前，SDK 会把 inflight batch 和剩余队列按 JSON Lines 写入内部自动存储；下次启动自动恢复，服务端完整 ACK 后才删除持久化副本。请求超过 15 秒没有终态回调时，watchdog 会释放请求、把 inflight batch 放回队首，并按退避间隔重试。迟到或重复回调由 request token 忽略；成功后 SDK 会连续发送，直到所有已有 context 的事件全部排空。事件入队时即固定 `sessionId` 和已有的 `contextId`；同一 session 刷新 context 不会重绑旧事件，切换 session 只会丢弃上一 session 尚未绑定 context 的事件。

队列默认最多保留 10,000 个事件，包含 inflight batch；达到上限时新的 Track 调用会返回 `false, "event queue is full ..."`，避免断网或宿主异常造成无界内存增长。payload 会在入队前做快照和 JSON 可序列化校验，非法结构不会污染整个发送队列。服务端响应的 `accepted` 必须等于发送条数；部分接收按失败处理并保留整批重试，服务端通过稳定 `eventId` 幂等去重。

测试或特殊运行环境可在 `Init` 中覆盖 `flushIntervalMs`、`flushTimeoutMs`、`maxBatchSize` 和 `maxQueueSize`。业务代码通常保持默认值即可。

`userId` 始终是 GameAlgo 生成并持久化的匿名设备标识，用于现有实验分流和报表。Maker 可用的 `getUserId()` 会自动写入独立的 `accountUserId`，不会替换匿名 `userId`；已知账号注册时间时也可以在 `GameAlgo.Init` 传 `accountUserCreatedAt`。context 保存完整账号身份，后续事件自动携带 `accountUserId`。

```lua
GameAlgo.TrackLevelEnd({
    level = 3,
    result = "win",
})

GameAlgo.TrackAd("rewarded_level_end", "reward", 0.018, "CNY", "admob")

GameAlgo.TrackSessionEnd()
GameAlgo.Flush()
```

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

客户端 HTTP 请求由 `HttpTransport.lua` 异步执行，不依赖 update loop 轮询网络进度。SDK 会自行订阅 Maker Update 驱动定时 Flush、watchdog 和失败重试，开发者不需要新增调用。Transport 会持有活动请求对象直到终态回调，创建、参数设置或 `Send` 的同步异常会转换成普通请求错误，同一请求只允许结算一次。

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
