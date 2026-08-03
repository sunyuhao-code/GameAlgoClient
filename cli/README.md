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
npm install -g gamealgo-cli@latest
gamealgo help
gamealgo --version
```

更新 CLI 使用同一条命令：

```bash
npm install -g gamealgo-cli@latest
```

安装和更新不需要拉取 GameAlgo Client 仓库。Node.js 版本需要为 24 或更高。

Client SDK 源码仓库：<https://github.com/sunyuhao-code/GameAlgoClient>

只有开发 CLI 本身时才需要源码仓库。源码内调试可以用 npm script，但涉及 `--json` 的命令必须加 `--silent`，避免 npm 自己的日志污染 JSON stdout：

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

请在游戏项目根目录执行登录。登录信息会写入当前目录的 `.gamealgo/cli.json`，CLI 会把文件权限设置为 `600`，并自动忽略整个 `.gamealgo/` 目录，避免密钥被提交到 Git。后续命令会从当前目录逐级向上查找该文件，因此可以在项目子目录执行；不同游戏仓库的登录信息互不覆盖。

旧版的 `~/.gamealgo/cli.json` 仍可作为未找到项目级配置时的兜底。也可以通过环境变量临时传入：

```bash
GAMEALGO_ADMIN_HOST=<admin-host>
GAMEALGO_GAME_ADMIN_KEY=ga_admin_xxx
```

检查当前身份：

```bash
gamealgo whoami
```

## 最新文档

AI Agent 可以通过 CLI 从 Admin Host 获取最新文档，不需要拉取本仓库：

```bash
gamealgo docs --host <admin-host>
gamealgo docs agent-onboarding --host <admin-host>
gamealgo docs report-packs --json
gamealgo docs --open
```

登录后可以省略 `--host`。CLI 会把已读取的文档缓存到 `~/.gamealgo/docs/`，网络不可用时自动回退到缓存。

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

版本升级判断、Strategy 最低版本和托管实验覆盖率门槛的完整说明可通过 `gamealgo docs experiment-integration-versions` 获取。

创建手动实验 Run：

```yaml
# run.yaml
displayName: 广告频率第一轮
type: manual
platform: ios
objectiveTemplate: ltv_proxy@1
baselineVariantId: control
variants:
  - variantId: control
    weight: 1
    config:
      firstAdLevel: 4
      interval: 30
    script:
      versionId: sv_xxxxxxxxxxxxxxxx
  - variantId: slower_ads
    weight: 1
    config:
      firstAdLevel: 5
      interval: 45
    script:
      versionId: sv_xxxxxxxxxxxxxxxx
```

```bash
gamealgo experiment run create ad_frequency run.yaml --yes
```

Run 不会继承 Strategy 的脚本。每个需要执行脚本的 variant 都必须显式配置 `script.versionId`；省略 `script` 明确表示该组是 config-only。即使多个 variant 使用同一份脚本，也要在每个 variant 上重复填写同一个不可变 `versionId`。

如果要把当前默认参数也放进实验，需要显式配置 `variantId: default`。`default` 会快照 Strategy 当前默认参数，因此不能写 `config`；如果默认组需要执行脚本，也必须在 `default` 上显式写 `script.versionId`。否则默认参数不参与流量。所有有流量的实验组数量必须至少为 2。

查看、评估和完成实验闭环：

```bash
gamealgo experiment strategies
gamealgo experiment strategy show ad_frequency
gamealgo experiment run show xrun_xxxxxxxxxxxxxxxx
gamealgo experiment run status xrun_xxxxxxxxxxxxxxxx
gamealgo experiment run evaluate xrun_xxxxxxxxxxxxxxxx --from 2026-07-01 --to 2026-07-07 --yes
gamealgo experiment run report xrun_xxxxxxxxxxxxxxxx
gamealgo experiment run promote xrun_xxxxxxxxxxxxxxxx --variant slower_ads --message "采用低频广告组" --yes
```

`baselineVariantId` 是本次评估的对照组，必须指向一个有流量的实验组。平台按小时更新“当前评估”；`report` 返回已生成的正式报告。`promote` 会把指定 variant 写回 Strategy 默认参数，并结束当前 Run。取消实验用：

`objectiveTemplate` 必须显式选择，并在 Run 创建后保持不变：

- `ltv_proxy@1`：优化标准化累计用户价值。
- `active_days@1`：优化用户活跃天数，口径为 `1 + D1 回访率 + ... + Dk 回访率`。D0 记为 1 个活跃日，每个 Dx 只使用已经成熟到该天的实验进入用户，未回访用户按 0 计入。

```bash
gamealgo experiment run cancel xrun_xxxxxxxxxxxxxxxx --message "实验停止" --yes
```

回滚默认参数会创建一个新的参数版本，不会改写历史版本：

```bash
gamealgo experiment strategy rollback ad_frequency --version-id xv_xxxxxxxxxxxxxxxx --message "回滚线上参数" --yes
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
objectiveTemplate: ltv_proxy@1
baselineVariantId: alpha
minWindowDays: 7
maxWindowDays: 14
maxVariantsPerRound: 3
# 可选：仅托管实验支持。最近 24 小时同时满足两个门槛后才开始首轮。
startCondition:
  minCoverage: 0.8
  minUsers: 100
