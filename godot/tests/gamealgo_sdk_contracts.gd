extends SceneTree

## Protocol v1 contracts for the Godot SDK.
##
## These pin the wire shape, not game behavior: what the SDK puts on the wire,
## which platforms it accepts, and where it fails closed. A protocol change that
## lands in the other SDKs but not here should break one of these.

const Client := preload("res://addons/gamealgo/gamealgo_client.gd")
const Tracker := preload("res://addons/gamealgo/gamealgo_tracker.gd")
const Util := preload("res://addons/gamealgo/gamealgo_util.gd")
const Executor := preload("res://addons/gamealgo/gamealgo_executor.gd")
const Runtime := preload("res://addons/gamealgo/gamealgo_script_runtime.gd")

const BASE_URL := "https://gamealgo.example/api"
const GAME_KEY := "ga_live_fixture"

var _passed := 0
var _failed := 0


class MemoryStore:
	extends RefCounted

	var values: Dictionary = {}

	func load_json_result(key: String) -> Dictionary:
		if not values.has(key):
			return {"status": "missing", "value": null}
		var value: Variant = values[key]
		return {
			"status": "loaded",
			"value": value.duplicate(true) if value is Dictionary or value is Array else value,
		}

	func save_json(key: String, value: Variant) -> bool:
		values[key] = value.duplicate(true) if value is Dictionary or value is Array else value
		return true

	func remove(key: String) -> bool:
		values.erase(key)
		return true


class TransportFixture:
	extends RefCounted

	var requests: Array[Dictionary] = []
	var experiments: Array = []
	var config_files: Array = []
	var accepted_override := -1
	var config_calls := 0
	var attribution_ok := true
	var events_ok := true
	var identifiers_ok := true
	var attribution_hash_override := ""

	func send(spec: Dictionary) -> Dictionary:
		requests.append(spec.duplicate(true))
		var url := String(spec.get("url", ""))
		if url.ends_with("/v1/attribution"):
			if not attribution_ok:
				return {
					"ok": false, "status": 503, "headers": {},
					"body": PackedByteArray(), "error": "http_503",
				}
			var sent: Variant = JSON.parse_string(String(spec.get("body", "")))
			var echoed := String(sent.get("attributionHash", "")) if sent is Dictionary else ""
			return _json({
				"ok": true,
				"accepted": 1,
				"attributionHash": attribution_hash_override if not attribution_hash_override.is_empty() else echoed,
			})
		if url.ends_with("/v1/context-identifiers"):
			if not identifiers_ok:
				return {
					"ok": false, "status": 404, "headers": {},
					"body": PackedByteArray(), "error": "http_404",
				}
			return _json({"ok": true, "accepted": 1})
		if url.ends_with("/v1/diagnostics/sdk"):
			return _json({"ok": true, "accepted": 1})
		if url.ends_with("/v1/config"):
			config_calls += 1
			return _json({
				"contextId": "context-1",
				"gameId": "fixture",
				"environment": "live",
				"configVersion": "config-1",
				"ttlSeconds": 60,
				"serverTime": "2026-01-01T00:00:00.000Z",
				"experiments": experiments.duplicate(true),
				"configFiles": config_files.duplicate(true),
			})
		if url.ends_with("/v1/events/batch"):
			if not events_ok:
				return {
					"ok": false, "status": 503, "headers": {},
					"body": PackedByteArray(), "error": "http_503",
				}
			var parsed: Variant = JSON.parse_string(String(spec.get("body", "")))
			var events: Array = parsed.get("events", []) if parsed is Dictionary else []
			var accepted := accepted_override if accepted_override >= 0 else events.size()
			return _json({"ok": true, "accepted": accepted})
		if url.contains("/v1/config-files/"):
			return {
				"ok": true,
				"status": 200,
				"headers": {"content-type": "application/json"},
				"body": "{}".to_utf8_buffer(),
				"error": "",
			}
		return {"ok": false, "status": 404, "headers": {}, "body": PackedByteArray(), "error": "http_404"}

	func bodies_for(suffix: String) -> Array:
		var out: Array = []
		for request: Dictionary in requests:
			if String(request.get("url", "")).ends_with(suffix):
				var parsed: Variant = JSON.parse_string(String(request.get("body", "")))
				if parsed is Dictionary:
					out.append(parsed)
		return out

	func _json(value: Dictionary) -> Dictionary:
		return {
			"ok": true,
			"status": 200,
			"headers": {"content-type": "application/json"},
			"body": JSON.stringify(value).to_utf8_buffer(),
			"error": "",
		}


class FailingStore:
	extends MemoryStore

	var refuse_saves := false

	func save_json(key: String, value: Variant) -> bool:
		if refuse_saves:
			return false
		return super.save_json(key, value)


