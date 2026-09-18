extends Node

## Shared HTTPS transport. This node owns SceneTree-facing HTTPRequest objects;
## response decoding and business validation intentionally live elsewhere.

const DEFAULT_TIMEOUT_SECONDS := 15.0
const DEFAULT_BODY_LIMIT_BYTES := 2 * 1024 * 1024
const ABSOLUTE_BODY_LIMIT_BYTES := 10 * 1024 * 1024

var timeout_seconds := DEFAULT_TIMEOUT_SECONDS
var body_limit_bytes := DEFAULT_BODY_LIMIT_BYTES
var use_threads := true


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
	add_child(request)
	var start_error := OK
	if body_value is PackedByteArray:
		start_error = request.request_raw(url, header_lines, method, body_value)
	else:
		start_error = request.request(url, header_lines, method, String(body_value))
	if start_error != OK:
		request.queue_free()
		return _failure("request_start_failed")
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() != 4 or not completed[2] is PackedStringArray \
			or not completed[3] is PackedByteArray:
		return _failure("invalid_transport_result")
	var result_code := int(completed[0])
	var status_code := int(completed[1])
	var response_headers: PackedStringArray = completed[2]
	var response_body: PackedByteArray = completed[3]
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
