# H5 Multiplayer Counter Duel

This demo exercises the V1 host-authoritative multiplayer path: matchmaking,
room initialization, aggregated input, public/private snapshots, reconnect, and
host migration.

From `GameAlgoServer`, run:

```bash
./scripts/run-multiplayer-demo.sh
```

Then open two browser pages:

```text
http://127.0.0.1:4173/?player=alice&rtt=10
http://127.0.0.1:4173/?player=bob&rtt=30
```

The lower-RTT page starts as host. Click “房主主动迁移” to verify that the
other page restores the last host checkpoint and continues the same match.
