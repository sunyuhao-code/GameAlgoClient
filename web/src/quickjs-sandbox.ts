import { getQuickJS } from "quickjs-emscripten";

import type { GameAlgoScriptInput, JsonValue } from "../../rest-api/src/types.ts";

export type BrowserScriptOperation = "prepare" | "execute";

export type BrowserScriptLimits = {
  scriptBytes: number;
  inputBytes: number;
  outputBytes: number;
  memoryBytes: number;
  stackBytes: number;
  timeoutMs: number;
  interruptPolls: number;
};

export const DEFAULT_BROWSER_SCRIPT_LIMITS: BrowserScriptLimits = {
  scriptBytes: 10 * 1024 * 1024,
  inputBytes: 256 * 1024,
  outputBytes: 256 * 1024,
  memoryBytes: 64 * 1024 * 1024,
  stackBytes: 512 * 1024,
  timeoutMs: 1_000,
  interruptPolls: 100_000,
};

const PRELUDE = String.raw`
  const __gamealgoDisableConstructor = (value) => {
    const prototype = Object.getPrototypeOf(value);
    if (prototype && Object.prototype.hasOwnProperty.call(prototype, "constructor")) {
      Object.defineProperty(prototype, "constructor", {
        value: undefined,
        writable: false,
        configurable: false
      });
    }
  };
  __gamealgoDisableConstructor(function() {});
  __gamealgoDisableConstructor(async function() {});
  __gamealgoDisableConstructor(function*() {});
  __gamealgoDisableConstructor(async function*() {});
  delete globalThis.eval;
  delete globalThis.Function;
  delete globalThis.AsyncFunction;
  delete globalThis.GeneratorFunction;
  delete globalThis.AsyncGeneratorFunction;
  delete globalThis.WebAssembly;
  delete globalThis.Date;
  Object.defineProperty(Math, "random", { value: undefined, writable: false, configurable: false });
  Object.defineProperty(globalThis, "__gamealgoDeepFreeze", {
    value: (value, seen = new Set()) => {
      if (value === null || typeof value !== "object" || seen.has(value)) return value;
      seen.add(value);
      for (const key of Object.keys(value)) __gamealgoDeepFreeze(value[key], seen);
      return Object.freeze(value);
    },
    writable: false,
    configurable: false
  });
`;

/** Execute a strategy in a host-isolated QuickJS context with no browser APIs. */
export async function runQuickJSSandbox(
  operation: BrowserScriptOperation,
  script: string,
  input?: GameAlgoScriptInput,
  limits: BrowserScriptLimits = DEFAULT_BROWSER_SCRIPT_LIMITS,
): Promise<JsonValue> {
  const scriptBytes = utf8Bytes(script);
  if (scriptBytes > limits.scriptBytes) throw new Error(`script exceeds ${limits.scriptBytes} bytes`);

  const inputJson = input === undefined ? "null" : JSON.stringify(input);
  if (utf8Bytes(inputJson) > limits.inputBytes) throw new Error(`input exceeds ${limits.inputBytes} bytes`);

  const QuickJS = await getQuickJS();
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(limits.memoryBytes);
  runtime.setMaxStackSize(limits.stackBytes);
  const deadline = Date.now() + limits.timeoutMs;
  let polls = 0;
  runtime.setInterruptHandler(() => Date.now() >= deadline || ++polls > limits.interruptPolls);
  const context = runtime.newContext();

  try {
    const command = operation === "prepare"
      ? `if (typeof execute !== "function") throw new Error("script must define execute(input)"); "prepared";`
      : `if (typeof execute !== "function") throw new Error("script must define execute(input)");\n`
        + `JSON.stringify(execute(__gamealgoDeepFreeze(JSON.parse(${JSON.stringify(inputJson)}))));`;
    const result = context.evalCode(`${PRELUDE}\n${script}\n;${command}`, "gamealgo-strategy.js");
    if (result.error) {
      const dumped = context.dump(result.error);
      result.error.dispose();
      if (Date.now() >= deadline || polls > limits.interruptPolls) {
        throw new Error("script execution exceeded its resource limit");
      }
      throw new Error(`script execution failed: ${formatQuickJSError(dumped)}`);
    }
    const encoded = context.dump(result.value);
    result.value.dispose();
    if (typeof encoded !== "string") throw new Error("script returned an unsupported value");
    if (utf8Bytes(encoded) > limits.outputBytes) throw new Error(`output exceeds ${limits.outputBytes} bytes`);
    if (operation === "prepare") return { prepared: true };
    return JSON.parse(encoded) as JsonValue;
  } finally {
    context.dispose();
    runtime.dispose();
  }
}

function utf8Bytes(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function formatQuickJSError(value: unknown): string {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const candidate = value as { name?: unknown; message?: unknown };
    const name = typeof candidate.name === "string" ? candidate.name : "Error";
    const message = typeof candidate.message === "string" ? candidate.message : JSON.stringify(value);
    return `${name}: ${message}`;
  }
  return String(value);
}
