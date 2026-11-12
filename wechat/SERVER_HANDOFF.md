# GamePropel 微信小游戏 SDK 服务端对接

客户端：`@gamepropel/wechat@1.0.0`，入口 `GamePropelWechatClient`（保留 `GameAlgoWechatClient` 别名）。正式 SDK 固定发送
`platform=wechat`，网络使用 `wx.request`，不需要业务服务器转发，也不使用浏览器
`fetch`、Worker、QuickJS 或 WebAssembly。TapTap H5 继续使用 `platform=web`。

品牌由 GameAlgo 更名为 GamePropel；新 npm 包使用 `@gamepropel` 命名空间。服务端及 CLI 的 SDK 下载配置和接入示例应同步使用新包名。现有 API 域名、鉴权请求头、Key 格式、协议字段及客户端存储标识继续沿用。

## 需要服务端接通的部分

复用已有 SDK 协议，不增加微信专用的配置或事件路由。所有请求使用真实 Client Game
Key 的 `X-GameAlgo-Key` 请求头，支持国内地址及海外 `/algo_sdk` 部署前缀。

| 接口 | 客户端行为 | 服务端要求 |
| --- | --- | --- |
| `POST /v1/config` | 发送 `platform=wechat`、用户/session、SDK/App 版本及设备字段 | 接受微信平台及对应 Key，返回有效 `contextId` 和现有配置结构 |
| `POST /v1/events/batch` | 使用原有事件结构；事件携带自己的 `contextId`、`sessionId`、`eventId`、时间戳和 `isDebug` | 将事件关联到原 Context，保持 `eventId` 幂等，返回原有批次确认结构 |
| `GET /v1/config-files/{name}` | 默认只预加载 JSON 配置文件 | 复用现有文件接口及鉴权 |
| `POST /v1/diagnostics/sdk` | 触发配额保护时携带 `platform=wechat` | 将微信加入已有诊断平台校验 |

如启用 SDK 继承的归因、Context 标识等可选接口，这些接口的平台校验也要接受
`wechat`。同步检查 Key 管理、配置发布、报表过滤/聚合、管理后台和 CLI 文档中的
平台枚举。`web` 的历史数据保持原义，不改写为微信数据。

配置响应继续提供 `gameId`、`environment`、`configVersion`、`ttlSeconds`、
`contextId`、`experiments` 和 `configFiles`。首版支持参数实验和 JSON 配置，不执行
远端脚本；有脚本的实验会使用本地默认逻辑。服务端不要依赖脚本执行来完成微信接入。

身份与设备字段：

- `userId` 是 SDK 原生存储中的匿名 ID，重开恢复；可选 `accountUserId` 关联游戏已有
  OpenID，不替换匿名 ID。不需要把 AppSecret 放进客户端。
- `device.runtime=wechat`；`device.os` 表示 `ios/android/windows/macos` 等实际系统，
  `device.osVersion` 是系统版本。
- `device.wechatAppId` 只来自真实的 `wx.getAccountInfoSync()`；还可带品牌、型号及微信
  客户端/基础库版本。无需 TapTap `tapmc...` ID、Maker 项目 ID 或 TapTap 绑定。
- 微信不调用 TapDB，也不应由服务端触发 TapDB Context 关联。

## session、计时和补发口径

初始化产生新 session；`onShow` 保留原 session。显式 `tracker.newSession()` 会先用
原 Context 为旧 session 入队 `session_end`，再切换 session。

`onHide`（包括全屏广告导致的 hide）入队并尝试立即上报 `session_end`，
`payload.reason=wechat_hide`。多次 hide/show 可以为同一 session 产生多个结束快照；
统计时取同一 session 的最大 `sessionDurationMs`，不能把这些快照相加。

`sessionDurationMs` 使用 1 秒前台采样计数，后台和挂起期间不补算，广告时间允许少计。
返回前台继续累计；读取 `getForegroundTimeMs()` 不触发网络或落盘。

事件入队即持久化。重开补发时保留原 `eventId`、session、Context、时间戳和时长，
服务端按原始身份接收，不能改挂到新 session/Context。进程直接终止且没有收到 hide
时，客户端不会凭空生成一个结束事件。

普通队列默认 500 条、5 秒发送、每批最多 20 条；`session_end/ad_view` 使用紧急发送
通道，不被已有的普通请求阻塞。传输失败会保留队列重试。成功响应中的 `accepted>0`
表示该批已处理，SDK 不会为剩余 rejected 事件持续重试。

## 广告口径

客户端提供真实微信激励广告的加载/播放/关闭封装，GameAlgo `gap_*` 点位与微信广告位
`adUnitId` 独立。真实 close 后生成一次 `ad_view`，保留原生 `isEnded` 奖励判断。

微信 close 回调没有 TapTap trackId 和逐次广告收入。自动事件使用 `network=wechat`、
`revenueStatus=unavailable`、`revenue=0` 占位，不伪造 trackId。报表不得把这个占位
当作真实零收入，也不能据此计算已核实的逐用户广告收益、CPM 或 ROAS。收入对账属于
独立接入。真实微信广告位尚未实测。

## 已完成的验证（2026-11-11）

本地构建包含无运行时依赖的 ESM、独立 CommonJS 和类型声明。测试覆盖微信传输、
生命周期、前台计时、持久化故障、离线恢复、超时/取消和模拟广告回调；包检查在没有
浏览器/Node 全局对象的受限 JS 环境中运行，并验证真实 HTTP、安装和类型解析。

iPhone 16 Pro Max / iOS 26.5 的微信小游戏真机验证：

| 场景 | 观察结果 |
| --- | --- |
| 初始化和关卡事件 | 配置 HTTP 200，自动生成的两条关卡事件 `accepted=2` |
| 两次切后台/返回 | 两条结束快照，总 `accepted` 从 2 增至 4，session 保持不变，返回后继续计时 |
| 锁屏/解锁 | 一条结束快照，`accepted=3`，恢复后继续计时 |
| 离线产生事件后强退微信并重开 | 原匿名用户和配置缓存恢复；本次未触发 hide 即补发旧结束快照；`accepted=5`，符合旧队列 3 条加新关卡事件 2 条 |

这些真机测试使用独立游戏 `game-97505d8ecf74b8aa`（GameAlgo 微信 SDK 测试）及
`wechat-host-test` 客户端 Key。密钥明文不在本仓库。

测试时线上服务对 `wechat` 返回 HTTP 400：`platform must be ios, android, maker,
or web`。因此只有外部测试工程临时把请求平台转换为 `web`，数据进入该测试游戏；
本仓库 SDK 没有转换逻辑。上述证据验证了微信宿主的采集、传输、存储和生命周期，
尚不能证明服务端已按微信平台完成存储、统计、发布和权限处理。Android 微信、开发者
工具及真实广告也尚未验证。

服务端更新后，用同一个测试游戏去掉探针的 `testWirePlatform: 'web'` 转换，再检查：
配置与事件成功、Context/报表记录 `wechat`、用户与原 Context 关联正确、TapTap H5
仍记录 `web`。不需要改动正式 SDK 的平台字段。对应本地测试工程为
`../GameAlgoWechatProbe`；其凭据、上传私钥及二维码均不进入 SDK 发布包。
