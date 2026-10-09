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
	var identifier_response: Dictionary = {"ok": true, "accepted": 1}

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
			return _json(identifier_response)
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


class ImmediateDecoder:
	extends RefCounted

	func decode_dictionary(bytes: PackedByteArray, _limit: int) -> Dictionary:
		return {"ok": true, "value": JSON.parse_string(bytes.get_string_from_utf8())}


class RecoveryTransport:
	extends TransportFixture

	signal released
	var config_ok := true
	var hold_config := false
	var hold_attribution := false
	var hold_events := false
	var held_event_batches: Array = []

	func send(spec: Dictionary) -> Dictionary:
		var url := String(spec.get("url", ""))
		if url.ends_with("/v1/config"):
			requests.append(spec.duplicate(true))
			config_calls += 1
			if hold_config:
				await released
			if not config_ok:
				return {"ok": false, "error": "offline"}
			var body: Dictionary = JSON.parse_string(String(spec["body"]))
			return _json({
				"contextId": "context-" + String(body["sessionId"]),
				"gameId": "fixture", "environment": "live", "configVersion": body["sessionId"],
				"ttlSeconds": 60, "serverTime": "2026-01-01T00:00:00.000Z",
				"experiments": experiments.duplicate(true), "configFiles": [],
			})
		if url.ends_with("/v1/events/batch") and hold_events:
			held_event_batches.append(JSON.parse_string(String(spec["body"]))["events"])
			await released
		if url.ends_with("/v1/attribution") and hold_attribution:
			await released
		return await super.send(spec)


class FailingStore:
	extends MemoryStore

	var refuse_saves := false

	func save_json(key: String, value: Variant) -> bool:
		if refuse_saves:
			return false
		return super.save_json(key, value)


class ConfigSaveFailureStore:
	extends MemoryStore

	var failures_remaining := 1
	var failing_prefix := "config_requests_"

	func save_json(key: String, value: Variant) -> bool:
		if key.begins_with(failing_prefix) and failures_remaining > 0:
			failures_remaining -= 1
			return false
		return super.save_json(key, value)


class RemovalFailureStore:
	extends MemoryStore

	var failures_remaining := 0
	var failing_prefix := ""

	func remove(key: String) -> bool:
		if key.begins_with(failing_prefix) and failures_remaining > 0:
			failures_remaining -= 1
			return false
		return super.remove(key)


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
	await _test_bound_event_admission_survives_restart()
	await _test_event_admission_storage_failure()
	await _test_cached_snapshot_does_not_own_new_session()
	await _test_attribution_and_identifiers_wait_for_matching_context()
	await _test_queue_limit_drops_oldest_silently()
	await _test_queue_limit_across_restarts()
	await _test_queue_limit_restores_oversized_storage()
	await _test_queue_limit_preserves_inflight()
	await _test_queue_limit_mixed_sessions()
	await _test_queue_restore_trim_storage_retry()
	await _test_config_envelope_recovers_first_save_failure()
	await _test_config_envelope_lifecycle_retries_save()
	await _test_config_envelope_waits_for_attribution_save()
	await _test_cross_origin_rejected()
	await _test_executor_typed_reads()
	await _test_script_runtime_fails_closed()
	await _test_custom_event_quota()
	await _test_quota_buckets_follow_the_context()
	await _test_quota_survives_restart()
	await _test_quota_diagnostic_is_reported_once()
	await _test_milestone_deduplication()
	await _test_milestone_survives_restart()
	await _test_attribution_upload_and_ack()
	await _test_attribution_status_normalization()
	await _test_bound_events_bypass_unbound()
	await _test_config_recovery_with_unresolved_measurement()
	await _test_config_binding_storage_failure()
	await _test_config_backoff_bound()
	await _test_config_recovers_without_foreground()
	await _test_unbound_sessions_survive_restart()
	await _test_overlapping_config_sessions()
	await _test_attribution_autonomous_retry()
	await _test_attribution_ack_cleanup_survives_restart()
	await _test_attribution_consent_and_restart()
	await _test_attribution_newer_value_race()
	await _test_attribution_pause_inflight()
	await _test_attribution_revoke_inflight()
	await _test_context_identifiers()
	await _test_malformed_identifier_responses()
	await _test_observability()
	await _test_automatic_idfv()
	await _test_automatic_idfv_after_context_recovery()
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


func _test_bound_event_admission_survives_restart() -> void:
	var storage := MemoryStore.new()
	var client := _bounded_client(storage, RecoveryTransport.new(), "durable-bound", 10)
	await client.start()
	_check(client.tracker.track_ad("banner", "banner", 0.1, "USD"), "bound revenue is accepted durably")
	_check(await client.tracker.track_session_end({}, false), "bound session end is accepted durably before flush")
	var events: Array = client.tracker.pending_events_for_testing()
	_check(storage.values.get("events_" + client._namespace, []) == events, "bound events reach durable storage before track returns")
	client.free()
	var restored := _bounded_client(storage, RecoveryTransport.new(), "durable-restart", 10)
	_check(restored.tracker.pending_events_for_testing() == events, "crash before first flush preserves original bound event IDs and envelopes")
	restored.free()


