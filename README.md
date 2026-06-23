# GameAlgo Client

GameAlgo Client 是面向游戏接入方的公开客户端仓库，包含 iOS SDK、Android SDK、REST helper、Protocol v1 文档和可运行示例。

## 接入前准备

向 GameAlgo 平台团队确认三件事：

- `baseUrl`: 服务地址，例如 `https://gamealgo.example.com`。
- `gameKey`: 游戏鉴权 key，在 GameAlgo 控制台的游戏下创建。客户端请求会通过 `X-GameAlgo-Key` 识别游戏，不需要自己传可信的 `gameId`。
- 配置项: 实验 key、配置文件名、脚本名。例如 `level_generator`、`gameplay.json`、`level-generator.js`。

核心原则：**不要让 GameAlgo 网络请求阻塞游戏主流程**。SDK 会后台拉取配置并写入本地快照；配置未就绪、网络失败或脚本执行失败时，游戏应走本地默认逻辑。

## 目录结构

```text
protocol/   Protocol v1 文档
ios/        iOS Swift Package SDK
android/    Android Java SDK core
rest-api/   REST API helper 和示例
lua/        TapTap 小游戏 Lua SDK 和服务端代理传输
cli/        游戏开发 Agent 使用的自动化 CLI
examples/   可运行接入示例
docs/       接入文档
```

## 快速接入

### iOS

推荐通过 SwiftPM remote package 接入整个 client 仓库：

```text
https://github.com/sunyuhao-code/GameAlgoClient.git
```

在 Xcode 里选择 `File > Add Package Dependencies...`，填入仓库 URL，添加 `GameAlgoSDK` product。正式发版前可以先使用 `main` branch；后续打 `1.x.x` tag 后再切到 `Up to Next Major Version`。

如果 App 自己也使用 `Package.swift` 管理依赖：

```swift
.package(url: "https://github.com/sunyuhao-code/GameAlgoClient.git", branch: "main")
```

并在 App target 里依赖：

```swift
.product(name: "GameAlgoSDK", package: "GameAlgoClient")
```

接入 App 后：

```swift
import GameAlgoSDK

let sdk = GameAlgoSDK(
    gameKey: "ga_live_xxx",
    baseURL: URL(string: "https://gamealgo.example.com")!,
    sdkVersion: "1.0.0",
    appVersion: "1.2.3"
)

let levelGenerator = sdk.executor("level_generator")

let variant = levelGenerator.variant(default: "control")
let difficulty = levelGenerator.string("difficulty", default: "normal")
let result = levelGenerator.execute(.object(["turn": .number(7)]))
let adsEnabled = sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json")
```

初始化 `GameAlgoSDK` 时会自动生成并持久化匿名 `userId`，后台刷新 `/v1/config`，并预加载 GameAlgo 控制台 Configs 页面下发的配置文件。需要手动立刻拉某个文件时，可以直接调用：

```swift
let gameplay = try await sdk.fetchConfigFile("gameplay.json")
```

如果首屏逻辑必须等远端配置，可以短时间等待；超时后仍然走本地默认逻辑：

```swift
if await sdk.waitForReady(timeout: 3.0) {
    let difficulty = levelGenerator.string("difficulty", default: "normal")
}
```

上传事件优先用内置 tracker。tracker 会把事件放进内存队列，最多 100 条一批上传，并每 30 秒自动 flush；iOS 进入后台或退出时也会主动 flush。

```swift
await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3), "result": .string("win")]))
await sdk.tracker.trackSessionEnd()
await sdk.tracker.flush()
```

`await sdk.tracker.flush()` 是手动 flush 接口，适合在切后台、游戏结束、关键事件后主动调用。`trackSessionEnd` 入队后也会自动触发一次 flush。

### Android

Android SDK 当前是无第三方依赖的 Java core，后续可以封装成 AAR 或 Kotlin facade。

```java
import com.gamealgo.sdk.*;
import java.util.LinkedHashMap;
import java.util.Map;

GameAlgoClient sdk = GameAlgo.init(
    "ga_live_xxx",
    "https://gamealgo.example.com",
    "1.0.0",
    "1.2.3"
);

GameAlgoExperimentExecutor levelGenerator = sdk.executor("level_generator");

String variant = levelGenerator.variant("control");
String difficulty = levelGenerator.string("difficulty", "normal");

Map<String, Object> state = new LinkedHashMap<>();
state.put("turn", 7);
GameAlgoExecutionResult result = levelGenerator.execute(state);

boolean adsEnabled = sdk.config().bool("ads.rewarded.enabled", true, "gameplay.json");
```

`GameAlgo.init(...)` 会自动生成匿名 `userId`，后台刷新 `/v1/config`，并预加载 GameAlgo 控制台 Configs 页面下发的配置文件。需要手动立刻拉某个文件时，可以直接调用：

