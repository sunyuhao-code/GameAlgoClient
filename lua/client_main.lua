local okGameAlgo, GameAlgo = pcall(require, "sdk.GameAlgo")
if not okGameAlgo then
    GameAlgo = require("GameAlgo")
end

local tapUserId = nil
if lobby and lobby.GetMyUserId then
    tapUserId = tostring(lobby:GetMyUserId())
end

-- Replace GameSave.Get/GameSave.Set with the current game's persistent save
-- implementation. Online games should call GameAlgo.Init after the save loads.
local gameAlgoStorage = {
    getItem = function(key)
        return GameSave.Get(key)
    end,
    setItem = function(key, value)
        GameSave.Set(key, value)
    end,
}

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    gameKey = "ga_live_xxx",
    appVersion = "1.0.0",
    platform = "rest",
    userId = tapUserId,
    storage = gameAlgoStorage,
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
    },
})
