# Web 游戏 Demo

`web-game-demo` 是一个静态浏览器游戏，用于端到端验证 SDK 埋点链路。它使用公开的 Protocol v1 REST 接口：

- `POST /v1/config`
- `POST /v1/events/batch`

Demo 会发送包含 `userCreatedAt` 和 `timezone` 的 SDK context 字段，并在游玩过程中上报这些事件类型：

- `level_start`
- `level_end`
- `ad_view`
- `purchase`
- `_tile_tap`
- `_demo_open`
- `session_end`

## 运行

可以直接用浏览器打开 `index.html`，也可以在该目录启动静态服务：

```bash
python3 -m http.server 8088
```

然后访问：

```text
http://127.0.0.1:8088
```

填写：

```text
Base URL: https://game-algo-sdk.dictapis.cn
Game Key: 从 GameAlgo 控制台获取的游戏 key
```

游戏 key 只会存到浏览器 `localStorage`，不会提交到仓库。

## Report Pack

`report-pack.json` 是这个 demo 配套的 report pack。把它导入 demo 游戏的 GameAlgo 控制台 Reports 页面后，运行报表即可验证事件是否能在看板中展示。
