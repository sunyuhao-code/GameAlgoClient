# GameAlgo REST Client 源码

这是符合 Protocol v1 的无第三方依赖 TypeScript helper。

导出内容：

- `GameAlgoRestClient`
- `GameAlgoApiError`
- `GameAlgoEventTracker`
- `GameAlgoExperimentExecutor`
- `GameAlgoConfigReader`
- `createEvent`
- Protocol v1 TypeScript 类型

helper 会在构造函数自动初始化或调用 `fetchConfig` 后保留一份内存快照。游戏逻辑应优先通过 `client.executor(key)` 和 `client.config` 读取本地快照。

`client.tracker` 负责内存事件队列、周期 flush 和单批次重试。它不负责持久化事件存储或进程生命周期；如果服务端接入方需要保证送达，应在外层增加自己的持久化策略。
