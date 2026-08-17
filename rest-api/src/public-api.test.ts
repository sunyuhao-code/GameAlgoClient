import assert from "node:assert/strict";
import test from "node:test";

import * as sdk from "./index.ts";

test("REST public entry exports the canonical Rust runtime", () => {
  assert.equal(typeof sdk.GameAlgoRestClient, "function");
  assert.equal(typeof sdk.RustProcessScriptRuntime, "function");
  assert.equal("FunctionScriptRuntime" in sdk, false);
});
