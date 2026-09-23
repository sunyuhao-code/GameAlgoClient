# GameAlgo Client

GameAlgo Client 是公开客户端仓库，包含 iOS SDK、Android SDK、H5 / Web SDK、TapTap Maker / Lua SDK、Godot SDK、底层 TypeScript HTTP helper 和协议定义。CLI 在独立的 [GameAlgoCli 仓库](https://github.com/sunyuhao-code/GameAlgoCli)维护和发布。

产品能力、接入流程、埋点、实验、报表与优化方法由 GameAlgo Server 在线文档统一维护，不在本仓库保留副本。

## AI Agent 从这里开始

不要把 README 原样转发给开发者。先安装最新 CLI，再从目标环境读取当前文档并完成接入。

| 环境 | Admin host | SDK API |
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
gamealgo integration get-plan --environment <domestic|overseas> --platform <ios|android|maker|web> --out gamealgo-integration-plan.json
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
- [H5 / Web SDK](./web/README.md)
- [TapTap Maker / Lua SDK](./lua/README.md)
- [Godot SDK](./godot/README.md)
- [底层 TypeScript HTTP helper](./rest-api/README.md)
- [客户端示例](./examples/README.md)
- [Protocol OpenAPI](./protocol/openapi.yaml)

海外 SDK 地址包含 `/algo_sdk` 路径前缀，必须完整保留。客户端只能配置 `ga_live_*`；`ga_admin_*` 只允许用于开发机器、AI Agent 或 CI。

## Godot SDK

Godot 客户端是独立的 Protocol v1 实现，用 GDScript 直接访问 GameAlgo HTTPS API，不桥接 iOS / Android SDK。协议层在 [`godot/`](./godot/README.md)，策略脚本运行时在 [`runtime/godot/`](./godot/README.md#策略运行时)——它是 `runtime/rust/` 的 gdext 绑定，和 iOS / Android 共用同一个 crate。

[`dirichlet-ai/pocket-native-plugins`](https://github.com/dirichlet-ai/pocket-native-plugins) 里另有一份独立实现，供既有接入使用；新接入用本仓库这套。

Godot SDK 只支持 `ios` 和 `android` 两个导出目标，上报的 `platform` 就是运行的操作系统。引擎信息走 `device` context（`runtime=godot`、`godotVersion`），不占用 `platform` 维度。桌面导出不受支持，`configure` 会直接拒绝。

Godot SDK 的埋点、归因、标识映射、自定义事件配额和 milestone 去重与其他 SDK 一致。

目前 CLI 还没有 Godot 接入形态。`--platform` 的取值是上报平台（`ios|android|maker|web`），Godot 项目应按目标导出平台取接入计划，其中「安装 SDK」一节以 [`godot/README.md`](./godot/README.md) 为准。

## 仓库结构

```text
ios/        iOS Swift Package SDK
android/    Android Java SDK core
web/        H5 / Web 浏览器 SDK
rest-api/   底层 TypeScript HTTP helper 和协议示例
lua/        TapTap Maker / Lua SDK
godot/      Godot 4 GDScript SDK
runtime/    Rust 脚本运行时和它的 Godot 绑定
protocol/   客户端协议定义
examples/   接入示例
```

## 协议一致性

Protocol v1 有五份客户端实现，都在本仓库：iOS / Android / Web / Lua / Godot。`protocol/openapi.yaml` 是唯一真相源，`protocol/fixtures/` 是跨实现的共同闸门。

Godot SDK 是 GDScript，进不了 Node 和 Swift 的测试套件，所以它的协议常量由 `rest-api/src/godot-sdk-drift.test.ts` 直接读源码校验，`npm run check` 就会跑，不需要装 Godot。GDScript 自身的契约测试用 `npm run check:godot`。

策略脚本运行时只有一份实现：`runtime/rust/`（rquickjs）。iOS 和 Android 走它的 C ABI，Godot 走 `runtime/godot/`（gdext 绑定，同一个 crate），Web 走 quickjs-emscripten 加载同一套语义。沙箱预算和 prelude 因此不存在需要人工对齐的副本：

| | 值 |
| --- | --- |
| 脚本源 / 输入 / 输出上限 | 10 MiB / 256 KiB / 256 KiB |
| 内存 / 栈上限 | 64 MiB / 512 KiB |
| 中断轮询上限 | 100,000 |
| 执行 / 预备超时 | 1s / 2s |

`protocol/fixtures/script-fixture.js` 是跨宿主的共同 fixture：`cargo test` 和 `npm run check:godot` 都执行它并断言同一份期望输出。

## 本地验证

```bash
npm install
npm run check
```

平台 SDK README 只描述与当前代码版本绑定的安装方式、公开 API 和运行时约束。业务流程与平台规则以 `gamealgo docs` 返回的在线文档为准。

Android AAR、Godot 发布包（`gamealgo-godot-<version>.zip`，含 iOS / Android 运行时二进制）和 Web npm 包由语义化版本 tag（`v1.2.3` 或 `1.2.3`）触发 `.github/workflows/release.yml` 构建，并附加到对应 GitHub Release。三个平台在各自的 runner 上并行构建，由同一个 `publish` job 统一发布。任一平台构建失败就不会发布，不会留下只有一部分产物的 Release。

GitHub Release 成功后，独立的 `.github/workflows/publish.yml` 会仿照 GameAlgoCli 使用 `environment: npm` 和 OIDC trusted publishing 发布 `@gamealgo/web`。整仓 Release tag 与 Web npm 包各自独立版本；工作流读取 `web/package.json`，已发布的版本会安全跳过。npm 侧需要把 `sunyuhao-code/GameAlgoClient`、`publish.yml` 和 `npm` environment 配置为 package trusted publisher，不再需要 `NPM_TOKEN`。