class UnavailableRuntime:
	extends RefCounted

	## Mirrors the shape the client requires without a working native runtime.

	func prepare(_script: String, _version_id: String = "", _hash: String = "") -> bool:
		return false

	func execute(
		_script: String, _input: Variant, _version_id: String = "", _hash: String = ""
	) -> Dictionary:
		return {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("GameAlgo Godot SDK Protocol v1 contracts")
	_test_platform_allowlist()
	_test_base_url_and_key_validation()
	await _test_config_request_envelope()
	await _test_event_envelope_and_batching()
	await _test_queue_limit_drops_oldest_silently()
	await _test_cross_origin_rejected()
	await _test_executor_typed_reads()
	await _test_script_runtime_fails_closed()
	await _test_custom_event_quota()
	await _test_quota_buckets_follow_the_context()
	await _test_quota_diagnostic_is_reported_once()
	await _test_milestone_deduplication()
	await _test_milestone_survives_restart()
	await _test_attribution_upload_and_ack()
	await _test_attribution_status_normalization()
	await _test_context_identifiers()
	await _test_observability()
	await _test_automatic_idfv()
	await _test_idfv_does_not_steal_last_error()
	print("RESULT: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


# --- contracts ---------------------------------------------------------------


func _test_platform_allowlist() -> void:
	# The wire value is the running OS, never the engine. Keep this list in step
	# with the platform enum in protocol/openapi.yaml.
	_check(
		Client.ALLOWED_PLATFORMS == ["android", "ios"],
		"only the two mobile platforms are accepted"
	)
	for platform: String in Client.ALLOWED_PLATFORMS:
		var client := _make_client({"platform": platform})
		_check(client != null, "platform %s accepted" % platform)
		if client != null:
			client.free()
	# Desktop exports are refused locally rather than sending a value the server
	# rejects with 400.
	for platform: String in ["web", "maker", "godot", "macos", "windows", "linux", ""]:
		var rejected := _configure_result({"platform": platform})
		_check(
			not rejected["ok"] and rejected["error"] == "invalid_platform",
			"platform %s rejected" % ("<empty>" if platform.is_empty() else platform)
		)
	# Case is normalized rather than rejected, so a caller passing OS.get_name()
	# verbatim still lands on a protocol value.
	_check(_configure_result({"platform": "IOS"})["ok"], "platform case is normalized")


func _test_base_url_and_key_validation() -> void:
	for base_url: String in [
		"http://gamealgo.example/api",
		"https://127.0.0.1/api",
		"https://gamealgo.example/api?token=x",
		"https://user@gamealgo.example/api",
	]:
		var result := _configure_result({"base_url": base_url})
		_check(
			not result["ok"] and result["error"] == "invalid_base_url",
			"base URL rejected: %s" % base_url
		)
	var bad_key := _configure_result({"game_key": "ga_admin_fixture"})
	_check(not bad_key["ok"], "admin key rejected as client key")
	var blank_key := _configure_result({"game_key": "ga_live_bad key"})
	_check(not blank_key["ok"], "game key with whitespace rejected")


func _test_config_request_envelope() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport, "app_version": "1.2.3"})
	if client == null:
		_check(false, "config envelope fixture configured")
		return
	await client.refresh(true)
	var bodies := transport.bodies_for("/v1/config")
	_check(bodies.size() == 1, "one /v1/config request issued")
	if bodies.is_empty():
		client.free()
		return
	var body: Dictionary = bodies[0]
	for field: String in [
		"userId", "sessionId", "platform", "sdkVersion", "appVersion",
		"experimentIntegrationVersion", "userCreatedAt", "userCreatedLocalAt",
		"createdLocalAt", "timezone", "device", "isDebug",
	]:
		_check(body.has(field), "/v1/config carries %s" % field)
	_check(body.get("platform", "") == "ios", "/v1/config reports the configured platform")
	_check(body.get("appVersion", "") == "1.2.3", "/v1/config reports the app version")
	_check(
		int(body.get("experimentIntegrationVersion", 0)) == 7,
		"/v1/config reports the pinned integration version"
	)
	var device: Variant = body.get("device", {})
	_check(device is Dictionary, "device context is an object")
	if device is Dictionary:
		# The engine is reported here so it never occupies the platform dimension.
		_check(device.get("runtime", "") == "godot", "device.runtime identifies the engine")
		_check(String(device.get("godotVersion", "")) != "", "device.godotVersion is populated")
	var headers: Dictionary = transport.requests[0].get("headers", {})
	_check(headers.get("X-GameAlgo-Key", "") == GAME_KEY, "every request carries X-GameAlgo-Key")
	_check(headers.get("Content-Type", "") == "application/json", "config POST is JSON")
	client.free()


