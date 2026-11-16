# TapTap 双通道上报协议

适用：Maker `2.1.4-lua`、TapTap H5 `2.1.9`（含旧 `@gamealgo/web` 兼容入口）。
其他平台不使用 TapDB，不受此功能影响。

## 配置响应

`POST /v1/config` 的新鲜成功响应下发 4 个独立开关，不设总开关：

```json
{
  "gamealgoStandardReportingEnabled": true,
  "gamealgoCustomReportingEnabled": true,
  "tapdbStandardReportingEnabled": false,
  "tapdbCustomReportingEnabled": false
}
```

| 分类 | 范围 | GameAlgo 默认 | TapDB 默认 |
|---|---|---|---|
| 标准 | session_end、level_start、level_end、ad_view、purchase、milestone、SDK 实验事件、归因、ID 关联、SDK 诊断 | 开 | 关 |
| 自定义 | 游戏业务事件，包括 TrackEvent 自动加 `_` 前缀的事件及其他自定义 Track 名称 | 开 | 关 |

实验保留名为 `experiment_exposure`、`experiment_execution`；其他未知事件名按自定义类处理。
归因、标识符、诊断等独立请求始终属于标准类。旧 `gamealgo_context_link` 也属于标准类，
须同时满足 `tapdbStandardReportingEnabled=true` 和原来的 `tapdbContextLinkEnabled=true`。

每类分别支持仅 GameAlgo、仅 TapDB、双报或双关。例如，关闭
`gamealgoCustomReportingEnabled` 并开启 `tapdbCustomReportingEnabled`，其余保持默认，
即可标准类走 GameAlgo、自定义类走 TapDB。同一批次按事件分流，原 ID、时间和 Context 不变。
某类双关时跳过并清除该类队列，不在重新开启后补报。

只认布尔值。GameAlgo 分类只有明确 `false` 才关闭；TapDB 分类只有明确 `true` 才开启。
启动默认 GameAlgo 两类开、TapDB 两类关；离线快照和 TTL 内的本地命中不会开启 TapDB。
收到当前 session 的新鲜成功配置后更新开关，旧 session 的迟到响应不更新它。
策略在绑定 Context 触发紧急发送之前生效，不等待配置快照写盘成功。
同一 Init 内配置刷新可以更新策略；切 session 不重置已取得的策略。

配置、配置文件、脚本和联机请求维持原路径。Maker 当前无归因/标识符绑定公开方法，
其已有数据请求均覆盖。开关只控制 SDK 发起的上报；配置请求仍携带原身份和设备上下文，
游戏自行直接调用的 TapDB 不受这些开关控制。

## 宿主接口与受理

* Maker：`sdk:LogEvent(name, properties)`，返回 `true` 视为宿主受理；不传回调。
* H5：`tap.logEvent({name, properties, success, fail, complete})`，回调 `errno=0`
  视为宿主受理。undefined 返回值不是 ACK；15 秒无回调按失败处理。
* 宿主受理不等于最终写入 TapDB。正常入队后由 TapTap 自己的 SDK 负责传输。
* 双报不等待 TapDB 回调才开始 HTTP。TapDB 失败不阻止正常 HTTP 上报；HTTP
  重试对仍在有限内存去重窗口中的宿主调用去重，不因为 HTTP 重试紧密调用 TapDB。
* 仅 TapDB 时，宿主未就绪、拒绝、异常或超时会使 flush 失败；已有持久化队列
  保留原事件，使用现有重试节奏，不自动改走关闭的 HTTP 通道。
* 混合批次中，TapDB-only 子集失败仍保留原批次；直连已终结的子集在同次运行的有限
  内存窗口中跳过重发。反向重试也不会重复已经受理的宿主调用。跨重启仍按原 ID 去重。
* 不建立第二套磁盘队列，不增加逐帧扫描。成功受理后的重启重放属于至少一次语义，
  下游按原事件 ID 去重。双报只保证现有 HTTP 队列的可靠发送，不另建 TapDB
  副本重试队列；一次 HTTP 成功但 TapDB 失败，不阻塞游戏和 HTTP 队列。
* 开关在下次成功配置请求时生效，不能撤销已经发起的 HTTP 或宿主调用。

