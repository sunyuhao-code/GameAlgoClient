import type { GameAlgoScriptInput, GameAlgoScriptRuntime, JsonValue } from "../../rest-api/src/types.ts";

type WorkerRequest = {
  id: number;
  operation: "prepare" | "execute";
  script: string;
  input?: GameAlgoScriptInput;
  timeoutMs: number;
};

type WorkerResponse = {
  id: number;
  ok: boolean;
  result?: JsonValue;
  error?: string;
};

type PendingRequest = {
  resolve(value: JsonValue): void;
  reject(error: Error): void;
  timer: ReturnType<typeof setTimeout>;
};

export type GameAlgoWebScriptRuntimeOptions = {
  prepareTimeoutMs?: number;
  executionTimeoutMs?: number;
};

/** Runs GameAlgo strategies in a dedicated QuickJS/WASM Web Worker. */
export class GameAlgoWebScriptRuntime implements GameAlgoScriptRuntime {
  private readonly prepareTimeoutMs: number;
  private readonly executionTimeoutMs: number;
  private worker?: Worker;
  private nextRequestId = 1;
  private readonly pending = new Map<number, PendingRequest>();

  constructor(options: GameAlgoWebScriptRuntimeOptions = {}) {
    this.prepareTimeoutMs = boundedTimeout(options.prepareTimeoutMs, 2_000);
    this.executionTimeoutMs = boundedTimeout(options.executionTimeoutMs, 1_000);
  }

  async prepare(script: string): Promise<void> {
    await this.request("prepare", script, undefined, this.prepareTimeoutMs);
  }

  execute(script: string, input: GameAlgoScriptInput): Promise<JsonValue> {
    return this.request("execute", script, input, this.executionTimeoutMs);
  }

  close(): void {
    this.stopWorker(new Error("GameAlgo Web script runtime closed"));
  }

  private request(
    operation: "prepare" | "execute",
    script: string,
    input: GameAlgoScriptInput | undefined,
    timeoutMs: number,
  ): Promise<JsonValue> {
    const worker = this.ensureWorker();
    const id = this.nextRequestId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.stopWorker(new Error(`script ${operation} timed out after ${timeoutMs}ms`));
      }, timeoutMs + 100);
      this.pending.set(id, { resolve, reject, timer });
      const request: WorkerRequest = { id, operation, script, input, timeoutMs };
      worker.postMessage(request);
    });
  }

  private ensureWorker(): Worker {
    if (this.worker) return this.worker;
    if (typeof Worker === "undefined") {
      throw new Error("Web Worker is required for GameAlgo remote script execution");
    }
    const worker = new Worker(new URL("./script-worker.ts", import.meta.url), {
      type: "module",
      name: "gamealgo-script-runtime",
    });
    worker.addEventListener("message", (event: MessageEvent<WorkerResponse>) => {
      const response = event.data;
      const pending = this.pending.get(response.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(response.id);
      if (response.ok && response.result !== undefined) pending.resolve(response.result);
      else pending.reject(new Error(response.error || "GameAlgo script worker failed"));
    });
    worker.addEventListener("error", (event) => {
      this.stopWorker(new Error(event.message || "GameAlgo script worker crashed"));
    });
    this.worker = worker;
    return worker;
  }

  private stopWorker(error: Error): void {
    this.worker?.terminate();
    this.worker = undefined;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }
}

function boundedTimeout(value: number | undefined, fallback: number): number {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(50, Math.min(Math.floor(value!), 10_000));
}
