# GameAlgo Client

GameAlgo Client is the public integration repository for game teams. It contains the iOS SDK, Android SDK, REST helper, public Protocol v1 docs, and runnable examples.

## 接入前准备

向 GameAlgo 平台团队确认三件事：

- `baseUrl`: 服务地址，例如 `https://gamealgo.example.com`。
- `gameKey`: 游戏鉴权 key，在控制台的游戏下创建。客户端请求会通过 `X-GameAlgo-Key` 识别游戏，不需要自己传可信的 `gameId`。
- 配置项: 实验 key、配置文件名、脚本名。例如 `level_generator`、`gameplay.json`、`level-generator.js`。

核心原则和老版 SDK 一样：**不要让 GameAlgo 网络请求阻塞游戏主流程**。SDK 会后台拉取配置并写入本地快照；配置未就绪、网络失败或脚本执行失败时，游戏应走本地默认逻辑。

## Layout

```text
protocol/   Public copy of Protocol v1
ios/        iOS Swift Package SDK
android/    Android Java SDK core
rest-api/   REST API helper and examples
examples/   Runnable integration examples
docs/       Client-facing docs
```

## 快速接入

### iOS

推荐通过 SwiftPM remote package 接入整个 client 仓库：

```text
https://github.com/dirichlet-ai/GameAlgoClient.git
```

在 Xcode 里选择 `File > Add Package Dependencies...`，填入仓库 URL，添加 `GameAlgoSDK` product。正式发版前可以先使用 `main` branch；后续打 `1.x.x` tag 后再切到 `Up to Next Major Version`。

如果 App 自己也使用 `Package.swift` 管理依赖：

```swift
.package(url: "https://github.com/dirichlet-ai/GameAlgoClient.git", branch: "main")
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

// App 启动后尽早调用。SDK 会自动生成并持久化匿名 userId。
sdk.start()

let variant = levelGenerator.variant(default: "control")
let difficulty = levelGenerator.string("difficulty", default: "normal")
let result = levelGenerator.execute(.object(["turn": .number(7)]))
let adsEnabled = sdk.config.bool("ads.rewarded.enabled", default: true, fileName: "gameplay.json")
```

`start()` 会预加载控制台 Configs 页面下发的配置文件。需要手动立刻拉某个文件时，可以直接调用：

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
await sdk.tracker.trackSessionStart()
await sdk.tracker.trackLevelEnd(payload: .object(["level": .number(3), "result": .string("win")]))
await sdk.tracker.flush()
```

`await sdk.tracker.flush()` 是手动 flush 接口，适合在切后台、游戏结束、关键事件后主动调用。`trackSessionEnd` 入队后也会自动触发一次 flush。

### Android

Android SDK 当前是 dependency-free Java core，后续可以封装成 AAR/Kotlin facade。

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

// 后台线程拉取 /v1/config 并预加载配置文件。SDK 会自动生成匿名 userId。
sdk.startAsync();

String variant = levelGenerator.variant("control");
String difficulty = levelGenerator.string("difficulty", "normal");

Map<String, Object> state = new LinkedHashMap<>();
state.put("turn", 7);
GameAlgoExecutionResult result = levelGenerator.execute(state);

boolean adsEnabled = sdk.config().bool("ads.rewarded.enabled", true, "gameplay.json");
```

`startAsync()` 会预加载控制台 Configs 页面下发的配置文件。需要手动立刻拉某个文件时，可以直接调用：

```java
GameAlgoConfigFile gameplay = sdk.fetchConfigFile("gameplay.json");
```

上传事件优先用内置 tracker。tracker 会把事件放进内存队列，最多 100 条一批上传，并每 30 秒自动 flush。

```kotlin
sdk.tracker().trackSessionStart()
sdk.tracker().trackLevelEnd(mapOf("level" to 3, "result" to "win"))
sdk.tracker().flushAsync()
```

`fetchConfig`、`fetchConfigFile`、`uploadEvents` 在 Java core 中是阻塞方法。Android App 应放到自己的 executor/coroutine 层调用，或用 `startAsync` 做启动预加载。普通事件上报直接用 `tracker()`，不需要游戏自己维护批量队列。

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

await client.start();

const variant = levelGenerator.variant("control");
const difficulty = levelGenerator.string("difficulty", "normal");
const result = await levelGenerator.execute({ turn: 7 });
const adsEnabled = client.config.bool("ads.rewarded.enabled", true, "gameplay.json");
const gameplay = await client.fetchConfigFile("gameplay.json");

client.tracker.trackSessionStart();
client.tracker.trackLevelEnd({ level: 3, result: "win" });
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

## 实验、配置和脚本

客户端推荐只读本地快照：

- `start` / `startAsync` 刷新 `/v1/config`，并预加载配置文件。
- SDK 默认生成匿名 `userId`；iOS 会用老版的 `gamealgo_user_id` 持久化，老用户升级后实验分组保持稳定。Android core / REST helper 传入 `cacheStorage` / `storage` 后也会持久化同一组 key。
- `executor(key)` 读取实验分组和实验 config。
- `executor(key).execute(state)` 执行预加载脚本；没有脚本时返回 config-only payload。
- `config` / `config()` 读取预加载的配置文件，例如 `gameplay.json`。
- 需要绕过预加载、立即拉取某个文件时，用 `fetchConfigFile("gameplay.json")`；iOS 写法是 `try await sdk.fetchConfigFile("gameplay.json")`。
- 启动时会先恢复上一次成功快照，再刷新远端配置；刷新成功后覆盖旧快照。

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

SDK 默认提供 `tracker`，游戏代码只需要调用 `trackSessionStart`、`trackLevelEnd`、`trackEvent` 等方法。tracker 会内存排队、最多 100 条一批上传、30 秒定时 flush、失败时保留上一批等待下次 retry。`uploadEvents` 仍保留为低层接口，只有在接入方自己有队列系统时才需要直接调用。

SDK 拉取配置时会带上 `userId/sessionId/platform/sdkVersion/timezone/device`，服务端生成一条 SDK context 日志并返回 `contextId`。官方 SDK 会自动补基础 `device` 信息，接入方可以额外传入自定义字段覆盖或追加。后续事件只引用这个 `contextId`；实验分组保存在 context 里，不再复制到每条事件。

最小推荐事件：

```text
session_start
session_end
config_loaded
level_start
level_end
```

有广告或内购时再接：

```text
ad_view
purchase
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
- 业务字段统一放在 `payload`；平台上报链路只保存原始 `payload_json`，不在写入时解释维度或指标。
- 后续由游戏提交 report pack 声明哪些 payload 字段用于报表维度、哪些字段用于聚合指标；离线任务只展开声明过的字段。
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
- `session_start`、`session_end`、核心玩法事件能上传成功。
- QA 包设置 `isDebug=true`，生产包使用正式 key。
- key 不写入日志、截图、崩溃上报或公开仓库。

## Checks

```bash
npm run check
swift test
cd ios && swift test
cd android && javac -d /tmp/gamealgo-android-classes src/main/java/com/gamealgo/sdk/*.java src/test/java/com/gamealgo/sdk/*.java
cd android && java -cp /tmp/gamealgo-android-classes com.gamealgo.sdk.GameAlgoClientSmokeTest
```

## Release Boundary

Anything in this project may be exposed to integration teams. Keep server implementation, dashboard admin code, internal SQL, deploy scripts, credentials, and production key values in the private server repository.
