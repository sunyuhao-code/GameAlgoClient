@tool
extends EditorPlugin

class AndroidLifecycleExport:
	extends EditorExportPlugin

	func _get_name() -> String:
		return "GameAlgoAndroidLifecycle"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(["res://addons/gamealgo/runtime/android/gamealgo-lifecycle.aar"])

var _export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	_export_plugin = AndroidLifecycleExport.new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null
