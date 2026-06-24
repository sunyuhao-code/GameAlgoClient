# GameAlgo TapTap 小游戏 Lua SDK

TapTap 小游戏客户端运行在沙盒中，不能直接调用 GameAlgo HTTP API。推荐使用下面的代理结构：

```text
Client
  GameAlgo.lua          SDK 业务层：config / experiment / track
  ProxyTransport.lua    RemoteEvent 传输层

Server
  ProxyServer.lua       RemoteEvent -> 真实 HTTP 代理
  server_main.lua       代理启动和服务端配置
```

## 服务端配置

TapTap Maker 接入时需要开启多人模式，也就是启用 Maker 自带的服务端能力。这个服务端由 Maker 平台部署和运行，不需要为 GameAlgo 额外部署独立后端。SDK 已提供服务端代理代码，直接使用本目录下的 `ProxyServer.lua` 和 `server_main.lua`。

把 `ProxyServer.lua` 和 `server_main.lua` 放在 TapTap 游戏服务端。真实 GameAlgo key 只配置在服务端 Proxy，用来给拉配置、拉配置文件和事件上报请求统一注入 `X-GameAlgo-Key`：

```lua
ProxyServer.Start({
    allowedHosts = { "game-algo-sdk.dictapis.cn" },
    allowedPathPrefixes = { "/v1/" },
    defaultHeaders = {
        ["X-GameAlgo-Key"] = "ga_live_xxx",
        ["X-Proxy-Source"] = "maker-server",
    },
})
```

不要把 `X-GameAlgo-Key` 放进小游戏客户端包，也不要让客户端自己传事件上报 key。`ProxyServer` 会在客户端 headers 后追加 `defaultHeaders`，因此服务端 headers 优先，客户端无法覆盖。

开启 Maker 服务端后，Maker 的数据默认会保存在服务端；但客户端已有本地数据和存档仍然可以继续读取。已有单机存档的游戏接入时，要么继续使用原来的本地存储，要么实现从本地存档到服务端存储的无缝迁移，不要直接丢弃旧存档。

## 客户端配置

把 `GameAlgo.lua` 和 `ProxyTransport.lua` 放在小游戏客户端：

```lua
local GameAlgo = require("GameAlgo")

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    appVersion = "1.0.0",
    device = {
        runtime = "taptap_mini_game",
    },
})
```

`Init` 会发起非阻塞的 `/v1/config` 请求。游戏逻辑应该保留本地默认值，只在远端配置可用时读取远端值。

persistent world / background match 模式下，客户端可能在服务端脚本 ready 前调用 `Init`。`ProxyTransport` 会先把待发送请求放入队列；`ServerConnected` 只记录连接状态，不发送队列；等 `ServerReady` 触发后才会 flush 队列。这样可以避免 RemoteEvent 在服务端 Proxy 尚未 ready 时被过早发送。

默认会等待 `ServerReady`。如果自定义运行时没有这个事件，可以在 `GameAlgo.Init` 中传 `waitForServerReady = false` 回到连接可用后立即发送的旧行为。

## 实验

```lua
local levelGenerator = GameAlgo.Executor("level_generator")

local variant = levelGenerator.Variant("control")
local difficulty = levelGenerator.Value("difficulty", "normal")
local result = levelGenerator.Execute({ turn = 7 })
```

Lua SDK 当前只返回 config-only 执行结果，不会在客户端执行 JavaScript 实验脚本。

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

`GameAlgo.TrackAd` 上报的是 `ad_view`，只用于广告成功曝光并产生一次有效展示。广告加载失败、未填充、播放失败、用户取消或关闭但没有完成有效曝光时，不要调用 `TrackAd`。

TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

如果游戏有 update loop，建议周期调用 `GameAlgo.Update()`，用于清理代理请求超时。如果 SDK 初始化发生在连接事件之后，它也会给 transport 一次补 flush 队列的机会。

```lua
function Update(timeStep)
    GameAlgo.Update()
end
```

## RemoteEvent

客户端传输层使用：

```text
HttpProxy_Request
HttpProxy_Response
```

如果自定义这些事件名，客户端和服务端必须使用同一个 `eventPrefix`。