func _test_event_admission_storage_failure() -> void:
	for bound: bool in [false, true]:
		var storage := FailingStore.new()
		var transport := RecoveryTransport.new()
		transport.config_ok = bound
		transport.events_ok = false
		var client := _bounded_client(storage, transport, "atomic-admission", 3, 3)
		await client.start()
		for index: int in range(3):
			client.tracker.track_ad("banner", "banner", 0.1, "USD", "", {"index": index})
		var before: Array = client.tracker.pending_events_for_testing()
		var event_key: String = "events_" + client._namespace
		var durable_before: Array = storage.values.get(event_key, []).duplicate(true)
		storage.refuse_saves = true
		_check(not client.tracker.track("_admission_probe", {}), "failed persistence truthfully rejects a new event with bound=%s" % bound)
		_check(client.tracker.pending_events_for_testing() == before, "rejected event cannot evict or remain queued with bound=%s" % bound)
		_check(storage.values.get(event_key, []) == durable_before, "failed admission preserves prior durable queue with bound=%s" % bound)
		_check(client.tracker._custom_counts.is_empty(), "rejected event consumes no custom quota")
		_check(not client.tracker.track_milestone("admission", "retry"), "failed milestone persistence rejects admission")
		_check(client.tracker._reached_milestone_keys.is_empty() and client.tracker._pending_milestone_keys.is_empty(), "rejected milestone consumes no dedupe key")
		storage.refuse_saves = false
		_check(client.tracker.track_milestone("admission", "retry"), "same milestone is accepted after storage recovers")
		var after: Array = client.tracker.pending_events_for_testing()
		_check(after.size() == 3 and _event_ids(after).slice(0, 2) == _event_ids(before).slice(1), "successful retry evicts only the oldest prior event")
		_check(storage.values.get(event_key, []) == after, "successful admission commits exactly the bounded live queue")
		client.free()


func _test_cached_snapshot_does_not_own_new_session() -> void:
	var storage := MemoryStore.new()
	var original_transport := RecoveryTransport.new()
	original_transport.experiments = [{"key": "cached_probe", "experimentId": "cached-experiment", "variant": "cached", "config": {"enabled": true}}]
	var original := _bounded_client(storage, original_transport, "cache-old", 10)
	await original.start()
	original.free()
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _bounded_client(storage, transport, "cache-new", 10)
	_check(await client.start(), "cached assignments remain available during offline startup")
	_check(client.executor("cached_probe").variant("missing") == "cached", "cache preserves experiment assignment usability")
	_check(client.tracker.track_ad("banner", "banner", 0.1, "USD"), "cached offline event is accepted")
	var before: Dictionary = client.tracker.pending_events_for_testing()[0]
	_check(before["contextId"] == "" and before["sessionId"] == "cache-new", "cached context never binds events from the new session")
	await client.tracker.flush()
	_check(transport.bodies_for("/v1/events/batch").is_empty(), "cached offline events wait for their own session context")
	transport.config_ok = true
	await client.refresh(true)
	var after: Array = client.tracker.pending_events_for_testing()
	_check(after.size() == 1 and after[0]["contextId"] == "context-cache-new" and after[0]["eventId"] == before["eventId"], "fresh config binds the original cached-start event to its matching session")
	client.free()


func _test_attribution_and_identifiers_wait_for_matching_context() -> void:
	var storage := MemoryStore.new()
	var transport := RecoveryTransport.new()
	var client := _bounded_client(storage, transport, "ownership-old", 10)
	await client.start()
	transport.config_ok = false
	await client.new_session("ownership-pending")
	var result: Dictionary = await client.set_attribution("adjust", {"network": "network-new"})
	_check(result.get("error") == "context_not_ready", "attribution waits while the new session has no matching context")
	_check(transport.bodies_for("/v1/attribution").is_empty(), "old cached context never leaks into new attribution requests")
	var original: Dictionary = client._pending_attributions.get("adjust", {}).duplicate(true)
	_check(original.get("contextId") == "" and original.get("sessionId") == "ownership-pending", "waiting attribution durably retains its original session without a stale context")
	var identifier: Dictionary = await client.set_adjust_adid("adid-new")
	_check(identifier.get("error") == "context_not_ready" and transport.bodies_for("/v1/context-identifiers").is_empty(), "identifier setter refuses a stale context during new-session recovery")
	client.free()
	var recovered_transport := RecoveryTransport.new()
	var recovered := _bounded_client(storage, recovered_transport, "ownership-current", 10)
	await recovered.start()
	recovered._tick_pending_requests(60.0)
	var bodies: Array = recovered_transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 1 and bodies[0]["sessionId"] == "ownership-pending" and bodies[0]["contextId"] == "context-ownership-pending", "historical attribution recovers with its original matching context after restart")
	if bodies.size() == 1:
		for field: String in ["userId", "attributionHash", "attributedAt", "attribution"]:
			_check(bodies[0][field] == original[field], "attribution recovery preserves " + field)
	await recovered.set_adjust_adid("adid-current")
	var identifiers := recovered_transport.bodies_for("/v1/context-identifiers")
	_check(identifiers.size() == 1 and identifiers[0]["sessionId"] == "ownership-current" and identifiers[0]["contextId"] == "context-ownership-current", "identifier uses the current session after historical attribution recovery")
	recovered.free()


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


