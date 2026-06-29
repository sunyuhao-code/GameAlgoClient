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

```bash
gamealgo login \
  --host https://game-algo-admin.dictapis.cn \
  --admin-key ga_admin_xxx
```

登录信息会写入本机 `~/.gamealgo/cli.json`，CLI 会把文件权限设置为 `600`。也可以通过环境变量临时传入：

```bash
GAMEALGO_ADMIN_HOST=https://game-algo-admin.dictapis.cn
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

拉取当前完整实验配置：

```bash
gamealgo experiment pull --out experiment.yaml
```

Agent 修改 `experiment.yaml` 后先看 diff：

```bash
gamealgo experiment diff experiment.yaml
```

发布会创建一个新的实验 commit，并立即生效：

```bash
gamealgo experiment publish experiment.yaml \
  --message "调整广告频率实验" \
  --yes
```

`publish` 和 `rollback` 会改线上状态。在 `--json`、CI 或非交互环境下也必须显式传 `--yes`，否则 CLI 会拒绝执行。

查看和回滚版本：

```bash
gamealgo experiment commits
gamealgo experiment rollback --commit exp_c_xxxxxxxxxxxxxxxx --message "回滚异常实验" --yes
```

如果 `latestCommitId` 不是当前线上 head，服务端会拒绝发布，避免多个 Agent 覆盖彼此的改动。

新游戏或从未通过 CLI/Admin 发布过实验版本时，`experiment pull` 可能返回空的 `latestCommitId`：

```yaml
latestCommitId:
```

这是正常的首次提交状态。Agent 保持这个字段为空或 `null`，执行 `experiment publish ... --yes` 时服务端会把它当成 `null` base；只要线上当前 head 也是空，就会创建第一个实验 commit。发布成功后再次 `experiment pull`，文件里会带上新的 `exp_c_...`。

## 脚本和配置

```bash
gamealgo script list
gamealgo script pull --all --out scripts/
gamealgo script publish scripts/level-generator.js

gamealgo config list
gamealgo config pull gameplay.json --out configs/
gamealgo config publish configs/gameplay.json
```

`script` 会按 `.js` / `.lua` 后缀识别脚本文件，其他文件走 `config`。
`pull --all` 落盘前会校验服务端返回的文件名，避免路径穿越。`publish --name` 只能和单个文件一起使用；发布 `.json` 配置时 CLI 会先在本地校验 JSON。

## Report Pack

```bash
gamealgo report pull --out gamealgo-report-pack-v1.json
gamealgo report validate gamealgo-report-pack-v1.json
gamealgo report publish gamealgo-report-pack-v1.json
```

`report validate` 和 Admin 控制台保存时使用同一套服务端校验逻辑。

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
  --pack gamealgo-report-pack-v1.json \
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

`preview` 使用本地 pack 内容，但 selector、group 和 chart 查找仍然走服务端规范化后的 dashboard model，不是直接按原始 JSON 查找。

常用参数：

- `--version <version>`：指定 Report Pack 版本，默认使用 active 版本。
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
