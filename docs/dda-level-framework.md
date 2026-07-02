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

DDA Adapter 是游戏侧提供的决策逻辑，可以是 JS 脚本、配置模板，或游戏代码里的适配层。它的输入和输出建议保持稳定。

输入：

```json
{
  "context": {
    "mode": "normal",
    "progressionNo": 42,
    "userSegment": "existing"
  },
  "state": {
    "difficultyScore": 38,
    "recentFriction": 0.2
  },
  "knobs": {
    "difficulty_bias": 0,
    "failure_protection": "high",
    "hard_level_mode": "soft"
  }
}
```

输出：

```json
{
  "decisionId": "client-generated-or-script-generated-id",
  "parameters": {
    "difficultyScore": 42,
    "difficultyBand": "normal",
    "puzzleBucket": "rank_3"
  },
  "nextState": {
    "difficultyScore": 42
  },
  "diagnostics": {
    "reason": "normal_progression"
  }
}
```

约定：

- `parameters` 是游戏真正使用的参数。
- `nextState` 由 SDK 或游戏保存到本地，用于下一次决策。
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
score =
  DAU_ARPU
  * (1 + D1_retention + D2_retention + D3_retention + D4_retention)
```

其中：

- `DAU_ARPU` 是整个实验窗口内的收入 / 活跃用户天数，用来近似用户单活跃日收入。
- `D1-D4 retention` 只使用实验窗口内已经成熟的日期来估算。例如 7 天窗口里，D4 只使用窗口前 3 天的 cohort。
- 当前第一版默认每个留存日权重为 1，后续可以从历史数据学习更准确的留存价值权重。

第一版不要求把留存精确换算成长期收入，只要求所有 variant 用同一套 score 口径可比。

### 成熟窗口

托管实验不为了等待 D5 额外拉长周期。实验窗口结束后，平台等待数据延迟并直接生成报告；报告只纳入窗口内已经成熟的留存日期。

```text
7 天实验窗口 -> 用 7 天窗口 DAU_ARPU
             -> 用成熟日期平均估算 D1/D2/D3/D4
             -> score = DAU_ARPU * (1 + D1 + D2 + D3 + D4)
```

报表必须显示每个 Dx 使用了多少个成熟日期，避免把未成熟 cohort 当成完整结果。

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

第一版可以完全基于现有 executor/config 能力实现。

推荐流程：

1. 游戏创建一个实验，例如 `level_dda`。
2. 每个 variant 配置一组 knobs。
3. 游戏接入 DDA Adapter 脚本或本地 Adapter。
4. SDK start 后拉取实验配置。
5. 关卡开始前调用 Adapter，得到下一关参数。
6. 游戏使用参数生成或选择关卡。
7. 关卡结束后更新本地 DDA state。
8. 上报关卡结果、收入和 DDA diagnostics。

伪代码：

```swift
let dda = sdk.executor("level_dda")
let knobs = dda.config
let state = loadLocalDDAState()

let decision = dda.execute([
  "context": currentLevelContext,
  "state": state,
  "knobs": knobs
])

let levelParams = decision.payload.parameters
saveLocalDDAState(decision.payload.nextState)
```

如果游戏不使用脚本，也可以直接读取 variant 配置：

```swift
let difficultyBias = sdk.executor("level_dda").int("difficulty_bias", default: 0)
```

## 8. 归因和报表

DDA 相关字段建议随 `level_start` / `level_end` 或游戏自定义关卡事件上报。

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

- 按 variant 的 DAU ARPU。
- 按 variant 的成熟日期平均 D1-D4 留存。
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
5. 计算 DAU ARPU * 成熟留存 multiplier 的 LTV proxy score。
6. 淘汰低分策略，保留高分策略。
7. 生成下一轮候选。

这部分是平台能力，不要求客户端 SDK 先实现。客户端第一版只要能稳定读取实验、执行 Adapter、保存 state、上报归因数据，就可以支持 DDA 优化闭环。
