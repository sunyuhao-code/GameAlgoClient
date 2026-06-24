# GameAlgo 开发者快速开始

这份文档面向接入 GameAlgo 的游戏开发者。它不展开协议细节，主要说明：平台地址是什么、账号和密钥怎么拿、客户端该配什么、为什么推荐让 AI Agent 通过 CLI 来维护实验和报表配置。

## 1. 平台地址

国内环境使用两个地址：

| 用途 | 地址 | 给谁用 |
| --- | --- | --- |
| SDK / REST API | `https://game-algo-sdk.dictapis.cn` | 游戏客户端 SDK、REST API、小游戏服务端代理 |
| Admin / CLI | `https://game-algo-admin.dictapis.cn` | 浏览器控制台、`gamealgo login --host` |

客户端 SDK 只能配置 SDK / REST API 地址。Admin / CLI 地址只给开发者、AI Agent 和 CI 使用，不要配置到游戏客户端里。

## 2. 管理员会给你什么

管理员只需要提供：

- Admin 平台地址
- 开发者账号
- 初始密码

管理员不直接提供游戏密钥。开发者登录控制台后，自己创建游戏，并为这个游戏创建一个 Game Admin Key。后续 Client Game Key 的创建、查看和维护，推荐交给 AI Agent 通过 CLI 自动完成。

## 3. 登录控制台并创建游戏

1. 打开 Admin 控制台：

   ```text
   https://game-algo-admin.dictapis.cn
   ```

2. 使用管理员提供的开发者账号和初始密码登录。
3. 创建或选择你的游戏。
4. 打开 `密钥 / Keys` 页面。

## 4. 创建 Game Admin Key

GameAlgo 有两类 key，名字接近但用途不同。

| Key | 示例 | 用途 | 放在哪里 |
| --- | --- | --- | --- |
| Client Game Key | `ga_test_*` / `ga_live_*` | 游戏运行时拉取配置、拉取配置文件、上报事件 | 游戏客户端包，或小游戏的服务端代理 |
| Game Admin Key | `ga_admin_*` | CLI / AI Agent / CI 管理实验、脚本、配置、Report Pack，拉取报表和事件统计 | 开发机器、CI Secret、Agent Secret |

推荐流程是：开发者只手工创建 `Game Admin Key`，然后把它交给 AI Agent。AI Agent 会用 CLI 检查当前游戏是否已有可用的 Client Game Key；没有时自动创建；需要写入 SDK 或 TapTap Maker 服务端 Proxy 时，再通过 CLI 读取明文。

- 在 `Game Admin Key` 区域点击创建。
- 用于 `gamealgo login`、AI Agent 和 CI。
- CLI 请求会通过 `X-GameAlgo-Game-Admin-Key` 携带它。
- 不要把 `ga_admin_*` 放进游戏客户端包。

AI Agent 维护 Client Game Key 时会使用这些命令：

```bash
gamealgo key list --json
gamealgo key create --name <用途名> --json
gamealgo key reveal --name <用途名> --json
gamealgo key revoke --name <用途名> --yes --json
```

QA 包使用 `ga_test_*`，生产包使用 `ga_live_*`。SDK / REST 请求会通过 `X-GameAlgo-Key` 携带 Client Game Key。

如果团队暂时不用 AI Agent，也可以在控制台的 `客户端密钥` 区域手工创建 Client Game Key。但常规接入建议只把 Game Admin Key 提供给 AI，让 AI 负责运行时 key 的创建和维护，开发者负责审核 AI 写入项目配置的位置是否正确。

## 5. 客户端接入最小路径

客户端需要配置：

```text
baseURL = https://game-algo-sdk.dictapis.cn
gameKey = ga_live_xxx
```

推荐使用官方 SDK：

- iOS：使用 `ios/`
- Android：使用 `android/`
- 其他环境：使用 REST API

TapTap 小游戏这类沙盒环境通常不能直接访问外部服务，推荐走服务端代理：

```text
小游戏客户端 -> 游戏服务端 Proxy -> https://game-algo-sdk.dictapis.cn
```

这种情况下，Client Game Key 建议放在服务端 Proxy，不直接放在小游戏客户端脚本里。

