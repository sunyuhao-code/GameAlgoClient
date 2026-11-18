# Web 游戏 Demo

该示例使用公开 REST 接口发送 Debug 测试事件，不加载真实广告；模拟广告收入为固定的 `0.018`，对应登记为 `CNY` 的测试广告位。真实游戏必须使用广告回调金额，并按实际收入币种登记。

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
Registered GamePropel Ad Placement ID: 当前游戏经 CLI 登记返回的 gap_* ID
```

游戏 key 只会存到浏览器 `localStorage`，不会提交到仓库。

## 先登记测试广告位

在已绑定目标游戏的 CLI 环境中读取现有目录，按[定义模板](../../rest-api/examples/ad-placements.json)编辑实际点位，校验并登记。以下命令从本仓库根目录执行：

```bash
gamepropel whoami --json
gamepropel ad-placements list --json
gamepropel ad-placements validate rest-api/examples/ad-placements.json --json
gamepropel ad-placements apply rest-api/examples/ad-placements.json --out ad-placement-ids.json --json
```

核对输出 `gameId` 与连接的游戏一致，把 `ids.rewarded_level_end` 的真实值填入页面。没有有效格式的 ID 时模拟曝光按钮禁用；该 ID 是否属于当前游戏由服务端核对，页面不执行管理端登记。

点击 **Simulate Ad (Debug)** 后发送 `ad_view`，payload 仅包含登记 ID、模拟收入、network 和动态关卡字段；名称、广告形式和币种由服务端按定义补齐。所有 context 和事件都标记 `isDebug=true`。这个按钮只验证测试上报链路；生产游戏在广告 SDK 确认有效曝光/收入的回调中上报真实事实。完整协议见 [REST 接入文档](../../rest-api/README.md#广告先登记点位再引用-id)。

## Report Pack

`report-pack.json` 是这个 demo 配套的 Report Pack。使用 GameAlgo CLI 执行 `report validate`、`report preview` 和 `report publish` 后，即可在管理后台的 Reports 页面查看结果。

其中 `placement/adType/currency` 读取的是服务端解析登记 ID 后补齐的字段，客户端不再重复发送。