func _bounded_client(storage: MemoryStore, transport: RecoveryTransport, session: String, limit: int, batch: int = 5) -> Node:
	var client := _make_client({
		"storage": storage, "transport": transport, "session_id": session,
		"json_decoder": ImmediateDecoder.new(), "logger": null, "platform": "android",
		"event_max_batch_size": batch, "event_queue_limit": limit,
	})
	client.set_process(false)
	return client


func _event_ids(events: Array) -> Array:
	return events.map(func(event: Dictionary) -> String: return String(event["eventId"]))


func _test_queue_limit_across_restarts() -> void:
	var storage := MemoryStore.new()
	var accepted_ids: Array = []
	for iteration: int in range(4):
		var transport := RecoveryTransport.new()
		transport.config_ok = false
		var client := _bounded_client(storage, transport, "bounded-%d" % iteration, 5)
		await client.start()
		for event_index: int in range(4):
			_check(client.tracker.track_ad("banner", "banner", 0.1, "USD"), "offline queue accepts newest event within bounded storage policy")
			var pending: Array = client.tracker.pending_events_for_testing()
			accepted_ids.append(pending.back()["eventId"])
			_check(pending.size() <= 5, "total pending count stays bounded across repeated restarts")
		var expected := accepted_ids.slice(maxi(accepted_ids.size() - 5, 0))
		_check(_event_ids(client.tracker.pending_events_for_testing()) == expected, "overflow deterministically retains newest event IDs")
		var persisted: Array = storage.values["events_" + client._namespace]
		_check(_event_ids(persisted) == expected, "disk queue shares the same total cap and event identities")
		var requests: Dictionary = storage.values["config_requests_" + client._namespace]
		_check(requests.size() <= 2, "overflow removes retired config envelopes no longer referenced by events")
		client.free()


func _test_queue_limit_restores_oversized_storage() -> void:
	var storage := MemoryStore.new()
	var offline := RecoveryTransport.new()
	offline.config_ok = false
	var original := _bounded_client(storage, offline, "oversized", 10)
	await original.start()
	for index: int in range(9):
		original.tracker.track_ad("banner", "banner", 0.1, "USD")
	var ids := _event_ids(original.tracker.pending_events_for_testing()).slice(4)
	original.free()
	var restored := _bounded_client(storage, RecoveryTransport.new(), "limited", 5)
	_check(restored.tracker.pending_count() == 5, "restoring a larger legacy queue enforces the configured limit")
	_check(_event_ids(restored.tracker.pending_events_for_testing()) == ids, "restore trimming retains original IDs of newest events")
	_check(_event_ids(storage.values["events_" + restored._namespace]) == ids, "restore trimming reconciles the durable queue")
	restored.free()


func _test_queue_limit_preserves_inflight() -> void:
	var transport := RecoveryTransport.new()
	var client := _bounded_client(MemoryStore.new(), transport, "inflight", 5, 3)
	await client.start()
	transport.hold_events = true
	for index: int in range(3):
		client.tracker.track_ad("banner", "banner", 0.1, "USD")
	var inflight_ids := _event_ids(transport.held_event_batches[0])
	var newest: Array = []
	for index: int in range(4):
		_check(client.tracker.track_ad("banner", "banner", 0.2, "USD"), "new event replaces oldest evictable event behind an in-flight batch")
		newest.append(client.tracker.pending_events_for_testing().back()["eventId"])
		_check(client.tracker.pending_count() <= 5, "in-flight events count toward the total limit")
	_check(_event_ids(client.tracker.pending_events_for_testing()) == inflight_ids + newest.slice(2), "overflow never evicts outstanding event identities")
	transport.events_ok = false
	transport.hold_events = false
	transport.released.emit()
	_check(client.tracker.pending_count() == 5, "failed in-flight batch returns to retry storage within the same cap")
	client.free()

	var full_transport := RecoveryTransport.new()
	var full := _bounded_client(MemoryStore.new(), full_transport, "full-inflight", 3, 3)
	await full.start()
	full_transport.hold_events = true
	for index: int in range(3):
		full.tracker.track_ad("banner", "banner", 0.1, "USD")
	_check(not full.tracker.track_ad("banner", "banner", 0.2, "USD"), "when all capacity is in-flight a new event is truthfully refused")
	_check(full.tracker.pending_count() == 3, "a fully in-flight queue remains bounded")
	full_transport.hold_events = false
	full_transport.released.emit()
	full.free()


