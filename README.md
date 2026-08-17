# GameAlgo Client

GameAlgo Client 是公开客户端仓库，包含 iOS SDK、Android SDK、REST helper、TapTap Maker / Lua SDK 和协议定义。CLI 以独立的 `gamealgo-cli` npm 包发布，不在本仓库维护实现。

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
gamealgo help --host <admin-host>
gamealgo docs sdk-integration --host <admin-host>
gamealgo listapi --host <admin-host>
```

开发者通常只需要提供游戏维度的 Game Admin Key，格式为 `ga_admin_*`。在游戏项目根目录登录后，AI Agent 应通过 CLI 创建或读取运行时使用的 `ga_live_*`，完成 SDK 接入、事件验证、Report Pack 和实验配置。

```bash
gamealgo login --host <admin-host> --admin-key <ga_admin_xxx>
gamealgo integration get-plan --environment <domestic|overseas> --platform <ios|android|maker|rest> --out gamealgo-integration-plan.json
```

AI Agent 必须先执行 `integration get-plan`，并按返回的完整清单完成接入和人工验收。不要依赖只读某一份 README 后自行推断其他平台规则。

凭据保存在当前游戏项目的 `.gamealgo/cli.json`，不同游戏互不覆盖。CLI 命令说明不在本仓库重复维护，每次通过 Server 获取最新版本：

```bash
gamealgo help
gamealgo help report publish
gamealgo experiment run create --help
```

`gamealgo help` 不使用本地缓存；需要 AI 在本地搜索完整命令手册时，显式执行 `gamealgo help --out gamealgo-cli-help.md`。接入流程和业务规则使用 `gamealgo docs`，公开 SDK 函数使用 `gamealgo listapi` 或 `gamealgo docs api <function-name>`。

## SDK 入口

- [iOS SDK](./ios/README.md)
- [Android SDK](./android/README.md)
- [REST helper](./rest-api/README.md)
- [TapTap Maker / Lua SDK](./lua/README.md)
- [客户端示例](./examples/README.md)
- [Protocol OpenAPI](./protocol/openapi.yaml)

海外 SDK 地址包含 `/algo_sdk` 路径前缀，必须完整保留。客户端只能配置 `ga_live_*`；`ga_admin_*` 只允许用于开发机器、AI Agent 或 CI。

## 仓库结构

```text
ios/        iOS Swift Package SDK
android/    Android Java SDK core
rest-api/   REST API helper 和示例
lua/        TapTap Maker / Lua SDK
protocol/   客户端协议定义
examples/   接入示例
```

## 本地验证

```bash
npm install
npm run check
```

平台 SDK README 只描述与当前代码版本绑定的安装方式、公开 API 和运行时约束。业务流程与平台规则以 `gamealgo docs` 返回的在线文档为准。

Server、CLI 和各平台 SDK 独立发布。兼容性由协议 fixture、不可变脚本版本以及 Server 暴露的最低 CLI 版本共同约束，不要求使用相同版本号。

事件上传采用 `at-least-once` 重试语义，不承诺 exactly-once：重试会保留原始 `eventId`，服务端应按 `eventId` 幂等处理。SDK 正常情况下使用内存队列，连续 3 次上传失败后才把完整未发送队列持久化为 JSON Lines；因此事件首次持久化前若进程被强制终止，尚未发送的内存事件仍属于 `best-effort`。各平台 README 记录了对应生命周期和存储约束。
