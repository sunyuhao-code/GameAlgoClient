# GameAlgo CLI

GameAlgo CLI 是给游戏开发 Agent 使用的自动化工具。它不运行在游戏客户端里，而是在开发环境、CI 或 AI Agent 工作目录里调用 GameAlgo Admin API。

CLI 使用游戏维度的 Game Admin Key 鉴权。这个 key 只绑定一个游戏，所以命令不需要 `--game`。

注意区分两类 key：

- `ga_live_*` 是 Client Game Key，只给游戏客户端 SDK 或 REST API 使用，用来拉配置和上报事件。
- `ga_admin_*` 是 Game Admin Key，只给 CLI、开发者 Agent 或 CI 使用，用来管理实验、脚本、配置、Report Pack，并读取报表和事件统计。

不要把 `ga_admin_*` 放进客户端包，也不要用 `ga_live_*` 执行 CLI 命令。

## 安装与运行

推荐安装后直接使用 `gamealgo` 命令：

```bash
gamealgo help
```

在源码仓库内调试时可以用 npm script，但涉及 `--json` 的命令必须加 `--silent`，避免 npm 自己的日志污染 JSON stdout：

```bash
npm install
npm --silent run cli -- help
npm --silent run cli -- report manifest --json
```

## 登录

平台管理员会给每个游戏生成一个 Game Admin Key。

Admin host 按环境选择：

| 环境 | Admin host |
| --- | --- |
| 国内 | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_admin` |

```bash
gamealgo login \
  --host <admin-host> \
  --admin-key ga_admin_xxx
```

登录信息会写入本机 `~/.gamealgo/cli.json`，CLI 会把文件权限设置为 `600`。也可以通过环境变量临时传入：

```bash
GAMEALGO_ADMIN_HOST=<admin-host>
GAMEALGO_GAME_ADMIN_KEY=ga_admin_xxx
```

检查当前身份：

```bash
gamealgo whoami
```

## Client Game Key

Agent 可以用 Game Admin Key 管理当前游戏的 Client Game Key。`key list` 只返回名称、前缀和状态，不返回明文：

```bash
gamealgo key list --json
```

创建给 SDK 或 TapTap Maker 服务端 Proxy 使用的 key：

```bash
gamealgo key create --name tapmaker-proxy --json
```

如果同名 active key 已存在，`create` 会复用已有 key 并返回它的明文；如果需要单独查看明文，用：

```bash
gamealgo key reveal --name tapmaker-proxy --json
```

吊销 key 必须显式确认：

```bash
gamealgo key revoke --name tapmaker-proxy --yes
```

## 实验闭环

新实验系统围绕 `Strategy` 和 `Run` 两层设计：

- `Strategy` 是游戏代码读取的稳定策略 key，包含默认参数和可选脚本版本。
- `Run` 是一次实验闭环，绑定某个 Strategy，包含实验组、流量、平台、目标和实验报表。

先为当前客户端支持的实验能力创建一个游戏级版本。版本号由服务端自增，写入客户端初始化代码，并由 Strategy 的 `requiredIntegrationVersion` 引用：

```bash
gamealgo experiment integration-version latest --json
gamealgo experiment integration-version create \
  --title "广告频率参数" \
  --message "客户端已支持 firstAdLevel 和 interval" \
  --json
gamealgo experiment integration-version get --version 3 --json
```

`title` 创建后不可修改；`message` 可以用 `integration-version update --version 3 --message "..."` 补充，服务端会保留修订记录。不要在运行时查询 latest 后上报，必须把创建后返回的 `version` 固定到对应 App 构建中。新增客户端能力时创建新版本，不要扩充已经被线上客户端观测到的旧版本语义。

如果实验依赖脚本，先发布不可变脚本版本，记录返回的 `scriptVersion.versionId`：

```bash
gamealgo script publish scripts/ad-frequency.lua \
  --message "广告频率实验脚本" \
  --json
```

创建或更新 Strategy：

```yaml
# strategy.yaml
strategyKey: ad_frequency
displayName: 广告频率
requiredIntegrationVersion: 3
defaultConfig:
  firstAdLevel: 4
  interval: 30
script:
  versionId: sv_xxxxxxxxxxxxxxxx
