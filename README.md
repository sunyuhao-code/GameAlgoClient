# GamePropel Client

本仓库是 GamePropel（原 GameAlgo）的公开客户端仓库，包含 iOS SDK、Android SDK、微信小游戏 SDK、CrazyGames SDK、TapTap H5 SDK、TapTap Maker / Lua SDK、Godot SDK、底层 TypeScript HTTP helper 和协议定义。现有 H5 SDK 统一归为 TapTap H5；其他小游戏宿主使用独立 SDK，共享协议与底层核心逻辑。CLI 在独立的 [GameAlgoCli 仓库](https://github.com/sunyuhao-code/GameAlgoCli)维护和发布。

产品能力、接入流程、埋点、实验、报表与优化方法由服务端在线文档统一维护，不在本仓库保留副本。

JavaScript 新接入使用 `@gamepropel` 下的独立宿主包；旧 `@gamealgo/web` 和现有 `GameAlgo*` API 保留兼容。现有 CLI 命令、仓库地址、API 域名、`X-GameAlgo-Key` 请求头和本地存储标识继续沿用，升级包名不会创建另一套用户或事件队列。

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

在游戏项目根目录执行 `gamealgo whoami --json`，先复用有效的项目绑定或已有组织登录，再按当前 Server 的 [SDK 接入文档](https://game-algo-admin.dictapis.cn/dashboard/docs/index.html?topic=sdk-integration)选择流程；海外使用上表对应 Admin host。不要要求所有开发者先在网页注册、创建游戏和复制管理密钥。

- **Maker / TapTap H5 首次基础接入**：项目能提供真实运行时小游戏 ID 时，按在线文档执行 `gamealgo integration bootstrap`，取得真实 SDK Key 和有效期 24 小时的临时接入 Key。Maker 至少正常构建过一次才会生成 `.project/project.json`，读取 `taptap_publish.miniapp_id`；H5 按文档从已授权的 TapTap 发布流程获取 `mini_app_id`，不要用数字 App ID、项目 ID 或猜测的值代替。临时接入权限支持元数据登记、初始 Report Pack 配置和实时验证，不开放历史查询、配置文件、脚本或实验。
- **已有游戏、其他平台或正式管理**：优先复用有效登录。没有适用权限时，使用下面的 TapTap 浏览器授权；开发者网页已登录时可以直接确认。在开发者本机执行可加 `--open`，远程 Agent 展示返回的 `authorizationUrl`，并在发起命令的同一 CLI 环境完成登录。授权后再通过 `game list` / `game bind` 选择目标游戏，不自动选择第一项，也不为已接入游戏重复创建数据空间。
- **手工密钥作为备选**：组织管理员可提供 `ga_org_*` 或目标游戏的 `ga_admin_*`，非组织管理员提供目标游戏的 `ga_admin_*`，两种只需一种。组织管理 Key 从“Admin 控制台 → 组织管理 → 组织管理密钥”获取，通过 `gamealgo login --region <cn|global> --admin-key <provided-key>` 登录。临时接入 Key 过期、丢失或权限不足时转正式授权，不反复匿名领取。

需要正式授权时执行：

```bash
gamealgo login --region <cn|global> --json
# 完成授权后列出并绑定目标游戏，再用 whoami 核对；已有有效绑定时跳过登录。
gamealgo game list --json
gamealgo game bind <gameId> --json
gamealgo whoami --json
```

确认目标游戏后，两种接入方式都继续读取计划：

```bash
gamealgo integration get-plan --environment <domestic|overseas> --platform <ios|android|maker|web|wechat> --out gamealgo-integration-plan.json
```

SDK 接入必须先执行 `integration get-plan`，并按返回的完整清单完成接入和真实运行验证。临时接入阶段直接读取该计划，不要求先读取需要正式管理权限的优化任务目录。不要依赖只读某一份 README 后自行推断其他平台规则。

正式游戏绑定保存在当前项目的 `.gamealgo/cli.json`，临时接入凭据在 `.gamealgo/telemetry.json`，组织登录全局保存；不要提交这些凭据文件。创建正式管理 Key 后临时接入 Key 永久失效，原 SDK Key 和游戏数据继续使用。CLI 命令说明不在本仓库重复维护，每次通过 Server 获取最新版本：

```bash
gamealgo help
gamealgo help report publish
gamealgo experiment run create --help
```

`gamealgo help` 不使用本地缓存；需要 AI 在本地搜索完整命令手册时，显式执行 `gamealgo help --out gamealgo-cli-help.md`。接入流程和业务规则使用 `gamealgo docs`，公开 SDK 函数使用 `gamealgo listapi` 或 `gamealgo docs api <function-name>`。

## SDK 入口

- [iOS SDK](./ios/README.md)
- [Android SDK](./android/README.md)
- [微信小游戏 SDK](./wechat/README.md)
- [TapTap H5 SDK](./taptap-h5/README.md)
- [TapTap Maker / Lua SDK](./lua/README.md)
- [Godot SDK](./godot/README.md)
- [底层 TypeScript HTTP helper](./rest-api/README.md)
- [客户端示例](./examples/README.md)
- [Protocol OpenAPI](./protocol/openapi.yaml)

海外 SDK 地址包含 `/algo_sdk` 路径前缀，必须完整保留。客户端只能配置 `ga_live_*`；`ga_org_*`、`ga_admin_*`、`ga_setup_*` 只允许用于开发机器、AI Agent 或 CI，不写入日志或聊天摘要。

## Godot SDK

Godot 客户端是独立的 Protocol v1 实现：配置、实验和归因用 GDScript 直接访问 GameAlgo HTTPS API，事件持久化与后台 flush 由包内原生 GDExtension 完成，不桥接 iOS / Android SDK。协议层在 [`godot/`](./godot/README.md)，原生事件 backend 和策略脚本运行时在 [`runtime/godot/`](./godot/README.md#策略运行时)。

[`dirichlet-ai/pocket-native-plugins`](https://github.com/dirichlet-ai/pocket-native-plugins) 里另有一份独立实现，供既有接入使用；新接入用本仓库这套。

Godot SDK 只支持 `ios` 和 `android` 两个导出目标，上报的 `platform` 就是运行的操作系统。引擎信息走 `device` context（`runtime=godot`、`godotVersion`），不占用 `platform` 维度。桌面导出不受支持，`configure` 会直接拒绝。

Godot SDK 的埋点、归因、标识映射、自定义事件配额和 milestone 去重与其他 SDK 一致。

目前 CLI 还没有 Godot 接入形态。`--platform` 的取值是上报平台（`ios|android|maker|web|wechat`），Godot 项目应按目标导出平台取接入计划，其中「安装 SDK」一节以 [`godot/README.md`](./godot/README.md) 为准。

## 仓库结构

```text
ios/        iOS Swift Package SDK
android/    Android Java SDK core
taptap-h5/  TapTap H5 SDK（@gamepropel/sdk-taptap-h5）
web/        旧 @gamealgo/web 兼容入口
wechat/     微信小游戏 SDK（@gamepropel/sdk-wechat）
crazygames/ CrazyGames HTML5 SDK（@gamepropel/sdk-crazygames）
douyin/     抖音小游戏 SDK（@gamepropel/sdk-douyin）
rest-api/   底层 TypeScript HTTP helper 和协议示例
lua/        TapTap Maker / Lua SDK
godot/      Godot 4 GDScript SDK
runtime/    Rust 脚本运行时、Godot 原生事件 backend 和 GDExtension 绑定
protocol/   客户端协议定义
examples/   接入示例
```

## 协议一致性

广告曝光使用标准 `ad_view` 事件，携带 CLI 返回的本游戏 `adPlacementId`、真实 `revenue` 和可选 `network`、`trackId` 等动态字段。名称、广告类型和币种由服务端按登记定义补齐，币种必须与实际收入单位一致。先登记点位再接入；服务端继续兼容已发布旧 SDK 的历史格式。

Maker Lua `2.1.3-lua` 起提供 `GameAlgo.ShowRewardVideoAd(id, callback?, payload?)`，TapTap H5 Web `2.1.7` 起推荐 `const rewardAd = client.createAdSpace({ adUnitId })`，SDK 自动预加载，关闭后自动准备下一条，开发者无需手动处理；用户点击后只调用 `rewardAd.show(id, { onClose, onError }, payload?)`。旧 `client.showRewardVideoAd` 保留兼容。这些封装调用真实宿主广告接口，统一处理 trackId、去重和曝光上报；游戏回调只处理奖励与收尾，不重复调用底层曝光接口。精确语义见各平台 README。

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

CI 只运行核心单元／契约测试、编译与产物完整性校验：

```bash
npm run check:core
npm run check:godot:core  # 需要 Godot 和当前主机的原生运行时
```

Rust、Android JVM／生命周期状态机、Swift 和 Lua 的核心测试继续保留。CI 不启动 iOS／Android 模拟器、WKWebView 或浏览器 E2E；这些兼容性、生命周期和真实设备集成检查留在本地运行。Godot Release 直接构建已验证提交的移动端产物并检查文件、安装名与 SHA-256，不重复执行完整 Godot 测试套件。

本地完整验证入口保持不变：

```bash
npm install
npm run check
npm run check:godot
npm run check:godot:ios  # macOS + Xcode，本地 iOS 生命周期／杀进程恢复
```

Android 模拟器／真机的 instrumentation 命令见 `android/README.md`；Web 的浏览器、WebView 和双页面联机检查仍可通过 `check:web:e2e`、`check:web:webview`、`check:web:multiplayer` 单独运行。

平台 SDK README 只描述与当前代码版本绑定的安装方式、公开 API 和运行时约束。业务流程与平台规则以 `gamealgo docs` 返回的在线文档为准。

Android AAR、Godot 发布包（`gamealgo-godot-<version>.zip`，含 iOS / Android 运行时二进制）和 Web npm 包由语义化版本 tag（`v1.2.3` 或 `1.2.3`）触发 `.github/workflows/release.yml` 构建，并附加到对应 GitHub Release。三个平台在各自的 runner 上并行构建，由同一个 `publish` job 统一发布。任一平台构建失败就不会发布，不会留下只有一部分产物的 Release。

GitHub Release 成功后，独立的 `.github/workflows/publish.yml` 使用 `environment: npm` 和 OIDC trusted publishing，按顺序发布 `@gamepropel/sdk-taptap-h5`、`@gamepropel/sdk-wechat`、`@gamepropel/sdk-crazygames`、`@gamepropel/sdk-douyin` 和 `@gamealgo/web` 兼容入口。TapTap H5 与旧 Web 兼容包版本一致，兼容包精确依赖同版本的 TapTap H5 包；微信、CrazyGames 和抖音包版本独立，已发布版本会安全跳过。整仓 Release tag 与 npm 包版本独立。五个 npm 包都需要把 `sunyuhao-code/GameAlgoClient`、`publish.yml` 和 `npm` environment 配置为 trusted publisher；新包首次创建时先完成 npm 侧初始化。

仅更新 JavaScript npm 包时，在 **Publish JavaScript npm** 工作流上手动运行 `workflow_dispatch` 即可，无需创建整仓 Release tag 或重发原生平台产物。Maker / Lua SDK 从仓库源码同步，不依赖 npm 发布。

新 npm 包先由组织 owner 在本机正式发布可安装的候选版（例如 `-rc.0`，使用 `--tag next`），再配置 trusted publisher，并在两天内由 CI 发布正式版验证连接。保留候选版作为包身份和发布记录；不要把删除新包的唯一暂存版作为初始化步骤，这会连同占位包一起撤销并触发 npm 的 24 小时冷却期。

`@gamealgo/web` 与 `GameAlgoWebClient` 保留兼容；新接入使用 `@gamepropel/sdk-taptap-h5` 的 `GamePropelTapTapH5Client`。协议中的 `web` 继续表示 TapTap H5，历史数据不重写，操作系统继续由 `device.os` 表达。微信小游戏使用 `@gamepropel/sdk-wechat` 的 `GamePropelWechatClient` 与 `platform=wechat`；首版支持原生采集、持久化、生命周期、广告封装和参数配置，不执行远端脚本。

微信客户端的服务端联调要求及真机验证范围见 [对接说明](./wechat/SERVER_HANDOFF.md)。

CrazyGames 独立客户端使用 `platform=crazygames`，见 [接入文档](./crazygames/README.md)
及 [服务端对接](./crazygames/SERVER_HANDOFF.md)。首版支持参数配置、事件持久化、
生命周期和 rewarded/midgame 广告封装；公开广告回调不提供单次收益。npm 包通过同一个 GitHub trusted publisher
流程发布，并附加到后续 GitHub Release。

抖音小游戏客户端见 [接入说明](./douyin/README.md) 和 [服务端对接](./douyin/SERVER_HANDOFF.md)。
该包通过相同的 GitHub trusted publisher 流程发布；广告关闭计数包含宿主的分享兜底。
目前完成本地协议及安装验证，抖音 IDE 和真机验证待账号、AppID 和广告位准备后进行。
