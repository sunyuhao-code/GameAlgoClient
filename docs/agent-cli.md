# Agent CLI 接入指南

GameAlgo CLI 用于开发期自动化，不是游戏运行时 SDK。推荐给游戏开发 Agent 使用，用来维护实验、脚本、配置、Report Pack，并拉取报表结果形成自迭代闭环。

CLI 必须使用 `ga_admin_*` 形式的 Game Admin Key。`ga_live_*` 是游戏客户端运行时使用的 Client Game Key，不能用于 `gamealgo login`。

Admin host 按环境选择：

| 环境 | Admin host |
| --- | --- |
| 国内 | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_admin` |

CLI 实现在 [../cli](../cli/README.md)。推荐安装后直接使用：

```bash
gamealgo help
```

源码仓库内调试可以用 npm script；如果命令带 `--json`，必须使用 `npm --silent`：

```bash
npm install
npm --silent run cli -- help
npm --silent run cli -- report manifest --json
```

核心流程：

1. 平台为当前游戏生成 Game Admin Key。
2. Agent 用 `gamealgo login` 登录，key 只绑定一个游戏。
3. Agent 用 `key list/create/reveal` 获取当前游戏的 Client Game Key，用于 SDK 或 TapTap Maker 服务端 Proxy。
4. Agent 拉取脚本、配置和 Report Pack，并按需发布脚本版本。
5. Agent 创建或更新 Strategy，提交手动或托管 Run。
6. 数据沉淀后，Agent 评估 Run，并通过 promote 把胜出组推为默认参数。
7. 数据沉淀后，Agent 用 `report manifest` 和 `report result` 回收看板结果。
8. Agent 根据报表继续调整实验或配置。

最常用命令：

```bash
gamealgo login --host <admin-host> --admin-key ga_admin_xxx
gamealgo key list --json
gamealgo key create --name tapmaker-proxy --json
gamealgo key reveal --name tapmaker-proxy --json
gamealgo script publish scripts/level-generator.js --message "level script" --json
gamealgo experiment strategy publish strategy.yaml --yes --json
gamealgo experiment run create ad_frequency run.yaml --yes --json
gamealgo experiment run evaluate xrun_xxx --from 2026-07-01 --to 2026-07-07 --yes --json
gamealgo experiment run report xrun_xxx --json
gamealgo experiment run promote xrun_xxx --variant bravo --yes --json
gamealgo experiment override set xrun_xxx --user user-1 --variant bravo --yes --json
gamealgo report manifest --json
gamealgo report result --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --selector experiment=ad_frequency --timeout 60 --out reports/daily-arpu.json
gamealgo report preview --pack gamealgo-report-pack.json --from 2026-06-14 --to 2026-06-21 --tab-id levels --group-id max_levels --chart-id max_levels__max_level_distribution --timeout 60 --out reports/max-level-distribution-preview.json
gamealgo events count --from 2026-06-23 --to 2026-06-23 --event-type level_end --timeout 60 --json
gamealgo marketing adjust configure --api-token "$ADJUST_API_TOKEN" --app-token "$ADJUST_APP_TOKEN" --platform ios --currency CNY --json
gamealgo marketing adjust sync --from 2026-06-01 --to 2026-06-07 --timeout 60 --json
```

`key list` 只返回 key 名称、前缀和状态，不返回明文。需要把 key 写入 SDK 或 TapTap Maker 服务端 Proxy 配置时，使用 `key create --name ...` 或 `key reveal --name ...` 获取明文。

实验相关写操作在 `--json` / CI / 非交互环境下必须显式传 `--yes`。`report result` 和 `report preview` 的进度和耗时输出到 stderr，不会污染 JSON stdout。

实验文件分两类。Strategy 定义游戏代码读取的稳定策略 key、默认参数和可选脚本版本：

```yaml
strategyKey: ad_frequency
displayName: 广告频率
defaultConfig:
  firstAdLevel: 4
  interval: 30
script:
  versionId: sv_xxxxxxxxxxxxxxxx
message: 初始化广告频率策略
```

Run 定义一次实验。手动实验由 Agent/开发者决定何时评估、推全或取消：

```yaml
displayName: 广告频率第一轮
type: manual
platform: ios
objective: ltv_proxy
variants:
  - variantId: control
    weight: 1
    config: { firstAdLevel: 4, interval: 30 }
  - variantId: slower_ads
    weight: 1
    config: { firstAdLevel: 5, interval: 45 }
```

如果要让当前默认参数参与实验，显式加入 `variantId: default`，且不要给 default 写 `config` 或 `script`；服务端会使用 Strategy 当前默认参数。没有显式 default 时，default 不参与流量。所有有流量的实验组数量必须至少为 2。

托管实验也是 Run，只是 `type: managed`，平台会按轮次自动测试候选 variant 并最终推全胜出组：

```yaml
displayName: 广告频率托管实验
type: managed
platform: ios
objective: ltv_proxy
cycleDays: 7
maxVariantsPerRound: 3
variants:
  - variantId: alpha
    config: { firstAdLevel: 4, interval: 30 }
  - variantId: bravo
    config: { firstAdLevel: 5, interval: 30 }
  - variantId: charlie
    config: { firstAdLevel: 4, interval: 45 }
