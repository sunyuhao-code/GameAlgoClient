extends Node

## Shared HTTPS transport. This node owns SceneTree-facing HTTPRequest objects;
## response decoding and business validation intentionally live elsewhere.

const DEFAULT_TIMEOUT_SECONDS := 15.0
const DEFAULT_BODY_LIMIT_BYTES := 2 * 1024 * 1024
const ABSOLUTE_BODY_LIMIT_BYTES := 10 * 1024 * 1024

var timeout_seconds := DEFAULT_TIMEOUT_SECONDS
var body_limit_bytes := DEFAULT_BODY_LIMIT_BYTES
# Godot 4.7.x can synchronously join the HTTP worker from the main thread when
# a threaded request times out. If the worker is blocked in a TLS read, this
# freezes the SceneTree and can make iOS terminate the app with 0x8BADF00D.
# Non-threaded HTTPRequest still advances asynchronously from the SceneTree,
# but its socket polling and cancellation never wait for a worker to exit.
var use_threads := false

var _active_requests: Dictionary = {}


class PendingRequest:
	extends RefCounted

	signal finished(response: Dictionary, completed: bool)

	var completed := false

	func complete(response: Dictionary) -> void:
		if completed:
			return
		completed = true
		finished.emit(response, true)


func send(spec: Dictionary) -> Dictionary:
	var url_value: Variant = spec.get("url", "")
	var method_value: Variant = spec.get("method", "GET")
	var headers_value: Variant = spec.get("headers", {})
	var body_value: Variant = spec.get("body", "")
	if not url_value is String or not method_value is String \
			or not headers_value is Dictionary \
			or not (body_value is String or body_value is PackedByteArray):
		return _failure("invalid_request")
	var url := String(url_value).strip_edges()
	var method_name := String(method_value).strip_edges().to_upper()
	if not url.begins_with("https://"):
		return _failure("invalid_request")
	var method := _method(method_name)
	if method < 0:
		return _failure("invalid_method")
	var header_lines := PackedStringArray()
	for raw_name: Variant in headers_value:
		if not raw_name is String or not headers_value[raw_name] is String:
			return _failure("invalid_headers")
		var name := String(raw_name)
		var value := String(headers_value[raw_name])
		if not _valid_header_name(name) or not _valid_header_value(value):
			return _failure("invalid_headers")
		header_lines.append("%s: %s" % [name, value])
	var timeout_value: Variant = spec.get("timeout_seconds", timeout_seconds)
	var limit_value: Variant = spec.get("body_limit_bytes", body_limit_bytes)
	if not (timeout_value is int or timeout_value is float) \
			or not is_finite(float(timeout_value)) or float(timeout_value) <= 0.0 \
			or not limit_value is int or int(limit_value) <= 0 \
			or int(limit_value) > ABSOLUTE_BODY_LIMIT_BYTES:
		return _failure("invalid_request")
	var request := HTTPRequest.new()
	request.timeout = float(timeout_value)
	request.download_chunk_size = 65_536
	request.body_size_limit = int(limit_value)
	request.max_redirects = 0
	request.use_threads = use_threads
	_configure_request(request)
	add_child(request)
	var pending := PendingRequest.new()
	_active_requests[request] = pending
	request.request_completed.connect(
		_on_request_completed.bind(request, pending), CONNECT_ONE_SHOT
	)
	var start_error := OK
	if body_value is PackedByteArray:
		start_error = request.request_raw(url, header_lines, method, body_value)
	else:
		start_error = request.request(url, header_lines, method, String(body_value))
	if start_error != OK:
		_active_requests.erase(request)
		request.queue_free()
		return _failure("request_start_failed")
	var completion: Array = await pending.finished
	if completion.size() != 2 or not completion[0] is Dictionary:
		return _failure("invalid_transport_result")
	return completion[0]


func cancel_requests() -> void:
	# Duplicate the keys because completing a request removes it from the live
	# map. PendingRequest makes cancellation and a same-frame network callback
	# idempotent, so callers can safely cancel during shutdown.
	for request_value: Variant in _active_requests.keys():
		var request := request_value as HTTPRequest
		var pending_value: Variant = _active_requests.get(request)
		_active_requests.erase(request)
		if is_instance_valid(request):
			request.cancel_request()
			request.queue_free()
		if pending_value is PendingRequest:
			(pending_value as PendingRequest).complete(_failure("request_cancelled"))


func _exit_tree() -> void:
	cancel_requests()


func _on_request_completed(
	result_code: int,
	status_code: int,
	response_headers: PackedStringArray,
	response_body: PackedByteArray,
	request: HTTPRequest,
	pending: PendingRequest
) -> void:
	if not _active_requests.has(request):
		return
	_active_requests.erase(request)
	request.queue_free()
	pending.complete(_response(
		result_code, status_code, response_headers, response_body
	))


func _response(
	result_code: int,
	status_code: int,
	response_headers: PackedStringArray,
	response_body: PackedByteArray
) -> Dictionary:
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {
			"ok": false,
			"status": status_code,
			"headers": _headers(response_headers),
			"body": response_body,
			"error": "transport_%d" % result_code,
		}
	return {
		"ok": status_code >= 200 and status_code < 300,
		"status": status_code,
		"headers": _headers(response_headers),
		"body": response_body,
		"error": "" if status_code >= 200 and status_code < 300 else "http_%d" % status_code,
	}


## Overridden only by the TLS fixture in the transport integration test. The
## production SDK always uses Godot's default certificate validation.
func _configure_request(_request: HTTPRequest) -> void:
	pass


func _method(name: String) -> int:
	match name:
		"GET": return HTTPClient.METHOD_GET
		"HEAD": return HTTPClient.METHOD_HEAD
		"POST": return HTTPClient.METHOD_POST
		"PUT": return HTTPClient.METHOD_PUT
		"DELETE": return HTTPClient.METHOD_DELETE
		"PATCH": return HTTPClient.METHOD_PATCH
		_: return -1


func _headers(lines: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for line: String in lines:
		var separator := line.find(":")
		if separator <= 0:
			continue
		var name := line.substr(0, separator).strip_edges().to_lower()
		var value := line.substr(separator + 1).strip_edges()
		if not result.has(name):
			result[name] = value
		elif result[name] is Array:
			result[name].append(value)
		else:
			result[name] = [result[name], value]
	return result


func _valid_header_name(name: String) -> bool:
	if name.is_empty():
		return false
	const TOKEN_PUNCTUATION := "!#$%&'*+-.^_`|~"
	for index: int in name.length():
		var code := name.unicode_at(index)
		if not (code >= 48 and code <= 57) and not (code >= 65 and code <= 90) \
				and not (code >= 97 and code <= 122) \
				and not TOKEN_PUNCTUATION.contains(name.substr(index, 1)):
			return false
	return true


func _valid_header_value(value: String) -> bool:
	for index: int in value.length():
		var code := value.unicode_at(index)
		if (code < 0x20 and code != 0x09) or code == 0x7f:
			return false
	return true


func _failure(code: String) -> Dictionary:
	return {
		"ok": false,
		"status": 0,
		"headers": {},
		"body": PackedByteArray(),
		"error": code,
	}
