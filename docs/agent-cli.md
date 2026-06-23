# Agent CLI 接入指南

GameAlgo CLI 用于开发期自动化，不是游戏运行时 SDK。推荐给游戏开发 Agent 使用，用来维护实验、脚本、配置、Report Pack，并拉取报表结果形成自迭代闭环。

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
3. Agent 拉取实验、脚本、配置和 Report Pack。
4. Agent 修改文件并通过 diff 检查变更。
5. Agent 发布配置，服务端生成实验版本记录。
6. 数据沉淀后，Agent 用 `report manifest` 和 `report result` 回收看板结果。
7. Agent 根据报表继续调整实验或配置。

最常用命令：

```bash
gamealgo login --host https://game-algo-admin.example.com --admin-key ga_admin_xxx
gamealgo experiment pull --out experiment.yaml
gamealgo experiment diff experiment.yaml
gamealgo experiment publish experiment.yaml --message "update experiment" --yes
gamealgo report manifest --json
gamealgo report result --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --selector experiment=ad_frequency --timeout 60 --out reports/daily-arpu.json
gamealgo report preview --pack gamealgo-report-pack-v1.json --from 2026-06-14 --to 2026-06-21 --tab-id levels --group-id max_levels --chart-id max_levels__max_level_distribution --timeout 60 --out reports/max-level-distribution-preview.json
gamealgo events count --from 2026-06-23 --to 2026-06-23 --event-type level_end --timeout 60 --json
```

`experiment publish` 和 `experiment rollback` 在 `--json` / CI / 非交互环境下也必须显式传 `--yes`。`report result` 和 `report preview` 的进度和耗时输出到 stderr，不会污染 JSON stdout。

`report preview` 用于本地 Report Pack 调试：CLI 会把本地 JSON 发给服务端执行一次查询，但不会保存 pack，也不会影响线上看板和正式缓存。

`events count` 用于 SDK 接入调试：它只查询当前游戏的固定事件计数，不需要传 `contextId`，也不接受自定义 SQL。先确认目标日期有事件，再继续看 Report Pack 计算结果。

Report Pack JSON 里的 chart id 可以是裸 id，例如 `max_level_distribution`；服务端 manifest 会规范化成 `groupId__chartId`，例如 `max_levels__max_level_distribution`。`--chart-id` 查询参数建议使用 manifest 返回的规范化 id；如果不确定，优先用 `--chart "Max Level Distribution"` 或先跑 `report manifest`。`preview` 使用本地 pack，但 selector/group/chart lookup 仍走服务端 normalized dashboard model。

如果新游戏的 `experiment pull` 返回空的 `latestCommitId`，表示还没有实验版本 commit。首次发布时保留为空或 `null` 即可，服务端会创建第一个 commit；发布成功后再 pull 会拿到新的 `exp_c_...`。

完整命令说明见 [CLI README](../cli/README.md)。
