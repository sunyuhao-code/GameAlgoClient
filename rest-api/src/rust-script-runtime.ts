import type { GameAlgoScriptInput, GameAlgoScriptRuntime, JsonValue } from "./types.ts";

type RustRuntimeResponse = {
  status?: string;
  result?: JsonValue;
  message?: string;
  prepared?: boolean;
};

type RustRuntimeRequest = {
  op: "prepare" | "execute";
  script: string;
  input?: GameAlgoScriptInput;
};

type PendingRustRequest = {
  request: RustRuntimeRequest;
  timeoutMs: number;
  resolve: (response: RustRuntimeResponse) => void;
  reject: (error: Error) => void;
};

type ActiveRustRequest = PendingRustRequest & {
  child: import("node:child_process").ChildProcessWithoutNullStreams;
  timeout: ReturnType<typeof setTimeout>;
};

export class RustProcessScriptRuntime implements GameAlgoScriptRuntime {
  private readonly binaryPath: string;
  private readonly processTimeoutMs: number;
  private readonly prepareTimeoutMs: number;
  private child?: import("node:child_process").ChildProcessWithoutNullStreams;
  private stdoutBuffer = "";
  private stdoutBytes = 0;
  private readonly queue: PendingRustRequest[] = [];
  private active?: ActiveRustRequest;
  private pumpPromise?: Promise<void>;
  private closed = false;

  constructor(binaryPath?: string, processTimeoutMs = 2000) {
    this.binaryPath = clean(binaryPath) ?? defaultRustRuntimeBinaryPath();
    this.processTimeoutMs = processTimeoutMs;
    // Parsing a 10 MB script is a load operation, not a strategy execution.
    this.prepareTimeoutMs = Math.max(processTimeoutMs, 10_000);
  }

  async prepare(script: string): Promise<void> {
    const response = await this.request({ op: "prepare", script }, this.prepareTimeoutMs);
    this.assertOk(response, "GameAlgo Rust runtime script preparation failed");
  }

  async execute(script: string, input: GameAlgoScriptInput): Promise<JsonValue> {
    const response = await this.request({ op: "execute", script, input }, this.processTimeoutMs);
    this.assertOk(response, "GameAlgo Rust runtime failed");
    return normalizeJsonValue(response.result);
  }

  close(): void {
    this.closed = true;
    const error = new Error("GameAlgo Rust runtime was closed");
    for (const pending of this.queue.splice(0)) pending.reject(error);
    if (this.child) {
      const child = this.child;
      this.failWorker(child, error);
      child.kill("SIGKILL");
    }
  }

  private assertOk(response: RustRuntimeResponse, fallback: string): void {
    if (response.status !== "ok") {
      throw new Error(response.message ?? fallback);
    }
  }

  private request(request: RustRuntimeRequest, timeoutMs: number): Promise<RustRuntimeResponse> {
    if (typeof process === "undefined" || !process.versions?.node) {
      return Promise.reject(new Error(
        "The canonical GameAlgo Rust runtime is unavailable in this environment; provide scriptRuntime explicitly",
      ));
    }
    if (this.closed) return Promise.reject(new Error("GameAlgo Rust runtime was closed"));
    return new Promise<RustRuntimeResponse>((resolve, reject) => {
      this.queue.push({ request, timeoutMs, resolve, reject });
      void this.pump();
    });
  }

  private async pump(): Promise<void> {
    if (this.pumpPromise) return this.pumpPromise;
    this.pumpPromise = (async () => {
      while (this.queue.length > 0 && !this.closed) {
        const pending = this.queue.shift()!;
        try {
          await this.ensureWorker();
          const response = await this.send(pending, pending.timeoutMs);
          pending.resolve(response);
        } catch (error) {
          pending.reject(error instanceof Error ? error : new Error(String(error)));
          // The current request is lost, but later queued requests can use a
          // freshly started worker. The Rust cache is rebuilt by prepare/execute.
          if (this.child) this.failWorker(this.child, error instanceof Error ? error : new Error(String(error)));
        }
      }
    })().finally(() => {
      this.pumpPromise = undefined;
      if (this.queue.length > 0 && !this.closed) void this.pump();
    });
    return this.pumpPromise;
  }

