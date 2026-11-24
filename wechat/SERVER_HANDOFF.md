# GamePropel 微信小游戏 SDK 服务端对接

客户端：`@gamepropel/sdk-wechat@1.1.0`，入口 `GamePropelWechatClient`（保留 `GameAlgoWechatClient` 别名）。正式 SDK 固定发送
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

- 老用户的 `userId` 从原生存储恢复，保持原值。首次本地用户在初次配置请求中可携带
  `wechatLoginCode`；服务端已配置 AppSecret 且换取成功时，以 OpenID 作为主 `userId`，
  其余情况保留请求里的匿名候选 ID。详见下方首次身份协议。`accountUserId` 仍只用于
  接入方另行提供的游戏账号，不自动重复填入 OpenID。AppSecret 不进入客户端。
- `device.runtime=wechat`；`device.os` 表示 `ios/android/windows/macos` 等实际系统，
  `device.osVersion` 是系统版本。
- `device.wechatAppId` 只来自真实的 `wx.getAccountInfoSync()`；还可带品牌、型号及微信
  客户端/基础库版本。无需 TapTap `tapmc...` ID、Maker 项目 ID 或 TapTap 绑定。
- 微信不调用 TapDB，也不应由服务端触发 TapDB Context 关联。

## 首次用户 OpenID 协议（2026-11-24，服务端已部署，线上真机验证通过）

客户端仅在本地尚无历史 `userId`、且没有显式传 `userId` 时调用一次 `wx.login`。
成功拿到 code 后，在原 `/v1/config` 请求增加 `wechatLoginCode: string`；AppID 来自
`device.wechatAppId`。不增加独立登录请求，不传 AppSecret，也不记录原始 code 到日志。
没有 code 的配置请求维持原来的语义，尤其不得为老用户重置主 ID。

服务端在鉴权后、缓存查询和实验分配及 Context 创建前完成以下操作：

1. 按鉴权绑定的游戏查找可选微信 AppID/AppSecret，不能信任客户端指定另一个游戏的密钥。
2. 仅在 `platform=wechat` 且带 `wechatLoginCode` 时尝试换取；配置 AppID 应与真实
   `device.wechatAppId` 一致。凭证仅保存在服务端私密配置，不放公开配置文件或响应。
3. 设置短超时，用微信 `jscode2session` 换取；不记录 code/AppSecret/session_key。
   缺配置、微信报错或超时均回退请求的匿名候选 `userId`，配置仍正常返回。
4. **先确定最终 userId，再进行缓存键计算、实验分桶、用户/Context 落库和响应生成**。
   成功响应增加 `userIdentity: { userId: '<openid>', source: 'wechat_openid' }`；
   回退可返回 `{ userId: '<请求的候选ID>', source: 'anonymous' }`。
   不返回 AppSecret、session_key 或微信原始响应。

成功身份还返回可选 `userCreatedAt`、`userCreatedLocalAt`。服务端按游戏和 OpenID
持久化首次注册时间，后续清缓存或换设备时复用，避免同一玩家重复被当作新用户。
SDK 在保存最终身份时同步保存这两个时间。

旧服务端不返回 `userIdentity` 时，客户端保持匿名身份。旧用户即使收到额外身份字段也
不替换本地主 ID。新用户已经走匿名回退后，后续启动/刷新不再发 code 或升级为 OpenID。
SDK 在 Context 绑定前更新待绑定事件的 userId，保留 eventId、发生时间、sessionId 和
payload；已经绑定 Context 的历史事件保持原始归属。并发初次配置共用一次换码请求。

服务端已实现配置入口、加密存储和换取链路，国内服务已部署并完成线上真机验证。
其他环境部署顺序：先服务端数据库迁移和密钥配置，再更新客户端。旧服务端上的首次用户会正常
回退为匿名用户，后续按产品约定保持匿名 ID。

管理 API 为 `/admin/v1/games/<gameId>/wechat-login`：GET 返回脱敏状态；PUT 接收
`{ appId, appSecret, enabled }`；DELETE 移除配置。配置写入需要所属游戏的写权限。
后台“游戏设置 → 微信小游戏 OpenID（可选）”提供同一入口。服务端环境变量
`GAMEALGO_WECHAT_SECRET_ENCRYPTION_KEY` 为持久保存的 64 位十六进制加密密钥。
AppSecret 使用 AES-256-GCM 加密，并绑定 gameId；不进入公开配置、日志或微信包。

2026-11-24 微信真机 + 本机新服务端验证：真实 code 换取 OpenID 成功；首次 Context、
关卡事件和 session_end 使用一致的 OpenID；停用配置后新用户保持匿名；重新启用后，
匿名用户刷新、热启动和微信进程销毁后冷启动均保持原 ID。测试探针没有做平台转换。

同日国内线上微信真机验证：首次用户身份来源为 `wechat_openid`，主 ID 为 OpenID；
完全销毁微信进程后重进，配置继续使用相同的 OpenID 且不再携带 `wechatLoginCode`。
两次配置均 HTTP 200，关卡事件均 accepted=2、stored=2、rejected=[]。

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