message: 初始化广告频率策略
```

```bash
gamealgo experiment strategy publish strategy.yaml --yes
```

每次发布 Strategy 都必须显式填写 `requiredIntegrationVersion`。填写 `0` 表示该 Strategy 不依赖任何客户端实验能力版本；填写大于 `0` 的值时，必须引用已经通过 `integration-version create` 创建、且客户端确实已经实现的版本。Run 会继承 Strategy 的最低版本，不需要重复配置。

版本升级判断、旧客户端行为和托管实验覆盖率门槛的完整说明见 [实验接入版本](../docs/experiment-integration-versions.md)。

创建手动实验 Run：

```yaml
# run.yaml
displayName: 广告频率第一轮
type: manual
platform: ios
objective: ltv_proxy
variants:
  - variantId: control
    weight: 1
    config:
      firstAdLevel: 4
      interval: 30
  - variantId: slower_ads
    weight: 1
    config:
      firstAdLevel: 5
      interval: 45
```

```bash
gamealgo experiment run create ad_frequency run.yaml --yes
```

如果要把当前默认参数也放进实验，需要显式配置 `variantId: default`；否则默认参数不参与流量。所有有流量的实验组数量必须至少为 2。

查看、评估和完成实验闭环：

```bash
gamealgo experiment strategies
gamealgo experiment strategy show ad_frequency
gamealgo experiment run show xrun_xxxxxxxxxxxxxxxx
gamealgo experiment run evaluate xrun_xxxxxxxxxxxxxxxx --from 2026-07-01 --to 2026-07-07 --yes
gamealgo experiment run report xrun_xxxxxxxxxxxxxxxx
gamealgo experiment run promote xrun_xxxxxxxxxxxxxxxx --variant slower_ads --yes
```

`promote` 会把胜出的 variant 写回 Strategy 默认参数，并结束当前 Run。取消实验用：

```bash
gamealgo experiment run cancel xrun_xxxxxxxxxxxxxxxx --yes
```

调试指定用户/设备强制进某个实验组：

```bash
gamealgo experiment override set xrun_xxxxxxxxxxxxxxxx --user user-1 --variant slower_ads --yes
gamealgo experiment override list xrun_xxxxxxxxxxxxxxxx
gamealgo experiment override delete xrun_xxxxxxxxxxxxxxxx --user user-1 --yes
```

托管实验也是创建 `type: managed` 的 Run，平台会按轮次自动调整流量并最终推全胜出组：

```yaml
displayName: 广告频率托管实验
type: managed
platform: ios
objective: ltv_proxy
cycleDays: 7
maxVariantsPerRound: 3
# 可选：仅托管实验支持。最近 24 小时同时满足两个门槛后才开始首轮。
startCondition:
  minCoverage: 0.8
  minUsers: 100
variants:
  - variantId: alpha
    config: { firstAdLevel: 4, interval: 30 }
  - variantId: bravo
    config: { firstAdLevel: 5, interval: 30 }
  - variantId: charlie
    config: { firstAdLevel: 4, interval: 45 }
```

`minCoverage` 表示指定平台最近 24 小时内，实验接入版本达到 Strategy `requiredIntegrationVersion` 的去重用户占比；`minUsers` 表示同一窗口内的非 Debug 去重用户数。两项可单独配置，同时配置时必须同时满足。等待期间 Strategy 继续下发默认参数，满足门槛后平台才生成首轮时间窗并开始分流。手动实验不支持 `startCondition`，托管实验不配置时仍会立即启动。`experiment run show` 返回 `startConditionSnapshot`，可查看当前用户数、覆盖率和最近检查时间。

所有会修改线上状态的实验命令都必须显式传 `--yes`。

## 脚本和配置

```bash
gamealgo script list
gamealgo script versions level-generator.js
gamealgo script pull --all --out scripts/
gamealgo script publish scripts/level-generator.js

gamealgo config list
gamealgo config pull gameplay.json --out configs/
gamealgo config publish configs/gameplay.json
```

`script publish` 会创建不可变脚本版本并返回 `scriptVersion.versionId`；v2 实验只能引用 `script.versionId`，不要引用脚本文件名。`script` 会按 `.js` / `.lua` 后缀识别脚本文件，其他文件走 `config`。
`pull --all` 落盘前会校验服务端返回的文件名，避免路径穿越。`publish --name` 只能和单个文件一起使用；发布 `.json` 配置时 CLI 会先在本地校验 JSON。

## Report Pack

```bash
gamealgo report pull --out gamealgo-report-pack.json
gamealgo report validate gamealgo-report-pack.json
gamealgo report publish gamealgo-report-pack.json
```

每个游戏只有一个当前 Report Pack。`publish` 会整体覆盖上一次提交的配置，不需要传版本号；配置历史由游戏项目自己的 Git 管理。

`report validate` 和 Admin 控制台保存时使用同一套服务端校验逻辑。

## Adjust 投放花费

如果游戏接入了 Adjust 归因，并希望在 GameAlgo 里看 ROAS、投放花费和获客用户 LTV，Agent 可以用 Game Admin Key 配置当前游戏的 Adjust App Token 和 API Token：

```bash
gamealgo marketing adjust configure \
  --api-token "$ADJUST_API_TOKEN" \
  --app-token "$ADJUST_APP_TOKEN" \
  --platform ios \
  --currency USD \
  --json
