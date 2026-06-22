# GameAlgo CLI

GameAlgo CLI 是给游戏开发 Agent 使用的自动化工具。它不运行在游戏客户端里，而是在开发环境、CI 或 AI Agent 工作目录里调用 GameAlgo Admin API。

CLI 使用游戏维度的 Game Admin Key 鉴权。这个 key 只绑定一个游戏，所以命令不需要 `--game`。

## 安装与运行

在当前客户端仓库里运行：

```bash
npm install
npm run cli -- help
```

后续如果发布成 npm 包，可以使用：

```bash
npx @gamealgo/cli help
```

## 登录

平台管理员会给每个游戏生成一个 Game Admin Key。

```bash
npm run cli -- login \
  --host https://game-algo-admin.example.com \
  --admin-key ga_admin_xxx
```

登录信息会写入本机 `~/.gamealgo/cli.json`。也可以通过环境变量临时传入：

```bash
GAMEALGO_ADMIN_HOST=https://game-algo-admin.example.com
GAMEALGO_GAME_ADMIN_KEY=ga_admin_xxx
```

检查当前身份：

```bash
npm run cli -- whoami
```

## 实验闭环

拉取当前完整实验配置：

```bash
npm run cli -- experiment pull --out experiment.yaml
```

Agent 修改 `experiment.yaml` 后先看 diff：

```bash
npm run cli -- experiment diff experiment.yaml
```

发布会创建一个新的实验 commit，并立即生效：

```bash
npm run cli -- experiment publish experiment.yaml \
  --message "调整广告频率实验" \
  --yes
```

查看和回滚版本：

```bash
npm run cli -- experiment commits
npm run cli -- experiment rollback --commit exp_c_xxxxxxxxxxxxxxxx --message "回滚异常实验" --yes
```

如果 `latestCommitId` 不是当前线上 head，服务端会拒绝发布，避免多个 Agent 覆盖彼此的改动。

## 脚本和配置

```bash
npm run cli -- script list
npm run cli -- script pull --all --out scripts/
npm run cli -- script publish scripts/level-generator.js

npm run cli -- config list
npm run cli -- config pull gameplay.json --out configs/
npm run cli -- config publish configs/gameplay.json
```

`script` 会按 `.js` / `.lua` 后缀识别脚本文件，其他文件走 `config`。

## Report Pack

```bash
npm run cli -- report pull --out gamealgo-report-pack-v1.json
npm run cli -- report validate gamealgo-report-pack-v1.json
npm run cli -- report publish gamealgo-report-pack-v1.json
```

`report validate` 和 Admin 控制台保存时使用同一套服务端校验逻辑。

## 回收报表结果

Agent 应先拉 manifest，了解有哪些 tab、group、chart 和 selector：

```bash
npm run cli -- report manifest --json
```

拉取某个 group 或 chart 的结构化结果：

```bash
npm run cli -- report result \
  --from 2026-06-14 \
  --to 2026-06-21 \
  --tab Revenue \
  --group "Daily ARPU" \
  --selector experiment=ad_frequency \
  --selector mode=normal \
  --out reports/daily-arpu.json
```

常用参数：

- `--version <version>`：指定 Report Pack 版本，默认使用 active 版本。
- `--tab <title>` / `--tab-id <id>`：选择 tab。
- `--group <title>` / `--group-id <id>`：选择 group。
- `--chart <title>` / `--chart-id <id>`：选择单个 chart。
- `--selector key=value`：传入 group selector，可重复。
- `--refresh`：绕过服务端缓存，重新计算并刷新缓存。
- `--out <file>`：把 JSON 结果写入文件。

返回结果包含 `columns`、`rows`、`rowCount`、chart 元信息、date range、selector 和缓存信息，适合 Agent 直接分析。
