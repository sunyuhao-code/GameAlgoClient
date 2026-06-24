# GameAlgo 客户端接入指南

这份文档描述游戏团队接入 GameAlgo 的最小路径。

## 1. 先区分两种 key

GameAlgo 有两类 key，名字接近但用途完全不同。接入时不要混用。

| Key | 示例 | 谁使用 | 放在哪里 | 主要用途 |
| --- | --- | --- | --- | --- |
| Client Game Key | `ga_test_*` / `ga_live_*` | 游戏客户端 SDK / REST API | 游戏客户端包或服务端代理里 | 拉取配置、拉取配置文件、上报事件 |
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
gamealgo key create --name tapmaker-proxy --json
gamealgo key reveal --name tapmaker-proxy --json
gamealgo key revoke --name tapmaker-proxy --yes --json
```

`key list` 返回名称、前缀和状态；`key create` 和 `key reveal` 会返回明文，用于写入 SDK 或 TapTap Maker 服务端 Proxy 配置。QA 包使用 `ga_test_*`，生产包使用 `ga_live_*`。`ga_admin_*` 只用于开发期自动化和控制台操作，不能打进游戏包。

## 2. 国内环境地址

国内接入使用下面两个 host：

| 用途 | Host | 说明 |
| --- | --- | --- |
| SDK / REST API | `https://game-algo-sdk.dictapis.cn` | 游戏运行时访问 `/v1/config`、`/v1/config-files/*`、`/v1/events/batch` |
| Admin / CLI | `https://game-algo-admin.dictapis.cn` | 开发者控制台和 `gamealgo login --host` 使用 |

客户端 SDK 的 `baseURL` / `baseUrl` 配置为 SDK host；CLI 和浏览器控制台使用 Admin host。不要把 Admin host 配到游戏客户端里。

## 3. 选择接入方式

- iOS SDK：使用 `../ios/`。
- Android SDK：使用 `../android/`。
- REST API：无法使用原生 SDK 时使用 `../rest-api/`。

所有接入方式都调用同一套 `/v1/*` 接口，并在每个请求中发送 `X-GameAlgo-Key`。

## 4. 运行时要求

- 在启动时，或依赖远端配置的玩法开始前，拉取 `/v1/config`。
- 默认使用 SDK 生成的匿名 `userId`。该 ID 需要持久化到本地，让老玩家在多次启动和版本更新后保持稳定实验分组。Android core 和 REST helper 需要配置 `cacheStorage` / `storage` 才能持久化这个 ID。
- 按 `ttlSeconds` 缓存配置。
- 按 hash 或 `ETag` 缓存配置文件。
- 需要时可以手动拉取 GameAlgo 控制台 Configs 页面里的文件：
  - iOS: `try await sdk.fetchConfigFile("gameplay.json")`
  - Android: `sdk.fetchConfigFile("gameplay.json")`
  - REST: `await client.fetchConfigFile("gameplay.json")`
- 事件上报优先使用 SDK tracker。tracker 会内存批量队列、周期 flush，并重试失败批次。
- 实验分组保存在配置拉取时创建的 SDK context 中，事件里不需要复制实验字段。
- 不要让 GameAlgo 网络请求阻塞游戏主流程。
- GameAlgo 不可用时走本地默认逻辑。

## 5. 推荐事件

最小推荐事件：

```text
session_end
level_start
level_end
```

有广告或内购的游戏还应上报：

```text
ad_view
purchase
```

内购使用 `trackPurchase`，有条件时传入 `productId`、`revenue` 和 `currency`。事件类型为 `purchase`。

国内游戏、TapTap Maker / TapTap 小游戏接入时，广告和付费事件的 `currency` 统一使用 `CNY`。不要默认使用 `USD`。

## 6. 接入测试时验证事件上报

接入测试时可以用 GameAlgo CLI 的事件统计命令确认事件是否已经进入数据表。这个命令使用游戏维度的 Game Admin Key，不使用客户端 Game Key。

先登录 CLI：

```bash
gamealgo login \
  --host https://game-algo-admin.dictapis.cn \
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

- 包内使用正确的 `gameKey`。
- 配置好的 key 能成功请求 `/v1/config`。
- 配置会缓存在本地。
- 配置文件可以成功拉取并缓存。
- 只要平台本地存储未被清空，重装/更新后 SDK 匿名 `userId` 能保持稳定。
- Debug 或 QA 事件设置 `isDebug=true`。
- 生产包使用 `ga_live_*`。
- 临时网络失败后，事件会继续重试。
- 可以通过 `gamealgo events count` 查到测试事件。