func _test_event_envelope_and_batching() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport, "event_max_batch_size": 3})
	if client == null:
		_check(false, "event envelope fixture configured")
		return
	await client.refresh(true)
	for index: int in range(5):
		client.tracker.track("level_end", {"level": index})
	# track() starts an automatic flush once a batch fills, so drain both that
	# upload and whatever is left before asserting.
	for _frame: int in range(4):
		await process_frame
	await client.tracker.flush()
	var bodies := transport.bodies_for("/v1/events/batch")
	_check(not bodies.is_empty(), "events are uploaded")
	if bodies.is_empty():
		client.free()
		return
	var oversized := 0
	var uploaded := 0
	for batch: Dictionary in bodies:
		var events: Array = batch.get("events", [])
		uploaded += events.size()
		if events.size() > 3:
			oversized += 1
	_check(oversized == 0, "no batch exceeds the configured batch size")
	_check(uploaded == 5, "every tracked event is uploaded exactly once")
	var first: Array = bodies[0].get("events", [])
	var event: Dictionary = first[0] if first.size() > 0 else {}
	for field: String in [
		"eventId", "contextId", "userId", "sessionId", "eventType",
		"timestamp", "createdLocalAt", "isDebug", "payload",
	]:
		_check(event.has(field), "event carries %s" % field)
	_check(String(event.get("contextId", "")) == "context-1", "queued events bind the live context")
	_check(String(event.get("eventType", "")) == "level_end", "standard event type is not prefixed")
	var ids: Dictionary = {}
	for batch: Dictionary in bodies:
		for queued: Dictionary in batch.get("events", []):
			ids[String(queued.get("eventId", ""))] = true
	_check(ids.size() == 5, "every event gets a distinct eventId")
	client.free()


func _test_queue_limit_drops_oldest_silently() -> void:
	# The queue is a ring and the quota is a separate, earlier gate. Within quota
	# the oldest events are discarded to bound memory, exactly as the other SDKs
	# do. Quota refusals are covered by the custom event quota contracts.
	var transport := TransportFixture.new()
	# The effective limit is max(queue_limit, max_batch_size), and no refresh runs
	# here so there is no context to bind: flush refuses and the queue stays put.
	var client := _make_client({
		"transport": transport,
		"event_queue_limit": 4,
		"event_max_batch_size": 4,
	})
	if client == null:
		_check(false, "queue limit fixture configured")
		return
	var accepted := 0
	for index: int in range(10):
		if client.tracker.track("custom_probe", {"index": index}):
			accepted += 1
	_check(accepted == 10, "track() accepts every event past the queue limit")
	_check(client.tracker.pending_count() == 4, "queue is capped at the configured limit")
	var pending: Array[Dictionary] = client.tracker.pending_events_for_testing()
	var first_index := int(pending[0].get("payload", {}).get("index", -1)) if pending.size() > 0 else -1
	_check(first_index == 6, "the oldest events are the ones discarded")
	client.free()


func _test_cross_origin_rejected() -> void:
	var transport := TransportFixture.new()
	transport.experiments = [_script_assignment("https://evil.example/v1/config-files/dda.js")]
	var client := _make_client({
		"transport": transport,
		"preload_config_files": "all",
		"script_runtime": UnavailableRuntime.new(),
	})
	if client == null:
		_check(false, "cross origin fixture configured")
		return
	await client.refresh(true)
	for request: Dictionary in transport.requests:
		_check(
			not String(request.get("url", "")).begins_with("https://evil.example"),
			"a script URL on another origin never reaches the transport"
		)
	_check(client.status == "degraded", "a refused script leaves the client degraded, not ready")
	# A config file name is a name, never a URL, so it cannot smuggle an origin.
	var by_name: Dictionary = await client.fetch_config_file("https://evil.example/x.json")
	_check(by_name.is_empty(), "a URL passed as a config file name is refused")
	_check(
		String(client.last_error) == "invalid_config_file_name",
		"config file names are validated as names"
	)
	client.free()


func _test_executor_typed_reads() -> void:
	var transport := TransportFixture.new()
	transport.experiments = [{
		"key": "level_dda",
		"experimentId": "dda-1",
		"variant": "treatment",
		"config": {
			"enabled": true,
			"bias": 2,
			"rate": 0.5,
			"pacing": "flat",
			"nested": {"depth": 3},
		},
		"script": null,
	}]
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "executor fixture configured")
		return
	await client.refresh(true)
	var executor: Executor = client.executor("level_dda")
	_check(executor.is_ready(), "assigned key is ready")
	_check(executor.variant("control") == "treatment", "variant is read from the assignment")
	_check(executor.boolean("enabled", false), "boolean config value")
	_check(executor.integer("bias", 0) == 2, "integer config value")
	_check(is_equal_approx(executor.number("rate", 0.0), 0.5), "number config value")
	_check(executor.string("pacing", "") == "flat", "string config value")
	_check(executor.integer("nested.depth", 0) == 3, "dotted path reads nested config")
	_check(executor.integer("missing.path", 42) == 42, "missing path falls back to the default")
	var absent: Executor = client.executor("not_assigned")
	_check(not absent.is_ready(), "unassigned key is not ready")
	_check(absent.variant("control") == "control", "unassigned key returns the local default")
	_check(absent.integer("bias", 9) == 9, "unassigned key never invents a value")
	client.free()


