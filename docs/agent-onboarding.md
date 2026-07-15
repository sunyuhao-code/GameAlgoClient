# GameAlgo AI 接入流程

这份文档给 AI Agent 使用。目标是：开发者把游戏仓库和 GameAlgo Client 仓库交给你后，你能主动完成接入，而不是把文档转发给开发者。

## 0. 完成状态规则

如果用户要求“接入 GameAlgo SDK”，默认目标是 Activated 接入。

| 状态 | 含义 | 交付口径 |
| --- | --- | --- |
| Activated | 已写入真实 `ga_live_*`，App 能拉配置，测试事件能进入平台 | 可以说接入完成 |
| Scaffolded | 只完成 SDK 代码接入，但没有真实 `ga_live_*` 或没有验证上报 | 只能说代码已接入，等待激活 |

如果没有真实 `ga_live_*`，必须先向用户索取 `ga_admin_*`，再用 CLI 创建或读取 Client Game Key。不要使用占位 key 后声称完成接入。

如果用户暂时无法提供 `ga_admin_*`，可以先继续做 Scaffolded 代码接入，但最终回复必须明确说明：

- 当前没有真实运行时 key
- 配置拉取和事件上报未验证
- 下一步需要 `ga_admin_*` 或真实 `ga_live_*`

## 1. 先问开发者要什么

只需要先问这几项：

```text
请确认当前游戏使用国内环境还是海外环境，并提供当前游戏的 Game Admin Key。
如果你还没有 Game Admin Key，请先登录 Admin 控制台，在游戏的 Keys 页面创建一个 ga_admin_*。
另外请告诉我当前游戏运行环境：iOS / Android / Web / Backend / TapTap Maker / TapTap 小游戏。
```

不要向开发者索要 `ga_live_*`。Client Game Key 由你通过 CLI 创建或读取。

例外：如果开发者已经明确提供真实 `ga_live_*`，可以直接使用；但仍然需要验证 `/v1/config` 和事件上报。不要把 `ga_live_xxx` 示例值当成真实 key。

## 2. 安装并登录 CLI

首次使用先从 npm 安装。后续更新也执行同一条命令，不需要拉取 GameAlgo Client 仓库：

```bash
npm install -g gamealgo-cli@latest
gamealgo help
```

根据开发者选择的环境使用对应 Admin host：

| 环境 | Admin host |
| --- | --- |
| 国内 | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_admin` |

然后使用 Game Admin Key 登录：

```bash
gamealgo login --host <admin-host> --admin-key ga_admin_xxx
```

如果在源码仓库内调试 CLI，并且命令需要 JSON 输出，使用：

```bash
npm --silent run cli -- <command>
```

## 3. 创建或读取 Client Game Key

Client Game Key 是游戏运行时 key，格式 `ga_live_*`。先检查当前游戏是否已有可用 key：

```bash
gamealgo key list --json
```

没有合适 key 时创建：

```bash
gamealgo key create --name production-client --json
```

已有 key 但需要写入 SDK 时读取明文：

```bash
gamealgo key reveal --name production-client --json
```

写入位置按运行环境决定：

| 环境 | Client Game Key 放哪里 |
| --- | --- |
| iOS / Android | App 配置、构建配置或安全的运行时配置位置 |
| Web / Backend / REST | 服务端环境变量或后端配置 |
| TapTap Maker / TapTap 小游戏 | Lua SDK 客户端配置 |

不要把 `ga_admin_*` 写入游戏客户端。不要把 key 打到日志、截图、崩溃上报或公开仓库。

不要把 `ga_live_xxx`、`TODO_GAME_KEY`、`NOOP_GAME_KEY` 之类占位值写入工程后继续后续验收。没有真实 `ga_live_*` 时，当前状态只能是 Scaffolded。

## 4. 判断接入方式

根据游戏工程选择 SDK：

| 场景 | 使用 |
| --- | --- |
| iOS 原生 | [iOS SDK](../ios/README.md) |
| Android 原生 | [Android SDK](../android/README.md) |
| Web / 后端 / 自定义运行时 | [REST helper](../rest-api/README.md) 或 [REST API](./rest-api-v1.md) |
| TapTap Maker / TapTap 小游戏 | [Lua SDK](../lua/README.md) |

通用接入原则见 [客户端接入指南](./integration-guide.md)。

## 5. 接入运行时配置

环境地址：

| 环境 | SDK / REST API | Admin / CLI |
| --- | --- | --- |
| 国内 | `https://game-algo-sdk.dictapis.cn` | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://gamealgo-server-v2.gamealgo-sdk-1ea5b9.workers.dev` | `https://dirichlet.ai/algo_admin` |