func _test_queue_limit_mixed_sessions() -> void:
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	transport.events_ok = false
	var client := _bounded_client(MemoryStore.new(), transport, "mixed-old", 5, 2)
	await client.start()
	for index: int in range(2):
		client.tracker.track_ad("banner", "banner", 0.1, "USD")
	var old_ids := _event_ids(client.tracker.pending_events_for_testing())
	transport.config_ok = true
	await client.new_session("mixed-current")
	var newer_ids: Array = []
	for index: int in range(4):
		client.tracker.track_ad("banner", "banner", 0.2, "USD")
		newer_ids.append(client.tracker.pending_events_for_testing().back()["eventId"])
	_check(_event_ids(client.tracker.pending_events_for_testing()) == [old_ids[1]] + newer_ids, "overflow uses original acceptance order after bound-event retry bypasses older unbound events")
	client.free()


func _test_queue_restore_trim_storage_retry() -> void:
	var storage := FailingStore.new()
	var original := _bounded_client(storage, RecoveryTransport.new(), "trim-original", 10)
	for index: int in range(9):
		original.tracker.track_ad("banner", "banner", 0.1, "USD")
	var ids := _event_ids(original.tracker.pending_events_for_testing()).slice(4)
	original.free()
	var client := _make_client({
		"storage": storage, "transport": RecoveryTransport.new(), "session_id": "trim-retry",
		"json_decoder": ImmediateDecoder.new(), "logger": null, "platform": "android",
		"event_max_batch_size": 5, "event_queue_limit": 5,
		"measurement_allowed": false, "measurement_resolved": false,
	})
	client.set_process(false)
	storage.refuse_saves = true
	_check(not client.set_measurement_allowed(true), "failed trimmed queue persistence keeps restoration unresolved")
	storage.refuse_saves = false
	_check(client.set_measurement_allowed(true), "restoration retries when storage recovers")
	_check(_event_ids(client.tracker.pending_events_for_testing()) == ids, "retrying a failed trim neither duplicates nor loses retained event identities")
	client.free()


func _test_config_envelope_recovers_first_save_failure() -> void:
	var storage := ConfigSaveFailureStore.new()
	var offline := RecoveryTransport.new()
	offline.config_ok = false
	var client := _recovery_client(storage, offline, "save-original")
	await client.start()
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	var expected: Dictionary = client._pending_configs["save-original"].duplicate(true)
	client._process(61.0)
	_check(storage.values.has("config_requests_" + client._namespace), "failed first envelope save is retried before config recovery")
	client.free()
	var online := RecoveryTransport.new()
	var restarted := _recovery_client(storage, online, "save-restarted")
	await restarted.start()
	for index: int in range(3):
		restarted._process(61.0)
	await restarted.tracker.flush()
	_check(online.bodies_for("/v1/config").has(JSON.parse_string(Util.canonical_json(expected))), "storage recovery replays the exact original config envelope")
	_check(restarted.tracker.pending_count() == 0, "one failed envelope write cannot orphan a later durable event")
	restarted.free()


func _test_config_envelope_lifecycle_retries_save() -> void:
	var storage := ConfigSaveFailureStore.new()
	storage.failures_remaining = 100
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _recovery_client(storage, transport, "lifecycle-original")
	var failures: Array = []
	client.request_failed.connect(func(code: String) -> void: failures.append(code))
	await client.start()
	var expected: Dictionary = client._pending_configs["lifecycle-original"].duplicate(true)
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	_check(failures.has("config_request_persistence_failed"), "config-envelope persistence failure is observable")
	storage.failures_remaining = 0
	client._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(storage.values.get("config_requests_" + client._namespace, {}).get("lifecycle-original", {}) == expected, "lifecycle save reconciles the original request without retiming it")
	client.free()


func _test_config_envelope_waits_for_attribution_save() -> void:
	var storage := ConfigSaveFailureStore.new()
	storage.failures_remaining = 0
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _recovery_client(storage, transport, "attr-save-old")
	await client.start()
	await client.set_attribution("adjust", {"network": "paid"})
	transport.config_ok = true
	await client.new_session("attr-save-current")
	storage.failing_prefix = "pending_attribution_"
	storage.failures_remaining = 100
	client._process(61.0)
	client._process(61.0)
	client.free()
	storage.failures_remaining = 0
	var online := RecoveryTransport.new()
	var restarted := _recovery_client(storage, online, "attr-save-restart")
	await restarted.start()
	for index: int in range(4):
		restarted._process(61.0)
	var bodies := online.bodies_for("/v1/attribution")
	_check(bodies.size() == 1 and bodies[0]["contextId"] == "context-attr-save-old", "historical envelope remains until attribution context binding is durable")
	restarted.free()


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

	# A new session uses a separate pending quota bucket.
	client.new_session()
	var fresh := 0
	for index: int in range(20):
		if tracker.track("session_probe", {"index": index}):
			fresh += 1
	_check(fresh == 20, "a new session starts from a clean pending bucket")
	client.free()


