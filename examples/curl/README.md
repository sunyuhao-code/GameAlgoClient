# GameAlgo Curl 示例

运行前请把 `https://gamealgo.example.com` 和 `ga_live_xxx` 替换成实际服务地址和游戏 key。

## 拉取配置

```bash
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
```

## 拉取配置文件

```bash
curl -s "https://gamealgo.example.com/v1/config-files/gameplay.json" \
  -H "X-GameAlgo-Key: ga_live_xxx"
```

## 上传事件

```bash
curl -s -X POST "https://gamealgo.example.com/v1/events/batch" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {
        "eventId": "00000000-0000-0000-0000-000000000001",
        "contextId": "ctx-001",
        "userId": "user-001",
        "sessionId": "session-001",
        "eventType": "session_end",
        "isDebug": false,
        "timestamp": "2026-05-28T10:00:00Z",
        "payload": {
          "sessionDurationMs": 125000
        }
      }
    ]
  }'
```
