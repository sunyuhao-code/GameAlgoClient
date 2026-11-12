# GamePropel 抖音小游戏服务端对接

客户端包 `@gamepropel/sdk-douyin`，入口 `GamePropelDouyinClient`。

1. Platform、Key 平台匹配、配置、诊断、归因和下载配置接受 `douyin`。客户端
   固定该值，不降级为 `web`/`wechat`。路由前缀、鉴权头和现有协议字段沿用。
2. 首版只支持参数实验和 JSON 配置，`device.runtime=douyin`、remoteScripts=false。
   不分配仅依赖远端脚本的策略。系统/版本、机型、宿主名/版本、基础库版本来自
   `getSystemInfoSync`，douyinAppId、douyinEnvironment、douyinGameVersion 来自
   `getEnvInfoSync().microapp`；不要把宿主 App 和当前游戏 AppID 混淆。
3. 当前明确选择的广告计数口径：原生 `onClose` 的广告和分享兜底都计一次
   `ad_view`。字段 network=douyin、completionSource=video_or_share、
   impressionVerified=false、revenueStatus=unavailable、revenue=0。
   报表 ad_view 计数包含这些事件，不因 impressionVerified=false 擅自排除；
   该标记用于说明它不能直接与抖音的纯广告展示数对账。
   不能把它当成已确认的纯广告曝光或实际零收入；不要要求 trackId。
   客户端不从 show Promise 成功推断曝光，isEnded/count 仍是原生奖励结果。
4. session_end 可能有多个累计快照，按 Context/session 取最大时长。onShow 不换
   session，明确 newSession 会先结束旧 session。跨次恢复保留旧事件上下文。
5. 配置抖音平台下载/接入示例；实际网络必须添加 HTTPS request 合法域名。

本地验证为模拟 tt 宿主及安装包协议检查，不是抖音 IDE/真机结果。账号、AppID、
流量主广告位准备后，再联调真实广告与分享、iOS/Android 生命周期差异及退出恢复。

验证边界见 [VALIDATION.md](./VALIDATION.md)。
