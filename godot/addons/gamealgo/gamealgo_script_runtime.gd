extends RefCounted

const GameAlgoUtil := preload("res://addons/gamealgo/gamealgo_util.gd")
const AVAILABILITY_METHOD := "is_available"
const PREPARE_METHOD := "prepare"
const HAS_PREPARED_METHOD := "has_prepared"
const EXECUTE_METHOD := "execute_json"
const HASH_PREFIX := "sha256:"

var last_error := ""
var _native: Variant
var _prepared_keys: Dictionary = {}


func _init(native_override: Variant = null, native_singleton: String = "") -> void:
	if native_override != null:
		_native = native_override
	elif not native_singleton.is_empty() and Engine.has_singleton(native_singleton):
		_native = Engine.get_singleton(native_singleton)


func is_available() -> bool:
	if not _native is Object or not _native.has_method(AVAILABILITY_METHOD) \
			or not _native.has_method(PREPARE_METHOD) \
			or not _native.has_method(HAS_PREPARED_METHOD) \
			or not _native.has_method(EXECUTE_METHOD):
		return false
	var available: Variant = _native.call(AVAILABILITY_METHOD)
	return available is bool and bool(available)


func prepare(script: String, version_id: String = "", expected_hash: String = "") -> bool:
	if not is_available():
		last_error = "native_runtime_unavailable"
		return false
	var script_key := _script_key(script, version_id, expected_hash)
	if script_key.is_empty():
		last_error = "script_hash_mismatch"
		return false
	var accepted: Variant = _native.call(PREPARE_METHOD, script_key, script)
	if not accepted is bool or not bool(accepted):
		_prepared_keys.erase(script_key)
		last_error = "script_prepare_failed"
		return false
	_prepared_keys[script_key] = true
	last_error = ""
	return true


func execute(
	script: String,
	input: Variant,
	version_id: String = "",
	expected_hash: String = ""
) -> Dictionary:
	if not is_available() or not GameAlgoUtil.valid_json_value(input):
		last_error = "native_runtime_unavailable" if not is_available() else "invalid_input"
		return {}
	var script_key := _script_key(script, version_id, expected_hash)
	if script_key.is_empty():
		last_error = "script_hash_mismatch"
		return {}
	var native_prepared: Variant = _native.call(HAS_PREPARED_METHOD, script_key) \
			if bool(_prepared_keys.get(script_key, false)) else false
	if not native_prepared is bool or not bool(native_prepared):
		_prepared_keys.erase(script_key)
		if not prepare(script, version_id, expected_hash):
			return {}
	var raw: Variant = _native.call(
		EXECUTE_METHOD, script_key, GameAlgoUtil.canonical_json(input)
	)
	if not raw is String:
		last_error = "invalid_native_result"
		return {}
	var parsed: Variant = JSON.parse_string(String(raw))
	if not parsed is Dictionary or String(parsed.get("status", "")) not in ["ok", "error"]:
		last_error = "invalid_native_result"
		return {}
	if String(parsed["status"]) != "ok":
		last_error = String(parsed.get("message", "script_execution_failed"))
		return (parsed as Dictionary).duplicate(true)
	if not parsed.has("result") or not GameAlgoUtil.valid_json_value(parsed["result"]):
		last_error = "invalid_native_result"
		return {}
	last_error = ""
	return (parsed as Dictionary).duplicate(true)


func _script_key(script: String, version_id: String = "", expected_hash: String = "") -> String:
	var actual_hash := GameAlgoUtil.sha256_text(script)
	if not expected_hash.is_empty() and expected_hash.to_lower() != actual_hash:
		return ""
	if version_id.is_empty():
		return actual_hash.trim_prefix(HASH_PREFIX)
	return GameAlgoUtil.sha256_text(version_id + "\n" + actual_hash).trim_prefix(HASH_PREFIX)
