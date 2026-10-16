extends SceneTree

## Integration probe for the real SDK HTTP transport. The Python harness gives
## this script a TLS server that accepts the request and never returns HTTP
## headers, reproducing the iOS watchdog failure without external networking.

const HttpTransport := preload("res://addons/gamealgo/internal/http_transport.gd")

var _last_frame_ms := 0
var _max_frame_gap_ms := 0
var _background_done := false
var _background_response: Dictionary = {}


class TrustedFixtureTransport:
	extends HttpTransport

	var fixture_tls_options: TLSOptions

	func _configure_request(request: HTTPRequest) -> void:
		request.set_tls_options(fixture_tls_options)


func _init() -> void:
	call_deferred("_run")


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if _last_frame_ms > 0:
		_max_frame_gap_ms = maxi(_max_frame_gap_ms, now - _last_frame_ms)
	_last_frame_ms = now
	return false


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		_fail("expected: mode port certificate_path")
		return
	var mode := String(args[0])
	if mode not in ["timeout", "cancel", "destroy", "exit"]:
		_fail("unknown mode: " + mode)
		return
	var certificate := X509Certificate.new()
	var certificate_error := certificate.load(String(args[2]))
	if certificate_error != OK:
		_fail("cannot load fixture certificate: %s" % certificate_error)
		return
	var transport := TrustedFixtureTransport.new()
	transport.fixture_tls_options = TLSOptions.client(certificate)
	root.add_child(transport)
	if transport.use_threads:
		_fail("SDK transport must default to non-threaded HTTPRequest")
		return
	var spec := {
		"url": "https://127.0.0.1:%s/stall" % String(args[1]),
		"method": "GET",
		"headers": {"Accept": "application/json"},
		"timeout_seconds": 1.0,
	}
	_reset_frame_measurement()
	var started := Time.get_ticks_msec()
	match mode:
		"timeout":
			var response: Dictionary = await transport.send(spec)
			var elapsed := Time.get_ticks_msec() - started
			if String(response.get("error", "")) != "transport_%d" % HTTPRequest.RESULT_TIMEOUT:
				_fail("timeout returned: " + JSON.stringify(response))
				return
			if elapsed > 2500:
				_fail("one-second timeout completed after %d ms" % elapsed)
				return
			if _max_frame_gap_ms > 500:
				_fail("main loop froze for %d ms" % _max_frame_gap_ms)
				return
			_pass(mode, elapsed)
		"cancel":
			create_timer(0.2).timeout.connect(transport.cancel_requests)
			var response: Dictionary = await transport.send(spec)
			var elapsed := Time.get_ticks_msec() - started
			if String(response.get("error", "")) != "request_cancelled":
				_fail("cancel returned: " + JSON.stringify(response))
				return
			if elapsed > 1500 or _max_frame_gap_ms > 500:
				_fail("cancel blocked: elapsed=%d gap=%d" % [elapsed, _max_frame_gap_ms])
				return
			_pass(mode, elapsed)
		"destroy":
			_send_background(transport, spec)
			await create_timer(0.2).timeout
			transport.queue_free()
			var deadline := Time.get_ticks_msec() + 1500
			while not _background_done and Time.get_ticks_msec() < deadline:
				await process_frame
			var elapsed := Time.get_ticks_msec() - started
			if not _background_done \
					or String(_background_response.get("error", "")) != "request_cancelled":
				_fail("destroy did not settle the pending request")
				return
			if elapsed > 1700 or _max_frame_gap_ms > 500:
				_fail("destroy blocked: elapsed=%d gap=%d" % [elapsed, _max_frame_gap_ms])
				return
			_pass(mode, elapsed)
		"exit":
			_send_background(transport, spec)
			await create_timer(0.2).timeout
			print("HTTP_TRANSPORT_EXIT_READY")
			quit(0)


func _send_background(transport: Node, spec: Dictionary) -> void:
	_background_response = await transport.send(spec)
	_background_done = true


func _reset_frame_measurement() -> void:
	_last_frame_ms = Time.get_ticks_msec()
	_max_frame_gap_ms = 0


func _pass(mode: String, elapsed_ms: int) -> void:
	print("HTTP_TRANSPORT_RESULT ", JSON.stringify({
		"mode": mode,
		"elapsed_ms": elapsed_ms,
		"max_frame_gap_ms": _max_frame_gap_ms,
	}))
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("HTTP_TRANSPORT_FAILED ", message)
	quit(1)
