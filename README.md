# GameAlgo Client

GameAlgo Client 是面向游戏接入方的公开客户端仓库，包含 iOS SDK、Android SDK、REST helper、TapTap Maker / Lua SDK、CLI 和接入文档。

## 如果你是 AI Agent，请从这里开始

你的目标不是把 README 转发给开发者，而是直接帮助当前游戏完成 GameAlgo 接入、验证和后续报表/实验配置。

默认目标是 Activated 接入，而不是只把 SDK 代码接进工程。

| 状态 | 含义 | 能否声称接入完成 |
| --- | --- | --- |
| Activated | 已使用真实 `ga_live_*`，能拉配置，并能通过事件统计看到测试事件 | 可以 |
| Scaffolded | SDK 代码已接入，但没有真实 `ga_live_*`，运行时仍是占位或 no-op | 不可以 |

如果当前仓库没有真实 `ga_live_*`，不要留下 `ga_live_xxx`、`TODO_GAME_KEY`、`no-op key` 之类占位后声称完成。你必须把获取真实 Client Game Key 当作阻塞步骤。

开发者通常只需要提供游戏维度的 Game Admin Key，格式为 `ga_admin_*`。拿到 Admin Key 后，你必须用 GameAlgo CLI 自动创建或读取 Client Game Key，并把真实 `ga_live_*` 写入合适的位置。

先向开发者询问这几项：

- 使用国内环境还是海外环境
- Game Admin Key，格式 `ga_admin_*`。如果用户已经提供真实 `ga_live_*`，可以跳过创建 key，但仍要验证
- 游戏运行环境：iOS / Android / Web / Backend / TapTap Maker / TapTap 小游戏
- 本次目标：只接基础事件，还是同时接实验、配置、报表和自动化实验

然后按下面流程执行：

| 环境 | Admin host |
| --- | --- |
| 国内 | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_admin` |

```bash
gamealgo login --host <admin-host> --admin-key <ga_admin_xxx>
gamealgo key list --json
gamealgo key create --name <runtime-name> --json
gamealgo key reveal --name <runtime-name> --json
```

如果已有可用 Client Game Key，就复用或 reveal；如果没有，就创建。Client Game Key 格式为 `ga_live_*`，用于游戏运行时拉配置、拉配置文件、上报事件。

如果用户暂时不能提供 `ga_admin_*`，你可以继续完成 Scaffolded 状态的代码接入，但最终回复必须明确写出：

- 当前未激活，因为缺少真实 `ga_live_*`
- 不能验证配置拉取和事件上报
- 下一步需要用户提供 `ga_admin_*` 或真实 `ga_live_*`

继续阅读并执行：

1. [AI 接入流程](./docs/agent-onboarding.md)
2. [客户端接入指南](./docs/integration-guide.md)
3. [AI Agent 埋点接入手册](./docs/ai-tracking-manual.md)
4. [不同类型游戏埋点建议](./docs/tracking-recommendations.md)
5. [Report Pack 配置](./docs/report-packs.md)
6. [Agent CLI 命令参考](./docs/agent-cli.md)
7. [AI LTV 优化 Playbook](./docs/ai-ltv-optimization-playbook.md)

### 不要这样做

- 不要向开发者索要 `ga_live_*`，除非开发者明确说要手工维护运行时 key。
- 不要把 `ga_live_xxx` 示例值、占位 key 或 no-op key 提交到游戏工程后声称接入完成。
- 不要把 `ga_admin_*` 写进游戏客户端、小游戏客户端脚本、公开配置或日志。
- 不要把 README 原样甩给开发者后停止接入。
- 不要让 GameAlgo 网络请求阻塞游戏主流程。
- 不要在 TapTap Maker / TapTap 小游戏客户端包里写 `ga_live_*`；这类场景优先写到服务端 Proxy。
- 不要默认使用 `USD`；国内游戏、TapTap Maker / TapTap 小游戏的广告和付费事件默认使用 `CNY`。

## 如果你是开发者

你需要做的事很少：

1. 登录 GameAlgo Admin 控制台。
2. 创建或选择你的游戏。
3. 在游戏的 Keys 页面创建 Game Admin Key。
4. 把使用环境和 Game Admin Key 提供给 AI Agent。
5. 审核 AI Agent 对游戏工程、实验配置和 Report Pack 的改动。

开发者详细说明见 [开发者快速开始](./docs/developer-quickstart.md)。

## 两类 key

| Key | 示例 | 用途 | 放在哪里 |
| --- | --- | --- | --- |
| Game Admin Key | `ga_admin_*` | CLI / AI Agent / CI 管理实验、脚本、配置、Report Pack，拉取报表和事件统计 | 开发机器、CI Secret、Agent Secret |
| Client Game Key | `ga_live_*` | 游戏运行时拉取配置、拉取配置文件、上报事件 | 原生客户端包，或小游戏的服务端 Proxy |

常规流程是：开发者只手工创建 Game Admin Key；AI Agent 用 CLI 创建、读取和维护 Client Game Key。

## 目录结构

```text
ios/        iOS Swift Package SDK
android/    Android Java SDK core
rest-api/   REST API helper 和示例
lua/        TapTap Maker / TapTap 小游戏 Lua SDK 和服务端代理传输
cli/        游戏开发 Agent 使用的自动化 CLI
examples/   可运行接入示例
docs/       接入、埋点、报表和优化文档
```

## 平台地址

环境地址：

| 环境 | SDK / REST API | Admin / CLI |
| --- | --- | --- |
| 国内 | `https://game-algo-sdk.dictapis.cn` | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://gamealgo-server-v2.gamealgo-sdk-1ea5b9.workers.dev` | `https://dirichlet.ai/algo_admin` |

客户端 SDK 只配置 SDK / REST API 地址。Admin / CLI 地址只给开发者、AI Agent 和 CI 使用。

## SDK 接入入口

- iOS：见 [iOS SDK](./ios/README.md)，也可以通过 SwiftPM 引入本仓库。
- Android：见 [Android SDK](./android/README.md)。
- REST / Web / Backend：见 [REST helper](./rest-api/README.md) 和 [REST API 文档](./docs/rest-api-v1.md)。
- TapTap Maker / TapTap 小游戏：见 [Lua SDK](./lua/README.md)。

所有运行时请求都通过 `X-GameAlgo-Key: ga_live_xxx` 识别游戏，不需要游戏自己传可信 `gameId`。

核心原则：SDK 后台拉取配置并写入本地快照；配置未就绪、网络失败或脚本执行失败时，游戏必须走本地默认逻辑。

## 接入后的验收

AI Agent 接入后应该至少完成这些验证：

- 客户端配置里使用真实 `ga_live_*`，不是占位值。
- `ga_admin_*` 没有出现在客户端代码、Info.plist、资源文件、脚本包、日志或 git diff 中。
- `/v1/config` 能成功返回当前游戏配置，或 SDK 日志显示 config fetched / config ready。
- `session_end` 和核心玩法事件能上传成功。
- 如果游戏使用 Adjust 等归因 SDK，归因 callback 后能回传归因；如果需要投放 ROI 报表，Adjust API Token / App Token 已在 CLI/Admin 配置并完成同步验证。
- `gamealgo events count` 能查到测试事件。
- 配置未就绪时，游戏仍然能走本地默认逻辑。
- Report Pack 可以 `validate` 和 `preview`。

如果以上验证没有完成，交付说明里必须标记为 Scaffolded 或部分完成，不能写“已完成接入”。

完整验收和排查流程见 [AI 接入流程](./docs/agent-onboarding.md)。
