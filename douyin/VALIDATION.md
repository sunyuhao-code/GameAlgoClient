# 抖音小游戏客户端验证记录

2026-11-12，Node 24，首版客户端验证记录。

* 抖音 11 项测试通过：原生对象类型的请求 data、平台/设备/游戏身份、JSON
  配置、后台快照、1 秒采样、离线尾部恢复、存储和网络失败、广告去重、原生
  单例互斥，以及 1004 后的分享关闭（含 show Promise 拒绝后继续关闭）。
* 关闭结果按已选口径统一记一次 ad_view，标记来源 video_or_share、曝光未确认、
  收益未知；不会因 show Promise 成功而产生事件或伪造奖励。
* VM 中移除 fetch、URL、Headers、Response、TextEncoder、window、document、
  Worker、WebAssembly 和 Node 全局，打包后的 SDK 仍可通过模拟 tt 原生桥进行
  本机真实 HTTP 请求和生命周期采集。这证明移植/协议边界，不是抖音真机结果。
* tarball 的独立安装、ESM/CommonJS 导出与 TypeScript 类型检查通过。
* 共享核心 71、TapTap H5 134、微信 8、CrazyGames 11 项回归测试通过；
  共 235 项。各 JavaScript 包的安装和 bundle 检查通过。

当前没有抖音开发者账号、小游戏 AppID 或广告位，未创建测试项目、未上传小游戏、
未伪造线上身份或连接生产 GamePropel 接口。后续需验证抖音 IDE 及 iOS/Android
上的广告/分享、广告中退后台、锁屏、断网和强杀恢复。计数口径包含分享兜底，
不能将其直接当成抖音平台纯广告展示数对账。