func _test_quota_survives_restart() -> void:
	var storage := MemoryStore.new()
	var first := _make_client({
		"storage": storage, "transport": RecoveryTransport.new(),
		"session_id": "quota-restart", "json_decoder": ImmediateDecoder.new(),
		"logger": null, "platform": "android",
	})
	first.set_process(false)
	for index: int in range(600):
		first.tracker.track("restart_probe", {"index": index})
	first.free()

	var restarted := _make_client({
		"storage": storage, "transport": RecoveryTransport.new(),
		"session_id": "quota-restart", "json_decoder": ImmediateDecoder.new(),
		"logger": null, "platform": "android",
	})
	restarted.set_process(false)
	var accepted := 0
	for index: int in range(500):
		if restarted.tracker.track("restart_probe", {"index": index + 600}):
			accepted += 1
	_check(accepted == 400, "restored custom events retain their pending quota usage")
	restarted.free()


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
		tracker.track_milestone("new_user", "第一关", {
			"milestoneType": "ignored", "milestonePoint": "ignored",
		}),
		"a milestone is reported the first time"
	)
	_check(
		not tracker.track_milestone("new_user", "第一关"),
		"the same milestone is refused the second time"
	)
	_check(
		tracker.track_milestone("new_user", "第二关"),
		"a different milestone point still reports"
	)
	_check(
		tracker.track_milestone("retention", "第一关"),
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
	var first_payload: Dictionary = milestones[0].get("payload", {}) if not milestones.is_empty() else {}
	_check(first_payload.get("milestoneType") == "new_user", "track_milestone owns milestoneType")
	_check(first_payload.get("milestonePoint") == "第一关", "track_milestone owns milestonePoint")
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

	# Retained unbound milestones stay deduplicated across sessions.
	var session_client := _make_client({"transport": TransportFixture.new()})
	_check(
		session_client.tracker.track("milestone", {"milestoneType": "loose", "milestonePoint": "p"}),
		"an unbound milestone is reported"
	)
	await session_client.new_session()
	_check(
		not session_client.tracker.track("milestone", {"milestoneType": "loose", "milestonePoint": "p"}),
		"a new session preserves dedupe for retained unbound milestones"
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


func _recovery_client(storage: MemoryStore, transport: RecoveryTransport, session: String) -> Node:
	var client := _make_client({
		"storage": storage, "transport": transport, "session_id": session,
		"json_decoder": ImmediateDecoder.new(), "logger": null, "platform": "android",
	})
	client.set_process(false)
	return client


func _test_bound_events_bypass_unbound() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "old")
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	await client.new_session("new")
	client.tracker.track_ad("banner", "banner", 0.2, "USD")
	await client.tracker.flush()
	var batches := transport.bodies_for("/v1/events/batch")
	_check(batches.size() == 1 and batches[0]["events"].size() == 1 \
		and batches[0]["events"][0]["sessionId"] == "new", "unbound older events do not block bound events")
	_check(client.tracker.pending_count() == 1, "bypassed unbound event remains pending")
	client._process(61.0)
	await client.tracker.flush()
	_check(client.tracker.pending_count() == 0, "bypassed event drains when its own context recovers")
	client.free()


func _test_config_recovery_with_unresolved_measurement() -> void:
	var storage := MemoryStore.new()
	var offline := RecoveryTransport.new()
	offline.config_ok = false
	var original := _recovery_client(storage, offline, "authorized")
	await original.start()
	original.tracker.track_ad("banner", "banner", 0.1, "USD")
	original.free()
	var transport := RecoveryTransport.new()
	var client := _make_client({
		"storage": storage, "transport": transport, "session_id": "pending-consent",
		"json_decoder": ImmediateDecoder.new(), "logger": null, "platform": "android",
		"measurement_allowed": false, "measurement_resolved": false,
	})
	client.set_process(false)
	await client.start()
	client._process(61.0)
	client._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_check(client.set_measurement_allowed(true), "late measurement grant restores retained queue")
	client._process(61.0)
	await client.tracker.flush()
	var batches := transport.bodies_for("/v1/events/batch")
	_check(batches.size() == 1 and batches[0]["events"][0]["contextId"] == "context-authorized", "unresolved consent must not discard historical config ownership")
	client.free()


func _test_config_binding_storage_failure() -> void:
	var storage := FailingStore.new()
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _recovery_client(storage, transport, "persist-old")
	await client.start()
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	storage.refuse_saves = true
	transport.events_ok = false
	transport.config_ok = true
	client._process(61.0)
	client.free()
	storage.refuse_saves = false
	var restarted := _recovery_client(storage, RecoveryTransport.new(), "persist-restart")
	_check(restarted.tracker.pending_count() == 1, "binding persistence failure fixture restores the original unbound event")
	await restarted.start()
	for index: int in range(3):
		restarted._process(61.0)
	await restarted.tracker.flush()
	_check(restarted.tracker.pending_count() == 0, "failed context-binding save retains replayable original config request")
	restarted.free()


func _test_config_backoff_bound() -> void:
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _recovery_client(MemoryStore.new(), transport, "backoff")
	await client.start()
	for delay: float in [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0]:
		var before := transport.config_calls
		client._process(delay - 0.1)
		_check(transport.config_calls == before, "backoff does not retry before its deadline")
		client._process(0.11)
		_check(transport.config_calls == before + 1, "backoff retries at a bounded deadline")
	transport.config_ok = true
	client._process(60.0)
	_check(client.status == "ready", "backoff eventually recovers after repeated failures")
	_check(await client.start(), "start reports recovered readiness after a prior failed startup")
	client.free()


func _test_config_recovers_without_foreground() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "first")
	await client.start()
	transport.config_ok = false
	_check(not await client.new_session("second"), "offline foreground reports the real config failure")
	client.tracker.track_ad("rewarded", "reward", 0.25, "USD")
	await client.tracker.track_session_end({}, false)
	var original: Array = client.tracker.pending_events_for_testing()
	client._process(0.1)
	_check(transport.config_calls == 2, "config recovery respects backoff")
	transport.config_ok = true
	client._process(61.0)
	await client.tracker.flush()
	var batches := transport.bodies_for("/v1/events/batch")
	_check(not batches.is_empty(), "network recovery uploads without another foreground")
	if not batches.is_empty():
		var events: Array = batches[0]["events"]
		for index: int in range(events.size()):
			var expected: Dictionary = original[index].duplicate(true)
			expected["contextId"] = "context-second"
			_check(events[index] == JSON.parse_string(Util.canonical_json(expected)), "recovery only binds context, preserving event identity and time")
	client._process(61.0)
	_check(client.tracker.pending_count() == 0 and batches.size() == 1, "successful recovery drains events once")
	client.free()


