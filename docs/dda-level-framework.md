# 关卡类游戏 DDA 实验框架

这份文档描述 GameAlgo 对关卡类游戏动态难度调整（DDA, Dynamic Difficulty Adjustment）的标准化接入思路。DDA 在 GameAlgo 里不是一套独立 runtime，而是建立在实验、配置、脚本、事件和报表之上的标准用法。

目标是让游戏可以持续实验不同难度策略，并用 ARPU + 留存折算后的统一指标判断哪套策略更有利于 LTV。

## 1. 核心定位

GameAlgo 不直接理解每个游戏的关卡难度，也不直接替游戏生成最终关卡。平台负责做实验和评估，游戏负责解释自己的玩法参数。

职责边界：

| 模块 | 负责什么 | 不负责什么 |
| --- | --- | --- |
| 游戏 DDA Adapter | 把实验 knobs、玩家状态和游戏上下文转换成具体关卡参数 | 不负责实验分流和全局 LTV 评估 |
| GameAlgo 实验系统 | 给用户分配 DDA variant，下发 knobs 和脚本 | 不直接学习高维 `context -> 具体关卡参数` 映射 |
| GameAlgo SDK | 拉取实验配置、执行脚本、保存本地状态、上报归因数据 | 不内置某个游戏专用的升降难规则 |
| Report Pack / 自动实验 | 计算 ARPU、留存、护栏指标和统一 score | 不替代游戏对玩法安全性的约束 |

因此，DDA 的第一版产品形态是：

```text
游戏提供 Adapter + 可调 knobs
平台用实验系统下发不同 knobs
SDK 在本地执行 Adapter
游戏根据 Adapter 输出生成下一关
平台用报表评估不同 variant 对 LTV proxy 的影响
```

## 2. 为什么不单独做 DDA Runtime

不同关卡类游戏的难度含义差异很大：

- 数独 / 解谜：题库 rank、棋盘大小、提示数量。
- 三消：步数、障碍密度、颜色数、目标数量。
- 塔防：敌人血量、波次节奏、初始资源。
- 麻将消除：牌型组合、可消除路径、关卡生成规则。

如果平台直接学习完整的 `用户上下文 -> 玩法参数` 映射，搜索空间会非常大，而且平台无法判断某些参数组合是否破坏游戏设计。更稳的抽象是让游戏只暴露少量低维 knobs，平台负责搜索 knobs 的组合。

例如：

```json
{
  "difficulty_bias": [-1, 0, 1],
  "failure_protection": ["medium", "high"],
  "hard_level_mode": ["soft", "strict"]
}
```

平台只需要比较不同 knobs 组合的用户级结果；游戏 Adapter 再把 knobs 转换成具体参数。

## 3. DDA Adapter

DDA Adapter 由平台脚本和游戏参数映射层组成。平台脚本只输出抽象升降难动作，游戏代码负责把动作映射为安全的具体参数。

输入：

```json
{
  "state": {
    "context": {
      "mode": "normal",
      "progressionNo": 42
    },
    "behavior": {
      "current": {},
      "recent": {
        "level_failed": 2,
        "item_used": 1
      },
      "lifetime": {
        "level_failed": 8,
        "item_used": 5
      },
      "recentSteps": [
        { "stepId": "level-40", "behaviors": { "level_failed": 1 } },
        { "stepId": "level-41", "behaviors": { "level_failed": 1, "item_used": 1 } }
      ],
      "completedSteps": 41,
      "windowSize": 10
    }
  },
  "config": {
    "behaviorWeights": {
      "level_failed": 1,
      "item_used": 0.25
    },
    "decreaseThreshold": 0.8
  }
}
```

输出：

```json
{
  "adjustment": "decrease"
}
```

脚本的完整返回值：

```json
{
  "payload": {
    "adjustment": "decrease"
  },
  "diagnostics": {
    "frictionPerStep": 1.125,
    "recentStepCount": 2
  }
}
```

约定：

- `adjustment` 只能是 `increase`、`keep`、`decrease`。
- 游戏 Adapter 把 `adjustment` 映射为真正使用的关卡参数。
- SDK 保存行为窗口，游戏不需要自己维护 DDA state。
- `diagnostics` 用于排查和报表归因，不应该影响玩法。
- Adapter 必须有本地 fallback，配置拉取失败时游戏仍能正常生成关卡。

