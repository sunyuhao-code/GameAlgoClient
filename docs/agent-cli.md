# Agent CLI 接入指南

GameAlgo CLI 用于开发期自动化，不是游戏运行时 SDK。推荐给游戏开发 Agent 使用，用来维护实验、脚本、配置、Report Pack，并拉取报表结果形成自迭代闭环。

CLI 实现在 [../cli](../cli/README.md)。当前仓库内运行方式：

```bash
npm install
npm run cli -- help
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
npm run cli -- login --host https://game-algo-admin.example.com --admin-key ga_admin_xxx
npm run cli -- experiment pull --out experiment.yaml
npm run cli -- experiment diff experiment.yaml
npm run cli -- experiment publish experiment.yaml --message "update experiment" --yes
npm run cli -- report manifest --json
npm run cli -- report result --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --selector experiment=ad_frequency --out reports/daily-arpu.json
```

完整命令说明见 [CLI README](../cli/README.md)。
