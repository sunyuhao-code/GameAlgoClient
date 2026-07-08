# AI Agent 埋点接入手册

这份文档给负责接入 GameAlgo 的 AI Agent 使用。目标是让 AI 不只是把 SDK 接进工程，而是能判断当前游戏应该接哪些埋点、哪些 context、哪些归因数据，并用 CLI 验证数据已经进入平台。

## 1. 接入目标

第一版埋点不要追求覆盖所有游戏行为。优先保证下面四类数据稳定：

| 类别 | 目的 | 是否推荐接入 |
| --- | --- | --- |
| SDK context | 识别用户、会话、平台、版本、国家、实验分组 | 所有游戏都要接 |
| 会话和核心玩法 | 计算 DAU、会话时长、核心玩法参与和进度 | 所有游戏都要接 |
| 商业化 | 计算广告收入、付费、ARPU、LTV | 有广告或内购就要接 |
| 归因 | 计算分渠道 ROI、LTV、留存和投放效果 | 接入 Adjust 等归因 SDK 时推荐接 |
| 投放成本 | 计算 ROAS、ROI、花费趋势、Campaign 明细 | 需要看投放相关报表时配置 |

埋点接入完成后，必须用 `gamealgo events count` 验证事件进表。只改代码但没有真实 key 或没有验证，不能写“接入完成”。

## 2. 必接 SDK Context

SDK 初始化或 `/v1/config` 请求会写入 SDK context。AI Agent 应尽量补齐这些字段，不要把它们重复塞进普通事件 payload。

| 字段 | 要求 | 说明 |
| --- | --- | --- |
| `gameKey` | 必填 | 真实 `ga_live_*`。TapTap Maker / 小游戏放服务端 Proxy。 |
| `baseUrl` / `baseURL` | 必填 | SDK / REST API host，不是 Admin host。 |
| `platform` | 必填 | `ios`、`android` 或 `rest`。TapTap Maker 当前用 `rest`。 |
| `appVersion` | 必填 | 游戏版本号，用于版本覆盖率和版本维度排查。 |
| `userId` | 可选但推荐 | 有平台稳定 ID 时传入；否则用 SDK 本地匿名 ID。 |
| `device.country` | 有条件必须 | 能拿到可靠国家码时传 ISO 国家码，例如 `US`、`CN`、`JP`。用于国家留存、国家 ROI、分国家投放分析。 |
| `device` 其他字段 | 可选 | 只放非敏感排查字段，例如 runtime、渠道包、设备分层。 |

iOS 推荐：

```swift
let country = Locale.current.region?.identifier

let sdk = GameAlgoSDK(
    gameKey: "ga_live_xxx",
    baseURL: URL(string: "<sdk-host>")!,
    appVersion: appVersion,
    platform: "ios",
    device: country.map { ["country": .string($0)] } ?? [:]
)
```

TapTap Maker 推荐优先使用 Maker 用户 ID：

```lua
local tapUserId = nil
if lobby and lobby.GetMyUserId then
    tapUserId = tostring(lobby:GetMyUserId())
end

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    appVersion = "1.0.0",
    platform = "rest",
    userId = tapUserId,
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
        -- country = "CN", -- 只有 Maker 环境能提供可靠国家码时再填
    },
})
```

不要上传手机号、邮箱、OAID、IDFA、TapID 等强身份字段。

## 3. 所有游戏推荐接入的事件

所有游戏都应该有会话结束事件和核心玩法开始/结束事件。核心玩法的事件名按玩法选择，不要求所有游戏都用 `level_start` / `level_end`。

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `session_end` | App 切后台、退出、或一次可度量会话结束时 | `sessionDurationMs` |
| `game_start` | 一局、一次 run、一次核心玩法开始时 | `mode`, `progressionType`, `runId` 或 `roundId` |
| `game_over` | 一局、一次 run、一次核心玩法结束时 | `mode`, `result`, `durationMs`, `progressionNo` |