func _test_script_runtime_fails_closed() -> void:
	var transport := TransportFixture.new()
	transport.experiments = [_script_assignment("%s/v1/config-files/dda.js" % BASE_URL)]
	var client := _make_client({
		"transport": transport,
		"preload_config_files": "all",
		"script_runtime": UnavailableRuntime.new(),
	})
	if client == null:
		_check(false, "fail-closed fixture configured")
		return
	await client.refresh(true)
	var executor: Executor = client.executor("level_dda")
	var decision: Dictionary = await executor.execute({"turn": 1})
	_check(decision.is_empty(), "no decision is invented when the runtime cannot prepare")
	_check(
		not client.assignment_script_ready(executor.assignment()),
		"script-backed assignment reports itself not ready"
	)
	# Config-only reads stay available even though the script cannot run.
	_check(executor.boolean("enabled", false), "config-only values survive a dead runtime")
	# A runtime that is simply absent behaves the same way.
	var bare := Runtime.new()
	_check(not bare.is_available(), "runtime without a native singleton is unavailable")
	_check(not bare.prepare("function execute(i){return i}"), "prepare fails closed")
	_check(bare.execute("function execute(i){return i}", {}).is_empty(), "execute fails closed")
	client.free()


# --- helpers -----------------------------------------------------------------


func _test_custom_event_quota() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "quota fixture configured")
		return
	await client.refresh(true)
	var tracker: RefCounted = client.tracker

	# Standard semantic events are exempt.
	var standard_refused := 0
	for index: int in range(1200):
		if not tracker.track("level_end", {"level": index}):
			standard_refused += 1
	_check(standard_refused == 0, "standard events are never charged against the quota")

	# Per event type: 1,000 accepted, then refused.
	var accepted := 0
	for index: int in range(1001):
		if tracker.track("custom_probe", {"index": index}):
			accepted += 1
	_check(accepted == 1000, "a custom event type is capped at 1,000 per context")
	_check(not tracker.track("custom_probe", {}), "the refusal is reported to the caller")
	_check(tracker.track("custom_other", {}), "a different event type is unaffected")

	# Distinct event types: 100 accepted, then refused.
	var distinct := _make_client({"transport": TransportFixture.new()})
	await distinct.refresh(true)
	for index: int in range(100):
		distinct.tracker.track("type_%d" % index, {})
	_check(
		not distinct.tracker.track("type_overflow", {}),
		"a context is capped at 100 distinct custom event types"
	)
	_check(distinct.tracker.track("type_7", {}), "an already-seen type still fits")
	distinct.free()

	# Per context total: 5,000 across types.
	var total := _make_client({"transport": TransportFixture.new()})
	await total.refresh(true)
	for type_index: int in range(5):
		for index: int in range(1000):
			total.tracker.track("bulk_%d" % type_index, {})
	_check(not total.tracker.track("bulk_last", {}), "a context is capped at 5,000 custom events")
	_check(total.tracker.track("level_start", {}), "standard events still pass a full context")
	total.free()
	client.free()


func _test_quota_buckets_follow_the_context() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "quota bucket fixture configured")
		return
	var tracker: RefCounted = client.tracker

	# Charged before a context exists, so they land in the pending bucket.
	for index: int in range(600):
		tracker.track("early_probe", {"index": index})
	await client.refresh(true)
	# The pending usage moved with the events, so only 400 of this type remain.
	var after_context := 0
	for index: int in range(500):
		if tracker.track("early_probe", {"index": index}):
			after_context += 1
	_check(after_context == 400, "pending quota usage follows the events onto the context")

	# A new session discards its unbound events, and their usage with them.
	client.new_session()
	var fresh := 0
	for index: int in range(20):
		if tracker.track("session_probe", {"index": index}):
			fresh += 1
	_check(fresh == 20, "a new session starts from a clean pending bucket")
	client.free()


func _test_quota_diagnostic_is_reported_once() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "quota diagnostic fixture configured")
		return
	await client.refresh(true)
	for index: int in range(1005):
		client.tracker.track("diag_probe", {"index": index})
	for _frame: int in range(4):
		await process_frame
	var diagnostics := transport.bodies_for("/v1/diagnostics/sdk")
	_check(diagnostics.size() == 1, "repeated refusals report one diagnostic per scope")
	if diagnostics.is_empty():
		client.free()
		return
	var report: Dictionary = diagnostics[0]
	_check(String(report.get("stage", "")) == "event_guard", "diagnostic names the guard stage")
	_check(
		String(report.get("reasonCode", "")) == "custom_event_quota_exceeded",
		"diagnostic carries the quota reason code"
	)
	_check(String(report.get("status", "")) == "degraded", "diagnostic reports degraded, not failed")
	_check(
		String(report.get("reasonDetail", "")).contains("scope=context_event_type"),
		"diagnostic names the scope that was exceeded"
	)
	_check(String(report.get("contextId", "")) == "context-1", "diagnostic binds the live context")
	_check(String(report.get("platform", "")) == "ios", "diagnostic reports the platform")
	client.free()