```java
GameAlgoConfigFile gameplay = sdk.fetchConfigFile("gameplay.json");
```

上传事件优先用内置 tracker。tracker 会把事件放进内存队列，最多 100 条一批上传，并每 30 秒自动 flush。

```kotlin
sdk.tracker().trackLevelEnd(mapOf("level" to 3, "result" to "win"))
sdk.tracker().trackSessionEnd()
sdk.tracker().flushAsync()
```

`fetchConfig`、`fetchConfigFile`、`uploadEvents` 在 Java core 中是阻塞方法。Android App 应放到自己的 executor/coroutine 层调用。普通事件上报直接用 `tracker()`，不需要游戏自己维护批量队列。

### REST / Web / Backend

不能使用原生 SDK 时，可以直接调用 REST API，或使用 `rest-api/src` 的 TypeScript helper。

```ts
import { GameAlgoRestClient } from "./rest-api/src/index.ts";

const client = new GameAlgoRestClient({
  baseUrl: "https://gamealgo.example.com",
  gameKey: "ga_live_xxx",
  sdkVersion: "1.0.0",
  appVersion: "1.2.3",
});

const levelGenerator = client.executor("level_generator");

const variant = levelGenerator.variant("control");
const difficulty = levelGenerator.string("difficulty", "normal");
const result = await levelGenerator.execute({ turn: 7 });
const adsEnabled = client.config.bool("ads.rewarded.enabled", true, "gameplay.json");
const gameplay = await client.fetchConfigFile("gameplay.json");

client.tracker.trackLevelEnd({ level: 3, result: "win" });
client.tracker.trackSessionEnd();
await client.tracker.flush();
```

底层 REST 请求都需要带鉴权头：

```http
X-GameAlgo-Key: ga_live_xxx
```

常用接口：

```text
POST /v1/config
GET  /v1/config-files/{fileName}
POST /v1/events/batch
```

### TapTap 小游戏 / Lua

TapTap 小游戏客户端在沙盒里不能直接访问 GameAlgo HTTP API，可以使用 `lua/` 下的代理方案：

```text
Client: GameAlgo.lua + ProxyTransport.lua
Server: ProxyServer.lua + server_main.lua
```

客户端只通过 `HttpProxy_Request` / `HttpProxy_Response` RemoteEvent 和游戏服务端通信；服务端 `ProxyServer` 再转发到 `game-algo-sdk.dictapis.cn`。推荐把 `X-GameAlgo-Key` 配在 `server_main.lua` 的服务端 `defaultHeaders` 里，不要放进小游戏客户端包。

persistent world / background match 模式下，客户端可能在服务端脚本 ready 前调用 `GameAlgo.Init()`。Lua transport 会先把 `/v1/config` 等请求放进队列；`ServerConnected` 只记录连接状态，收到 `ServerReady` 后才通过 RemoteEvent 发出。自定义运行时如果没有 `ServerReady`，可以在 `GameAlgo.Init` 里传 `waitForServerReady = false` 回到连接可用后立即发送的旧行为。有 update loop 的游戏继续周期调用 `GameAlgo.Update()`，用于清理超时请求。

最小客户端调用：

```lua
local GameAlgo = require("GameAlgo")

GameAlgo.Init({
    baseUrl = "https://game-algo-sdk.dictapis.cn",
    appVersion = "1.0.0",
    device = { runtime = "taptap_mini_game" },
})

local levelGenerator = GameAlgo.Executor("level_generator")
local variant = levelGenerator.Variant("control")

GameAlgo.TrackLevelEnd({ level = 3, result = "win" })
GameAlgo.TrackSessionEnd()
GameAlgo.Flush()
```

完整说明见 `lua/README.md`。

## 开发 Agent CLI

`cli/` 提供面向游戏开发 Agent 的自动化工具，用于维护实验、脚本、配置、Report Pack，并拉取报表结果。CLI 使用游戏维度的 Game Admin Key，不使用客户端 `gameKey`。

```bash
gamealgo login --host https://game-algo-admin.example.com --admin-key ga_admin_xxx
gamealgo experiment pull --out experiment.yaml
gamealgo report result --from 2026-06-14 --to 2026-06-21 --group "Daily ARPU" --timeout 60
```

源码仓库内调试可用 `npm --silent run cli -- ...`。

完整说明见 [Agent CLI guide](./docs/agent-cli.md)。

Agent 在接入后可以参考 [AI LTV 优化 Playbook](./docs/ai-ltv-optimization-playbook.md)，按“观察数据 -> 提出假设 -> 发布实验 -> 回收报表”的流程持续优化留存、广告收入、玩法进度和整体 LTV。

## 实验、配置和脚本

客户端推荐只读本地快照：