如果游戏是明确的关卡、对局、章节挑战，推荐额外或直接使用：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `level_start` | 关卡、对局、波次或章节开始 | `mode`, `level_index`, `progressionId`, `difficulty` |
| `level_end` | 关卡、对局、波次或章节结束 | `mode`, `level_index`, `progressionId`, `result`, `durationMs`, `attemptNo` |

选择规则：

- 关卡/对局游戏：优先 `level_start` / `level_end`。
- Run / Roguelike / 吸血鬼幸存者类：整局用 `game_start` / `game_over`；局内波次、房间、章节再用 `level_start` / `level_end`。
- 剧情分支、模拟经营、开放世界：使用玩法自定义事件，但仍要能回答“开始、结束、进度、结果、时长”。

不同玩法字段建议见 [不同类型游戏埋点建议](./tracking-recommendations.md)。

## 4. 有广告时必须接入 `ad_view`

如果游戏有广告变现，必须接入 `ad_view`。它只表示实际产生收入的有效曝光；用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也应该上报。

| 字段 | 要求 | 说明 |
| --- | --- | --- |
| `placement` | 必填 | 广告位，例如 `level_end_reward`、`home_banner`。 |
| `adType` | 必填 | 广告类型，例如 `reward`、`banner`、`interstitial`。 |
| `revenue` | 必填 | 本次曝光收入。TapTap Maker 拿不到单次收入时，可以先填 `0`，但必须尽量带上 `trackId` 供平台回补。 |
| `currency` | 必填 | 国内游戏、TapTap Maker / 小游戏默认 `CNY`。海外按实际收入币种。 |
| `network` | 可选 | 广告网络，例如 `admob`、`applovin`。 |
| `trackId` | Maker 必填 | TapTap Maker 广告回调 `result.extra` 里的内部广告标识，用于和内部广告收入数据关联。Lua SDK 可用 `GameAlgo.ExtractAdTrackId(result)` 解析。 |

广告加载失败、无填充、播放失败，或广告 SDK 没有确认产生收入的展示，不要上报为 `ad_view`。这些只能作为诊断事件，例如 `_ad_load_failed`。

TapTap Maker / TapTap 小游戏上报广告时，开发者仍然需要自己填写 `placement`、`adType`、`network` 和业务字段；SDK 只提供 `trackId` 解析工具。示例：

```lua
local trackId = GameAlgo.ExtractAdTrackId(result)
if exposureSuccess then
    GameAlgo.TrackAd("classic_revive", "reward", 0, "CNY", "taptap", {
        round = round,
        wave = wave,
        action = result.success and "completed" or "skipped",
        trackId = trackId,
    })
end
if not trackId then
    GameAlgo.TrackEvent("ad_no_track_id", {
        placement = "classic_revive",
        adType = "reward",
        network = "taptap",
    })
end
```

示例：

```swift
await sdk.tracker.trackAd(
    placement: "rewarded_level_end",
    adType: "reward",
    revenue: 0.018,
    currency: "CNY",
    network: "admob"
)
```

## 5. 有内购时推荐接入 `purchase`

如果游戏有 IAP 或付费订单，推荐接入 `purchase`。

| 字段 | 要求 | 说明 |
| --- | --- | --- |
| `productId` | 推荐 | 商品 ID。 |
| `revenue` | 推荐 | 实收金额。 |
| `currency` | 推荐 | 国内游戏默认 `CNY`。 |
| `source` | 可选 | 购买入口，例如 `shop`、`offer_popup`。 |

示例：

```swift
await sdk.tracker.trackPurchase(
    productId: "starter_pack",
    revenue: 4.99,
    currency: "CNY"
)
```

## 6. 接入归因 SDK 时推荐回传归因

如果游戏使用 Adjust、AppsFlyer、Firebase Installations + Campaign 等归因服务，并且 SDK 能回调归因信息，AI Agent 应推荐回传归因数据。

归因不是普通业务事件，不要作为 `_attribution` 事件上报。它应该走 GameAlgo 的 attribution API：

| SDK | 推荐调用 |
| --- | --- |
| iOS | `try await sdk.setAttribution(GameAlgoUserAttribution(provider: "adjust", attribution: [...]))` |
| Android | `sdk.setAttribution("adjust", attributionMap)` |
| REST | `await client.setAttribution({ provider: "adjust", attribution })` |