```

实验报告里的 `LTV Proxy` 口径是：

```text
LTV Proxy = DAU_ARPU * (1 + D1_RET + D2_RET + D3_RET + D4_RET)
```

`DAU_ARPU` 是实验窗口内收入 / 活跃用户天数；`D1_RET` 到 `D4_RET` 使用实验窗口内已经成熟的日期平均估算。平台不会为了等待 D5 额外拖长托管周期。

```bash
gamealgo experiment strategies --json
gamealgo experiment strategy show ad_frequency --json
gamealgo experiment run show xrun_xxx --json
gamealgo experiment run cancel xrun_xxx --yes
```

`report preview` 用于本地 Report Pack 调试：CLI 会把本地 JSON 发给服务端执行一次查询，但不会保存 pack，也不会影响线上看板和正式缓存。

`events count` 用于 SDK 接入调试：它只查询当前游戏原始事件表里的固定事件计数，不需要传 `contextId`，也不接受自定义 SQL，不依赖 Report Pack 或标准中间表。先确认目标日期有事件，再继续看 Report Pack 计算结果。

如果游戏接入了 Adjust，Agent 可以用 `marketing adjust configure` 保存当前游戏的 Adjust App Token 和 API Token。保存后用 `gamealgo marketing adjust get --json` 读取 `integration.callbackUrl`，把这个 URL 填到 Adjust Raw Data Export / Server Callback 配置里；URL 由服务端生成，Agent 不要自己拼。Adjust callback trigger 选择 `Install`，并建议额外配置一条 `Reattribution`；如果 UI 一次只能选一个 trigger，就两条 callback 都填同一个 URL。不要选择 `Session`、普通 `Event` 或 `Ad revenue`。之后用 `marketing adjust sync` 同步花费。国内游戏、TapTap Maker / TapTap 小游戏通常使用 `--currency CNY`，海外游戏按 Adjust 投放账户实际成本币种填写。GameAlgo 使用 Adjust `network_cost` 字段，按 campaign / country 粒度写入数据；Report Pack 可以引用 `marketing.overview@1` 和 `marketing.roi@1` 查看投放总览、ROAS、获客用户 LTV 和投放花费。

TapTap Maker / TapTap 小游戏 / Lua SDK 这类通过服务端 Proxy 或 REST 协议接入的环境，`platform` 使用 `rest`。不要扩展成 `tapmaker` 之类的新枚举；具体运行环境写到 `device` 中，例如：

```json
{
  "platform": "rest",
  "device": {
    "runtime": "tapmaker",
    "engine": "lua",
    "channel": "taptap_mini_game"
  }
}
```

TapTap Maker 接入时需要开启多人模式服务端。这个服务端是 Maker 自带的部署和运行能力，不需要额外部署独立后端；GameAlgo SDK 已经提供服务端代理代码，直接使用 `lua/ProxyServer.lua` 和 `lua/server_main.lua`。Agent 不要为 GameAlgo 另起一个服务，也不要把 Client Game Key 放进客户端脚本。

TapTap Maker 客户端初始化时，优先使用 Maker 环境提供的稳定用户 ID 作为 `userId`，例如：

```lua
local tapUserId = nil
if lobby and lobby.GetMyUserId then
    tapUserId = tostring(lobby:GetMyUserId())
end

GameAlgo.Init({
    baseUrl = "<sdk-host>",
    appVersion = "1.0.0",
    platform = "rest",
    userId = tapUserId,
    device = {
        runtime = "taptap_mini_game",
        game = "your_game_id",
        -- country = "CN", -- 如果 Maker 环境能提供可靠国家码再填写，用于国家留存看板
    },
})
```

如果拿不到 Maker 用户 ID，可以传 `nil`，SDK 会退回到本地匿名 ID。不要使用昵称、头像、手机号等可识别信息作为 `userId`。

开启 Maker 服务端后，数据默认会保存在服务端；但客户端已有的本地数据和存档仍然可以继续读取。如果游戏原来是单机存档，接入时必须保留兼容策略：要么继续使用原来的本地存储，要么实现从本地存档到 Maker 服务端存储的无缝迁移。不要因为接入 SDK 删除或覆盖旧存档。

国内游戏、TapTap Maker / TapTap 小游戏接入时，`ad_view` 和 `purchase` 的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

Report Pack JSON 里的 chart id 可以是裸 id，例如 `max_level_distribution`；服务端 manifest 会规范化成 `groupId__chartId`，例如 `max_levels__max_level_distribution`。`--chart-id` 查询参数建议使用 manifest 返回的规范化 id；如果不确定，优先用 `--chart "Max Level Distribution"` 或先跑 `report manifest`。`preview` 使用本地 pack，但 selector/group/chart lookup 仍走服务端规范化后的看板结构。

完整命令说明见 [CLI README](../cli/README.md)。
