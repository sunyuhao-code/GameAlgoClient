extends Node

## Off-main-thread UTF-8 and JSON decoder for bounded HTTP response bodies.
## Worker callables touch only copied value data and a mutex-protected result;
## SceneTree and business state remain on the calling thread.

const DEFAULT_BODY_LIMIT_BYTES := 2 * 1024 * 1024
const ABSOLUTE_BODY_LIMIT_BYTES := 10 * 1024 * 1024
const ROOT_ANY := 0
const ROOT_DICTIONARY := 1
const ROOT_ARRAY := 2
const DEFAULT_MAX_CONCURRENT_TASKS := 2

var max_concurrent_tasks := DEFAULT_MAX_CONCURRENT_TASKS
var _active_tasks := 0


class DecodeJob:
	extends RefCounted

	var _mutex := Mutex.new()
	var _result: Dictionary = {}

	func run(bytes: PackedByteArray, required_root: int) -> void:
		var result := _decode(bytes, required_root)
		_mutex.lock()
		_result = result
		_mutex.unlock()

	func take_result() -> Dictionary:
		_mutex.lock()
		var result := _result
		_mutex.unlock()
		return result

	static func _decode(bytes: PackedByteArray, required_root: int) -> Dictionary:
		if not _valid_utf8(bytes):
			return {"ok": false, "value": null, "error": "invalid_utf8"}
		var text := bytes.get_string_from_utf8()
		var parser := JSON.new()
		if parser.parse(text) != OK:
			return {"ok": false, "value": null, "error": "invalid_json"}
		var value: Variant = parser.data
		if required_root == ROOT_DICTIONARY and not value is Dictionary:
			return {"ok": false, "value": null, "error": "invalid_json_root"}
		if required_root == ROOT_ARRAY and not value is Array:
			return {"ok": false, "value": null, "error": "invalid_json_root"}
		return {"ok": true, "value": value, "error": ""}

	static func _valid_utf8(bytes: PackedByteArray) -> bool:
		var index := 0
		while index < bytes.size():
			var first := int(bytes[index])
			if first <= 0x7f:
				index += 1
				continue
			if first >= 0xc2 and first <= 0xdf:
				if index + 1 >= bytes.size() or not _continuation(bytes[index + 1]):
					return false
				index += 2
				continue
			if first >= 0xe0 and first <= 0xef:
				if index + 2 >= bytes.size() or not _continuation(bytes[index + 2]):
					return false
				var second := int(bytes[index + 1])
				if first == 0xe0 and (second < 0xa0 or second > 0xbf):
					return false
				if first == 0xed and (second < 0x80 or second > 0x9f):
					return false
				if first not in [0xe0, 0xed] and not _continuation(second):
					return false
				index += 3
				continue
			if first >= 0xf0 and first <= 0xf4:
				if index + 3 >= bytes.size() or not _continuation(bytes[index + 2]) \
						or not _continuation(bytes[index + 3]):
					return false
				var second := int(bytes[index + 1])
				if first == 0xf0 and (second < 0x90 or second > 0xbf):
					return false
				if first == 0xf4 and (second < 0x80 or second > 0x8f):
					return false
				if first not in [0xf0, 0xf4] and not _continuation(second):
					return false
				index += 4
				continue
			return false
		return true

	static func _continuation(value: int) -> bool:
		return value >= 0x80 and value <= 0xbf


func decode(
	body: PackedByteArray,
	required_root: int = ROOT_ANY,
	body_limit_bytes: int = DEFAULT_BODY_LIMIT_BYTES
) -> Dictionary:
	if required_root not in [ROOT_ANY, ROOT_DICTIONARY, ROOT_ARRAY]:
		return _failure("invalid_root_requirement")
	var effective_limit := clampi(body_limit_bytes, 1, ABSOLUTE_BODY_LIMIT_BYTES)
	if body.size() > effective_limit:
		return _failure("body_too_large")
	if not is_inside_tree():
		return _failure("decoder_unavailable")
	# Keep the scheduler alive for an accepted task even if this reusable node is
	# temporarily removed or reparented while the worker is running.
	var scheduler := get_tree()
	while _active_tasks >= clampi(max_concurrent_tasks, 1, 8):
		await scheduler.process_frame
		if not is_inside_tree():
			return _failure("decoder_unavailable")
	_active_tasks += 1
	var job := DecodeJob.new()
	var task_id := WorkerThreadPool.add_task(
		job.run.bind(body.duplicate(), required_root), false, "GameAlgo JSON decode"
	)
	# Always yield at least one frame. Even a tiny response must never turn the
	# worker handoff into an immediate main-thread wait.
	await scheduler.process_frame
	while not WorkerThreadPool.is_task_completed(task_id):
		await scheduler.process_frame
	# The completion query is true before collecting the task, so this wait only
	# retires an already-finished job and cannot consume the caller's frame budget.
	var wait_error: Variant = WorkerThreadPool.wait_for_task_completion(task_id)
	_active_tasks -= 1
	if wait_error != OK:
		return _failure("worker_failed")
	return job.take_result()


func decode_dictionary(
	body: PackedByteArray,
	body_limit_bytes: int = DEFAULT_BODY_LIMIT_BYTES
) -> Dictionary:
	return await decode(body, ROOT_DICTIONARY, body_limit_bytes)


func active_task_count() -> int:
	return _active_tasks


func _failure(code: String) -> Dictionary:
	return {"ok": false, "value": null, "error": code}
