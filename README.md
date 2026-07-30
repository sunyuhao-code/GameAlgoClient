# GameAlgo Client

GameAlgo Client 是公开客户端仓库，包含 iOS SDK、Android SDK、REST helper、TapTap Maker / Lua SDK、CLI 和协议定义。

产品能力、接入流程、埋点、实验、报表与优化方法由 GameAlgo Server 在线文档统一维护，不在本仓库保留副本。

## AI Agent 从这里开始

不要把 README 原样转发给开发者。先安装最新 CLI，再从目标环境读取当前文档并完成接入。

| 环境 | Admin host | SDK / REST API |
| --- | --- | --- |
| 国内 | `https://game-algo-admin.dictapis.cn` | `https://game-algo-sdk.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_admin` | `https://dirichlet.ai/algo_sdk` |

```bash
npm install -g gamealgo-cli@latest
gamealgo --version
gamealgo docs agent-onboarding --host <admin-host>
```

开发者通常只需要提供游戏维度的 Game Admin Key，格式为 `ga_admin_*`。在游戏项目根目录登录后，AI Agent 应通过 CLI 创建或读取运行时使用的 `ga_live_*`，完成 SDK 接入、事件验证、Report Pack 和实验配置。

```bash
gamealgo login --host <admin-host> --admin-key <ga_admin_xxx>
gamealgo key list --json
gamealgo key create --name <runtime-name> --json
gamealgo key reveal --name <runtime-name> --json
```

凭据保存在当前游戏项目的 `.gamealgo/cli.json`，不同游戏互不覆盖。需要其他主题时使用：

```bash
gamealgo docs --host <admin-host>
gamealgo docs integration-guide --host <admin-host>
gamealgo docs ai-tracking-manual --host <admin-host>
gamealgo docs report-packs --host <admin-host>
gamealgo docs experiment-integration-versions --host <admin-host>
gamealgo docs agent-cli --host <admin-host>
```

## SDK 入口

- [iOS SDK](./ios/README.md)
- [Android SDK](./android/README.md)
- [REST helper](./rest-api/README.md)
- [TapTap Maker / Lua SDK](./lua/README.md)
- [CLI](./cli/README.md)
- [Protocol OpenAPI](./protocol/openapi.yaml)

海外 SDK 地址包含 `/algo_sdk` 路径前缀，必须完整保留。客户端只能配置 `ga_live_*`；`ga_admin_*` 只允许用于开发机器、AI Agent 或 CI。

## 仓库结构

```text
ios/        iOS Swift Package SDK
android/    Android Java SDK core
rest-api/   REST API helper 和示例
lua/        TapTap Maker / Lua SDK
cli/        GameAlgo CLI
protocol/   客户端协议定义
examples/   接入示例
```

## 本地验证

```bash
npm install
npm run check
```

平台 SDK README 只描述与当前代码版本绑定的安装方式、公开 API 和运行时约束。业务流程与平台规则以 `gamealgo docs` 返回的在线文档为准。
