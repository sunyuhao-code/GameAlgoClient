# GamePropel CrazyGames 服务端对接

客户端包：`@gamepropel/sdk-crazygames@1.0.0`，入口 `GamePropelCrazyGamesClient`。
客户端与服务端分别发布；服务端由负责该部分的 agent 接续上线。

1. 配置、归因、诊断等使用 Platform 的接口及游戏平台/Key 校验允许 `crazygames`。
   SDK 不会伪装成 `web`（历史 TapTap H5）或 `wechat`。现有域名、路由前缀、
   `X-GameAlgo-Key`、事件格式、Key 格式均沿用。事件通过 Context 关联平台。
2. 参数实验和 JSON 配置支持；`device.runtime=crazygames`、
   `device.remoteScripts=false`。首版不分配远端脚本为唯一生效策略。
3. `device` 可包含官方 systemInfo 的 OS、OS 版本、设备类型、浏览器/版本、
   locale、countryCode、applicationType，以及 crazyGamesEnvironment。
   操作系统与投放平台是两个维度；环境 `local` 的数据强制标为 debug。
4. 注册 GamePropel 广告位，静态 adType 对应宿主的 rewarded/midgame。
   曝光在 adStarted 时产生，携带 adPlacementId、network=crazygames、
   hostAdType、hostEnvironment、revenueStatus=unavailable、revenue=0。
   公开 SDK 没有单次广告收益金额或 trackId；不要把 0 解释为已知实际收入，
   不要要求 trackId 才接收曝光，也不要由缺失收益推算实际 eCPM。
5. session_end 为累计前台时长快照；同 Context/session 可多次上报。
   时长取最大值，不能求和。回到游戏不会自动创建新 session。
6. CLI 下载配置、平台枚举及接入示例增加独立包，保留现有平台与统计历史。

验证范围：本地协议、队列/生命周期单元测试及安装包检查；官方 v3 的 localhost
探针用于验证宿主初始化和模拟广告。生产域名 CORS、实际广告、移动 App/iframe
生命周期和 APS 云存档对设备标识/待发队列的影响，需要在 CrazyGames Preview 联调。
客户端默认单独 IndexedDB，不主动写 SDK Data Module 或 localStorage；这不是
已经确认平台不会同步该数据库的保证。

本机具体结果见 [验证记录](./VALIDATION.md)。
