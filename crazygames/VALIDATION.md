# CrazyGames 客户端验证记录

2026-11-12，本机 Node 24 / Chrome，客户端 `1.0.0` 的发布前验证；npm 可用版本以 registry 为准。

## 自动检查

* CrazyGames：11 项通过，覆盖官方宿主初始化的等待/超时、平台字段固定、
  设备信息、参数/JSON 配置、广告开始去重、失败/取消/并发互斥、生命周期、
  1 秒计时、5 秒发送、离线恢复、部分接受不重试及持久化/网络异常。
* 共享核心：71 项通过。
* TapTap H5：134 项通过，Web 兼容入口、打包及生产 bundle 检查通过。
* 微信：8 项通过，安装包检查通过。
* CrazyGames 安装包：ESM、CommonJS、TypeScript、独立安装及本机真实 HTTP
  校验通过。不包含 QuickJS/WASM、Node 运行时或 TapTap 广告/TapDB 实现。

## 官方 SDK 本地浏览器探针

加载自 `https://sdk.crazygames.com/crazygames-sdk-v3.js`，使用其真实
`environment=local` 模式。GamePropel 配置和事件发送到本机协议模拟服务，
未创建线上游戏、未发送生产数据，事件均为 debug。

实际操作验证：

1. 宿主初始化成功，参数读取成功。
2. 激励广告收到 adStarted、adFinished，仅产生一次 ad_view。
3. 插屏广告收到 adStarted、adFinished，仅产生一次 ad_view。
4. 页面隐藏/恢复时 session 不变；重新加载时创建新 session，用户身份不变。
5. 服务端模拟 503 后产生关卡事件，重新加载页面；恢复上报后，原关卡事件
   和 session_end 从真实 IndexedDB 队列恢复，事件保留旧 session。

本地广告是 CrazyGames 官方模拟覆盖层，无法证明生产广告展示/填充或收益。

## 仍需平台 Preview 联调

* 服务端接受 `platform=crazygames` 和生产域名 CORS。
* 实际 rewarded/midgame 回调、广告拦截、无填充及 Basic Launch 禁用行为。
* 移动端浏览器/平台 App、锁屏、广告中退后台、iframe 生命周期。
* APS/云存档是否会同步独立遥测数据库；目前仅确认本 SDK 不主动使用
  CrazyGames Data Module 或 localStorage。不能据此声称已保证跨设备隔离。
