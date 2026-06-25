# AI LTV 优化 Playbook

这份文档面向接入 GameAlgo 的游戏开发 Agent。目标不是说明 SDK 内部实现，而是告诉 Agent 如何基于数据持续优化游戏 LTV。

GameAlgo 提供三类能力：

- 动态配置和实验：不发版调整游戏参数、脚本和策略。
- 标准事件和自定义事件：让关键玩法行为、广告、付费和留存可以被分析。
- Report Pack 和 CLI：让 Agent 可以拉取报表结果，形成“观察数据 -> 提出假设 -> 发布实验 -> 回收结果”的迭代闭环。

## 1. 优化目标

LTV 可以拆成几个可操作的问题：

- 新用户是否留下来：D1 / D3 / D7 留存、新手关键节点流失。
- 用户是否玩得更深：关卡进度、模式参与率、失败率、单局时长。
- 广告收入是否健康：广告展示次数、广告收入、ARPDAU、广告位和广告类型表现。
- 内购收入是否增长：付费率、ARPPU、商品转化。
- 收入增长是否牺牲体验：留存、时长、失败率和关键玩法参与是否恶化。

Agent 的任务不是单次调参，而是持续迭代：先找到高影响问题，再用实验验证改动，最后根据数据决定保留、回滚或继续优化。

## 2. 推荐工作流

每一轮优化建议按这个顺序执行：

1. 拉取当前实验、配置、脚本和 Report Pack。
2. 拉取最近 7 到 14 天核心报表。
3. 找到最值得优化的问题，例如某个关卡段流失高、某个广告位收入高但留存下降、某个模式参与率低。
4. 写清楚优化假设：改什么、为什么、预期影响什么指标。
5. 修改实验、配置或脚本，一次只改变一个主要变量。
6. 发布实验，并记录版本说明。
7. 等待数据沉淀后拉取报表结果。
8. 对比主指标和护栏指标，决定放量、回滚或继续实验。

不要在没有数据依据时同时修改多个核心变量。多个变量一起改会让实验结果难以解释。

## 3. 使用 CLI

CLI 使用游戏维度的 Game Admin Key。这个 key 只用于开发期自动化，不放进客户端包，也不用于运行时事件上报。

```bash
gamealgo login --host https://game-algo-admin.dictapis.cn --admin-key ga_admin_xxx
```

拉取当前实验：

```bash
gamealgo experiment pull --out experiment.yaml
```

修改后先看 diff：

```bash
gamealgo experiment diff experiment.yaml
```

发布实验：

```bash
gamealgo experiment publish experiment.yaml --message "adjust first ad level" --yes
```

拉取可用报表：

```bash
gamealgo report manifest --json
```

拉取报表结果：

```bash
gamealgo report result \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --group "Daily ARPU" \
  --selector experiment=ad_frequency \
  --timeout 60 \
  --out reports/daily-arpu.json
```

确认 SDK 事件已经进入数据表：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --event-type level_end \
  --timeout 60 \
  --json
```

接入 TapTap Maker / TapTap 小游戏 / Lua SDK 时，`platform` 填 `rest`。这类环境通过服务端 Proxy 或 REST 协议接入，不属于原生 `ios` / `android`。如果需要在报表或排查中识别 TapMaker，把运行环境写入 `device`，例如 `device.runtime = "tapmaker"`、`device.engine = "lua"`、`device.channel = "taptap_mini_game"`。

TapTap Maker 接入需要开启多人模式服务端。服务端部署能力是 Maker 自带的，GameAlgo SDK 里已经提供 `lua/ProxyServer.lua` 和 `lua/server_main.lua`，不需要为 GameAlgo 额外开发或部署独立后端。

TapTap Maker 初始化时优先使用 Maker 环境提供的稳定用户 ID，例如 `lobby:GetMyUserId()`，并传给 `GameAlgo.Init({ userId = tapUserId })`。拿不到时可以传 `nil`，SDK 会退回到本地匿名 ID。不要使用昵称、头像、手机号等可识别信息作为 `userId`。

开启服务端后，Maker 数据默认会落在服务端；但客户端已有本地数据和存档仍然可以继续读取。优化或接入时不要破坏旧单机存档：要么继续使用本地存储，要么设计从本地存档到服务端存储的无缝迁移。

国内游戏、TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

本地修改 Report Pack 后，可以先预览查询结果，不必马上发布：

```bash
gamealgo report preview \
  --pack gamealgo-report-pack-v1.json \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --tab-id levels \
  --group-id max_levels \
  --chart-id max_levels__max_level_distribution \
  --timeout 60 \
  --out reports/max-level-distribution-preview.json
