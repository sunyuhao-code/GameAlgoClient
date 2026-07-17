# GameAlgo 客户端接入指南

这份文档描述游戏团队接入 GameAlgo 的最小路径。

## 1. 先区分两种 key

GameAlgo 有两类 key，名字接近但用途完全不同。接入时不要混用。

| Key | 示例 | 谁使用 | 放在哪里 | 主要用途 |
| --- | --- | --- | --- | --- |
| Client Game Key | `ga_live_*` | 游戏客户端 SDK / REST API | 游戏客户端 SDK 配置 | 拉取配置、拉取配置文件、上报事件 |
| Game Admin Key | `ga_admin_*` | 开发者、AI Agent、CI、CLI | 开发机器、CI Secret、Agent Secret | 管理实验、脚本、配置、Report Pack，拉取报表和事件统计 |

Client Game Key 是运行时 key。游戏启动后，SDK 会用它访问 SDK host 下的 `/v1/config`、`/v1/config-files/*` 和 `/v1/events/batch`，请求头是：

```http
X-GameAlgo-Key: ga_live_xxx
```

Game Admin Key 是管理 key。它只给 CLI/Admin 使用，不能放进客户端包，也不能用于 `/v1/*` 运行时接口。CLI 登录时会用它访问 Admin host，请求头是：

```http
X-GameAlgo-Game-Admin-Key: ga_admin_xxx
```

推荐接入流程是：开发者登录控制台后，只为当前游戏创建一个 Game Admin Key，然后把它提供给 AI Agent。Client Game Key 不需要开发者手工维护，Agent 会通过 CLI 创建、查看和吊销。

```bash
gamealgo key list --json
gamealgo key create --name tapmaker-client --json
gamealgo key reveal --name tapmaker-client --json
gamealgo key revoke --name tapmaker-client --yes --json
```

`key list` 返回名称、前缀和状态；`key create` 和 `key reveal` 会返回明文，用于写入 SDK 配置。Client Game Key 统一使用 `ga_live_*` 前缀；QA/测试环境如需区分，可以创建单独命名的 key，并通过 `isDebug=true` 标记测试配置请求和事件。`ga_admin_*` 只用于开发期自动化和控制台操作，不能打进游戏包。

如果当前没有真实 `ga_live_*`，AI Agent 必须使用 `ga_admin_*` 通过 CLI 创建或读取。不要把 `ga_live_xxx`、`TODO_GAME_KEY`、`NOOP_GAME_KEY` 等占位值提交到游戏工程后声称完成接入。没有真实 Client Game Key 时，只能标记为 Scaffolded，不能进入事件上报验收。

## 2. 环境地址

GameAlgo 目前有国内和海外两套环境：

| 环境 | SDK / REST API | Admin / CLI |
| --- | --- | --- |
| 国内 | `https://game-algo-sdk.dictapis.cn` | `https://game-algo-admin.dictapis.cn` |
| 海外 | `https://dirichlet.ai/algo_sdk` | `https://dirichlet.ai/algo_admin` |

客户端 SDK 的 `baseURL` / `baseUrl` 配置为 SDK host；CLI 和浏览器控制台使用 Admin host。不要把 Admin host 配到游戏客户端里。

海外 SDK 地址包含 `/algo_sdk` 路径前缀，必须完整保留。iOS SDK 和 REST helper 会在该前缀后追加 `/v1/*`；不要自行用会把 `/v1/*` 解析到域名根路径的相对 URL 逻辑替换 SDK 请求实现。

## 3. 选择接入方式

- iOS SDK：使用 `../ios/`。
- Android SDK：使用 `../android/`。
- REST API：无法使用原生 SDK 时使用 `../rest-api/`。
- TapTap Maker / TapTap 小游戏：使用 `../lua/`。

TapTap Maker / TapTap 小游戏使用 Lua SDK 从客户端直接访问国内 SDK host。把 `game-algo-sdk.dictapis.cn` 加入 Maker 网络白名单，并在 `GameAlgo.Init` 中配置真实 Client Game Key；不需要开启多人模式或部署 GameAlgo 服务端代理。

所有接入方式都调用同一套 `/v1/*` 接口，并在每个请求中发送 `X-GameAlgo-Key`。

## 4. 运行时要求

- 在启动时，或依赖远端配置的玩法开始前，拉取 `/v1/config`。
- 默认使用 SDK 生成的匿名 `userId`。该 ID 需要持久化到本地，让老玩家在多次启动和版本更新后保持稳定实验分组。Android core 和 REST helper 需要配置 `cacheStorage` / `storage` 才能持久化这个 ID。
- TapTap Maker / TapTap 小游戏优先使用 Maker 环境提供的稳定用户 ID，例如 `lobby:GetMyUserId()`，并传给 Lua SDK 的 `GameAlgo.Init({ userId = tapUserId })`。拿不到时再使用 SDK 本地匿名 ID；不要使用昵称、头像、手机号等可识别信息作为 `userId`。
- 按 `ttlSeconds` 缓存配置。
- 按 hash 或 `ETag` 缓存配置文件。
- 需要时可以手动拉取 GameAlgo 控制台 Configs 页面里的文件：
  - iOS: `try await sdk.fetchConfigFile("gameplay.json")`
  - Android: `sdk.fetchConfigFile("gameplay.json")`
  - REST: `await client.fetchConfigFile("gameplay.json")`