游戏运行时只配置 SDK / REST API 地址。Admin host 只给 CLI、控制台和 CI 使用。

初始化 SDK 时需要：

- `baseUrl` / `baseURL`
- `gameKey = ga_live_*`
- `appVersion`
- `platform`
- 可选 `userId`
- 可选 `device`

iOS 如需国家留存、国家 ROI 等看板，推荐用 `Locale.current.region` 获取 ISO 国家码并写入 `device.country`。

TapTap Maker / TapTap 小游戏优先使用平台稳定用户 ID：

```lua
local tapUserId = nil
if lobby and lobby.GetMyUserId then
    tapUserId = tostring(lobby:GetMyUserId())
end
```

如果拿不到稳定用户 ID，可以传 `nil`，SDK 会使用本地匿名 ID。不要使用昵称、头像、手机号、邮箱等可识别信息作为 `userId`。

## 6. 接入基础事件

先读 [AI Agent 埋点接入手册](./ai-tracking-manual.md)，按“所有游戏必接 + 条件接入 + 玩法补充”的顺序接入。不要一开始做过多自定义。

所有游戏都应该先保证：

```text
session_end
核心玩法开始事件：game_start 或 level_start
核心玩法结束事件：game_over 或 level_end
```

有广告或内购时继续接：

```text
ad_view
purchase
```

广告事件使用 `ad_view`，只在广告 SDK 确认实际产生收入的有效曝光时上报；用户看了一部分广告后跳过，但广告 SDK 已确认本次曝光有效并产生收入，也算有效曝光。`placement`、`adType`、`revenue`、`currency` 必填。

国内游戏、TapTap Maker / TapTap 小游戏的广告和付费事件默认使用：

```text
currency = CNY
```

如果游戏使用 Adjust 等归因 SDK，并且能从 SDK callback 拿到归因信息，推荐每次 callback 都调用 GameAlgo SDK 的 attribution API。GameAlgo SDK 会自己做 hash、ack 去重和失败后重试，开发者不需要维护重试状态。需要看投放 ROAS、花费、获客用户 LTV 或投放总览时，还要用 CLI 配置 Adjust API Token 和 App Token，并同步成本。

不同玩法的字段建议见 [不同类型游戏埋点建议](./tracking-recommendations.md)。如果游戏是章节 + 小关这类多层进度，报表先按粗粒度章节看，再对流失严重章节补小关分析。

## 7. 验证事件是否进平台

启动游戏，触发一批测试事件，等待 SDK flush 或手动 flush 后查询：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --json
```

只查某个事件：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --event-type level_end \
  --json
```

如果 `total` 为 0，按顺序排查：

1. SDK host 是否是运行时 host，不是 Admin host。
2. `ga_live_*` 是否写入正确位置。
3. 请求头是否是 `X-GameAlgo-Key`。
4. TapTap Maker 是否已配置 SDK 域名网络白名单。
5. 事件是否真的触发。
6. 是否调用了 flush，或等待了自动 flush。
7. Debug 包是否设置了 `isDebug=true`，查询口径是否包含 debug 数据。

这一步只验证事件链路。报表为空时，再查事件字段和 Report Pack。

如果还没有真实 `ga_live_*`，不要执行这一节并声称验证通过。需要先回到第 3 节创建或读取 Client Game Key。

## 8. 生成 Report Pack

事件进入平台后，再开发报表配置。不要让开发者手写复杂 JSON。

推荐步骤：

