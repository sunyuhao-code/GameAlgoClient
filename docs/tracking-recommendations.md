# 不同类型游戏的埋点建议

这份文档用于指导游戏团队和 AI Agent 设计 GameAlgo 埋点。埋点的目标不是把所有游戏状态都上传，而是让后续 Report Pack 能稳定计算留存、收入、进度、模式渗透率、实验效果和 LTV。

## 基本原则

埋点可以拆成三件事：

- 点位：什么时候上报，例如一局开始、一局结束、广告展示成功、购买完成。
- 字段：这个点位上报什么，例如关卡序号、结果、模式、时长、收入。
- 报表口径：这些字段怎么串起来，例如先按用户取最大通关进度，再按天求平均。

设计事件时先回答报表问题，再反推字段。不要因为游戏里已有某个变量名就直接拿来做报表字段。字段名必须表达清楚语义，例如 `stage_code`、`chapter`、`stage`、`level_index` 要区分清楚，不要把编码值当成连续关卡序号。

推荐所有游戏都接入：

| 事件 | 什么时候上报 | 关键字段 |
| --- | --- | --- |
| `session_end` | 一次 App / 游戏会话结束，或切后台前可以安全 flush 时 | `sessionDurationMs` |
| `game_start` | 一局、一次对局、一次 run 或一次核心玩法开始 | `mode`, `progressionType`, `runId` 或 `gameId` |
| `game_over` | 一局、一次对局、一次 run 或一次核心玩法结束 | `mode`, `result`, `durationMs`, `progressionNo` |
| `ad_view` | 广告完成有效曝光并产生收入时 | `placement`, `adType`, `revenue`, `currency` |
| `purchase` | 内购或付费成功时 | `productId`, `revenue`, `currency` |

国内游戏、TapTap Maker / TapTap 小游戏的 `currency` 统一使用 `CNY`。

## 字段命名建议

优先使用稳定、扁平、语义明确的 payload 字段：

| 字段类型 | 推荐字段 | 说明 |
| --- | --- | --- |
| 玩法模式 | `mode` | 例如 `classic`、`daily`、`pvp`、`endless`。 |
| 进度类型 | `progressionType` | 例如 `level`、`chapter`、`match`、`run`、`story_node`。 |
| 进度 ID | `progressionId` | 稳定字符串 ID，例如 `chapter_10_stage_3`。 |
| 连续进度序号 | `progressionNo` 或 `level_index` | 用于 max / avg / bucket 的数字，必须是连续可比较口径。 |
| 展示编码 | `stage_code` | 如果游戏内部用 `1001` 表示第 10 章第 1 小关，不要叫 `level`；这类编码默认只用于定位和排查，不建议用于正式报表聚合。 |
| 结果 | `result` | 建议用 `win`、`lose`、`quit`、`timeout`、`fail`。 |
| 是否成功 | `success` 或 `passed` | 布尔值，适合简单通过率。 |
| 时长 | `durationMs` 或 `duration_ms` | 建议同一游戏内统一一种命名风格。 |
| 尝试原因 | `exit_reason` | 例如 `complete`、`fail`、`quit`、`app_background`。 |

如果一个字段会用于排序、分桶或最大值，必须确认它是业务上可比较的数字。不要把拼接编码、字符串 ID、显示文案用于这类计算。

## 关卡 / 对局 / 局内挑战类

适用游戏：三消、解谜、麻将消除、塔防关卡、卡牌对局、PVP/PVE 单局。

推荐事件：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `level_start` | 关卡或对局开始 | `mode`, `level_index`, `progressionId`, `difficulty` |
| `level_end` | 关卡或对局结束 | `mode`, `level_index`, `progressionId`, `result`, `durationMs`, `attemptNo` |

可选字段：

- `chapter`、`stage`：章节和章内小关。
- `stage_code`：游戏内部编码，例如 `23005`。
- `score`、`stars`、`clear_rate`：完成质量。
- `retry_count`、`revive_count`、`hint_used`、`shuffle_used`：关卡摩擦和道具使用。
- `enemy_level`、`deck_power`、`player_power`：数值对抗类平衡分析。

常见报表：

- 关卡开始人数、结束人数、通过率、失败率。
- 按 `level_index` 的流失分布和最大进度分布。
- `AVG(MAX(level_index) BY userId)`：用户最大通关进度均值。
- 按实验 variant 对比通过率、时长、广告收入和 LTV。

注意：

- 如果游戏有 `chapter` 和 `stage`，建议额外上报 `level_index = (chapter - 1) * stages_per_chapter + stage`。
- 如果只能上报编码值，例如 `chapter * 100 + stage`，字段应命名为 `stage_code`。这类字段尽量不要用于报表聚合、趋势、排序或分桶，正式报表优先使用 `chapter`、`stage` 或连续的 `level_index`。