## 4. Knobs 设计

knobs 应该少而清晰。不要把所有游戏参数都暴露给平台搜索。

推荐第一版只暴露 2 到 4 个核心 knobs：

| Knob | 示例值 | 含义 |
| --- | --- | --- |
| `difficulty_bias` | `-1 / 0 / 1` | 整体难度向低、默认、高偏移 |
| `promotion_speed` | `slow / normal / fast` | 表现好时升难速度 |
| `failure_protection` | `low / medium / high` | 失败、重试、退出后的保护强度 |
| `hard_level_mode` | `off / soft / strict` | 高难节点是否受保护 |

好 knobs 的特征：

- 业务含义清楚，AI Agent 和开发者能理解。
- 值域小，适合小 DAU 游戏实验。
- 安全边界清楚，不会生成不可玩关卡。
- 可以跨多个版本复用，便于平台积累实验经验。

不建议：

- 直接暴露几十个底层参数。
- 把每个关卡的具体配置都作为 knobs。
- 让平台直接决定题库 ID、怪物组合或完整关卡布局。

## 5. 实验设计

DDA 实验的评估单位是用户，不是单次关卡决策。因为“一个关卡好不好”没有统一答案，耗时、失败、重试只能作为诊断或护栏，最终还是要看用户级 ARPU 和留存。

推荐把用户第一次进入 DDA 实验的日期记为 `assignment_day`：

```text
D0 = assignment_day
D1 = assignment_day + 1
...
D4 = assignment_day + 4
```

实验用户可以是新用户，也可以是老用户。主判断口径使用所有进入实验的活跃用户，同时单独观察新用户和老用户。

### 统一评分

一轮实验的核心指标建议折算为一个 LTV proxy score：

```text
score = LTV Proxy (Dk)
      = STANDARDIZED_DAY_VALUE_D0 + ... + STANDARDIZED_DAY_VALUE_Dk
```

其中：

- `STANDARDIZED_DAY_VALUE_Dx` 使用所有在 Dx 已成熟的实验进入用户作为分母；未回访用户当日价值为 0。
- 广告曝光按广告类型和用户本地日内曝光序号分桶，每个桶使用本轮所有参与组在实验窗口内共同计算的参考 CPM；各组曝光按对应桶估值，再加实际内购收入。
- 所有实验组使用同一个 `k`。`k` 的上限是 `min(14, 实验周期天数 - 3)`，并要求每个实验组在对应 Dx 至少有 10 个成熟进入用户。

新用户留存、新用户 LTV、实际 ARPU 和实际收入作为诊断信息单独展示，不再通过固定倍率间接折算主指标。

### 成熟窗口

托管实验不会为了等待更远的 Dx 额外拉长周期。实验窗口结束后，平台等待数据延迟并直接生成报告；报告使用所有实验组共同成熟的最大 `k`。

```text
7 天实验窗口 -> k 上限为 D4
             -> 逐日计算 D0-D4 的标准化用户价值
             -> 取所有实验组共同满足成熟样本门槛的最大连续 Dx
             -> score = D0 到该 Dx 的标准化日价值之和
```

报表显示实际使用的 `LTV Proxy (Dk)` 和各组成熟用户数，避免用不同生命周期长度比较实验组。

## 6. 策略阶段

小 DAU 游戏不适合永远使用同一种探索逻辑。推荐按阶段调整流量分配。

### 探索期

适用场景：

- 新游戏刚接入 DDA。
- 当前没有明确最优方向。
- 需要快速比较多个策略方向。

建议：

- 并行 3 到 4 个 variant。
- 每个 variant 流量接近均分。
- 一次只改变少数 knobs。
- 周期约 1 周，配合后续观察期。

### 收敛期

适用场景：

- 已经知道几个方向更有潜力。
- 需要比较相近候选。

建议：

- 当前较优策略占 40% 到 60%。
- 其余流量给 1 到 2 个 challenger。
- 使用统一 score 选出下一轮候选。

### 稳定期

适用场景：

- 已有稳定 champion。
- 只做小步迭代。

建议：

- champion 占 80% 到 90%。
- challenger 占 10% 到 20%。
- 明显负向时提前停止。

## 7. SDK 接入流程

SDK 提供 strategy 维度的本地 DDA controller。行为名称由游戏自定义，SDK 不写死游戏分类或具体规则。

推荐流程：