func _test_milestone_deduplication() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({
		"transport": transport,
		"user_created_at": "2026-01-01T00:00:00.000Z",
	})
	if client == null:
		_check(false, "milestone fixture configured")
		return
	await client.refresh(true)
	var tracker: RefCounted = client.tracker

	_check(
		tracker.track("milestone", {"milestoneType": "new_user", "milestonePoint": "第一关"}),
		"a milestone is reported the first time"
	)
	_check(
		not tracker.track("milestone", {"milestoneType": "new_user", "milestonePoint": "第一关"}),
		"the same milestone is refused the second time"
	)
	_check(
		tracker.track("milestone", {"milestoneType": "new_user", "milestonePoint": "第二关"}),
		"a different milestone point still reports"
	)
	_check(
		tracker.track("milestone", {"milestoneType": "retention", "milestonePoint": "第一关"}),
		"a different milestone type still reports"
	)
	# Without both fields there is nothing to deduplicate on, so it passes through.
	_check(tracker.track("milestone", {"milestoneType": "new_user"}), "an incomplete milestone passes")
	_check(tracker.track("milestone", {"milestoneType": "new_user"}), "and is not deduplicated")

	# The SDK owns the elapsed time; a caller-supplied value is replaced.
	tracker.track("milestone", {
		"milestoneType": "spoof", "milestonePoint": "p", "elapsedSinceRegistrationMs": -5,
	})
	await tracker.flush()
	var milestones: Array = []
	for batch: Dictionary in transport.bodies_for("/v1/events/batch"):
		for event: Dictionary in batch.get("events", []):
			if String(event.get("eventType", "")) == "milestone":
				milestones.append(event)
	# 7 tracked, 1 refused as a duplicate.
	_check(milestones.size() == 6, "only the accepted milestones reach the wire")
	var spoofed: Dictionary = {}
	for event: Dictionary in milestones:
		if String(event.get("payload", {}).get("milestoneType", "")) == "spoof":
			spoofed = event
	_check(not spoofed.is_empty(), "the elapsed-time milestone was uploaded")
	if not spoofed.is_empty():
		var elapsed: Variant = spoofed.get("payload", {}).get("elapsedSinceRegistrationMs", null)
		_check(elapsed is int or elapsed is float, "elapsedSinceRegistrationMs is stamped by the SDK")
		_check(float(elapsed) > 0.0, "a caller-supplied elapsed value is replaced, not trusted")
	client.free()


func _test_milestone_survives_restart() -> void:
	var storage := MemoryStore.new()
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport, "storage": storage})
	if client == null:
		_check(false, "milestone persistence fixture configured")
		return
	await client.refresh(true)
	_check(
		client.tracker.track("milestone", {"milestoneType": "new_user", "milestonePoint": "第一关"}),
		"milestone reported before the restart"
	)
	client.free()

	# Same storage, new client: the milestone must not be reported again.
	var restarted := _make_client({"transport": TransportFixture.new(), "storage": storage})
	await restarted.refresh(true)
	_check(
		not restarted.tracker.track(
			"milestone", {"milestoneType": "new_user", "milestonePoint": "第一关"}
		),
		"a reached milestone survives a restart"
	)
	_check(
		restarted.tracker.track("milestone", {"milestoneType": "new_user", "milestonePoint": "第三关"}),
		"an unreached milestone is unaffected by the restored cache"
	)
	restarted.free()

	# A milestone reached before the context exists becomes durable once its
	# event binds, so it is not reported again after a restart either.
	var pending_storage := MemoryStore.new()
	var pending := _make_client({"transport": TransportFixture.new(), "storage": pending_storage})
	_check(
		pending.tracker.track("milestone", {"milestoneType": "early", "milestonePoint": "p"}),
		"a milestone before the context is reported"
	)
	_check(
		not pending.tracker.track("milestone", {"milestoneType": "early", "milestonePoint": "p"}),
		"and is deduplicated within the session"
	)
	await pending.refresh(true)
	pending.free()
	var after_bind := _make_client({
		"transport": TransportFixture.new(), "storage": pending_storage,
	})
	await after_bind.refresh(true)
	_check(
		not after_bind.tracker.track("milestone", {"milestoneType": "early", "milestonePoint": "p"}),
		"a milestone bound to a context becomes durable"
	)
	after_bind.free()

	# A new session releases only the milestones that never bound to a context.
	var session_client := _make_client({"transport": TransportFixture.new()})
	_check(
		session_client.tracker.track("milestone", {"milestoneType": "loose", "milestonePoint": "p"}),
		"an unbound milestone is reported"
	)
	session_client.new_session()
	_check(
		session_client.tracker.track("milestone", {"milestoneType": "loose", "milestonePoint": "p"}),
		"a new session releases unbound milestones with their discarded events"
	)
	session_client.free()