多层次关卡的卡点分析建议从粗到细设计报表。第一层先用 `chapter` 看最大通关章节、章节通过率和章节流失，快速判断用户主要卡在哪些大章节；第二层再针对异常章节展开 `stage` 或 `level_index`，看章内第几小关流失、失败或耗时异常。这样比一开始就把所有 `chapter + stage` 小关全铺成一张图更容易观察，也能减少报表噪音。

例如一个游戏用 `23005` 表示第 230 章第 5 小关：

- `stage_code = 23005`：只适合定位具体小关和排查单点问题，尽量不要作为正式报表指标或维度。
- `chapter = 230`：适合第一层分析最大通关章节和章节流失。
- `stage = 5`：适合在选中某个章节后分析章内卡点。
- `level_index = (chapter - 1) * 5 + stage`：适合需要连续进度、分桶和最大进度分布时使用。

## Run / Roguelike / 吸血鬼幸存者类

适用游戏：单次 run 有开始、结束、成长、掉落、死亡结算的游戏。

这类游戏不要为 run 再发明一套 `_run_start` / `_run_end` 标准点位。一次 run 本质上就是一局核心玩法，优先复用 `game_start` / `game_over`；如果 run 内还有清晰的关卡、波次、房间、章节，也可以在这些子阶段复用 `level_start` / `level_end`，并用 `progressionType`、`progressionNo`、`wave`、`room` 等字段表达具体进度。

推荐事件：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `game_start` | 一次 run 开始 | `mode`, `runId`, `character`, `build_seed`, `difficulty` |
| `game_over` | run 结束 | `mode`, `runId`, `result`, `durationMs`, `survivalSeconds`, `stageReached` |
| `level_start` / `level_end` | run 内有明确阶段、波次、房间或章节时 | `mode`, `runId`, `progressionType`, `progressionNo`, `wave`, `room`, `result`, `durationMs` |
| `_build_choice` | 关键构筑节点，例如游戏中期、Boss 前、游戏结束结算时记录技能、装备、天赋选择 | `runId`, `choiceType`, `choiceId`, `choiceName`, `nodeType`, `nodeNo`, `survivalSeconds`, `stageReached`, `options_count` |

可选字段：

- `kills`、`damage`、`gold`、`xp`、`boss_killed`。
- `death_reason`、`wave`、`map_id`。
- `power_score`：结算时玩家强度。

常见报表：

- run 完成率、平均存活时长、死亡波次分布。
- 技能/角色选择率和胜率。
- 不同构筑在关键节点的使用率、成功率、平均存活时长和收入表现。
- 按 `stageReached` 或 `survivalSeconds` 的进度分布。
- 实验对新手 run 时长、广告收入、付费转化的影响。

注意：

- `_build_choice` 不建议在每次普通升级、每次掉落或每个微小选择都上报。第一版更适合在少量关键节点上报，例如 `nodeType = mid_game`、`pre_boss`、`game_over`。
- `_build_choice` 必须带上游戏节点信息，例如 `nodeType`、`nodeNo`、`survivalSeconds`、`stageReached`。这样报表才能比较“某个阶段选择某个 build 后”的成功率和使用率，而不是只看到全局选择次数。

## 模拟经营 / 放置 / 养成类

适用游戏：餐厅、农场、城市建造、放置 RPG、合成经营。

推荐事件：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `_economy_snapshot` | 关键节点或定时低频快照 | `level_index`, `soft_currency`, `hard_currency`, `power_score` |
| `_upgrade` | 升级建筑、角色、技能 | `targetType`, `targetId`, `fromLevel`, `toLevel`, `costType`, `costAmount` |
| `_resource_gain` | 重要资源获得 | `source`, `resourceType`, `amount` |
| `_resource_spend` | 重要资源消耗 | `sink`, `resourceType`, `amount` |

可选字段：

- `building_count`、`worker_count`、`production_rate`。
- `offlineDurationMs`、`offlineRewardAmount`。
- `questId`、`questType`、`questCompleted`。

常见报表：

- 新用户首日升级深度、资源缺口点。
- 资源来源 / 消耗结构。
- 建筑或系统解锁率。
- 离线奖励对次留、广告收入和 LTV 的影响。

注意：

- 不要高频上传每次数值变化。资源类事件只记录关键来源、关键消耗和低频快照。
- 金币余额这类会频繁变化的字段，适合在 session end 或关键节点做 snapshot。

## 剧情 / 分支 / GAL Game 类

适用游戏：剧情推进、章节阅读、分支选择、角色好感度。

