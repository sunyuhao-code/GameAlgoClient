# GameAlgo 文档地图

这个目录是 GameAlgo Client 仓库的文档入口。AI Agent 拿到仓库后，应优先阅读根目录 [README](../README.md) 和本页，再按任务阶段进入具体文档。

## AI Agent 推荐阅读顺序

1. [AI 接入流程](./agent-onboarding.md)
   从获取 Game Admin Key、创建 Client Game Key、接入 SDK、验证事件，到提交 Report Pack 的完整任务剧本。

2. [客户端接入指南](./integration-guide.md)
   两类 key、国内/海外 host、运行时要求、推荐事件和验收清单。

3. [实验接入版本与最低版本](./experiment-integration-versions.md)
   解释客户端能力版本、Strategy 最低版本、旧客户端行为和托管实验覆盖率启动门槛。

4. [AI Agent 埋点接入手册](./ai-tracking-manual.md)
   AI 接入时哪些 context、事件、广告、付费、归因和 Adjust 成本配置推荐接入。

5. [不同类型游戏埋点建议](./tracking-recommendations.md)
   关卡/对局、run/roguelike、模拟经营、剧情分支等玩法的事件设计建议。

6. [Report Pack 配置](./report-packs.md)
   报表配置结构、标准看板、自定义 dataset/report/calculation、chart 和 selector。

7. [Agent CLI 命令参考](./agent-cli.md)
   CLI 安装、登录、key 管理、实验、脚本、配置、报表、事件统计和投放同步命令。

8. [AI LTV 优化 Playbook](./ai-ltv-optimization-playbook.md)
   接入完成后，如何围绕 LTV 做数据回收、实验和持续优化。

9. [Level DDA framework](./dda-level-framework.md)
   关卡类游戏动态难度调整的标准化框架。

## 开发者推荐阅读

- [开发者快速开始](./developer-quickstart.md)
  给人看的平台地址、账号、密钥、控制台操作和推荐协作流程。

- [客户端接入指南](./integration-guide.md)
  需要审核 AI 改动或理解 key / host / 事件链路时阅读。

## 协议和 API 参考

- [Protocol v1 guide](./protocol-v1.md)
- [REST API v1 guide](./rest-api-v1.md)

## 平台 SDK 入口

- [iOS SDK](../ios/README.md)
- [Android SDK](../android/README.md)
- [REST helper](../rest-api/README.md)
- [TapTap Maker / Lua SDK](../lua/README.md)

## 文档维护原则

- 根目录 README 面向 AI Agent，重点告诉 AI 应该怎么推进接入。
- `developer-quickstart.md` 面向开发者，重点告诉人需要提供什么、审核什么。
- `agent-onboarding.md` 面向 AI Agent，重点给完整执行流程。
- `agent-cli.md` 是命令参考，不承担完整接入流程教学。
- `integration-guide.md` 是 SDK 接入细节和验收要求。