推荐字段：

| 字段 | 说明 |
| --- | --- |
| `network` | 渠道或广告网络。 |
| `campaign` | Campaign 名或 ID。 |
| `adgroup` | Ad group 名或 ID。 |
| `creative` | 素材名或 ID；第一版不强制。 |
| `country` | 如果归因 SDK 返回可靠国家码，可以回传。 |

状态处理：

- `attributed` 只表示能识别出有效投放归因。
- `organic` 表示自然量。
- `unknown` 表示无法归因、用户未授权或归因 SDK 返回占位值。
- Adjust 返回 `tracker_token=unattr`、`trackerToken=unattr`、`network=No User Consent`、`tracker_name=No User Consent` 或 `trackerName=No User Consent` 时，不要当成有效渠道。GameAlgo SDK 会自动把这类结果归一化为 `status=unknown`。

开发者接入时机：

- 每次归因 SDK callback 返回归因信息时，都可以调用 GameAlgo SDK 的 `setAttribution`。
- 开发者不需要自己维护 `attributionHash`、ack 状态或重试队列。
- GameAlgo SDK 会根据 provider + 归因内容计算稳定 hash；同一份归因已经成功 ack 后会跳过重复请求。
- 如果上次上传失败或没有拿到服务端 ack，下次开发者再次调用 `setAttribution` 时 SDK 会重新上报。

如果使用 Adjust Server Callback，AI Agent 还要在 Adjust SDK 初始化前配置 GameAlgo callback 参数：

| SDK | 调用方式 |
| --- | --- |
| iOS | `sdk.configureAdjustServerCallbackParams { key, value in Adjust.addGlobalCallbackParameter(value, forKey: key) }` |
| Android | `sdk.configureAdjustServerCallbackParams { key, value -> Adjust.addGlobalCallbackParameter(key, value) }` |
| REST/Web | `await client.configureAdjustServerCallbackParams((key, value) => adjustSetCallbackParam(key, value))` |

`gamealgo_user_id` 和 `gamealgo_user_created_at` 是 GameAlgo 写入 Adjust 的自定义 global callback parameters，不是 Adjust 自带字段。不要让开发者或 AI 自己拼这两个值；统一调用 SDK helper。

归因数据用于分渠道留存、LTV、ROI 和投放看板。不要上传手机号、邮箱、OAID、IDFA、TapID 等强身份字段。

## 7. 需要投放报表时配置 Adjust 成本同步

如果开发者需要在 GameAlgo 里看投放 ROI、ROAS、花费趋势、获客用户 LTV 或 Campaign 明细，AI Agent 需要配置 Adjust 成本同步。只回传用户归因还不够；ROI 报表还需要从 Adjust 拉取投放花费。

需要向开发者确认或让开发者的投放 Agent 提供：

| 配置 | 用途 | 放在哪里 |
| --- | --- | --- |
| Adjust API Token | 调用 Adjust 报表 API 拉取成本 | CLI/Admin 配置，不能进客户端 |
| Adjust App Token | 指定当前游戏对应的 Adjust app | CLI/Admin 配置，不能进客户端 |
| platform | `ios` 或 `android` | 与游戏平台一致 |
| currency | 成本币种 | 国内游戏通常 `CNY`，海外按投放账户实际币种 |

配置示例：

```bash
gamealgo marketing adjust configure \
  --api-token "$ADJUST_API_TOKEN" \
  --app-token "$ADJUST_APP_TOKEN" \
  --platform ios \
  --currency CNY \
  --json
```

保存成功后，Agent 可以读取 Adjust Server Callback URL：

```bash
gamealgo marketing adjust get --json
```

返回的 `integration.callbackUrl` 就是要填到 Adjust Raw Data Export / Server Callback 里的 URL。URL 由服务端生成，包含当前游戏、callback token 和 Adjust placeholder；Agent 不要自己拼 URL。

配置 Adjust Server Callback trigger 时：