TapTap Maker 接入时需要开启多人模式，也就是启用 Maker 自带的服务端能力。这个服务端由 Maker 平台部署和运行，不需要开发者额外购买服务器、部署独立后端，或为 GameAlgo 单独开发一套服务。GameAlgo Lua SDK 已经提供服务端代理代码：把 `lua/ProxyServer.lua` 和 `lua/server_main.lua` 放到 Maker 服务端脚本里即可。

开启服务端后，Maker 的数据默认会保存在服务端；但客户端原来的本地数据和存档仍然可以继续读取。已有单机存档的游戏接入时，需要二选一：继续沿用原来的本地存储，或者在合适的版本里把本地存档无缝迁移到服务端存储。不要因为接入 GameAlgo 就直接丢弃旧本地存档。

## 6. 推荐让 AI Agent 使用 CLI

GameAlgo CLI 的主要使用者不是普通玩家客户端，也不建议开发者长期手工维护复杂 JSON。推荐方式是：开发者提出目标，AI Agent 通过 CLI 拉取配置、修改、展示 diff、发布，并回收报表结果。

开发者负责：

- 提出优化目标
- 审核 AI Agent 给出的 diff
- 确认是否发布
- 查看实验结果，决定继续迭代、回滚或扩大实验

AI Agent 负责：

- 修改实验策略
- 修改脚本和配置文件
- 编写和校验 Report Pack
- 发布配置
- 拉取报表结果
- 根据数据继续提出下一轮修改建议

## 7. 推荐推进流程

拿到账号和 Game Admin Key 之后，不建议一上来就做复杂实验。推荐按下面顺序推进，每一步都让 AI Agent 帮你完成具体配置和代码改动。

开始前，把 Admin 地址和你创建的 Game Admin Key 提供给 AI Agent：

```text
Admin host: https://game-algo-admin.dictapis.cn
Game Admin Key: ga_admin_xxx
```

### 第一步：让 AI 接入 SDK 和基础事件

你给 AI Agent 的目标：

```text
请把 GameAlgo SDK 接入到游戏里，使用 SDK host。
Client Game Key 请通过 GameAlgo CLI 创建或复用，不要让我手工维护。
先接入最小事件：session_end、level_start、level_end。
如果游戏有广告或内购，也接入 ad_view 和 purchase。
```

AI Agent 应该做的事：

- 在游戏工程里配置 SDK host：`https://game-algo-sdk.dictapis.cn`
- 先用 `gamealgo key list --json` 检查当前游戏是否已有可用 Client Game Key
- 没有合适的 key 时，用 `gamealgo key create --name <用途名> --json` 创建；已有 key 但需要明文时，用 `gamealgo key reveal --name <用途名> --json`
- 把 Client Game Key 配到 SDK 或 TapTap Maker 服务端 Proxy 中
- 初始化 SDK，确保匿名 `userId` 能持久化
- 在关键点位补充事件上报
- 国内游戏、TapTap Maker / TapTap 小游戏的 `ad_view` 和 `purchase` 事件统一使用 `currency = "CNY"`，不要默认使用 `USD`
- 如果是 TapTap Maker / TapTap 小游戏这类沙盒环境，开启多人模式服务端，使用 SDK 内置 `lua/ProxyServer.lua` 和 `lua/server_main.lua` 转发请求；不要额外设计或部署新的后端服务
- 如果游戏已经有单机本地存档，保留读取逻辑，按项目需要继续使用本地存储或迁移到 Maker 服务端存储

开发者需要确认：

- 游戏能正常启动，不被 GameAlgo 网络请求阻塞
- 配置拉取失败时，游戏仍然走本地默认逻辑
- Debug / QA 包不要误用生产 key

### 第二步：验证事件上报链路

在游戏里触发一批测试事件后，让 AI Agent 用 CLI 查询事件数：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --json
```

只验证某个事件：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --event-type level_end \
  --json
```

你要看的结果：

- `total` 有增长
- `eventTypes` 里能看到目标事件名
- 如果没有数据，先查 SDK host、Client Game Key、事件触发点、flush 时机和网络代理

这一步只验证“事件有没有进平台”。如果后续报表为空，再检查事件字段和 Report Pack。

### 第三步：让 AI 设计并提交 Report Pack

事件上报成功后，再让 AI Agent 开发报表配置。

你给 AI Agent 的目标可以这样写：

