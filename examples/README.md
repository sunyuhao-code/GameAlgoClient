# GameAlgo 客户端示例

这里集中说明仓库内可以直接运行或发布的客户端示例。示例只能使用公开 SDK API 和 `/v1/*` 接口。

## 示例目录

| 示例 | 位置 | 用途 |
| --- | --- | --- |
| Node REST | `../rest-api/examples/node/basic.ts` | 最小后端接入 |
| Curl | 本文下方 | 直接验证配置和事件接口 |
| DDA 脚本 | `dda/level-dda.js`、`dda/level-dda.lua` | JavaScript / Lua 关卡策略模板 |
| Web 游戏 Demo | [`web-game-demo/`](./web-game-demo/README.md) | 浏览器端到端验证事件和 Report Pack |

## Curl

运行前把 Base URL 和 `ga_live_xxx` 替换为当前环境的真实值。

```bash
# 拉取配置
curl -s -X POST "https://gamealgo.example.com/v1/config" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "userId": "user-001",
    "sessionId": "session-001",
    "platform": "rest",
    "sdkVersion": "1.0.0",
    "appVersion": "1.2.3",
    "timezone": "Asia/Shanghai",
    "device": {}
  }'

# 拉取配置文件
curl -s "https://gamealgo.example.com/v1/config-files/gameplay.json" \
  -H "X-GameAlgo-Key: ga_live_xxx"

# 上传事件；contextId 使用配置响应中的真实值
curl -s -X POST "https://gamealgo.example.com/v1/events/batch" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [{
      "eventId": "00000000-0000-0000-0000-000000000001",
      "contextId": "ctx-001",
      "userId": "user-001",
      "sessionId": "session-001",
      "eventType": "session_end",
      "isDebug": true,
      "timestamp": "2026-08-14T10:00:00Z",
      "payload": { "sessionDurationMs": 125000 }
    }]
  }'
```

## DDA 策略模板

`level-dda.js` 和 `level-dda.lua` 是同一套策略的 JavaScript / Lua 实现。模板把最近行为按 variant config 中的 `behaviorWeights` 折算为每关摩擦分，只输出 `increase`、`keep`、`decrease` 三个稳定动作。游戏必须提供 Adapter，把动作映射为安全的游戏参数。

```json
{
  "behaviorWeights": {
    "level_failed": 1,
    "level_retry": 0.75,
    "item_used": 0.25,
    "mistake": 0.5
  },
  "minRecentSteps": 3,
  "decreaseThreshold": 0.8,
  "increaseThreshold": 0
}
```

按客户端能够执行的语言发布不可变脚本版本：

```bash
gamealgo script publish examples/dda/level-dda.js --message "DDA template v1" --json
gamealgo script publish examples/dda/level-dda.lua --message "Lua DDA template v1" --json
```
