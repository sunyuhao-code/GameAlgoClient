# GameAlgo Lua SDK for TapTap Mini Games

TapTap mini game clients run in a sandbox and cannot call GameAlgo HTTP APIs directly. Use this layout:

```text
Client
  GameAlgo.lua          SDK facade: config / experiment / track
  ProxyTransport.lua    RemoteEvent transport

Server
  ProxyServer.lua       RemoteEvent -> real HTTP proxy
  server_main.lua       proxy startup and service-side config
```

## Server Setup

Put `ProxyServer.lua` and `server_main.lua` on the TapTap game server side. Configure the real GameAlgo key on the server:

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

Do not put `X-GameAlgo-Key` in the mini game client package. `ProxyServer` adds `defaultHeaders` after client headers, so server-side headers win and cannot be overridden by the client.

## Client Setup

Put `GameAlgo.lua` and `ProxyTransport.lua` on the mini game client side:

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

`Init` starts a non-blocking `/v1/config` request. Game logic should keep local defaults and read remote values only when available.

In persistent world mode, the client may call `Init` before the server
connection is ready. `ProxyTransport` queues outbound requests until
`ServerConnected` fires, then flushes the queue automatically.

## Experiments

```lua
local levelGenerator = GameAlgo.Executor("level_generator")

local variant = levelGenerator.Variant("control")
local difficulty = levelGenerator.Value("difficulty", "normal")
local result = levelGenerator.Execute({ turn = 7 })
```

Lua SDK currently returns config-only execution results. It does not execute JavaScript experiment scripts on the client.

## Config Files

Config files listed by `/v1/config` are preloaded after config fetch succeeds.

```lua
GameAlgo.FetchConfigFile("gameplay.json", function(err, file)
    if not err then
        print(file.content)
    end
end)

local enabled = GameAlgo.ConfigValue("ads.rewarded.enabled", true, "gameplay.json")
```

## Events

Events are queued in memory. If config is not ready yet, `Flush` waits until a `contextId` exists.

```lua
GameAlgo.TrackLevelEnd({
    level = 3,
    result = "win",
})

GameAlgo.TrackAd("rewarded_level_end", "reward", 0.018, "USD", "admob")

GameAlgo.TrackSessionEnd()
GameAlgo.Flush()
```

If the game has an update loop, call `GameAlgo.Update()` periodically so proxy request timeouts can be cleaned up:
It also gives the transport another chance to flush queued requests if the
SDK was initialized after the connection event had already fired.

```lua
function Update(timeStep)
    GameAlgo.Update()
end
```

## Remote Events

The client transport uses:

```text
HttpProxy_Request
HttpProxy_Response
```

Use the same `eventPrefix` on both sides if you customize these names.