```bash
gamealgo report pull --out gamealgo-report-pack.json
gamealgo report validate gamealgo-report-pack.json
gamealgo report preview \
  --pack gamealgo-report-pack.json \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --timeout 60 \
  --out reports/preview.json
gamealgo report publish gamealgo-report-pack.json
```

Report Pack 结构和标准看板见 [Report Pack 配置](./report-packs.md)。

第一版建议至少覆盖：

- Overview：DAU、新用户、DAU 人均时长等核心指标
- Retention：新用户留存矩阵、留存趋势
- Revenue：广告收入、ARPU、LTV、广告位表现
- Progression：关卡/章节进度、胜率、最大进度分布

如果接入了 Adjust，并且需要投放 ROI 看板，可以配置投放成本同步：

```bash
gamealgo marketing adjust configure --api-token "$ADJUST_API_TOKEN" --app-token "$ADJUST_APP_TOKEN" --platform ios --currency CNY --json
gamealgo marketing adjust get --json
gamealgo marketing adjust sync --from 2026-06-01 --to 2026-06-07 --timeout 60 --json
```

`get --json` 返回的 `integration.callbackUrl` 是 Adjust Server Callback URL，Agent 可以把它配置到 Adjust Raw Data Export / Server Callback。Trigger 选择 `Install`，并建议额外配置一条 `Reattribution`；如果 Adjust UI 一次只能选一个 trigger，就两条 callback 都使用同一个 URL。不要选择 `Session`、普通 `Event` 或 `Ad revenue`。海外游戏按 Adjust 投放账户实际成本币种替换 `--currency`。

## 9. 接入实验、配置和脚本

如果游戏需要动态参数、动态脚本或 DDA：

```bash
gamealgo experiment integration-version create --title "关卡生成参数" --message "客户端已支持本轮实验参数" --json
gamealgo script publish scripts/level-generator.js --message "level script" --json
gamealgo experiment strategy publish strategy.yaml --yes
gamealgo experiment run create level_generator run.yaml --yes
gamealgo experiment run evaluate xrun_xxx --from 2026-07-01 --to 2026-07-07 --yes
gamealgo experiment run promote xrun_xxx --variant better_levels --yes
```

`strategy.yaml` 必须显式包含 `requiredIntegrationVersion`。没有客户端版本门槛时填写 `0`；需要新增参数、脚本输入或执行能力时，填写前一步创建并固化到客户端的版本号。

不要把 App 版本、Strategy 版本或脚本版本当成实验接入版本。详细的版本生命周期、兼容规则和托管实验覆盖率门槛见 [实验接入版本](./experiment-integration-versions.md)。

实验、配置和脚本的改动必须先让开发者看 Strategy / Run 配置。发布后再通过实验报告和日常报表观察结果。

如果要做关卡类动态难度调整，先读 [Level DDA framework](./dda-level-framework.md)。不要直接把具体规则写死成平台逻辑；游戏侧保留难度参数到玩法结果的映射，平台通过实验和数据优化参数组合。

## 10. 数据回收和优化闭环

接入和报表跑通后，按这个节奏持续迭代：

1. 用 `report manifest` 查看有哪些看板。
2. 用 `report result` 拉最近 7-14 天核心指标。
3. 找出影响 LTV 的问题：新用户留存、广告收入、关卡流失、模式渗透率、投放 ROI。
4. 提出一个小范围实验或配置改动。
5. 发布后回收数据，继续下一轮。

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

优化方法论见 [AI LTV 优化 Playbook](./ai-ltv-optimization-playbook.md)。

## 11. 最终交付给开发者

完成接入后，不要只说“已完成”。请给开发者一份简短交付说明：

- 改了哪些文件
- Client Game Key 写在哪里
- 接了哪些事件
- 如何验证事件已经进入平台
- 当前 Report Pack 覆盖哪些 tab 和看板
- 还有哪些风险或需要开发者确认的点

只有满足 Activated 状态时，才可以写“接入完成”。如果还缺真实 key、缺配置拉取验证或缺事件统计验证，必须写“Scaffolded，尚未激活”，并列出阻塞项。

开发者需要重点审核 key 的存放位置、事件字段语义、实验脚本逻辑和 Report Pack 指标口径。