func _test_attribution_upload_and_ack() -> void:
	var transport := TransportFixture.new()
	var storage := MemoryStore.new()
	var client := _make_client({"transport": transport, "storage": storage})
	if client == null:
		_check(false, "attribution fixture configured")
		return
	await client.refresh(true)

	var first: Dictionary = await client.set_attribution("adjust", {
		"network": "Google Ads", "campaign": "launch_cn",
	})
	_check(bool(first.get("ok", false)), "attribution upload succeeds")
	_check(int(first.get("accepted", 0)) == 1, "attribution reports the accepted count")
	var bodies := transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 1, "one attribution request issued")
	if bodies.is_empty():
		client.free()
		return
	var body: Dictionary = bodies[0]
	for field: String in [
		"userId", "userCreatedAt", "sessionId", "contextId", "platform",
		"provider", "status", "attribution", "attributionHash",
	]:
		_check(body.has(field), "/v1/attribution carries %s" % field)
	_check(String(body.get("provider", "")) == "adjust", "provider is reported")
	_check(String(body.get("contextId", "")) == "context-1", "attribution binds the live context")
	_check(
		String(body.get("attributionHash", "")).begins_with("sha256:"),
		"attributionHash uses the protocol form"
	)

	# The same attribution is not uploaded twice.
	var repeat: Dictionary = await client.set_attribution("adjust", {
		"network": "Google Ads", "campaign": "launch_cn",
	})
	_check(bool(repeat.get("ok", false)), "a repeated attribution still reports success")
	_check(int(repeat.get("accepted", 0)) == 0, "a repeated attribution accepts nothing")
	_check(
		transport.bodies_for("/v1/attribution").size() == 1,
		"an unchanged attribution is not re-uploaded"
	)

	# A changed attribution is uploaded again.
	await client.set_attribution("adjust", {"network": "Google Ads", "campaign": "retarget_cn"})
	_check(
		transport.bodies_for("/v1/attribution").size() == 2,
		"a changed attribution is uploaded"
	)

	# A different provider is tracked separately.
	await client.set_attribution("appsflyer", {"network": "Google Ads", "campaign": "launch_cn"})
	_check(
		transport.bodies_for("/v1/attribution").size() == 3,
		"each provider keeps its own acknowledged hash"
	)
	client.free()

	# A failed upload is not acknowledged, so the next call retries it.
	var failing := TransportFixture.new()
	failing.attribution_ok = false
	var retry_client := _make_client({"transport": failing, "storage": MemoryStore.new()})
	await retry_client.refresh(true)
	var failed: Dictionary = await retry_client.set_attribution("adjust", {"network": "Organic"})
	_check(not bool(failed.get("ok", true)), "a failed attribution upload reports failure")
	failing.attribution_ok = true
	await retry_client.set_attribution("adjust", {"network": "Organic"})
	_check(
		failing.bodies_for("/v1/attribution").size() == 2,
		"a failed attribution is retried rather than acknowledged"
	)
	retry_client.free()


func _test_attribution_status_normalization() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "attribution status fixture configured")
		return
	await client.refresh(true)
	# Adjust spells organic and unknown through several fields; they must not be
	# reported as real networks.
	await client.set_attribution("adjust", {"network": "Organic"})
	await client.set_attribution("adjust", {"network": "unattributed"})
	await client.set_attribution("adjust", {"trackerName": "Unknown"})
	await client.set_attribution("adjust", {"network": "Google Ads"})
	await client.set_attribution("other", {"network": "Organic"})
	var statuses: Array = []
	for body: Dictionary in transport.bodies_for("/v1/attribution"):
		statuses.append(String(body.get("status", "")))
	_check(statuses.size() == 5, "each distinct attribution is uploaded")
	if statuses.size() == 5:
		_check(statuses[0] == "organic", "an organic network reports organic")
		_check(statuses[1] == "unknown", "unattributed reports unknown")
		_check(statuses[2] == "unknown", "an unknown tracker name reports unknown")
		_check(statuses[3] == "attributed", "a real network reports attributed")
		_check(statuses[4] == "attributed", "only adjust gets the field-level folding")
	client.free()


