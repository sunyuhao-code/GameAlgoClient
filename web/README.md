# GamePropel TapTap H5 SDK — compatibility package

`@gamealgo/web` is the legacy package name for the **TapTap H5 SDK**.
New integrations use [`@gamepropel/sdk-taptap-h5`](https://www.npmjs.com/package/@gamepropel/sdk-taptap-h5).
It is not a generic SDK for WeChat or other minigame hosts.

```ts
import { GamePropelTapTapH5Client } from "@gamepropel/sdk-taptap-h5";

const gamePropel = GamePropelTapTapH5Client.init({
  baseUrl: "https://game-algo-sdk.dictapis.cn",
  gameKey: "ga_live_xxx",
});
```

Existing `import { GameAlgoWebClient } from "@gamealgo/web"` calls remain valid.
This package re-exports the same implementation and pins the matching TapTap H5
version; it does not bundle a second SDK, worker, WASM runtime or event queue.
Changing the import does not change persisted identities, sessions or queued events.

The wire value `platform=web` continues to mean **TapTap H5**, including historical
data. The device operating system is reported separately in `device.os`.
See the [TapTap H5 SDK documentation](https://github.com/sunyuhao-code/GameAlgoClient/tree/main/taptap-h5)
for the full API, host requirements and integration instructions.