1. 游戏创建一个实验，例如 `level_dda`。
2. 每个 variant 配置一组 knobs。
3. 游戏接入 DDA Adapter 脚本或本地 Adapter。
4. SDK start 后拉取实验配置。
5. 关卡开始前调用 `decide(context)`，得到升降难动作。
6. 游戏使用参数生成或选择关卡。
7. 游戏过程中调用 `recordBehavior`；关卡结束后调用 `completeStep`。
8. 上报关卡结果、收入和 DDA diagnostics。

伪代码：

```swift
let dda = sdk.dda("level_dda")
let decision = dda.decide(context: .object([
  "mode": .string("normal"),
  "progressionNo": .number(42)
]))
let levelParams = gameDDAAdapter.apply(decision.adjustment)

// 关卡过程中记录游戏自定义行为。
try dda.recordBehavior("item_used")
try dda.recordBehavior("mistake")

// 关卡结束后推进滚动窗口。
dda.completeStep("level-42")
```

如果脚本未准备好、执行失败或返回非法动作，`decide` 会安全返回 `keep`。如果游戏不使用脚本，也可以直接读取 variant 配置：

```swift
let difficultyBias = sdk.executor("level_dda").int("difficulty_bias", default: 0)
```

## 8. 归因和报表

DDA 行为计数默认只保存在本地，不会自动上报。需要分析时，把决策摘要随 `level_start` / `level_end` 或游戏自定义关卡事件上报，不要上传完整行为历史。

推荐字段：

| 字段 | 含义 |
| --- | --- |
| `ddaPolicy` | DDA 实验 key，例如 `level_dda` |
| `ddaVariant` | 当前实验 variant |
| `ddaDecisionId` | 本次决策 ID |
| `ddaDifficultyScore` | Adapter 输出的抽象难度分 |
| `ddaDifficultyBand` | Adapter 输出的难度档 |
| `ddaReason` | 本次决策原因，用于排查 |
| `ddaParameters` | 游戏实际使用的关键参数摘要 |

主报表：

- 按 variant 的标准化 DAU ARPU、实际 DAU ARPU 和实际综合 CPM。
- 按 variant 的成熟同期群 D1-D5 留存。
- LTV proxy score 排名。
- 新用户 / 老用户拆分。

诊断报表：

- 按难度档的通过率、失败率、退出率。
- 按难度档的平均时长。
- 关卡最大进度分布。
- DDA 参数分布。
- 高流失关卡段在不同 variant 下的表现。

诊断报表只解释原因，不作为最终胜负裁判。

## 9. Meowdokus 示例映射

Meowdokus 现有 DDA 是一个很适合的 adapter 案例：

```text
local DDA state + experiment knobs + levelNumber
  -> strategy
  -> rank / tier / size
  -> puzzle bucket
```

可以保留的部分：

- 本地保存 DDA state。
- 下一关生效，不改当前关。
- JS 根据实验配置和 state 输出题库选择。
- 返回 diagnostics 供事件上报和报表分析。

需要产品化的部分：

- 把 `clean win`、失败、重试、道具使用等规则参数化。
- 把 `strategy/rank/tier` 包在 Adapter 内部，不作为 SDK 通用概念。
- 把 `hard level` 和 `special level` 的保护策略做成 knobs。
- 每次决策上报 `ddaVariant`、`difficultyScore`、`rank/tier/size` 摘要。

Meowdokus 可暴露的 knobs 示例：

```json
{
  "difficulty_bias": [-1, 0, 1],
  "promotion_speed": ["slow", "normal"],
  "failure_protection": ["medium", "high"],
  "hard_level_mode": ["soft", "strict"]
}
```

Adapter 内部再把这些 knobs 映射到原来的 `strategy`、`rank`、`tier` 和 `size`。

## 10. 后续平台能力

后续自动化实验功能可以基于这套框架实现：

1. 读取游戏声明的 knob 空间。
2. 自动生成候选 variants。
3. 发布实验并记录版本。
4. 按阶段分配流量。
5. 计算 D0 到共同成熟 Dx 的标准化日价值之和，得到 LTV proxy score。
6. 淘汰低分策略，保留高分策略。
7. 生成下一轮候选。

客户端 SDK 已提供统一行为窗口和决策输入；后续平台能力只需要围绕 knobs 搜索、实验评估与自动迭代扩展。