- `Install` 必选，用于新用户首次归因，是 ROI、LTV 和分渠道留存的核心来源。
- `Reattribution` 建议也配置；如果游戏有召回、再营销或用户被重新归因，需要靠它更新渠道。
- 如果 Adjust UI 一次只能选一个 trigger，就创建两条 callback，`Install` 和 `Reattribution` 都使用同一个 `integration.callbackUrl`。
- 不要选择 `Session`、普通 `Event`、`Ad revenue`、SKAN、subscription 或 uninstall。Session 量很大且不是归因主链路；广告收入由 GameAlgo `ad_view` 上报，不走 Adjust callback。

手动同步最近一段时间用于验证：

```bash
gamealgo marketing adjust sync \
  --from 2026-06-01 \
  --to 2026-06-07 \
  --timeout 60 \
  --json
```

配置完成后，Report Pack 可以引用标准看板：

```json
{
  "id": "marketing_roi",
  "title": "投放 ROI",
  "standard": "marketing.roi@1"
}
```

注意：

- Adjust API Token 和 App Token 是管理配置，不要写进 iOS/Android/Lua/REST 客户端代码。
- 国内游戏、TapTap Maker / TapTap 小游戏通常使用 `CNY`；海外游戏按 Adjust 投放账户实际成本币种填写。
- GameAlgo 使用 Adjust `network_cost` 作为成本字段，不使用空的 `cost` 字段。
- 成本数据按同步时间写入，报表会按业务日期和最新同步结果取数。
- 如果开发者只需要分渠道留存/LTV，不看花费和 ROAS，可以先只做第 6 节归因回传。

## 8. 按玩法补充埋点

在完成上面的最小集合后，再按玩法补充字段和自定义事件。

| 游戏类型 | 重点补充 | 文档 |
| --- | --- | --- |
| 关卡 / 对局 | `level_index`、`chapter`、`stage`、`result`、`durationMs`、道具使用 | [关卡 / 对局](./tracking-recommendations.md#关卡--对局--局内挑战类) |
| Run / Roguelike | `runId`、`survivalSeconds`、`stageReached`、关键 `_build_choice` | [Run / Roguelike](./tracking-recommendations.md#run--roguelike--吸血鬼幸存者类) |
| 模拟经营 / 放置 | 低频经济快照、升级、资源获得和消耗 | [模拟经营](./tracking-recommendations.md#模拟经营--放置--养成类) |
| 剧情 / 分支 | 节点开始结束、选择、路线、结局 | [剧情分支](./tracking-recommendations.md#剧情--分支--gal-game-类) |
| 开放世界 / 沙盒 | 目标、区域、制作、死亡原因 | [开放世界](./tracking-recommendations.md#开放世界--沙盒--生存类) |

多层关卡不要直接把 `chapter * 100 + stage` 当连续 `level` 做报表。推荐同时上报：

- `chapter`：粗粒度章节分析。
- `stage`：选中章节后的章内分析。
- `level_index`：连续数字，用于最大进度、分桶、排序。
- `stage_code`：内部定位码，只用于排查，不建议作为正式聚合维度。

## 9. 验证清单

接入完成前，AI Agent 必须验证：

- `/v1/config` 成功，SDK context 已创建。
- `appVersion`、`platform` 正确。
- 如果需要国家看板，`device.country` 已写入 SDK context。
- `session_end` 能上报，且 `sessionDurationMs` 有值。
- 核心玩法开始/结束事件能上报，字段语义清晰。
- 有广告时 `ad_view` 能上报，且只代表有效曝光。
- 有内购时 `purchase` 能上报。
- 使用 Adjust 等归因服务时，已在每次归因 callback 后调用官方 SDK / REST helper 的 `setAttribution`，或明确说明当前游戏没有可用归因 SDK。
- 需要投放 ROI 报表时，已配置 Adjust API Token、App Token，并完成一次成本同步。
- 使用 `gamealgo events count` 能查到测试事件。
- Report Pack 能 `validate` 和 `preview`。

事件能进表只说明链路正常；如果报表数据异常，继续检查字段语义和 Report Pack 口径。
