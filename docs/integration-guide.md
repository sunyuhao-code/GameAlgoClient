# GameAlgo 客户端接入指南

这份文档描述游戏团队接入 GameAlgo 的最小路径。

## 1. 获取 Game Key

GameAlgo 平台会为每个游戏环境提供一个 key：

```text
ga_test_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ga_live_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

QA 包使用 `ga_test_*`，生产包使用 `ga_live_*`。

## 2. 选择接入方式

- iOS SDK：使用 `../ios/`。
- Android SDK：使用 `../android/`。
- REST API：无法使用原生 SDK 时使用 `../rest-api/`。

所有接入方式都调用同一套 `/v1/*` 接口，并在每个请求中发送 `X-GameAlgo-Key`。

## 3. 运行时要求

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

## 4. 推荐事件

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

## 5. 验收清单

- 包内使用正确的 `gameKey`。
- 配置好的 key 能成功请求 `/v1/config`。
- 配置会缓存在本地。
- 配置文件可以成功拉取并缓存。
- 只要平台本地存储未被清空，重装/更新后 SDK 匿名 `userId` 能保持稳定。
- Debug 或 QA 事件设置 `isDebug=true`。
- 生产包使用 `ga_live_*`。
- 临时网络失败后，事件会继续重试。
