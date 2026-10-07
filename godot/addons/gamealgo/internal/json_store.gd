extends RefCounted

## Minimal durable JSON capability. Games provide the platform-specific adapter.
## save_json must atomically replace one key: true confirms the supplied value
## is committed for process-restart recovery; false preserves the previous value.
## A write followed by a failed durability check cannot report false while leaving
## the new value readable, because callers may retry a rejected event admission.

const STATUS_LOADED := "loaded"
const STATUS_MISSING := "missing"
const STATUS_ERROR := "error"


func load_json_result(_key: String) -> Dictionary:
	return {"status": STATUS_ERROR, "value": null}


func save_json(_key: String, _value: Variant) -> bool:
	return false


func remove(_key: String) -> bool:
	return false
