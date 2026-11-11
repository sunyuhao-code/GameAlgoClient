import { runQuickJSSandbox, type BrowserScriptOperation } from "./quickjs-sandbox.ts";
import type { GameAlgoScriptInput, JsonValue } from "../../rest-api/src/types.ts";

type ScriptWorkerRequest = {
  id: number;
  operation: BrowserScriptOperation;
  script: string;
  input?: GameAlgoScriptInput;
  timeoutMs: number;
};

type ScriptWorkerResponse = {
  id: number;
  ok: boolean;
  result?: JsonValue;
  error?: string;
};

const workerScope = globalThis as unknown as {
  onmessage: ((event: MessageEvent<ScriptWorkerRequest>) => void) | null;
  postMessage(message: ScriptWorkerResponse): void;
};

workerScope.onmessage = (event) => {
  const request = event.data;
  void runQuickJSSandbox(request.operation, request.script, request.input, {
    scriptBytes: 10 * 1024 * 1024,
    inputBytes: 256 * 1024,
    outputBytes: 256 * 1024,
    memoryBytes: 64 * 1024 * 1024,
    stackBytes: 512 * 1024,
    timeoutMs: request.timeoutMs,
    interruptPolls: 100_000,
  }).then(
    (result) => workerScope.postMessage({ id: request.id, ok: true, result }),
    (error: unknown) => workerScope.postMessage({
      id: request.id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }),
  );
};
