# 实验接入版本

实验接入版本用于描述“某个客户端构建已经实现了哪些实验能力”，避免旧版本客户端被分配到自己无法正确执行的实验组。

它不是 App 版本、Strategy 版本、脚本版本或 Report Pack 版本。它是当前游戏内单调递增的客户端能力版本。

## 为什么需要它

假设线上同时存在两个客户端版本：

- 老版本只认识 `interval`。
- 新版本增加了 `firstAdLevel`，并修改游戏逻辑读取这个参数。

如果实验直接向全部用户下发 `firstAdLevel`，老版本会忽略或错误处理这个参数。报表里同一个 Variant 会混入两种实际行为，实验结论不再可信。

实验接入版本把这个边界显式化：

- 新客户端固定上报 `experimentIntegrationVersion: 3`。
- Strategy 声明 `requiredIntegrationVersion: 3`。
- 低于版本 3 的客户端不会收到这个 Strategy，也不会进入它的 Run。

旧客户端继续使用游戏本地默认逻辑，不会因为平台发布新实验而改变行为。

## 两个核心字段

| 字段 | 所属位置 | 含义 |
| --- | --- | --- |
| `experimentIntegrationVersion` | SDK 初始化和 `/v1/config` 请求 | 当前客户端构建已经实现的实验能力版本；未接入时为 `0` |
| `requiredIntegrationVersion` | Strategy | 使用这个 Strategy 所需的最低客户端能力版本；每次发布都必须显式填写 |

Run 自动继承 Strategy 的 `requiredIntegrationVersion`，不需要也不能单独声明另一套最低版本。

服务端按以下规则处理：

| 客户端上报 | Strategy 要求 | 结果 |
| --- | --- | --- |
| 已注册版本且大于等于最低版本 | `> 0` | 可以收到默认参数或进入当前 Run |
| 低于最低版本 | `> 0` | 响应中不包含该 Strategy，游戏走本地默认逻辑 |
| 未上报、上报 `0` 或版本未在平台创建 | `> 0` | 按版本 `0` 处理，不下发该 Strategy |
| 任意非负版本 | `0` | 可以收到该 Strategy |

因此，玩法代码必须始终保留本地默认值。不能假设每个客户端都会收到远端 Strategy。

## 标准接入流程

### 1. 创建能力版本

当客户端准备实现一组新的实验能力时，由 AI Agent 创建版本：

```bash
gamealgo experiment integration-version latest --json
gamealgo experiment integration-version create \
  --title "广告频率参数" \
  --message "支持 firstAdLevel 和 interval" \
  --json
```

版本按游戏从 `1` 开始自增。`title` 用于标识这次客户端能力，创建后不可修改；`message` 用于记录具体参数、脚本输入和兼容约束，可以后续补充：

```bash
gamealgo experiment integration-version update \
  --version 3 \
  --message "支持 firstAdLevel、interval 和 placementRules" \
  --json
```

补充 `message` 只能完善记录，不能扩大已经上线版本的真实能力。如果客户端增加了新的执行能力，应创建下一个版本。

### 2. 在客户端实现并固定版本号

先实现对应参数读取、脚本执行或玩法映射，再把创建得到的整数写进当前 App 构建：

```swift
let sdk = GameAlgoSDK(
    gameKey: gameKey,
    baseURL: baseURL,
    experimentIntegrationVersion: 3
)
```

```kotlin
val sdk = GameAlgo.init(gameKey, baseUrl, sdkVersion, appVersion, 3)
```

```lua
GameAlgo.Init({
    gameKey = gameKey,
    baseUrl = baseUrl,
    experimentIntegrationVersion = 3,
})
```

版本号必须随客户端代码发布并保持不变。客户端不能在运行时调用 `latest`，否则老客户端会把自己伪装成支持最新能力，最低版本保护将失效。

### 3. 让 Strategy 引用最低版本

```yaml
strategyKey: ad_frequency
displayName: 广告频率
requiredIntegrationVersion: 3
defaultConfig:
  firstAdLevel: 4
  interval: 30
message: 初始化广告频率策略
```

```bash
gamealgo experiment strategy publish strategy.yaml --yes --json
```