- 事件上报优先使用 SDK tracker。tracker 会内存批量队列、周期 flush，并重试失败批次。
- 实验分组保存在配置拉取时创建的 SDK context 中，事件里不需要复制实验字段。
- 发布 Strategy 时必须显式提交 `requiredIntegrationVersion`。不依赖客户端新增实验能力时填写 `0`；否则先由 AI Agent 创建能力版本，把返回的整数固定到 SDK 初始化参数 `experimentIntegrationVersion`，再让 Strategy 引用该版本。低于最低版本的客户端不会收到这个 Strategy，必须继续使用游戏本地默认逻辑。完整语义、升级判断和托管实验覆盖率门槛见 [实验接入版本](./experiment-integration-versions.md)。
- 如果接入 Adjust 等归因 SDK，归因结果异步返回后调用 SDK 的 `setAttribution` / REST helper。开发者可以每次 callback 都调用；同一份归因成功 ack 后 SDK 会跳过重复上报，归因变化或上次失败时会重试。直调 `/v1/attribution` 时才需要调用方自己处理 ack 去重。
- 不要让 GameAlgo 网络请求阻塞游戏主流程。
- GameAlgo 不可用时走本地默认逻辑。

## 5. 推荐事件

更完整的 AI 接入清单见 [AI Agent 埋点接入手册](./ai-tracking-manual.md)。

所有游戏最小推荐接入：

```text
session_end
核心玩法开始事件：game_start 或 level_start
核心玩法结束事件：game_over 或 level_end
```

有广告或内购的游戏还应上报：

```text
ad_view
purchase
```

内购使用 `trackPurchase`，有条件时传入 `productId`、`revenue` 和 `currency`。事件类型为 `purchase`。

国内游戏、TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

归因信息不是普通事件。开发者如果使用 Adjust，可以让 AI Agent 在 Adjust attribution callback 里调用：

- iOS: `try await sdk.setAttribution(GameAlgoUserAttribution(provider: "adjust", attribution: [...]))`
- Android: `sdk.setAttribution("adjust", attributionMap)`
- REST: `await client.setAttribution({ provider: "adjust", attribution })`

`attribution` 里只放渠道、campaign、adgroup、creative 等非敏感字段。不要上传手机号、邮箱、OAID、IDFA、TapID 等强身份字段。

GameAlgo 官方 SDK 会持久化归因 ack 状态。开发者不需要自己保存 `attributionHash` 或实现重试队列，只要在归因 SDK callback 里调用 `setAttribution`。

如果游戏启用 Adjust Server Callback，还需要在 Adjust SDK 初始化前调用 GameAlgo 的 callback 参数 helper：

- iOS: `sdk.configureAdjustServerCallbackParams { key, value in Adjust.addGlobalCallbackParameter(value, forKey: key) }`
- Android: `sdk.configureAdjustServerCallbackParams { key, value -> Adjust.addGlobalCallbackParameter(key, value) }`
- REST/Web: `await client.configureAdjustServerCallbackParams((key, value) => adjustSetCallbackParam(key, value))`

这里配置的是 Adjust global callback parameters。`gamealgo_user_id` / `gamealgo_user_created_at` 不是 Adjust 内置参数，也不是开发者自己生成的业务字段；GameAlgo SDK 会从本地 identity 里读取并写入 Adjust。这个调用要早于 Adjust SDK 首次上报，否则首次 install/session server callback 可能无法关联到 GameAlgo 用户。

Adjust Server Callback 的 trigger 选择 `Install`，并建议额外配置 `Reattribution`。如果 Adjust UI 一次只能选一个 trigger，就创建两条 callback，两个 trigger 都使用 GameAlgo CLI/Admin 返回的同一个 callback URL。不要选择 `Session`、普通 `Event` 或 `Ad revenue`；广告收入由 GameAlgo `ad_view` 上报。

如果需要看投放 ROAS、花费趋势、获客用户 LTV 或投放总览，AI Agent 还需要在 CLI/Admin 中配置 Adjust API Token 和 App Token，并执行一次成本同步；这些 token 不能写进客户端。

## 6. 接入测试时验证事件上报

接入测试时可以用 GameAlgo CLI 的事件统计命令确认事件是否已经进入数据表。这个命令使用游戏维度的 Game Admin Key，不使用客户端 Game Key。

首次使用先安装 CLI，然后登录；更新 CLI 时再次执行安装命令即可：

```bash
npm install -g gamealgo-cli@latest
gamealgo login \
  --host <admin-host> \
  --admin-key ga_admin_xxx
```

启动游戏并触发一批测试事件后，查询当天事件数：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --json
```

只验证某个事件类型：

```bash
gamealgo events count \
  --from 2026-06-23 \
  --to 2026-06-23 \
  --event-type level_end \
  --json
```

如果返回结果里的 `total` 增加，并且 `eventTypes` 中包含目标事件名，说明事件已经被服务端接收并进入平台事件明细。这个命令只验证上报链路是否成功；如果 Report Pack 看板仍然没有数据，需要继续检查事件字段、日期范围和报表配置。

事件上报可能有批量 flush 和数据同步延迟。测试时建议先停留几秒或手动触发 SDK flush，再等待数据链路同步后查询。

## 7. 验收清单

- 包内使用真实 `ga_live_*`，不是占位值。
- `ga_admin_*` 没有出现在客户端代码、资源文件、脚本包、日志或 git diff 中。
- 配置好的 key 能成功请求 `/v1/config`。
- 配置会缓存在本地。
- 配置文件可以成功拉取并缓存。
- 只要平台本地存储未被清空，重装/更新后 SDK 匿名 `userId` 能保持稳定。
- Debug 或 QA 包的配置请求和事件都设置 `isDebug=true`。
- 客户端运行时使用 `ga_live_*`；如需区分 QA/生产环境，使用不同名称的 Client Game Key。
- 临时网络失败后，事件会继续重试。
- 可以通过 `gamealgo events count` 查到测试事件。
- 如接入归因，每次归因 SDK callback 后能调用官方 SDK / REST helper 的 `setAttribution`，重复相同归因时 SDK 会跳过重复上报。