func _test_unbound_sessions_survive_restart() -> void:
	var storage := MemoryStore.new()
	var transport := RecoveryTransport.new()
	transport.config_ok = false
	var client := _recovery_client(storage, transport, "old")
	await client.start()
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	await client.tracker.track_session_end({}, false)
	var first: Array = client.tracker.pending_events_for_testing()
	await client.new_session("middle")
	client.tracker.track_ad("banner", "banner", 0.2, "USD")
	_check(client.tracker.pending_count() == 3, "second foreground retains prior unbound events")
	var old_requests := transport.bodies_for("/v1/config")
	client.free()
	var recovered := RecoveryTransport.new()
	var restarted := _recovery_client(storage, recovered, "current")
	_check(restarted.tracker.pending_count() == 3, "unbound revenue and session end survive restart")
	await restarted.start()
	for index: int in range(4):
		restarted._process(61.0)
	await restarted.tracker.flush()
	var sent: Array = []
	for batch: Dictionary in recovered.bodies_for("/v1/events/batch"):
		sent.append_array(batch["events"])
	_check(sent.size() == 3, "all retained sessions upload after restart")
	for original: Dictionary in first:
		var expected := original.duplicate(true)
		expected["contextId"] = "context-old"
		_check(sent.has(JSON.parse_string(Util.canonical_json(expected))), "restart preserves original event id, session and timestamps")
	for original: Dictionary in old_requests:
		_check(recovered.bodies_for("/v1/config").has(original), "original config request is replayed verbatim")
	_check(restarted.snapshot()["config"]["configVersion"] == "current", "past recovery cannot overwrite current assignments")
	restarted.free()


func _test_overlapping_config_sessions() -> void:
	var transport := RecoveryTransport.new()
	transport.hold_config = true
	var client := _recovery_client(MemoryStore.new(), transport, "old")
	client.start()
	client.tracker.track_ad("banner", "banner", 0.1, "USD")
	client.new_session("new")
	_check(client.tracker.current_session_id() == "new", "foreground switches session while old config is in flight")
	client.tracker.track_ad("banner", "banner", 0.2, "USD")
	transport.hold_config = false
	transport.released.emit()
	client._process(61.0)
	await client.tracker.flush()
	var sent: Array = []
	for batch: Dictionary in transport.bodies_for("/v1/events/batch"):
		sent.append_array(batch["events"])
	_check(sent.size() == 2, "overlapping session config responses retain both events")
	for event: Dictionary in sent:
		_check(event["contextId"] == "context-" + event["sessionId"], "overlapping config binds only its originating session")
	_check(client.snapshot().get("config", {}).get("configVersion", "") == "new", "overlapping response publishes only current config")
	client.free()


