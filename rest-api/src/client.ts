import { GameAlgoRestClient as GameAlgoClientCore } from "./core-client.ts";
import { RustProcessScriptRuntime } from "./rust-script-runtime.ts";
import type { GameAlgoRestClientOptions } from "./types.ts";

/** Node/REST entry; browser and minigame hosts use the portable core directly. */
export class GameAlgoRestClient extends GameAlgoClientCore {
  constructor(options: GameAlgoRestClientOptions) {
    super({ ...options, scriptRuntime: options.scriptRuntime ?? new RustProcessScriptRuntime(options.scriptRuntimeBinaryPath) });
  }
}

export { GameAlgoApiError, GameAlgoConfigReader, GameAlgoEventTracker, GameAlgoExperimentExecutor, createEvent } from "./core-client.ts";
export { RustProcessScriptRuntime } from "./rust-script-runtime.ts";
