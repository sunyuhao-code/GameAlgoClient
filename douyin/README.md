# GamePropel 抖音小游戏 SDK

独立包 `@gamepropel/sdk-douyin`，入口 `GamePropelDouyinClient`。
支持 `tt` 原生网络、存储、生命周期、参数/JSON 配置及激励广告。
没有浏览器 fetch/DOM、Node、QuickJS/WASM 或其他宿主 SDK 的运行时依赖。

## 接入

```sh
npm install @gamepropel/sdk-douyin
```

使用项目的打包工具引入 npm 包，或在仓库运行 `npm run build:douyin`，将
`douyin/dist/commonjs/index.js` 复制到已有小游戏项目，以 CommonJS 加载。

```js
const { GamePropelDouyinClient } = require('./gamepropel-sdk.js');
const gamePropel = GamePropelDouyinClient.init({
  baseUrl: yourGamePropelBaseUrl,
  gameKey: yourExistingClientGameKey,
  isDebug: true, // 测试项目打开；正式版按游戏需要配置。
});
gamePropel.waitForReady(5000).then(ready => {
  if (ready) gamePropel.tracker.trackLevelStart({ levelId: '1' });
});
```

正式使用需要服务端接受 `platform=douyin`，并在抖音开发者后台配置 HTTPS
request 合法域名。`tt.request` 使用对象类型的 JSON data 和 `dataType=string`；
SDK 保留 URL 路径前缀及 `X-GameAlgo-Key`，不尝试伪装成微信或 TapTap 平台。
设备信息由 `tt.getSystemInfoSync()` 提供，游戏 AppID 来自
`tt.getEnvInfoSync().microapp.appId`，不会由调用方参数或 URL 猜测。

## 激励广告

```js
const revive = gamePropel.createAdSpace({ adUnitId: yourDouyinRewardedAdUnitId });
revive.show(yourGamePropelAdPlacementId, {
  onClose(result) {
    // 业务按原生 isEnded/count 判断奖励；SDK 不替游戏发奖励。
    applyNativeRewardResult(result); // 游戏自行决定 isEnded/count 对应的奖励。
    resumeGame();
  },
  onError(error) { resumeGame(); console.log(error.errCode); },
}).catch(error => { resumeGame(); });
```

* 按当前产品口径，每次有效的原生 `onClose` 记一次 `ad_view` 并立即 flush，
  重复回调去重。抖音的分享兜底关闭也纳入该计数。
* 数据标记 `network=douyin`、`completionSource=video_or_share`、
  `impressionVerified=false`、`revenueStatus=unavailable`。`revenue=0` 是协议占位，
  不代表已确认的实际收入。原生 `isEnded`、`count` 原样保留，调用方伪造的
  `trackId` 不转发。没有公开的单次收益金额。
* `show()` Promise 成功不产生曝光，也不代表可以发奖励；奖励由原生关闭结果决定。
  广告可能在 1004 无填充后转成分享，所以保留该流程后续的 `onClose`。
* 按官方建议直接调用原生 `show()`，不会把 `load()` 成功作为显示/分享的前提，
  也不自动重试广告。宿主的全局视频单例在各 SDK 实例间共用播放锁，切换广告位
  会在空闲时先销毁旧原生对象。
* 首版仅支持单次激励广告。未接插屏、Banner 或再得广告（multiton）。
  SDK 自己管理实例，请不要在同一播放期间绕过 SDK 操作同一个原生单例。
* `adTimeoutMs` 默认 180 秒，用于清理无关闭回调的过期播放上下文；关闭 SDK
  会释放它拥有的回调与原生实例。业务回调抛错不阻止采集。

## 会话和持久化

* 普通事件每 5 秒发送，默认队列上限 500，单批最多 20 条/48 KiB。
* `tt.onHide` 生成累计时长的 `session_end` 快照、入队并立即尝试发送。
  `tt.onShow` 保留 session；只有初始化或 `tracker.newSession()` 创建新 session。
* 前台计时以 1 秒采样，长时间挂起每次最多补 1 秒。广告导致 JS 暂停的时间
  不追补。`getForegroundTimeMs()` 只读内存，不进行网络/落盘。
* 原生存储立即保存队列变化，分块先写数据、后提交目录；断网和失败批次会恢复
  原事件 ID、时间、session 和 Context。I/O 失败不会被伪装成已成功持久化。
  强杀、缺失生命周期回调或 JS 被暂停前未完成的最后一段写入仍需真机验证。
* 同 Context/session 的多次 `session_end` 是累计快照，服务端时长取最大值。

宿主差异：官方说明 iOS 播放/关闭激励广告会触发生命周期事件，Android 不会。
不能仅凭 `onHide` 区分真正退后台和正常广告；本 SDK 沿用“允许广告期间上报快照”
的口径，不在恢复时切断 session。

## 验证和后续联调

```sh
npm run check:douyin
npm run check:douyin:pack
```

目前是模拟原生宿主、真实本机 HTTP 及安装包验证；尚无抖音开发者账号/AppID，
没有声称完成 IDE 或真机验证。创建小游戏、配置合法域名并开通流量主/取得真实
广告位后，需验证 iOS/Android 广告、分享兜底、锁屏、广告中切后台和强杀恢复。
服务端要求见 [SERVER_HANDOFF.md](./SERVER_HANDOFF.md)。
本地检查的具体范围见 [VALIDATION.md](./VALIDATION.md)。

官方参考：[网络](https://developer.open-douyin.com/docs/resource/zh-CN/mini-game/develop/api/javascript-api/network/initiate-a-request/tt-request)、
[后台](https://developer.open-douyin.com/docs/resource/zh-CN/mini-game/develop/api/javascript-api/foundation/system/lifecycle/tt-on-hide)、
[系统信息](https://developer.open-douyin.com/docs/resource/zh-CN/mini-game/develop/api/javascript-api/foundation/system/system-information/tt-get-system-info-sync)、
[环境信息](https://developer.open-douyin.com/docs/resource/zh-CN/mini-game/develop/api/javascript-api/foundation/system/system-information/tt-get-env-info-sync)、
[激励广告及分享兜底](https://developer.open-douyin.com/docs/resource/zh-CN/mini-game/develop/api/javascript-api/ads/tt-create-rewarded-video-ad)。
