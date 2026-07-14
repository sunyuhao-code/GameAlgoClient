# GameAlgo TapTap Maker / 小游戏 Lua SDK

TapTap Maker 客户端支持直接访问 GameAlgo HTTPS API。接入时把以下文件放入客户端脚本，不需要开启多人模式，也不需要部署服务端代理：

- `GameAlgo.lua`
- `HttpTransport.lua`
- `LuaScriptRuntime.lua`
- `Sha256.lua`
- `DDA.lua`

`client_main.lua` 是可直接参考的初始化示例。

## 网络白名单

在 Maker 项目网络白名单中加入 SDK 域名：

```text
game-algo-sdk.dictapis.cn
```

SDK 固定访问这个域名下的 `/v1/config`、`/v1/config-files/*`、`/v1/scripts/*` 和 `/v1/events/batch`。

## 客户端配置

```lua
local GameAlgo = require("GameAlgo")

local tapUserId = nil
if lobby and lobby.GetMyUserId then
    tapUserId = tostring(lobby:GetMyUserId())
end

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    gameKey = "ga_live_xxx",
    appVersion = "1.0.0",
    experimentIntegrationVersion = 3,
    platform = "rest",
    userId = tapUserId,
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
    },
})
```

`ga_live_xxx` 只是示例占位。实际接入必须使用真实 `ga_live_*`；如果当前没有真实 key，AI Agent 应使用 `ga_admin_*` 通过 GameAlgo CLI 创建或读取。`ga_admin_*` 只能给 CLI 使用，不能放入客户端。

`experimentIntegrationVersion` 来自 `gamealgo experiment integration-version create`，表示当前小游戏版本支持的实验参数能力。它需要固定在发布代码中，不能在运行时查询 latest；没有接入实验时可省略，默认是 `0`。

TapTap Maker 接入时推荐优先使用 Maker 环境提供的稳定用户 ID，例如 `lobby:GetMyUserId()`。这样同一个玩家跨会话、跨版本的实验分组和报表归因更稳定。不要使用昵称、头像、手机号等可识别信息作为 `userId`；如果当前运行时拿不到 Maker 用户 ID，可以传 `nil`，SDK 会退回到本地匿名 ID。

`Init` 会从客户端发起非阻塞的 `/v1/config` 请求。游戏逻辑应该保留本地默认值，只在远端配置可用时读取远端值。

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

事件会先进入内存队列。如果配置还没准备好，`Flush` 会等待拿到 `contextId` 后再上传。

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

TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

TapTap Maker 的广告回调 `result.extra` 中通常会包含内部广告 `trackId`。这是 GameAlgo 把 Maker 游戏埋点和内部广告收入数据串起来的关键字段。Maker 游戏上报 `ad_view` 时必须尽量把 `trackId` 放进 payload；广告收入可以先填 `0`，后续平台通过 `trackId` 回补真实收入。

Lua SDK 提供 `GameAlgo.ExtractAdTrackId(result)`，用于从 `result.trackId`、`result.track_id`、`result.extra` JSON、`result.msg` JSON 中解析 `trackId`。开发者仍然需要自己传入广告位、广告类型和业务字段：

```lua
sdk:ShowRewardVideoAd(function(result)
    result = result or {}
    local trackId = GameAlgo.ExtractAdTrackId(result)

    -- exposureSuccess 由游戏根据 Maker 回调语义判断。
    if exposureSuccess then
        GameAlgo.TrackAd("classic_revive", "reward", 0, "CNY", "taptap", {
            round = round,
            wave = wave,
            score = score,
            kills = totalKills,
            reviveCount = reviveCount,
            action = result.success and "completed" or "skipped",
            trackId = trackId,
        })
    end

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

客户端 HTTP 请求由 `HttpTransport.lua` 异步执行，不依赖游戏服务端连接状态，也不要求在 update loop 中轮询网络请求。
