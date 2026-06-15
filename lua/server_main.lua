--- ============================================================
--- server_main.lua — 服务端入口
--- ============================================================
--- 职责：启动 HTTP 代理服务，转发客户端请求到外部 API。
---
--- 【接入新游戏时】通常只需要修改 GAMEALGO_KEY 和白名单配置。
--- ============================================================

local okProxyServer, ProxyServer = pcall(require, "sdk.ProxyServer")
if not okProxyServer then
    ProxyServer = require("ProxyServer")
end

local GAMEALGO_KEY = "REPLACE_WITH_GAMEALGO_KEY"

--- 全局事件处理函数（ProxyServer 内部通过字符串引用）
function HandleProxyRequest(eventType, eventData)
    ProxyServer.HandleRequest(eventType, eventData)
end

function Start()
    print("[Server] Starting HTTP Proxy Server...")
    assert(GAMEALGO_KEY ~= "REPLACE_WITH_GAMEALGO_KEY", "[Server] GAMEALGO_KEY must be configured before starting proxy")

    -- ============================================================
    -- 配置区（接入新游戏时只需改这里）
    -- ============================================================
    ProxyServer.Start({
        -- 白名单：只允许转发到这些域名
        allowedHosts = {
            "game-algo-sdk.dictapis.cn",
            -- 如需接入其他服务，在此添加域名即可
            -- "api.other-service.com",
        },

        -- 只允许访问 GameAlgo SDK 公共协议接口，避免客户端借代理访问同域其他路径。
        allowedPathPrefixes = {
            "/v1/",
        },

        -- 所有转发请求附加的公共 header（可选）
        -- 推荐在服务端注入 GameAlgo Key，不要把 key 放进小游戏客户端包里。
        defaultHeaders = {
            ["X-Proxy-Source"] = "maker-server",
            ["X-GameAlgo-Key"] = GAMEALGO_KEY,
        },

        -- HTTP 超时（毫秒）
        timeout = 10000,

        -- 最大请求 body 大小（字节）
        maxBodySize = 65536,
    })

    print("[Server] HTTP Proxy Server ready.")
end