推荐事件：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `_story_node_start` | 进入剧情节点 | `chapter`, `nodeId`, `route`, `sceneType` |
| `_story_node_end` | 离开剧情节点 | `chapter`, `nodeId`, `route`, `result`, `durationMs` |
| `_choice_made` | 玩家做分支选择 | `chapter`, `nodeId`, `choiceId`, `route`, `choiceIndex` |

可选字段：

- `skip_used`、`auto_play_used`、`text_speed`。
- `characterId`、`affinityDelta`。
- `endingId`、`routeUnlocked`。

常见报表：

- 节点到达率、节点流失率。
- 分支选择占比。
- 路线完成率、结局解锁率。
- 剧情节奏对留存和付费的影响。

## 开放世界 / 沙盒 / 生存类

适用游戏：非线性目标、探索、建造、生存。

推荐事件：

| 事件 | 什么时候上报 | 推荐字段 |
| --- | --- | --- |
| `_objective_start` | 目标或任务开始 | `objectiveId`, `objectiveType`, `areaId`, `difficulty` |
| `_objective_end` | 目标或任务结束 | `objectiveId`, `objectiveType`, `result`, `durationMs` |
| `_area_enter` | 进入重要区域 | `areaId`, `areaType`, `playerLevel` |
| `_craft` | 制作关键物品 | `itemId`, `itemType`, `rarity`, `source` |

可选字段：

- `survivalDay`、`distanceTravelled`、`death_reason`。
- `teamSize`、`serverRegion`。

常见报表：

- 目标完成率、区域到达率、死亡原因分布。
- 制作系统使用率和关键物品渗透率。
- 早期探索路径和新手流失点。

## 广告和付费

所有商业化游戏都建议标准化广告和付费事件。

`ad_view` 必填字段：

| 字段 | 说明 |
| --- | --- |
| `placement` | 广告位，例如 `level_end_reward`、`home_banner`。 |
| `adType` | 广告类型，例如 `reward`、`banner`、`interstitial`。 |
| `revenue` | 本次曝光收入。 |
| `currency` | 国内统一 `CNY`。 |

`purchase` 建议字段：

| 字段 | 说明 |
| --- | --- |
| `productId` | 商品 ID。 |
| `revenue` | 实收金额。 |
| `currency` | 国内统一 `CNY`。 |
| `source` | 购买入口，例如 `shop`、`offer_popup`。 |

广告加载失败、无填充、播放中断、用户关闭但没有形成有效曝光时，不要上报 `ad_view`。这些可以作为自定义诊断事件，例如 `_ad_load_failed`，但不要混入收入报表口径。

## 用户归因

如果游戏接入 Adjust 等三方归因 SDK，不要把归因作为 `_attribution` 普通事件上报。归因是用户属性，应该在归因 SDK 异步返回结果后调用 GameAlgo 的 attribution API：

| SDK | 推荐调用 |
| --- | --- |
| iOS | `try await sdk.setAttribution(GameAlgoUserAttribution(provider: "adjust", attribution: [...]))` |
| Android | `sdk.setAttribution("adjust", attributionMap)` |
| REST | `await client.setAttribution({ provider: "adjust", attribution })` |

上报时机：

- 第一次拿到归因结果时上报。
- 归因内容变化时上报。
- 上次上传失败或没有拿到服务端 `attributionHash` ack 时，下次启动后重试。
- 不需要每次 App 打开都重复上报同一份归因。

建议字段：

| 字段 | 说明 |
| --- | --- |
| `network` | 渠道或广告网络。 |
| `campaign` | Campaign 名或 ID。 |
| `adgroup` | Ad group 名或 ID。 |
| `creative` | 素材名或 ID。 |
| `clickLabel` | 如果业务确实需要，放非敏感 label。 |

不要上传手机号、邮箱、OAID、IDFA、TapID 等强身份字段。归因字段用于后续分渠道留存、收入、LTV 和实验效果分析。

## 给 AI Agent 的接入流程

建议让 AI Agent 按下面顺序接入：

1. 先识别游戏类型和核心循环。
2. 列出需要回答的报表问题，例如“用户卡在哪一关”“哪个模式收入高”“实验是否提升 LTV”。
3. 只接最小事件集，保证 `session_end`、核心进度结束事件、`ad_view` 和 `purchase` 先稳定。
4. 为每个进度字段确认语义：连续序号、展示 ID、内部编码不要混用。
5. 用 `gamealgo events count` 验证事件进表。
6. 编写 Report Pack，并用 `report preview` 验证报表口径。
7. 再增加实验和动态配置。

如果报表数据异常，先检查字段语义和 Report Pack 口径，再怀疑 SDK 上报链路。事件能进表只说明链路正常，不代表报表字段选对了。