```

查看配置状态不会返回 API Token 明文，只会返回是否已配置：

```bash
gamealgo marketing adjust get --json
```

手动同步某个日期区间的花费：

```bash
gamealgo marketing adjust sync \
  --from 2026-06-01 \
  --to 2026-06-07 \
  --timeout 60 \
  --json
```

花费使用 Adjust 报表里的 `network_cost` 字段，并按 campaign / country 粒度写入平台。Report Pack 里引用 `marketing.overview@1` 和 `marketing.roi@1` 即可使用标准投放总览和 ROAS 看板。

## 回收报表结果

Agent 应先拉 manifest，了解有哪些 tab、group、chart 和 selector：

```bash
gamealgo report manifest --json
```

拉取某个 group 或 chart 的结构化结果：

```bash
gamealgo report result \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --tab Revenue \
  --group "Daily ARPU" \
  --selector experiment=ad_frequency \
  --selector mode=normal \
  --timeout 60 \
  --out reports/daily-arpu.json
```

本地修改 Report Pack 后，可以先用 `preview` 直接跑查询结果，不需要发布到线上：

```bash
gamealgo report manifest --json

gamealgo report preview \
  --pack gamealgo-report-pack.json \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --tab-id levels \
  --group-id max_levels \
  --chart-id max_levels__max_level_distribution \
  --timeout 60 \
  --out reports/max-level-distribution-preview.json
```

`preview` 会把本地 pack 发到服务端，用和线上查询相同的校验、SQL 生成和执行逻辑跑一次，但不会保存 pack，也不会写入正式报表缓存。

注意 chart id 会被服务端 manifest 规范化。Report Pack 原始 JSON 里可以写裸 id，例如 `max_level_distribution`；manifest 返回的查询 id 会带上 group 前缀，例如 `max_levels__max_level_distribution`。`--chart-id` 优先使用 manifest 返回的规范化 id。如果不确定，先跑 `gamealgo report manifest --json`，或者使用 `--chart "Max Level Distribution"` 按标题查询。为了方便本地调试，已经指定 `--group-id max_levels` 时，也可以用裸 chart id：`--chart-id max_level_distribution`。

`preview` 使用本地 pack 内容，但 selector、group 和 chart 查找仍然走服务端规范化后的看板结构，不是直接按原始 JSON 查找。

常用参数：

- `--tab <title>` / `--tab-id <id>`：选择 tab。
- `--group <title>` / `--group-id <id>`：选择 group。
- `--chart <title>` / `--chart-id <id>`：选择单个 chart。`--chart-id` 建议使用 manifest 返回的规范化 id。
- `--selector key=value`：传入 group selector，可重复。
- `--refresh`：绕过服务端缓存，重新计算并刷新缓存。
- `--timeout <seconds>` / `--timeout-ms <ms>`：限制 HTTP 查询最长等待时间。
- `--out <file>`：把 JSON 结果写入文件。
- `report preview --pack <file>`：指定本地 Report Pack 文件，适合发布前调试。

查询进度和耗时会输出到 stderr，不会污染 `--json` 的 stdout。返回结果包含 `columns`、`rows`、`rowCount`、chart 元信息、date range、selector、缓存信息和 `cli.elapsedMs`，适合 Agent 直接分析。

## 事件上报调试

接入 SDK 后，Agent 可以用 `events count` 检查某天事件是否已经进入原始事件表：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --timeout 60 \
  --json
```

只看某个事件类型：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --event-type level_end \
  --json
```

这个命令只按当前 Game Admin Key 绑定的游戏查询固定事件计数 SQL，不接受自定义 SQL，也不依赖 Report Pack 或标准中间表。未传 `--from/--to` 时默认查询当天；只传一边时会把另一边补成同一天。结果里的 `total` 是总事件数，`eventTypes` 是按事件名聚合的数量。
