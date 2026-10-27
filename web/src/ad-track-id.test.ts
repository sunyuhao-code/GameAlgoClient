import assert from "node:assert/strict";
import test from "node:test";

import { extractAdTrackId } from "./index.ts";

test("ad track IDs are extracted from TapTap callback fields without changing the original ID", () => {
  const original = "  opaque+/=track_id  ";
  const callbacks = [
    { trackId: original },
    { track_id: original },
    { isEnded: true, extra: JSON.stringify({ trackId: original }) },
    { isEnded: false, extra: JSON.stringify({ track_id: original }) },
    { success: false, msg: JSON.stringify({ trackId: original }) },
    { message: JSON.stringify({ track_id: original }) },
    { extra: { trackId: original } },
    { msg: { track_id: original } },
    { message: { trackId: original } },
  ];
  for (const callback of callbacks) assert.equal(extractAdTrackId(callback), original);
  assert.equal(extractAdTrackId({ trackId: "direct", extra: { trackId: "nested" } }), "direct");
});

test("missing and malformed ad track IDs are safe and do not block valid fallback fields", () => {
  const invalidCallbacks = [
    undefined, null, false, 42, "not an object", [], [{ trackId: "array" }], {},
    { trackId: "", track_id: "  " },
    { trackId: 123, extra: "invalid JSON", msg: null },
    { extra: "null", msg: "[]", message: '"string"' },
    { extra: { trackId: false }, msg: { track_id: {} } },
  ];
  for (const callback of invalidCallbacks) assert.equal(extractAdTrackId(callback), undefined);
  assert.equal(extractAdTrackId({ trackId: " ", track_id: "alias" }), "alias");
  assert.equal(extractAdTrackId({ trackId: 123, extra: { trackId: "extra" } }), "extra");
  assert.equal(extractAdTrackId({ extra: "invalid JSON", msg: '{"trackId":"msg"}' }), "msg");
  assert.equal(extractAdTrackId({ msg: "plain message", message: { track_id: "message" } }), "message");
});