func _test_attribution_autonomous_retry() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "attribution")
	await client.start()
	transport.attribution_ok = false
	var failed: Dictionary = await client.set_attribution("adjust", {"network": "paid"}, {
		"attributed_at": "2026-10-05T01:02:03.000Z",
	})
	_check(not failed.get("ok", true), "queued attribution returns actual network failure")
	var original: Dictionary = transport.bodies_for("/v1/attribution")[0]
	client._process(0.1)
	_check(transport.bodies_for("/v1/attribution").size() == 1, "attribution recovery respects backoff")
	transport.attribution_ok = true
	client._process(61.0)
	var bodies := transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 2 and bodies.back() == original, "autonomous attribution retry preserves exact occurrence and identity")
	client._process(61.0)
	_check(transport.bodies_for("/v1/attribution").size() == 2, "acknowledged attribution is not retried again")
	client.free()


func _test_attribution_ack_cleanup_survives_restart() -> void:
	var storage := RemovalFailureStore.new()
	var transport := RecoveryTransport.new()
	var client := _recovery_client(storage, transport, "ack-cleanup")
	await client.start()
	storage.failing_prefix = "pending_attribution_"
	storage.failures_remaining = 1
	var result: Dictionary = await client.set_attribution("adjust", {"network": "paid"})
	var pending_key: String = "pending_attribution_" + String(client._namespace)
	_check(bool(result.get("ok", false)), "a durable server acknowledgement remains successful when local cleanup is deferred")
	_check(storage.values.has(pending_key), "failed pending cleanup leaves the acknowledged envelope recoverable")
	_check(transport.bodies_for("/v1/attribution").size() == 1, "the acknowledged attribution is sent once before restart")
	client.free()

	var recovered := RecoveryTransport.new()
	var restarted := _recovery_client(storage, recovered, "ack-cleanup-restart")
	await restarted.start()
	restarted._process(61.0)
	_check(recovered.bodies_for("/v1/attribution").is_empty(), "restart reconciles an acknowledged pending envelope without retransmission")
	_check(not storage.values.has(pending_key), "restart removes the stale acknowledged pending envelope")
	restarted.free()


func _test_attribution_consent_and_restart() -> void:
	var storage := MemoryStore.new()
	var transport := RecoveryTransport.new()
	var client := _recovery_client(storage, transport, "original")
	await client.start()
	transport.attribution_ok = false
	await client.set_attribution("adjust", {"network": "paid"})
	var original: Dictionary = transport.bodies_for("/v1/attribution")[0]
	client.free()
	var recovered := RecoveryTransport.new()
	var restarted := _make_client({
		"storage": storage, "transport": recovered, "session_id": "restart",
		"json_decoder": ImmediateDecoder.new(), "logger": null, "platform": "android",
		"attribution_allowed": false,
	})
	restarted.set_process(false)
	await restarted.start()
	restarted._process(61.0)
	_check(recovered.bodies_for("/v1/attribution").is_empty(), "configured attribution pause prevents restored uploads")
	if not restarted.has_method("set_attribution_allowed"):
		_check(false, "attribution pause and revoke API exists")
		restarted.free()
		return
	var blocked: Dictionary = await restarted.set_attribution("adjust", {"network": "unauthorized"})
	_check(not blocked.get("ok", true), "pause refuses new attribution collection")
	restarted.set_attribution_allowed(true)
	restarted._process(61.0)
	_check(recovered.bodies_for("/v1/attribution") == [original], "resume recovers durable authorized attribution with original identity")
	recovered.attribution_ok = false
	await restarted.set_attribution("adjust", {"network": "revoke-me"})
	restarted.set_attribution_allowed(false, true)
	recovered.attribution_ok = true
	restarted.set_attribution_allowed(true)
	restarted._process(61.0)
	_check(recovered.bodies_for("/v1/attribution").size() == 2, "explicit denial discards pending data before regrant")
	_check(restarted.tracker.track("level_start", {}), "advertising consent changes leave basic events enabled")
	restarted.free()


func _test_attribution_newer_value_race() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "race")
	await client.start()
	transport.hold_attribution = true
	client.set_attribution("adjust", {"network": "old"})
	var queued: Dictionary = await client.set_attribution("adjust", {"network": "new"})
	_check(not queued.get("ok", true), "new value queued behind inflight request is not claimed accepted")
	transport.hold_attribution = false
	transport.released.emit()
	client._process(61.0)
	var bodies := transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 2, "stale attribution acknowledgement cannot clear newer pending value")
	if bodies.size() == 2:
		_check(bodies[0]["attribution"]["network"] == "old" and bodies[1]["attribution"]["network"] == "new", "provider values upload in occurrence order")
	client._process(61.0)
	_check(transport.bodies_for("/v1/attribution").size() == 2, "latest value acknowledged exactly once")
	client.free()


