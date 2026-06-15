# Web Game Demo

`web-game-demo` is a static browser game for end-to-end SDK telemetry checks. It
uses the public Protocol v1 REST endpoints:

- `POST /v1/config`
- `POST /v1/events/batch`

The demo sends SDK context fields including `userCreatedAt` and `timezone`, then
uploads these event types while playing:

- `level_start`
- `level_end`
- `ad_view`
- `purchase`
- `_tile_tap`
- `_demo_open`
- `session_end`

## Run

Open `index.html` in a browser, or serve this directory:

```bash
python3 -m http.server 8088
```

Then visit:

```text
http://127.0.0.1:8088
```

Use:

```text
Base URL: https://game-algo-sdk.dictapis.cn
Game Key: your game key from the GameAlgo console
```

The game key is stored only in browser `localStorage`; it is not committed in
this repository.

## Report Pack

`report-pack.json` is a matching report pack for this demo. Import it into the
GameAlgo console Reports page for the demo game, then run the reports to verify
that events are visible in dashboards.