variants:
  - variantId: alpha
    config: { firstAdLevel: 4, interval: 30 }
    script: { versionId: sv_xxxxxxxxxxxxxxxx }
  - variantId: bravo
    config: { firstAdLevel: 5, interval: 30 }
    script: { versionId: sv_xxxxxxxxxxxxxxxx }
  - variantId: charlie
    config: { firstAdLevel: 4, interval: 45 }
    script: { versionId: sv_xxxxxxxxxxxxxxxx }
```

`minCoverage` 表示指定平台最近 24 小时内，实验接入版本达到 Strategy `requiredIntegrationVersion` 的去重用户占比；`minUsers` 表示同一窗口内的非 Debug 去重用户数。两项可单独配置，同时配置时必须同时满足。等待期间 Strategy 继续下发默认参数，满足门槛后平台才生成首轮时间窗并开始分流。手动实验不支持 `startCondition`，托管实验不配置时仍会立即启动。`experiment run show` 返回 `startConditionSnapshot`，可查看当前用户数、覆盖率和最近检查时间。

托管实验只执行候选组数量决定的计划轮次，不会自动增加复赛轮次。每轮至少运行 `minWindowDays` 天；达到参考周期后若证据仍不明确，平台逐日延长，最长运行到 `maxWindowDays`。`minWindowDays` 支持 1～30 天，`maxWindowDays` 支持到 60 天且不能小于参考周期。达到最长周期仍无明确胜出组时结束本轮，Strategy 默认参数保持不变。

`ltv_proxy@1` 的标准口径为：

```text
LTV Proxy (Dk) = STANDARDIZED_DAY_VALUE_D0 + ... + STANDARDIZED_DAY_VALUE_Dk
```

`STANDARDIZED_DAY_VALUE_Dx` 使用所有在 Dx 已成熟的实验进入用户作为分母，未回访用户当日价值按 0 计入。广告曝光按广告类型和用户本地日内曝光序号分桶，每个桶使用本轮所有参与组在实验窗口内共同计算的参考 CPM，再加实际内购收入。

所有实验组使用同一个 `k`。平台按参考周期固定 `k 上限 = min(14, minWindowDays - 3)`，再选择不超过上限、且每个参与组都至少有 10 个成熟进入用户的最大连续 Dx。延长只增加样本，不改变评分口径。平台用本轮真实用户和线上 MurmurHash 分流规则模拟大量随机 seed，估计当前游戏用户结构下的自然组间波动，并校正多实验组与逐日重复评估。实际收入、实际 ARPU、新用户留存和新用户 LTV 只作为诊断指标，不参与主指标计算。

`active_days@1` 使用相同的共同成熟 `k`、随机化检验和正式胜出规则，收入和 LTV 指标仍作为诊断数据展示，但不参与主指标排序。

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