H5 `uploadEvents` 和 Lua `Flush` 的纯本地路由结果保留 `accepted=0`；混合批次的 accepted 只计本次直连受理数，并增加
`skipped`（跳过直连的行数）、`tapdbAttempted`（本次宿主调用数）。不能把它当成
GameAlgo 服务端已接收，也不能把它当成 TapDB 已落盘。归因的直连 ACK 缓存不会
由本地回执填充，避免以后打开 HTTP 时漏报。

## TapDB 格式

固定事件名，避免平台对自定义事件名字符的限制：

* `gamealgo_event`：一个原始埋点事件。
* `gamealgo_request`：一个独立上报请求，仅限归因、标识符和诊断路径。

平铺属性如下，原始事件的完整值以 JSON 分片为准：

| 属性 | 类型与说明 |
|---|---|
| gamealgo_envelope_version | 字符串 `1` |
| gamealgo_part_count | 分片数的十进制字符串 |
| gamealgo_part_0 … gamealgo_part_N | 完整 JSON 按数字索引拼接；单片最多 240 UTF-8 字节，保持 Unicode 边界 |
| gamealgo_event_id | 原 eventId；独立请求用 diagnosticId 或内容散列 |
| gamealgo_event_type | 原 eventType；独立请求使用路径 |
| gamealgo_context_id | 原 Context |
| gamealgo_device_id | 原 GameAlgo userId，不冒充 TapDB deviceid |
| gamealgo_session_id | 原 sessionId |
| gamealgo_is_debug | 原布尔标记 |

用于索引的字符串属性最多取前 240 UTF-8 字节，完整值不裁剪，保存在 JSON 中。
分片在同一条原生事件内发送，不为每一片制造新事件。不包含 HTTP 鉴权头或
SDK Key。分片避免 [TapDB 通用 SDK 的字符串属性限制](https://developer.taptap.cn/docs/sdk/tapdb/sdk/client-side-integration/unreal-engine-5/)；
小游戏宿主实际支持的属性数量及 TapDB 最终落库完整性仍需正式包验证。

`gamealgo_event` 的拼接结果：

```json
{
  "schemaVersion": 1,
  "path": "/v1/events/batch",
  "event": {
    "eventId": "original-event-id",
    "contextId": "original-context-id",
    "userId": "original-gamealgo-user-id",
    "sessionId": "original-session-id",
    "eventType": "level_end",
    "isDebug": false,
    "timestamp": "2026-11-16T08:00:00.000Z",
    "createdLocalAt": "2026-11-16T16:00:00.000+08:00",
    "payload": { "level_id": "1", "result": "win" }
  }
}
```

`gamealgo_request` 的拼接结果为
`{schemaVersion:1,path,requestId,body}`。body 是对应原 HTTP JSON 正文；允许的路径：
`/v1/attribution`、`/v1/context-identifiers`、`/v1/diagnostics/sdk`、`/v1/diagnostics/init`。
不允许把任意 URL 当作代理目标。

## 服务端与 DW

* 服务端必须在 Context 幂等缓存命中后仍合并当前开关，不让旧缓存盖住关闭指令。
* 只有 Maker/web 读取这些通道配置；其余平台继续原来通道。
* DW 提取 `dataname=gamealgo_event|gamealgo_request`，从 properties 或原始
  `_preset` 字典读取分片，按数字索引拼接、验证 schemaVersion、解析后走已有校验。
* 保留原 eventId、发生时间和 Context，不使用 TapDB 上报时间重新生成事件。
  不用客户端声称的 gameId 授权；按可信游戏绑定/导入任务身份校验来源。
* 双报和重放的数据最终按原事件 ID 及现有 debug 隔离规则去重，不能把两路计数相加。
* 先完成数据导入、属性完整性和真实事件对账，再给正式游戏开启仅 TapDB。

## 本地验证边界

本地测试覆盖 4 开关的 16 种组合和混合批次重试隔离、全事件类型、独立请求、开关刷新、持久化恢复、
HTTP 重试去重、TapDB 异常/超时、Unicode 长参数、只 TapDB 的失败重试及空闲
Update 不探测宿主。安装包和其他 JavaScript SDK 继续做回归检查。
这些是模拟宿主/协议验证，不能替代正式 Maker/H5 包的 TapDB 真实落库和数据对账。