func _test_attribution_pause_inflight() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "pause")
	await client.start()
	transport.hold_attribution = true
	client.set_attribution("adjust", {"network": "authorized"})
	client.set_attribution_allowed(false)
	transport.hold_attribution = false
	transport.released.emit()
	client._process(61.0)
	_check(transport.bodies_for("/v1/attribution").size() == 1, "paused in-flight completion cannot trigger a retry")
	client.set_attribution_allowed(true)
	client._process(61.0)
	var bodies := transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 2 and bodies[0] == bodies[1], "pause retains the original authorized body across an in-flight completion")
	client.free()


func _test_attribution_revoke_inflight() -> void:
	var transport := RecoveryTransport.new()
	var client := _recovery_client(MemoryStore.new(), transport, "revoke")
	await client.start()
	if not client.has_method("set_attribution_allowed"):
		client.free()
		return
	transport.hold_attribution = true
	client.set_attribution("adjust", {"network": "old"})
	client.set_attribution_allowed(false, true)
	client.set_attribution_allowed(true)
	var newer: Dictionary = await client.set_attribution("adjust", {"network": "new"})
	_check(not newer.get("ok", true), "regrant waits for prior provider request to settle")
	transport.hold_attribution = false
	transport.released.emit()
	client._process(61.0)
	var bodies := transport.bodies_for("/v1/attribution")
	_check(bodies.size() == 2 and bodies.back()["attribution"]["network"] == "new", "pre-denial response cannot erase regranted attribution")
	client.free()


func _test_malformed_identifier_responses() -> void:
	var transport := TransportFixture.new()
	var client := _make_client({"transport": transport, "platform": "android", "logger": null, "json_decoder": ImmediateDecoder.new()})
	await client.refresh(true)
	for malformed: Dictionary in [
		{"ok": "false", "accepted": 1}, {"ok": true, "accepted": "1"},
		{"ok": true, "accepted": -1}, {"ok": true, "accepted": 1.5},
		{"ok": true, "accepted": 2}, {"ok": false, "accepted": 0}, {},
	]:
		transport.identifier_response = malformed
		var result: Dictionary = await client.set_adjust_adid("adid-1")
		_check(result.get("ok") == false and result.get("accepted") == 0 and result.get("error") == "invalid_context_identifier_response", "malformed identifier response returns a structured failure: " + JSON.stringify(malformed))
		_check(client.last_error == "invalid_context_identifier_response", "malformed identifier failure sets the public error")
	transport.identifier_response = {"ok": true, "accepted": 0}
	var duplicate: Dictionary = await client.set_adjust_adid("adid-1")
	_check(duplicate.get("ok") == true and duplicate.get("accepted") == 0, "valid identifier duplicate acknowledgement succeeds")
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


func _test_automatic_idfv_after_context_recovery() -> void:
	for has_cache: bool in [false, true]:
		var storage := MemoryStore.new()
		if has_cache:
			var previous := _make_client({
				"transport": RecoveryTransport.new(), "storage": storage, "platform": "ios",
				"session_id": "idfv-previous", "json_decoder": ImmediateDecoder.new(), "logger": null,
			})
			previous.set_process(false)
			await previous.start()
			previous.free()
		var transport := RecoveryTransport.new()
		transport.config_ok = false
		var client := _make_client({
			"transport": transport, "storage": storage, "platform": "ios",
			"session_id": "idfv-offline", "json_decoder": ImmediateDecoder.new(), "logger": null,
			"measurement_allowed": false, "measurement_resolved": true,
		})
		client.set_process(false)
		await client.start()
		_check(transport.bodies_for("/v1/context-identifiers").is_empty() and not client._reported_idfv,
			"offline startup defers IDFV without using cached context: cached=%s" % has_cache)
		await client.new_session("idfv-current")
		transport.config_ok = true
		await client._fetch_pending_config("idfv-offline")
		_check(transport.bodies_for("/v1/context-identifiers").is_empty() and not client._reported_idfv,
			"historical config recovery cannot trigger automatic IDFV")
		client._tick_pending_requests(60.0)
		var bodies: Array = transport.bodies_for("/v1/context-identifiers")
		_check(bodies.size() == 1 and client._reported_idfv,
			"first recovered current context automatically reports the deferred IDFV: cached=%s" % has_cache)
		if bodies.size() == 1:
			_check(bodies[0]["identifierType"] == "idfv" and bodies[0]["sessionId"] == "idfv-current" \
				and bodies[0]["contextId"] == "context-idfv-current", "recovered IDFV has matching current-session ownership")
		await client.refresh(true)
		await client.new_session("idfv-later")
		_check(transport.bodies_for("/v1/context-identifiers").size() == 1,
			"later refreshes and sessions preserve once-per-startup automatic IDFV")
		client.free()


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