func _test_context_identifiers() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport})
	if client == null:
		_check(false, "identifier fixture configured")
		return

	# Without a context there is nothing to map the identifier onto.
	var early: Dictionary = await client.set_adjust_adid("adid-1")
	_check(not bool(early.get("ok", true)), "an identifier before the context is refused")
	_check(
		String(early.get("error", "")) == "context_not_ready",
		"the refusal names the missing context"
	)

	await client.refresh(true)
	var result: Dictionary = await client.set_adjust_adid("adid-1")
	_check(bool(result.get("ok", false)), "adjust adid is uploaded")
	await client.set_firebase_app_instance_id("fid-1")
	await client.set_google_advertising_id("11111111-2222-3333-4444-555555555555")
	await client.set_idfa("00000000-0000-0000-0000-000000000000")
	await client.set_google_advertising_id(null)

	var bodies := transport.bodies_for("/v1/context-identifiers")
	_check(bodies.size() == 5, "each identifier is reported separately")
	if bodies.size() < 5:
		client.free()
		return
	for field: String in [
		"userId", "sessionId", "contextId", "platform",
		"identifierType", "identifierValue", "observedAt", "identifierHash",
	]:
		_check(bodies[0].has(field), "/v1/context-identifiers carries %s" % field)
	var types: Array = []
	for body: Dictionary in bodies:
		types.append(String(body.get("identifierType", "")))
	_check(
		types == ["adjust_adid", "firebase_app_instance_id", "gaid", "idfa", "gaid"],
		"identifier types match the protocol enum"
	)
	_check(
		String(bodies[0].get("identifierHash", "")).begins_with("sha256:"),
		"identifierHash uses the protocol form"
	)
	_check(bodies[3].get("identifierValue", "") == null, "a zeroed IDFA is reported as cleared")
	_check(bodies[4].get("identifierValue", "") == null, "a null identifier clears the mapping")
	_check(
		String(bodies[2].get("identifierValue", "")) == "11111111-2222-3333-4444-555555555555",
		"a real advertising id is reported verbatim"
	)
	client.free()


## Matches the iOS SDK, which reports IDFV once after the startup config fetch.
## Godot surfaces the same value through OS.get_unique_id() on iOS.
func _test_automatic_idfv() -> void:
	# The test host is macOS, so start() cannot exercise the real iOS path. Drive
	# the reporter directly with platform=ios to cover the decisions it makes.
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport, "platform": "ios"})
	if client == null:
		_check(false, "idfv fixture configured")
		return
	await client.refresh(true)
	await client._report_identifier_for_vendor()
	var bodies := transport.bodies_for("/v1/context-identifiers")
	_check(bodies.size() == 1, "idfv is reported once after startup")
	if not bodies.is_empty():
		_check(
			String(bodies[0].get("identifierType", "")) == "idfv",
			"the automatic report uses the idfv identifier type"
		)
		_check(
			String(bodies[0].get("contextId", "")) == "context-1",
			"the automatic report binds the live context"
		)
	# Once per startup, never on every call.
	await client._report_identifier_for_vendor()
	_check(
		transport.bodies_for("/v1/context-identifiers").size() == 1,
		"idfv is not reported again within the same startup"
	)
	client.free()

	# Android and desktop have no vendor identifier to report.
	var android_transport := TransportFixture.new()
	var android := _make_client({"transport": android_transport, "platform": "android"})
	await android.refresh(true)
	await android._report_identifier_for_vendor()
	_check(
		android_transport.bodies_for("/v1/context-identifiers").is_empty(),
		"idfv is never reported off iOS"
	)
	android.free()

	# IDFV needs no ATT authorization, measurement consent governs events here,
	# and the manual identifier setters do not consult it either, so neither does
	# this. The iOS SDK reports it unconditionally as well.
	var denied_transport := TransportFixture.new()
	var denied := _make_client({
		"transport": denied_transport,
		"platform": "ios",
		"measurement_allowed": false,
		"measurement_resolved": true,
	})
	await denied.refresh(true)
	await denied._report_identifier_for_vendor()
	_check(
		denied_transport.bodies_for("/v1/context-identifiers").size() == 1,
		"idfv does not depend on measurement consent"
	)
	denied.free()


## The automatic report is fire-and-forget from start(). It must not write to
## last_error, which belongs to whatever the caller was doing: a host reads
## status and last_error together right after start() to explain a degraded
## startup, and an IDFV result would replace that reason with its own.
func _test_idfv_does_not_steal_last_error() -> void:
	# A storage that refuses to persist leaves start() degraded with a reason.
	var failing := FailingStore.new()
	var transport := TransportFixture.new()
	transport.identifiers_ok = false
	var client := _make_client({
		"transport": transport, "platform": "ios", "storage": failing,
	})
	if client == null:
		_check(false, "last_error fixture configured")
		return
	failing.refuse_saves = true
	await client.start()
	# The report is detached, so let it finish before reading last_error; the
	# point is that it never writes there, not that it loses a race.
	for _frame: int in range(4):
		await process_frame
	_check(client.status == "degraded", "a snapshot persistence failure is degraded")
	_check(
		String(client.last_error) == "snapshot_persistence_failed",
		"a failed idfv report does not replace the startup failure reason"
	)
	client.free()

	# The success path is the quieter half: it would clear last_error outright.
	var ok_storage := FailingStore.new()
	var ok_transport := TransportFixture.new()
	var succeeding := _make_client({
		"transport": ok_transport, "platform": "ios", "storage": ok_storage,
	})
	ok_storage.refuse_saves = true
	await succeeding.start()
	for _frame: int in range(4):
		await process_frame
	_check(
		String(succeeding.last_error) == "snapshot_persistence_failed",
		"a successful idfv report does not clear the startup failure reason"
	)
	# The manual setters still own last_error.
	var manual: Dictionary = await succeeding.set_adjust_adid("adid-1")
	_check(bool(manual.get("ok", false)), "a manual identifier call still succeeds")
	_check(String(succeeding.last_error) == "", "a manual identifier call still clears last_error")
	succeeding.free()


