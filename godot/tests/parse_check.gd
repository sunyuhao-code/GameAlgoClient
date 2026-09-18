extends SceneTree

## Fails closed if any SDK script does not compile or its dependencies do not resolve.

const SCRIPTS := [
	"res://addons/gamealgo/gamealgo_client.gd",
	"res://addons/gamealgo/gamealgo_tracker.gd",
	"res://addons/gamealgo/gamealgo_util.gd",
	"res://addons/gamealgo/gamealgo_executor.gd",
	"res://addons/gamealgo/gamealgo_script_runtime.gd",
	"res://addons/gamealgo/internal/http_transport.gd",
	"res://addons/gamealgo/internal/async_json_decoder.gd",
	"res://addons/gamealgo/internal/json_store.gd",
]


func _init() -> void:
	var failed := 0
	for path: String in SCRIPTS:
		var script: Variant = load(path)
		if script == null or not script is GDScript:
			push_error("failed to load " + path)
			failed += 1
			continue
		if not (script as GDScript).can_instantiate():
			push_error("cannot instantiate " + path)
			failed += 1
	if failed > 0:
		push_error("parse_check failed: %d script(s)" % failed)
		quit(1)
		return
	print("parse_check ok: %d scripts" % SCRIPTS.size())
	quit(0)