即使 Strategy 不依赖任何新增客户端能力，也必须显式填写：

```yaml
requiredIntegrationVersion: 0
```

显式填写 `0` 表示 Agent 已经检查过兼容性，不是遗漏配置。

### 4. 验证版本已经上线

```bash
gamealgo experiment integration-version get --version 3 --json
```

版本刚创建时为 `draft`。非 Debug 客户端成功拉取配置并上报 SDK context 后，版本会变为 `observed`，并记录 `firstSeenAt`。

Debug Context 可以用来验证配置和实验行为，但不会把版本标记为 `observed`，也不会计入正式覆盖率统计。

## 什么时候需要创建新版本

判断标准不是“配置有没有变化”，而是“旧客户端是否能安全、等价地执行新 Strategy”。

通常需要新版本：

- 增加客户端必须读取的新参数。
- 改变现有参数的类型、单位或语义。
- 首次增加远端 JavaScript / Lua 执行能力。
- 给脚本输入增加策略必须依赖的新状态字段。
- 修改参数到游戏难度、广告或玩法行为的映射逻辑。
- 修复会导致同一 Variant 在新旧客户端表现不同的客户端缺陷。

通常不需要新版本：

- 调整已有参数的数值。
- 修改 Variant 流量。
- 创建新 Run，或评估、推全已有 Run。
- 只修改 Report Pack、图表标题或离线统计逻辑。
- 更新脚本内容，但脚本接口和客户端执行能力没有变化。
- 只补充版本 `message`，且客户端能力本身没有变化。

拿不准时，优先创建新版本。错误地多创建一个版本只会增加发布记录；错误地复用旧版本会污染实验数据。

## 托管实验的覆盖率启动门槛

最低实验版本负责单个用户能否收到 Strategy。托管实验的 `startCondition` 负责决定整体覆盖率是否足够开始实验，两者职责不同。

```yaml
displayName: 广告频率托管实验
type: managed
platform: ios
objectiveTemplate: ltv_proxy@1
baselineVariantId: control
cycleDays: 7
startCondition:
  minCoverage: 0.8
  minUsers: 100
variants:
  - variantId: control
    config: { firstAdLevel: 4, interval: 30 }
  - variantId: later_ad
    config: { firstAdLevel: 6, interval: 30 }
```

- `minCoverage`：指定平台最近 24 小时非 Debug 活跃用户中，接入版本达到 Strategy 最低版本的用户占比。
- `minUsers`：同一窗口内的全部非 Debug 去重活跃用户数，不是只统计已达到版本要求的用户。
- 两项同时配置时按 AND 判断。
- 等待期间 Run 状态为 `waiting_for_coverage`，Strategy 继续按默认参数工作，不开始实验分流。
- 达标后平台生成第一轮时间窗并自动开始托管实验。
- `startCondition` 只适用于托管实验；手动实验不能配置。

查看当前覆盖情况：

```bash
gamealgo experiment run show <runId> --json
```

返回的 `startConditionSnapshot` 包含统计窗口、总用户数、达标用户数、覆盖率和检查时间。

## 多平台和回滚

- 版本号属于游戏，但每个平台的客户端独立上报。iOS 已实现版本 3、Android 尚未实现时，Android 应继续上报自己的旧版本。
- Run 绑定一个平台，托管启动门槛也只统计该平台。
- 客户端能力版本应单调递增；不要在后续构建中回退版本号。
- Strategy 回滚到旧参数时，只有确认这些参数仍兼容目标客户端，才能降低 `requiredIntegrationVersion`。
- 已上线但未携带该字段的旧 SDK 自动按版本 `0` 处理。

## AI Agent 检查清单

提交实验前，Agent 必须确认：

1. Strategy 使用的参数和脚本输入在什么客户端版本中实现。
2. 对应实验接入版本已经创建，并固定在客户端构建中。
3. `requiredIntegrationVersion` 已显式填写；不需要门槛时明确填写 `0`。
4. 低版本客户端拿不到 Strategy 时，游戏仍有可用的本地默认逻辑。
5. 托管实验是否需要等待覆盖率和最小用户数。
6. 实验报表只在正式时间窗和满足版本要求的用户范围内解释。
