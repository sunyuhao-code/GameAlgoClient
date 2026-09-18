extends SceneTree

## Contracts for the GameAlgoRuntime GDExtension.
##
## These deliberately assert the same expected values as the Rust unit tests in
## runtime/rust/src/lib.rs. The Godot runtime is a binding around that crate, so
## if the two ever disagree, one of the two suites breaks.

const Runtime := preload("res://addons/gamealgo/gamealgo_script_runtime.gd")

const SINGLETON := "GameAlgoRuntime"
## Shared with the Rust suite; read from the real file rather than a copy.
const FIXTURE_PATH := "res://../protocol/fixtures/script-fixture.js"

var _passed := 0
var _failed := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("GameAlgo Godot runtime contracts")
	if not Engine.has_singleton(SINGLETON):
		push_error("GameAlgoRuntime singleton is not registered")
		print("FAILED: GameAlgoRuntime singleton is not registered")
		quit(1)
		return
	var native: Object = Engine.get_singleton(SINGLETON)
	_test_shared_fixture(native)
	_test_sandbox_has_no_host_capabilities(native)
	_test_indirect_constructors_blocked(native)
	_test_input_is_frozen(native)
	_test_freeze_survives_tampered_intrinsics(native)
	_test_budgets_are_enforced(native)
	_test_error_envelopes(native)
	_test_prepared_scripts_are_evicted(native)
	_test_sdk_wrapper_uses_the_runtime()
	print("RESULT: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_shared_fixture(native: Object) -> void:
	var source := _read_fixture()
	_check(not source.is_empty(), "shared script fixture is readable")
	if source.is_empty():
		return
	_check(native.call("prepare", "fixture", source), "shared fixture prepares")
	var input := JSON.stringify({"config": {"level": 2}, "state": {}, "meta": {}})
	# Compared as raw JSON on purpose. Godot's JSON parser widens every number to
	# float, so a parsed comparison could not tell 2 from 2.0 — but the wire form
	# is what has to match the Rust runtime, byte for byte.
	var first_raw := String(native.call("execute_json", "fixture", input))
	var second_raw := String(native.call("execute_json", "fixture", input))
	_check(
		first_raw == '{"result":{"diagnostics":{"fixture":true},"payload":{"level":2}},"status":"ok"}',
		"shared fixture produces the same result as the Rust runtime"
	)
	_check(first_raw == second_raw, "repeated execution is deterministic")
	_check(String(_envelope(native, "fixture", input).get("status", "")) == "ok", "shared fixture executes")


func _test_sandbox_has_no_host_capabilities(native: Object) -> void:
	var script := """function execute() { return { payload: {
	  process: typeof process,
	  require: typeof require,
	  fetch: typeof fetch,
	  eval: typeof eval,
	  Function: typeof Function,
	  Date: typeof Date,
	  random: typeof Math.random,
	  performance: typeof performance
	}}; }"""
	_check(native.call("prepare", "sandbox", script), "sandbox probe prepares")
	var result := _envelope(native, "sandbox", "{}")
	var payload: Variant = result.get("result", {}).get("payload", {})
	_check(
		payload == {
			"process": "undefined", "require": "undefined", "fetch": "undefined",
			"eval": "undefined", "Function": "undefined", "Date": "undefined",
			"random": "undefined", "performance": "undefined",
		},
		"no host, clock, randomness or dynamic code is reachable"
	)


func _test_indirect_constructors_blocked(native: Object) -> void:
	var constructors := [
		"(function() {}).constructor",
		"Object.constructor",
		"(async function() {}).constructor",
		"(function*() {}).constructor",
		"(async function*() {}).constructor",
	]
	for index: int in range(constructors.size()):
		var script := "function execute() { const c = %s; return { payload: typeof c }; }" % constructors[index]
		var key := "ctor_%d" % index
		native.call("prepare", key, script)
		var result := _envelope(native, key, "{}")
		_check(
			String(result.get("result", {}).get("payload", "")) == "undefined",
			"indirect constructor is blocked: %s" % constructors[index]
		)


func _test_input_is_frozen(native: Object) -> void:
	var script := """function execute(input) {
	  let mutated = false;
	  try { input.config.level = 99; mutated = input.config.level === 99; } catch (error) { mutated = false; }
	  return { payload: { mutated, level: input.config.level } };
	}"""
	_check(native.call("prepare", "frozen", script), "freeze probe prepares")
	var result := _envelope(native, "frozen", JSON.stringify({"config": {"level": 2}}))
	var payload: Dictionary = result.get("result", {}).get("payload", {})
	_check(not bool(payload.get("mutated", true)), "script input is deeply frozen")
	_check(int(payload.get("level", -1)) == 2, "a frozen input keeps its value")


## A script runs before its input is frozen, so it can replace any global the
## freeze relies on. Mirrors deep_freeze_survives_tampered_intrinsics in
## runtime/rust/src/lib.rs.
func _test_freeze_survives_tampered_intrinsics(native: Object) -> void:
	var tampering := {
		"freeze": "Object.freeze = function (v) { return v; };",
		"keys": "Object.keys = function () { return []; };",
		"iterator": "Array.prototype[Symbol.iterator] = function* () {};",
		"set": "globalThis.Set = function () { throw new Error('denied'); };",
	}
	var combined := ""
	for label: String in tampering:
		combined += String(tampering[label])
	tampering["all"] = combined
	var index := 0
	for label: String in tampering:
		var script := "%s function execute(input) { try { input.nested.value = 99; } catch (error) {} return { value: input.nested.value, frozen: Object.isFrozen(input.nested) }; }" % tampering[label]
		var key := "tamper_%d" % index
		index += 1
		_check(native.call("prepare", key, script), "tampering script prepares: %s" % label)
		var result := _envelope(native, key, JSON.stringify({"nested": {"value": 7}}))
		_check(
			String(result.get("status", "")) == "ok",
			"tampering does not break execution: %s" % label
		)
		var payload: Dictionary = result.get("result", {})
		_check(
			int(payload.get("value", -1)) == 7 and bool(payload.get("frozen", false)),
			"input stays frozen after tampering with %s" % label
		)


func _test_budgets_are_enforced(native: Object) -> void:
	# An unbounded loop must be interrupted rather than hanging the caller.
	_check(native.call("prepare", "spin", "function execute(){ while(true){} }"), "spin prepares")
	var started := Time.get_ticks_msec()
	var spun := _envelope(native, "spin", "{}")
	var elapsed := Time.get_ticks_msec() - started
	_check(String(spun.get("status", "")) == "error", "an unbounded script is refused")
	_check(elapsed < 5000, "the execution budget bounds the call (%d ms)" % elapsed)

	# Output beyond the 256 KiB budget is refused rather than truncated.
	var oversized := "function execute(){ return { payload: 'x'.repeat(300000) }; }"
	native.call("prepare", "oversized", oversized)
	var big := _envelope(native, "oversized", "{}")
	_check(String(big.get("status", "")) == "error", "an oversized output is refused")

	# A script that does not define execute() cannot be prepared.
	_check(
		not native.call("prepare", "no_execute", "const value = 1;"),
		"a script without execute() fails to prepare"
	)


func _test_error_envelopes(native: Object) -> void:
	var unknown := _envelope(native, "never_prepared", "{}")
	_check(String(unknown.get("status", "")) == "error", "an unprepared key is an error")
	_check(not String(unknown.get("message", "")).is_empty(), "the error carries a message")

	native.call("prepare", "echo", "function execute(i){ return i; }")
	var bad_input := _envelope(native, "echo", "{not json")
	_check(String(bad_input.get("status", "")) == "error", "invalid input JSON is an error")

	var thrown := "function execute(){ throw new Error('boom'); }"
	native.call("prepare", "thrown", thrown)
	var failed := _envelope(native, "thrown", "{}")
	_check(String(failed.get("status", "")) == "error", "a throwing script is an error")
	_check(
		not failed.has("result"),
		"a failed execution never carries a result"
	)


func _test_prepared_scripts_are_evicted(native: Object) -> void:
	# Prepared contexts are capped; the oldest is dropped rather than growing
	# without bound. Eviction must not be observable as a wrong answer.
	for index: int in range(6):
		native.call("prepare", "lru_%d" % index, "function execute(){ return { payload: %d }; }" % index)
	var newest := _envelope(native, "lru_5", "{}")
	_check(
		int(newest.get("result", {}).get("payload", -1)) == 5,
		"the most recent script stays prepared"
	)
	_check(
		native.call("has_prepared", "lru_5") and not native.call("has_prepared", "lru_0"),
		"the least recently used script is evicted"
	)
	# Re-preparing an evicted script works and returns its own result.
	native.call("prepare", "lru_0", "function execute(){ return { payload: 0 }; }")
	var revived := _envelope(native, "lru_0", "{}")
	_check(
		int(revived.get("result", {}).get("payload", -1)) == 0,
		"an evicted script can be prepared again"
	)


func _test_sdk_wrapper_uses_the_runtime() -> void:
	# The SDK wrapper resolves the singleton by name and verifies the script hash
	# before running anything. This is the path the game actually takes.
	var runtime: RefCounted = Runtime.new(null, SINGLETON)
	_check(runtime.is_available(), "the SDK wrapper finds the runtime singleton")
	var source := _read_fixture()
	_check(runtime.prepare(source), "the SDK wrapper prepares the shared fixture")
	var result: Dictionary = runtime.execute(source, {"config": {"level": 7}, "state": {}, "meta": {}})
	var payload: Variant = result.get("result", {}).get("payload", {})
	_check(
		payload is Dictionary and int((payload as Dictionary).get("level", -1)) == 7,
		"the SDK wrapper returns the runtime result"
	)
	_check(
		bool(result.get("result", {}).get("diagnostics", {}).get("fixture", false)),
		"the SDK wrapper preserves the whole result document"
	)
	var wrong_hash: Dictionary = runtime.execute(source, {}, "v1", "sha256:" + "0".repeat(64))
	_check(wrong_hash.is_empty(), "a hash mismatch refuses to execute")
	_check(
		String(runtime.last_error) == "script_hash_mismatch",
		"the hash refusal is explicit"
	)


# --- helpers -----------------------------------------------------------------


func _read_fixture() -> String:
	var path := ProjectSettings.globalize_path(FIXTURE_PATH).simplify_path()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("cannot read shared fixture at " + path)
		return ""
	var source := file.get_as_text()
	file.close()
	return source


func _envelope(native: Object, key: String, input_json: String) -> Dictionary:
	var raw: Variant = native.call("execute_json", key, input_json)
	if not raw is String:
		return {}
	var parsed: Variant = JSON.parse_string(String(raw))
	return parsed as Dictionary if parsed is Dictionary else {}


func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		return
	_failed += 1
	push_error("FAILED: " + label)
	print("FAILED: %s" % label)
