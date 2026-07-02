# Agent CLI 接入指南

GameAlgo CLI 用于开发期自动化，不是游戏运行时 SDK。推荐给游戏开发 Agent 使用，用来维护实验、脚本、配置、Report Pack，并拉取报表结果形成自迭代闭环。

CLI 必须使用 `ga_admin_*` 形式的 Game Admin Key。`ga_live_*` 是游戏客户端运行时使用的 Client Game Key，不能用于 `gamealgo login`。

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
4. Agent 拉取实验、脚本、配置和 Report Pack。
5. Agent 修改文件并通过 diff 检查变更。
6. Agent 发布配置，服务端生成实验版本记录。
7. 数据沉淀后，Agent 用 `report manifest` 和 `report result` 回收看板结果。
8. Agent 根据报表继续调整实验或配置。

最常用命令：

```bash
gamealgo login --host https://game-algo-admin.dictapis.cn --admin-key ga_admin_xxx
gamealgo key list --json
gamealgo key create --name tapmaker-proxy --json
gamealgo key reveal --name tapmaker-proxy --json
gamealgo experiment pull --out experiment.yaml
gamealgo experiment diff experiment.yaml
gamealgo experiment publish experiment.yaml --message "update experiment" --yes
gamealgo experiment managed create managed-experiment.yaml --yes --json
gamealgo experiment managed status mxt_xxx --json
gamealgo experiment managed report mxt_xxx --round 1 --json
gamealgo report manifest --json
gamealgo report result --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --selector experiment=ad_frequency --timeout 60 --out reports/daily-arpu.json
gamealgo report preview --pack gamealgo-report-pack-v1.json --from 2026-06-14 --to 2026-06-21 --tab-id levels --group-id max_levels --chart-id max_levels__max_level_distribution --timeout 60 --out reports/max-level-distribution-preview.json
gamealgo events count --from 2026-06-23 --to 2026-06-23 --event-type level_end --timeout 60 --json
```

`key list` 只返回 key 名称、前缀和状态，不返回明文。需要把 key 写入 SDK 或 TapTap Maker 服务端 Proxy 配置时，使用 `key create --name ...` 或 `key reveal --name ...` 获取明文。

`experiment publish` 和 `experiment rollback` 在 `--json` / CI / 非交互环境下也必须显式传 `--yes`。`report result` 和 `report preview` 的进度和耗时输出到 stderr，不会污染 JSON stdout。

托管实验用于让平台自动跑多轮 variant 对比。先确保普通实验里已经存在对应 strategy，游戏侧也已经读取这个 strategy；然后让 Agent 生成托管任务文件：

```yaml
strategyName: ad_frequency
cycleDays: 7
maxVariantsPerRound: 3
candidates:
  - candidateId: alpha
    config:
      firstAdLevel: 4
      interval: 30
  - candidateId: bravo
    config:
      firstAdLevel: 5
      interval: 30
  - candidateId: charlie
    config:
      firstAdLevel: 4
      interval: 45
```

提交任务：

```bash
gamealgo experiment managed create managed-experiment.yaml --yes --json
```

创建成功后响应里的 `summary.estimate` 会返回预计轮数、实验周期、预计总天数；`summary.currentRound` 会返回当前轮的统计 dt、实验完成时间和报告生成时间。查看和取消任务：

托管实验报告里的 `LTV Proxy` 口径是：

```text
LTV Proxy = DAU_ARPU * (1 + D1_RET + D2_RET + D3_RET + D4_RET)
```

`DAU_ARPU` 是实验窗口内收入 / 活跃用户天数；`D1_RET` 到 `D4_RET` 使用实验窗口内已经成熟的日期平均估算。平台不会为了等待 D5 额外拖长托管周期。

```bash
gamealgo experiment managed list --json
gamealgo experiment managed status mxt_xxx --json
gamealgo experiment managed report mxt_xxx --round 1 --json
gamealgo experiment managed cancel mxt_xxx --yes
```

`status` 只用于看任务和轮次轻量状态，不返回完整报告。需要分析某轮实验结果时，用 `managed report` 拉指定轮次；`--round 1` 表示页面上的第 1 轮，也可以用 `--round-id mxr_xxx` 精确指定。

`report preview` 用于本地 Report Pack 调试：CLI 会把本地 JSON 发给服务端执行一次查询，但不会保存 pack，也不会影响线上看板和正式缓存。

`events count` 用于 SDK 接入调试：它只查询当前游戏原始事件表里的固定事件计数，不需要传 `contextId`，也不接受自定义 SQL，不依赖 Report Pack 或标准中间表。先确认目标日期有事件，再继续看 Report Pack 计算结果。

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
    baseUrl = "https://game-algo-sdk.dictapis.cn",
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

Report Pack JSON 里的 chart id 可以是裸 id，例如 `max_level_distribution`；服务端 manifest 会规范化成 `groupId__chartId`，例如 `max_levels__max_level_distribution`。`--chart-id` 查询参数建议使用 manifest 返回的规范化 id；如果不确定，优先用 `--chart "Max Level Distribution"` 或先跑 `report manifest`。`preview` 使用本地 pack，但 selector/group/chart lookup 仍走服务端 normalized dashboard model。

如果新游戏的 `experiment pull` 返回空的 `latestCommitId`，表示还没有实验版本 commit。首次发布时保留为空或 `null` 即可，服务端会创建第一个 commit；发布成功后再 pull 会拿到新的 `exp_c_...`。

完整命令说明见 [CLI README](../cli/README.md)。