- 初始化 SDK 对象时会后台刷新 `/v1/config`，并预加载配置文件。
- SDK 默认生成匿名 `userId` 并持久化；Android core / REST helper 传入 `cacheStorage` / `storage` 后也会持久化同一组 key。
- `executor(key)` 读取实验分组和实验 config。
- `executor(key).execute(state)` 执行预加载脚本；没有脚本时返回 config-only payload。
- `config` / `config()` 读取预加载的配置文件，例如 `gameplay.json`。
- 需要绕过预加载、立即拉取某个文件时，用 `fetchConfigFile("gameplay.json")`；iOS 写法是 `try await sdk.fetchConfigFile("gameplay.json")`。
- 初始化时会先恢复上一次成功快照，再刷新远端配置；刷新成功后覆盖旧快照。

脚本格式：

```js
function execute(input) {
  return {
    payload: {
      difficulty: input.config.difficulty,
      turn: input.state.turn
    },
    diagnostics: {
      variant: input.meta.variant
    }
  };
}
```

如果 `execute` 返回空、脚本 hash 不匹配或脚本报错，客户端应使用本地兜底逻辑。

## 事件接入

SDK 默认提供 `tracker`，游戏代码只需要调用 `trackLevelEnd`、`trackSessionEnd`、`trackEvent` 等方法。tracker 会内存排队、最多 100 条一批上传、30 秒定时 flush、失败时保留上一批等待下次 retry。配置 context 还没返回时，tracker 会先暂存事件，flush 时统一补当前 `contextId` 后上传。`uploadEvents` 仍保留为低层接口，只有在接入方自己有队列系统时才需要直接调用。

SDK 拉取配置时会带上 `userId/userCreatedAt/sessionId/platform/sdkVersion/timezone/device`，GameAlgo 会创建本次会话的 context 并返回 `contextId`。官方 SDK 会自动补基础 `device` 信息，接入方可以额外传入自定义字段覆盖或追加。后续事件只引用这个 `contextId`；实验分组保存在 context 里，不再复制到每条事件。

最小推荐事件：

```text
session_end
level_start
level_end
```

有广告或内购时再接：

```text
ad_view
purchase
```

广告事件使用 `trackAd`，事件名仍是 `ad_view`。`ad_view` 只表示广告已经成功曝光并产生一次有效展示；广告加载失败、未填充、播放失败、用户取消或关闭但没有完成有效曝光时，不要上报到 `ad_view`。`placement`、`adType`、`revenue`、`currency` 必填，`network` 可选：

```swift
await sdk.tracker.trackAd(
    placement: "rewarded_level_end",
    adType: "reward",
    revenue: 0.018,
    currency: "USD",
    network: "admob"
)
```

付费事件使用 `trackPurchase`，事件名是 `purchase`。`productId`、`revenue`、`currency` 建议都传，字段会原样进入 payload：

```swift
await sdk.tracker.trackPurchase(
    productId: "starter_pack",
    revenue: 4.99,
    currency: "USD"
)
```

自定义事件必须以 `_` 开头，只使用小写字母、数字和下划线，例如：

```text
_button_click
_tutorial_skip
```

事件要求：

- 批量上传，每批最多 100 条。
- QA 或测试设备设置 `isDebug=true`。
- 网络失败时重试，不阻塞游戏。
- `userId` 默认由 SDK 生成并持久化；有账号体系时也可以显式传自己的稳定匿名 ID。`sessionId` 每次启动或每局会话生成一个新的。
- 业务字段统一放在 `payload`；GameAlgo 会按原始 payload 保存事件，报表再按 report pack 声明的字段读取和聚合。
- 后续由游戏提交 report pack 声明哪些 payload 字段用于报表维度、哪些字段用于聚合指标。配置格式见 [Report Packs](./docs/report-packs.md)。
- 第一版建议 payload 保持 flat object，字段值使用 string / number / boolean / null。
- 不要在 payload 里放密钥、手机号、邮箱、完整用户 ID、实验分组或设备信息；这些要么敏感，要么已经由协议字段或 SDK context 提供。
- SDK 默认向控制台输出配置拉取、实验分组、配置文件和脚本加载日志；需要静默时 iOS 传 `logger: nil`，Android 传 `null` logger，REST 传 `logger: false`。

## 验收清单

- 使用正确的 `baseUrl` 和 `gameKey`。
- `/v1/config` 能成功返回当前游戏的 `configVersion`。
- 配置和配置文件可以本地缓存。
- 配置未就绪时，游戏有本地默认逻辑。
- `executor(key).variant(...)` 能读到实验分组。
- `config` 能读到 `gameplay.json` 等配置文件。
- `session_end` 和核心玩法事件能上传成功。
- QA 包设置 `isDebug=true`，生产包使用正式 key。
- key 不写入日志、截图、崩溃上报或公开仓库。