## Godot redirects stdio on iOS, so print() never reaches the console there. The
## signal and the injectable sink are the only ways an iOS host sees anything,
## and a failed event upload has to be as observable as a failed config fetch.
func _test_observability() -> void:
	var transport := TransportFixture.new()
	transport.experiments = [{
		"key": "level_dda", "experimentId": "dda-1", "variant": "treatment",
		"config": {"enabled": true}, "script": null,
	}]
	var lines: Array[String] = []
	var signalled: Array[String] = []
	var client := _make_client({
		"transport": transport,
		"logger": func(message: String) -> void: lines.append(message),
	})
	if client == null:
		_check(false, "observability fixture configured")
		return
	# configure() already logged, and the signal can only be connected afterwards,
	# so compare from here on.
	var before_connect := lines.size()
	client.sdk_log.connect(func(message: String) -> void: signalled.append(message))
	var failures: Array[String] = []
	client.request_failed.connect(func(code: String) -> void: failures.append(code))

	await client.refresh(true)
	_check(not lines.is_empty(), "the injected logger receives SDK lines")
	_check(
		lines.all(func(line: String) -> bool: return line.begins_with("[GameAlgoSDK] ")),
		"every line carries the SDK prefix"
	)
	_check(
		lines.any(func(line: String) -> bool: return line.contains("config fetched")),
		"a successful config fetch is logged"
	)
	_check(
		lines.any(func(line: String) -> bool: return line.contains("assignment:")),
		"assignments are logged"
	)

	# The signal must carry everything the sink does, because on iOS it is the
	# only one that works.
	_check(
		signalled.size() == lines.size() - before_connect and not signalled.is_empty(),
		"sdk_log mirrors the injected logger"
	)

	# A failed event upload emits request_failed, like a failed config fetch.
	transport.events_ok = false
	client.tracker.track("level_end", {"level": 1})
	await client.tracker.flush()
	_check(
		failures.has("http_503"),
		"a failed event upload emits request_failed"
	)
	_check(
		lines.any(func(line: String) -> bool: return line.contains("event upload failed")),
		"a failed event upload is logged"
	)
	_check(
		lines.any(func(line: String) -> bool: return line.contains("flush failed")),
		"the held queue depth is logged on a failed flush"
	)
	client.free()

	# logger = null silences the sink but never the signal.
	var quiet_transport := TransportFixture.new()
	var quiet_signals: Array[String] = []
	var quiet := _make_client({"transport": quiet_transport, "logger": null})
	quiet.sdk_log.connect(func(message: String) -> void: quiet_signals.append(message))
	await quiet.refresh(true)
	_check(not quiet_signals.is_empty(), "sdk_log still fires with the logger disabled")
	quiet.free()

	_check(
		not _configure_result({"logger": "not a callable"})["ok"],
		"a non-callable logger is rejected"
	)


func _script_assignment(url: String) -> Dictionary:
	return {
		"key": "level_dda",
		"experimentId": "dda-1",
		"variant": "treatment",
		"config": {"enabled": true},
		"script": {
			"versionId": "v1",
			"name": "dda.js",
			"url": url,
			"hash": "sha256:" + "0".repeat(64),
		},
	}


func _default_options() -> Dictionary:
	return {
		"game_key": GAME_KEY,
		"base_url": BASE_URL,
		"platform": "ios",
		"experiment_integration_version": 7,
		"storage": MemoryStore.new(),
		"measurement_allowed": true,
		"measurement_resolved": true,
		"preload_config_files": [],
	}


func _configure_result(overrides: Dictionary) -> Dictionary:
	var client: Node = Client.new()
	root.add_child(client)
	var options := _default_options()
	options.merge(overrides, true)
	var ok: Variant = client.configure(options)
	var error := String(client.last_error)
	client.free()
	return {"ok": ok is bool and bool(ok), "error": error}


func _make_client(overrides: Dictionary) -> Node:
	var client: Node = Client.new()
	root.add_child(client)
	var options := _default_options()
	options.merge(overrides, true)
	if not client.configure(options):
		push_error("configure failed: " + String(client.last_error))
		client.free()
		return null
	return client


func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		return
	_failed += 1
	push_error("FAILED: " + label)
	print("FAILED: %s" % label)
