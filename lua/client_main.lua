local okGameAlgo, GameAlgo = pcall(require, "sdk.GameAlgo")
if not okGameAlgo then
    GameAlgo = require("GameAlgo")
end

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    gameKey = "ga_live_xxx",
    appVersion = "1.0.0",
    platform = "rest",
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
    },
})