```

如果要指定 `--chart-id`，优先使用 `report manifest` 返回的规范化 id。Report Pack 原始 JSON 里可以写 `max_level_distribution`，服务端会在 manifest 中规范化为 `max_levels__max_level_distribution`。已经指定 `--group-id max_levels` 时，CLI 也支持用裸 id `--chart-id max_level_distribution` 做本地调试。

如果命令输出给其他程序读取，使用 `--json`，并确保 stdout 不被日志污染。源码仓库内通过 npm script 调试时使用：

```bash
npm --silent run cli -- report manifest --json
```

## 4. 实验设计规则

每个实验至少写清楚：

- 实验目标：提升哪个核心指标。
- 修改内容：改了哪个配置、脚本或策略。
- 主指标：用来判断实验是否成功。
- 护栏指标：用来判断是否伤害体验。
- 观察窗口：至少观察多少天或多少用户。
- 成功标准：达到什么阈值后放量。
- 回滚条件：什么情况下立即停止。

常见主指标：

- 留存优化：D1 / D3 / D7 retention。
- 广告优化：ad revenue、ARPDAU、impressions per DAU、LTV。
- 关卡优化：level completion rate、max level distribution、session duration。
- 模式优化：mode penetration、mode revenue、mode completion。

常见护栏指标：

- D1 retention 不能明显下降。
- session duration 不能异常下降。
- level fail rate 不能异常升高。
- ad impressions per user 不能过高。
- 关键模式参与率不能下降。

## 5. 常见优化方向

### 新手流失

先看新用户 cohort、关卡完成率、最大关卡分布和 session duration。优先定位用户集中离开的关卡段或玩法节点。

可尝试：

- 降低早期关卡难度。
- 调整教程触发时机。
- 提前展示核心玩法爽点。
- 减少过早广告打断。

### 广告策略

先看广告收入曲线、广告位收入、广告类型收入、impressions per DAU 和 retention。广告收入提升必须同时观察留存和时长。

可尝试：

- 调整第一次广告出现的关卡位置。
- 调整激励视频和插屏广告的频率。
- 对高价值广告位做不同频控实验。
- 对不同玩法模式使用不同广告策略。

### 关卡和难度

先看 level completion、fail rate、max level distribution 和分实验留存。不要只追求完成率，过低难度也可能降低时长和广告机会。

可尝试：

- 动态下发关卡生成参数。
- 对高流失关卡段做难度回调。
- 对不同用户分层尝试不同生成策略。
- 比较不同关卡组合对留存和收入的影响。

### 玩法模式

先看 mode penetration、mode revenue、mode retention 和 mode completion。模式参与率低不一定是模式不好，也可能是入口、奖励或解锁时机问题。

可尝试：

- 调整模式入口展示位置。
- 调整解锁条件。
- 调整模式奖励。
- 对高潜力模式加引导。

## 6. 麻将游戏示例

### 示例 1：关卡生成逻辑优化

观察：

- 新用户在某些关卡段集中流失。
- 最大关卡分布显示用户卡在固定区间。
- 广告收入和关卡进度相关。

假设：

- 当前关卡生成逻辑在高流失节点过难，导致用户提前离开。
- 通过动态下发新的关卡生成组合，可以降低流失并提升后续广告机会。

动作：

- 使用 `script pull` 拉取当前关卡生成脚本。
- 新增一个实验 variant，绑定新的关卡生成参数或脚本。
- 发布实验，只给一部分新用户流量。
- 观察 D1 retention、max level distribution、ad revenue 和 LTV。

决策：

- 如果新策略提升留存且广告收入不下降，继续放量。
- 如果收入提升但留存明显下降，不直接采用，需要继续调低广告或难度压力。

### 示例 2：首次广告关卡和广告频率优化

观察：

- 过早展示广告可能影响新用户留存。
- 过晚展示广告会损失早期收入。

假设：

- 把首次广告位置和广告频率做实验，可以在体验和收入之间找到更优平衡。

动作：

- 配置多个 variant，例如 `first_ad_level=3/5/7` 和不同 frequency。
- 观察 D1 retention、ad revenue、ARPDAU、LTV、session duration。

决策：

- 选择 LTV 更高且留存没有明显恶化的策略。
- 如果不同用户群体表现差异明显，后续可以继续做分层策略。

## 7. Agent 输出格式

每次提出优化方案时，建议按下面格式输出，方便开发者审核和追踪：

```text
观察：
- ...

问题判断：
- ...

优化假设：
- ...

计划改动：
- ...

实验设计：
- strategy:
- variants:
- traffic:

主指标：
- ...

护栏指标：
- ...

风险：
- ...

验证方式：
- 使用哪些 report group / chart / selector。

下一步：
- 发布、观察、放量、回滚或继续实验。
```

## 8. 不要做的事

- 不要把 Game Admin Key 放进客户端包。
- 不要为了短期收入忽略留存和体验指标。
- 不要在一个实验里同时修改多个无法拆分解释的变量。
- 不要只看一天数据就做最终结论，除非样本量足够且风险很低。
- 不要把密钥、手机号、邮箱、完整账号标识写进事件 payload。
- 不要在没有本地默认逻辑的情况下依赖远端配置。

## 9. 未来方向

当前阶段，Agent 通过实验和报表完成“人审 + 自动化执行”的优化闭环。长期目标是让平台基于数据自动为不同用户选择更合适的参数组合，以持续优化游戏 LTV。

在达到全自动优化之前，Agent 应优先把实验设计、指标回收和复盘结论标准化，让每一轮调整都能被数据解释。
