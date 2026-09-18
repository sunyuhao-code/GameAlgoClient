extends RefCounted

## Minimal durable JSON capability. Games provide the platform-specific adapter.

const STATUS_LOADED := "loaded"
const STATUS_MISSING := "missing"
const STATUS_ERROR := "error"


func load_json_result(_key: String) -> Dictionary:
	return {"status": STATUS_ERROR, "value": null}


func save_json(_key: String, _value: Variant) -> bool:
	return false


func remove(_key: String) -> bool:
	return false
