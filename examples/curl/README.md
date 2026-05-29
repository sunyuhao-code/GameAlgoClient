# GameAlgo Curl Examples

Replace `https://gamealgo.example.com` and `ga_live_xxx` before running.

## Fetch Config

```bash
curl -s "https://gamealgo.example.com/v1/config?userId=user-001&platform=rest&sdkVersion=1.0.0&appVersion=1.2.3" \
  -H "X-GameAlgo-Key: ga_live_xxx"
```

## Fetch Config File

```bash
curl -s "https://gamealgo.example.com/v1/config-files/gameplay.json" \
  -H "X-GameAlgo-Key: ga_live_xxx"
```

## Upload Events

```bash
curl -s -X POST "https://gamealgo.example.com/v1/events/batch" \
  -H "X-GameAlgo-Key: ga_live_xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {
        "eventId": "00000000-0000-0000-0000-000000000001",
        "userId": "user-001",
        "sessionId": "session-001",
        "eventType": "session_start",
        "platform": "rest",
        "sdkVersion": "1.0.0",
        "appVersion": "1.2.3",
        "timezone": "Asia/Shanghai",
        "isDebug": false,
        "timestamp": "2026-05-28T10:00:00Z",
        "payload": {}
      }
    ]
  }'
```