  private async ensureWorker(): Promise<void> {
    if (this.child && !this.child.killed) return;
    const { spawn } = await import("node:child_process");
    const child = spawn(this.binaryPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.stdoutBuffer = "";
    this.stdoutBytes = 0;
    // The cache worker should not keep a short-lived CLI/test process alive.
    // A server with an active event loop still keeps using the same worker.
    child.unref();
    (child.stdin as { unref?: () => void }).unref?.();
    (child.stdout as { unref?: () => void }).unref?.();
    (child.stderr as { unref?: () => void }).unref?.();
    child.stdout.on("data", (chunk: Buffer) => this.handleStdout(child, chunk));
    child.stderr.on("data", () => undefined);
    child.once("error", (error) => {
      this.failWorker(child, new Error(`Unable to start GameAlgo Rust runtime at ${this.binaryPath}: ${error.message}`));
    });
    child.once("close", (code, signal) => {
      if (this.child !== child) return;
      this.failWorker(child, new Error(
        `GameAlgo Rust runtime exited with ${code ?? "unknown"}${signal ? ` (${signal})` : ""}`,
      ));
    });
  }

  private send(pending: PendingRustRequest, timeoutMs: number): Promise<RustRuntimeResponse> {
    const child = this.child;
    if (!child) return Promise.reject(new Error("GameAlgo Rust runtime worker is unavailable"));
    return new Promise<RustRuntimeResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        const error = new Error(`GameAlgo Rust runtime request exceeded ${timeoutMs}ms`);
        child.kill("SIGKILL");
        this.failWorker(child, error);
      }, timeoutMs);
      this.active = { ...pending, child, timeout, resolve, reject };
      const encoded = `${JSON.stringify(pending.request)}\n`;
      child.stdin.write(encoded, (error) => {
        if (error) this.failWorker(child, error);
      });
    });
  }

  private handleStdout(child: import("node:child_process").ChildProcessWithoutNullStreams, chunk: Buffer): void {
    if (this.child !== child) return;
    this.stdoutBytes += chunk.length;
    if (this.stdoutBytes > 512 * 1024) {
      const error = new Error("GameAlgo Rust runtime response exceeds 524288 bytes");
      child.kill("SIGKILL");
      this.failWorker(child, error);
      return;
    }
    this.stdoutBuffer += chunk.toString("utf8");
    let newlineIndex = this.stdoutBuffer.indexOf("\n");
    while (newlineIndex >= 0) {
      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (!line) {
        newlineIndex = this.stdoutBuffer.indexOf("\n");
        continue;
      }
      if (!this.active) {
        this.failWorker(child, new Error("GameAlgo Rust runtime returned an unsolicited response"));
        return;
      }
      let response: RustRuntimeResponse;
      try {
        response = JSON.parse(line) as RustRuntimeResponse;
      } catch (error) {
        this.failWorker(child, new Error(
          `Invalid GameAlgo Rust runtime response: ${error instanceof Error ? error.message : String(error)}`,
        ));
        return;
      }
      const active = this.active;
      this.active = undefined;
      clearTimeout(active.timeout);
      active.resolve(response);
      newlineIndex = this.stdoutBuffer.indexOf("\n");
    }
  }

  private failWorker(child: import("node:child_process").ChildProcessWithoutNullStreams, error: Error): void {
    if (this.child !== child) return;
    this.child = undefined;
    this.stdoutBuffer = "";
    this.stdoutBytes = 0;
    const active = this.active;
    this.active = undefined;
    if (active) {
      clearTimeout(active.timeout);
      active.reject(error);
    }
  }
}

function defaultRustRuntimeBinaryPath(): string {
  const configured = typeof process !== "undefined" ? clean(process.env.GAMEALGO_SCRIPT_RUNTIME_BIN) : undefined;
  if (configured) return configured;
  const profile = typeof process !== "undefined" && process.env.NODE_ENV === "production" ? "release" : "debug";
  return decodeURIComponent(new URL(`../../runtime/rust/target/${profile}/gamealgo-script-runtime`, import.meta.url).pathname);
}


function clean(value: string | undefined): string | undefined { return value?.trim() || undefined; }
function normalizeJsonValue(value: unknown): JsonValue { return JSON.parse(JSON.stringify(value)) as JsonValue; }
