extends RefCounted

const GameAlgoUtil := preload("res://addons/gamealgo/gamealgo_util.gd")

var _client: Object
var _key := ""


func _init(client: Object, key: String) -> void:
	_client = client
	_key = key


func is_ready() -> bool:
	return not assignment().is_empty()


func assignment() -> Dictionary:
	if not is_instance_valid(_client) or not _client.has_method("assignment_for_key"):
		return {}
	var result: Variant = _client.call("assignment_for_key", _key)
	return (result as Dictionary).duplicate(true) if result is Dictionary else {}


func variant(default_value: String = "control") -> String:
	var current := assignment()
	return String(current.get("variant", default_value)) if not current.is_empty() else default_value


func config(default_value: Variant = {}) -> Variant:
	var current := assignment()
	return current.get("config", default_value) if not current.is_empty() else default_value


func value(path: String, default_value: Variant = null) -> Variant:
	var current := assignment()
	if current.is_empty():
		return default_value
	return GameAlgoUtil.dictionary_path(current.get("config", null), path, default_value)


func string(path: String, default_value: String = "") -> String:
	var result: Variant = value(path, null)
	return String(result) if result is String else default_value


func integer(path: String, default_value: int = 0) -> int:
	var result: Variant = value(path, null)
	if result is int:
		return int(result)
	if result is float and is_finite(float(result)) and floor(float(result)) == float(result):
		return int(result)
	return default_value


func number(path: String, default_value: float = 0.0) -> float:
	var result: Variant = value(path, null)
	if result is int:
		return float(result)
	if result is float and is_finite(float(result)):
		return float(result)
	return default_value


func boolean(path: String, default_value: bool = false) -> bool:
	var result: Variant = value(path, null)
	return bool(result) if result is bool else default_value


func execute(state: Variant) -> Dictionary:
	var current := assignment()
	if current.is_empty() or not GameAlgoUtil.valid_json_value(state):
		return {}
	if not current.has("script") or current["script"] == null:
		return {
			"payload": current.get("config", null),
			"diagnostics": {"mode": "config-only"},
			"assignment": current.duplicate(true),
		}
	if not is_instance_valid(_client) or not _client.has_method("execute_assignment_script"):
		return {}
	var result: Variant = _client.call(
		"execute_assignment_script", current.duplicate(true), state
	)
	return (result as Dictionary).duplicate(true) if result is Dictionary else {}