```text
请根据当前游戏玩法设计 GameAlgo Report Pack。
先做 Overview、Retention、Revenue、Progression 这几个 tab。
每个 tab 只放能指导决策的核心图表。
```

AI Agent 应该做的事：

- 根据游戏事件 payload 定义 `events`
- 设计 `datasets` 和 `reports`
- 组织 dashboard tab / group / chart
- 优先引用标准看板，例如 `core.overview@1`、`retention.cohort@1`、`revenue.placement@1`、`revenue.ltv@1`
- 对游戏特有玩法补充自定义报表，例如分模式 ARPU、关卡流失、最大进度分布
- 先用 `report validate` 和 `report preview` 验证，再发布

常用命令：

```bash
gamealgo report validate gamealgo-report-pack-v1.json
gamealgo report preview \
  --pack gamealgo-report-pack-v1.json \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --group "Progression" \
  --timeout 60 \
  --out reports/preview.json
gamealgo report publish gamealgo-report-pack-v1.json
```

开发者需要确认：

- tab 是否对应真实业务问题
- 图表是否能指导决策，而不是只展示数据
- 百分比、金额、分桶排序等展示是否正确
- 报表结果和游戏内实际情况是否大致一致

### 第四步：用报表发现优化点

报表跑通后，让 AI Agent 拉取结果并总结问题。

示例目标：

```text
请查看最近 7 天报表，找出可能影响 LTV 的问题。
重点关注新用户留存、广告收入、关卡流失、模式渗透率。
```

常用命令：

```bash
gamealgo report manifest --json
gamealgo report result \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --group "Daily ARPU" \
  --timeout 60 \
  --out reports/daily-arpu.json
```

AI Agent 应该输出：

- 当前最值得优化的指标
- 可能原因
- 建议改哪些配置或脚本
- 需要新增哪些事件或报表
- 是否值得做实验验证

### 第五步：再引入实验和动态配置

只有在事件和报表都稳定之后，再让 AI Agent 做实验。实验应该围绕具体业务问题，而不是为了做实验而做实验。

适合做实验的场景：

- 第一次出广告的关卡位置
- 广告频率
- 关卡生成参数
- 新手引导节奏
- 玩法模式入口、奖励、解锁条件

你给 AI Agent 的目标可以这样写：

```text
请基于最近 7 天报表，设计一个广告频率实验。
目标是提升 LTV，但 D1 留存不能明显下降。
先给我看 experiment diff，再发布。
```

常用命令：

```bash
gamealgo experiment pull --out experiment.yaml
gamealgo experiment diff experiment.yaml
gamealgo experiment publish experiment.yaml --message "adjust ad frequency" --yes
```

开发者需要确认：

- 实验目标是否清楚
- variant 差异是否足够小，方便判断原因
- 流量分配是否合理
- 是否有可观察的报表指标
- 发布前是否看过 diff

### 第六步：形成持续优化闭环

一个完整闭环通常是：

```text
接入事件 -> 验证上报 -> 开发报表 -> 发现问题 -> 配置/脚本实验 -> 回收数据 -> 继续迭代
```

开发者不需要每天手动编辑平台配置。更推荐把目标告诉 AI Agent，让它通过 CLI 完成可 diff、可回滚、可复现的配置变更。

## 8. 最小验收清单

接入完成后，建议逐项确认：

- 客户端配置的是 SDK 地址 `https://game-algo-sdk.dictapis.cn`。
- 客户端使用的是 Client Game Key，不是 Game Admin Key。
- `/v1/config` 可以成功返回配置。
- 配置文件可以成功拉取。
- SDK 生成或持久化的匿名 `userId` 在多次启动后保持稳定。
- 可以上报 `session_end`、`level_start`、`level_end`。
- 有广告的游戏可以上报 `ad_view`。
- 有内购的游戏可以上报 `purchase`。
- AI Agent 可以查询事件统计，确认测试事件已进入平台。
- AI Agent 可以拉取报表结果。

## 9. 继续阅读

- [客户端接入指南](./integration-guide.md)
- [Agent CLI 接入指南](./agent-cli.md)
- [AI LTV 优化 Playbook](./ai-ltv-optimization-playbook.md)
- [Protocol v1](./protocol-v1.md)
- [REST API v1](./rest-api-v1.md)
- [Report Pack 报表配置](./report-packs.md)
