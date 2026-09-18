extends RefCounted

const GameAlgoUtil := preload("res://addons/gamealgo/gamealgo_util.gd")
const GameAlgoJsonStore := preload("res://addons/gamealgo/internal/json_store.gd")

const DEFAULT_MAX_BATCH_SIZE := 100
const DEFAULT_QUEUE_LIMIT := 1000
const DEFAULT_FLUSH_INTERVAL := 30.0

## Standard semantic events are never charged against the custom-event quota.
const STANDARD_EVENT_TYPES := [
	"session_end", "level_start", "level_end", "ad_view", "purchase", "milestone",
]

## Per-context custom-event quota, matching the other SDKs.
const QUOTA_PER_EVENT_TYPE := 1000
const QUOTA_PER_CONTEXT := 5000
const QUOTA_DISTINCT_EVENT_TYPES := 100
const QUOTA_DIAGNOSTIC_LIMIT := 10

var _client: Object
var _storage: Variant
var _storage_key := ""
var _max_batch_size := DEFAULT_MAX_BATCH_SIZE
var _queue_limit := DEFAULT_QUEUE_LIMIT
var _flush_interval := DEFAULT_FLUSH_INTERVAL
var _flush_elapsed := 0.0
var _user_id := ""
var _session_id := ""
var _context_id := ""
var _platform := "rest"
var _sdk_version := "1.0.5"
var _app_version := ""
var _timezone := "UTC"
var _user_created_at := ""
var _account_user_id := ""
var _is_debug := false
var _queue: Array[Dictionary] = []
var _retry_batch: Array[Dictionary] = []
var _inflight_batch: Array[Dictionary] = []
var _is_flushing := false
var _session_start_unix := 0.0
var _consecutive_failures := 0
var _has_persisted_queue := false
var _measurement_allowed := false
var _measurement_resolved := true
var _consent_generation := 0
## bucket key -> {"total": int, "byType": {event_type: int}}
var _custom_counts: Dictionary = {}
var _diagnostic_keys: Dictionary = {}
var _diagnostic_count := 0
var _milestone_storage_key := ""
## Milestones already bound to a context. Persisted, so a reinstall-free restart
## does not report the same milestone twice.
var _reached_milestone_keys: Dictionary = {}
## Milestones reached before a context existed. Dropped with the session.
var _pending_milestone_keys: Dictionary = {}


func configure(client: Object, storage: Variant, options: Dictionary) -> bool:
	var measurement_value: Variant = options.get("measurement_allowed", false)
	var measurement_resolved_value: Variant = options.get("measurement_resolved", true)
	if not measurement_value is bool or not measurement_resolved_value is bool \
			or (bool(measurement_value) and not bool(measurement_resolved_value)):
		return false
	_client = client
	_storage = storage
	_storage_key = String(options.get("storage_key", "events"))
	_milestone_storage_key = String(options.get("milestone_storage_key", ""))
	_restore_reached_milestones()
	_max_batch_size = clampi(int(options.get("max_batch_size", 100)), 1, 100)
	_queue_limit = maxi(int(options.get("queue_limit", 1000)), _max_batch_size)
	_flush_interval = maxf(float(options.get("flush_interval", 30.0)), 0.0)
	_user_id = String(options.get("user_id", ""))
	_session_id = GameAlgoUtil.clean(options.get("session_id", ""))
	if _session_id.is_empty():
		_session_id = GameAlgoUtil.uuid()
	_platform = String(options.get("platform", "rest"))
	_sdk_version = String(options.get("sdk_version", "1.0.5"))
	_app_version = String(options.get("app_version", ""))
	_timezone = String(options.get("timezone", GameAlgoUtil.timezone_name()))
	_user_created_at = String(options.get("user_created_at", ""))
	_account_user_id = String(options.get("account_user_id", ""))
	_is_debug = bool(options.get("is_debug", false))
	_measurement_allowed = bool(measurement_value)
	_measurement_resolved = bool(measurement_resolved_value)
	_session_start_unix = Time.get_unix_time_from_system()
	if _measurement_allowed:
		return _restore_queue()
	return _clear_persisted() if _measurement_resolved else true


func set_measurement_allowed(allowed: bool) -> bool:
	if not _measurement_resolved:
		if allowed:
			if not _restore_queue():
				return false
			_consent_generation += 1
			_measurement_resolved = true
			_measurement_allowed = true
			return true
		_consent_generation += 1
		_measurement_resolved = true
		_retry_batch.clear()
		_queue.clear()
		_inflight_batch.clear()
		return _clear_persisted()
	if _measurement_allowed == allowed:
		return true if allowed else _clear_persisted()
	_consent_generation += 1
	if allowed:
		# A post-denial grant starts clean. If revocation cleanup could not be
		# proven, fail closed rather than resurrecting pre-consent events.
		if not _clear_persisted():
			return false
		_measurement_allowed = true
		return true
	_measurement_allowed = false
	_retry_batch.clear()
	_queue.clear()
	_inflight_batch.clear()
	return _clear_persisted()


func measurement_allowed() -> bool:
	return _measurement_allowed


func identify(options: Dictionary) -> void:
	if GameAlgoUtil.clean(options.get("user_id", "")) != "":
		_user_id = GameAlgoUtil.clean(options["user_id"])
	if GameAlgoUtil.clean(options.get("session_id", "")) != "":
		_session_id = GameAlgoUtil.clean(options["session_id"])
	if GameAlgoUtil.clean(options.get("platform", "")) != "":
		_platform = GameAlgoUtil.clean(options["platform"])
	if GameAlgoUtil.clean(options.get("sdk_version", "")) != "":
		_sdk_version = GameAlgoUtil.clean(options["sdk_version"])
	if options.has("app_version"):
		_app_version = GameAlgoUtil.clean(options["app_version"])
	if GameAlgoUtil.clean(options.get("timezone", "")) != "":
		_timezone = GameAlgoUtil.clean(options["timezone"])
	if GameAlgoUtil.clean(options.get("user_created_at", "")) != "":
		_user_created_at = GameAlgoUtil.clean(options["user_created_at"])
	if options.has("account_user_id"):
		_account_user_id = GameAlgoUtil.clean(options["account_user_id"])
	if options.has("is_debug") and options["is_debug"] is bool:
		_is_debug = bool(options["is_debug"])


func new_session(session_id: String = "") -> void:
	var previous := _session_id
	_retry_batch = _retry_batch.filter(func(event: Dictionary) -> bool:
		return not (String(event.get("contextId", "")).is_empty() \
			and String(event.get("sessionId", "")) == previous)
	)
	_queue = _queue.filter(func(event: Dictionary) -> bool:
		return not (String(event.get("contextId", "")).is_empty() \
			and String(event.get("sessionId", "")) == previous)
	)
	# The previous session's unbound events were just discarded, so its pending
	# quota usage goes with them. Usage already charged to a context stays.
	_custom_counts.erase("pending:" + previous)
	_pending_milestone_keys.clear()
	_diagnostic_keys.clear()
	_diagnostic_count = 0
	_session_id = GameAlgoUtil.clean(session_id)
	if _session_id.is_empty():
		_session_id = GameAlgoUtil.uuid()
	_context_id = ""
	_session_start_unix = Time.get_unix_time_from_system()
	if _has_persisted_queue:
		_persist_pending()


func current_session_id() -> String:
	return _session_id


func set_context_id(context_id: String) -> void:
	var pending_key := "pending:" + _session_id
	_context_id = GameAlgoUtil.clean(context_id)
	if _context_id.is_empty():
		return
	_merge_custom_bucket(pending_key, "context:" + _context_id)
	_bind_context(_retry_batch)
	_bind_context(_queue)
	_remember_bound_milestones(_context_id)
	if _has_persisted_queue:
		_persist_pending()


func tick(delta: float) -> void:
	if _flush_interval <= 0.0:
		return
	_flush_elapsed += maxf(delta, 0.0)
	if _flush_elapsed < _flush_interval:
		return
	_flush_elapsed = 0.0
	flush()


func track(event_type: String, payload: Variant = {}) -> bool:
	if not _measurement_allowed or _user_id.is_empty() \
			or event_type.is_empty() or event_type != event_type.strip_edges():
		return false
	if not _consume_custom_event_quota(event_type):
		return false
	var event_unix := Time.get_unix_time_from_system()
	var normalized := GameAlgoUtil.normalize_payload(payload)
	var milestone: Dictionary = {}
	if event_type == "milestone":
		milestone = _prepare_milestone(normalized, event_unix)
		if bool(milestone.get("duplicate", false)):
			return false
	var event := {
		"eventId": GameAlgoUtil.uuid(),
		"contextId": _context_id,
		"userId": _user_id,
		"sessionId": _session_id,
		"eventType": event_type,
		"isDebug": _is_debug,
		"timestamp": GameAlgoUtil.utc_timestamp(event_unix),
		"createdLocalAt": GameAlgoUtil.local_timestamp(event_unix),
		"payload": normalized,
	}
	if not _account_user_id.is_empty():
		event["accountUserId"] = _account_user_id
	_queue.append(event)
	if not String(milestone.get("key", "")).is_empty():
		_remember_milestone(String(milestone["key"]), bool(milestone.get("durable", false)))
	if _queue.size() > _queue_limit:
		_queue = _queue.slice(_queue.size() - _queue_limit)
	if _queue.size() >= _max_batch_size:
		flush()
	return true


## Stamps the milestone with its elapsed time since registration and decides
## whether this milestone was already reported. The elapsed value is always
## recomputed here so a caller cannot supply its own.
func _prepare_milestone(payload: Dictionary, event_unix: float) -> Dictionary:
	payload.erase("elapsedSinceRegistrationMs")
	var registered_unix := _user_created_unix()
	if registered_unix > 0.0:
		payload["elapsedSinceRegistrationMs"] = int(maxf(
			floor((event_unix - registered_unix) * 1000.0), 0.0
		))
	var milestone_type := GameAlgoUtil.clean(payload.get("milestoneType", null))
	var milestone_point := GameAlgoUtil.clean(payload.get("milestonePoint", null))
	if milestone_type.is_empty() or milestone_point.is_empty():
		return {}
	var key := GameAlgoUtil.canonical_json([
		"debug" if _is_debug else "live", _user_id, milestone_type, milestone_point,
	])
	var durable := not _context_id.is_empty()
	var seen: Dictionary = _reached_milestone_keys if durable else _pending_milestone_keys
	return {"duplicate": seen.has(key), "key": key, "durable": durable}


func _remember_milestone(key: String, durable: bool) -> void:
	if not durable:
		_pending_milestone_keys[key] = true
		return
	if _reached_milestone_keys.has(key):
		return
	_reached_milestone_keys[key] = true
	_persist_reached_milestones()


## Milestones queued before the context arrived become durable once their events
## bind to it, so a restart does not report them again.
func _remember_bound_milestones(context_id: String) -> void:
	var changed := false
	var bound: Array[Dictionary] = []
	bound.append_array(_retry_batch)
	bound.append_array(_queue)
	for event: Dictionary in bound:
		if String(event.get("contextId", "")) != context_id \
				or String(event.get("eventType", "")) != "milestone":
			continue
		var payload: Variant = event.get("payload", null)
		if not payload is Dictionary:
			continue
		var milestone_type := GameAlgoUtil.clean((payload as Dictionary).get("milestoneType", null))
		var milestone_point := GameAlgoUtil.clean((payload as Dictionary).get("milestonePoint", null))
		if milestone_type.is_empty() or milestone_point.is_empty():
			continue
		var key := GameAlgoUtil.canonical_json([
			"debug" if bool(event.get("isDebug", false)) else "live",
			String(event.get("userId", "")), milestone_type, milestone_point,
		])
		if not _reached_milestone_keys.has(key):
			_reached_milestone_keys[key] = true
			changed = true
	if changed:
		_persist_reached_milestones()


func _user_created_unix() -> float:
	if _user_created_at.is_empty():
		return 0.0
	var parsed := Time.get_unix_time_from_datetime_string(_user_created_at)
	return float(parsed) if parsed > 0 else 0.0


func _restore_reached_milestones() -> void:
	_reached_milestone_keys.clear()
	if _milestone_storage_key.is_empty() or _storage == null \
			or not _storage.has_method("load_json_result"):
		return
	var loaded: Variant = _storage.call("load_json_result", _milestone_storage_key)
	if not loaded is Dictionary \
			or String(loaded.get("status", "")) != GameAlgoJsonStore.STATUS_LOADED:
		return
	var restored: Variant = loaded.get("value", null)
	if not restored is Array:
		# A corrupt cache is dropped rather than trusted; at worst one milestone
		# is reported twice, which is better than silently suppressing later ones.
		if _storage.has_method("remove"):
			_storage.call("remove", _milestone_storage_key)
		return
	for key: Variant in restored:
		if key is String and not String(key).is_empty():
			_reached_milestone_keys[String(key)] = true


func _persist_reached_milestones() -> void:
	if _milestone_storage_key.is_empty() or _storage == null \
			or not _storage.has_method("save_json"):
		return
	var keys: Array[String] = []
	for key: String in _reached_milestone_keys:
		keys.append(key)
	keys.sort()
	_storage.call("save_json", _milestone_storage_key, keys)


func _quota_bucket_key() -> String:
	return "context:" + _context_id if not _context_id.is_empty() else "pending:" + _session_id


## Charges one custom event against the current context. Standard semantic events
## are exempt. Returns false when a limit is reached; the event is then refused
## outright rather than queued, so the game learns about it from track().
func _consume_custom_event_quota(event_type: String) -> bool:
	if event_type in STANDARD_EVENT_TYPES:
		return true
	var bucket_key := _quota_bucket_key()
	var bucket: Dictionary = _custom_counts.get(bucket_key, {"total": 0, "byType": {}})
	var by_type: Dictionary = bucket["byType"]
	var current := int(by_type.get(event_type, 0))
	var scope := ""
	var limit := 0
	var observed := 0
	if not by_type.has(event_type) and by_type.size() >= QUOTA_DISTINCT_EVENT_TYPES:
		scope = "distinct_event_types"
		limit = QUOTA_DISTINCT_EVENT_TYPES
		observed = by_type.size() + 1
	elif current >= QUOTA_PER_EVENT_TYPE:
		scope = "context_event_type"
		limit = QUOTA_PER_EVENT_TYPE
		observed = current + 1
	elif int(bucket["total"]) >= QUOTA_PER_CONTEXT:
		scope = "context_total"
		limit = QUOTA_PER_CONTEXT
		observed = int(bucket["total"]) + 1
	if not scope.is_empty():
		_report_quota_diagnostic(event_type, scope, limit, observed)
		return false
	bucket["total"] = int(bucket["total"]) + 1
	by_type[event_type] = current + 1
	_custom_counts[bucket_key] = bucket
	return true


## Events queued before the context arrived are charged to a pending bucket.
## When the context binds, their usage moves with them.
func _merge_custom_bucket(from_key: String, to_key: String) -> void:
	if not _custom_counts.has(from_key) or from_key == to_key:
		return
	var pending: Dictionary = _custom_counts[from_key]
	var target: Dictionary = _custom_counts.get(to_key, {"total": 0, "byType": {}})
	var target_types: Dictionary = target["byType"]
	target["total"] = int(target["total"]) + int(pending["total"])
	for event_type: String in pending["byType"]:
		target_types[event_type] = int(target_types.get(event_type, 0)) + int(pending["byType"][event_type])
	_custom_counts[to_key] = target
	_custom_counts.erase(from_key)


func _report_quota_diagnostic(event_type: String, scope: String, limit: int, observed: int) -> void:
	if not is_instance_valid(_client) or not _client.has_method("report_sdk_diagnostic"):
		return
	# Unit separator: event types are validated to have no surrounding whitespace
	# but may contain most printable characters, so avoid a printable delimiter.
	var key := "%s%s%s" % [_session_id, event_type, scope]
	if _diagnostic_keys.has(key) or _diagnostic_count >= QUOTA_DIAGNOSTIC_LIMIT:
		return
	_diagnostic_keys[key] = true
	_diagnostic_count += 1
	var safe_event_type := event_type.replace(";", "_").replace("\r", "_").replace("\n", "_").substr(0, 96)
	_client.call("report_sdk_diagnostic", {
		"diagnosticId": GameAlgoUtil.uuid(),
		"userId": _user_id,
		"sessionId": _session_id,
		"contextId": _context_id,
		"platform": _platform,
		"sdkVersion": _sdk_version,
		"appVersion": _app_version,
		"stage": "event_guard",
		"status": "degraded",
		"reasonCode": "custom_event_quota_exceeded",
		"reasonDetail": "eventType=%s;scope=%s;limit=%d;observed=%d;dropped=1" % [
			safe_event_type, scope, limit, observed
		],
		"createdAt": GameAlgoUtil.utc_timestamp(),
		"createdLocalAt": GameAlgoUtil.local_timestamp(),
		"isDebug": _is_debug,
	})


func track_event(event_type: String, payload: Variant = {}) -> bool:
	return track(event_type if event_type.begins_with("_") else "_" + event_type, payload)


func track_level_start(payload: Variant = {}) -> bool:
	return track("level_start", payload)


func track_level_end(payload: Variant = {}) -> bool:
	return track("level_end", payload)


func track_ad(
	placement: String,
	ad_type: String,
	revenue: float,
	currency: String,
	network: String = "",
	payload: Variant = {}
) -> bool:
	if not is_finite(revenue):
		return false
	var merged: Dictionary = payload.duplicate(true) if payload is Dictionary else {}
	merged["placement"] = placement
	merged["adType"] = ad_type
	merged["revenue"] = revenue
	merged["currency"] = currency
	if not network.is_empty():
		merged["network"] = network
	return track("ad_view", merged)


func track_purchase(
	product_id: String = "",
	revenue: Variant = null,
	currency: String = "",
	payload: Variant = {}
) -> bool:
	var merged: Dictionary = payload.duplicate(true) if payload is Dictionary else {}
	if not product_id.is_empty():
		merged["productId"] = product_id
	if revenue != null:
		if not (revenue is int or revenue is float) or not is_finite(float(revenue)):
			return false
		merged["revenue"] = revenue
	if not currency.is_empty():
		merged["currency"] = currency
	return track("purchase", merged)


func track_session_end(payload: Variant = {}, flush_immediately: bool = true) -> bool:
	var merged: Dictionary = payload.duplicate(true) if payload is Dictionary else {}
	if _session_start_unix > 0.0:
		merged["sessionDurationMs"] = int(maxf(
			(Time.get_unix_time_from_system() - _session_start_unix) * 1000.0, 0.0
		))
	var accepted := track("session_end", merged)
	if accepted and flush_immediately:
		await flush()
	return accepted


func flush() -> bool:
	if not _measurement_allowed or _is_flushing or not is_instance_valid(_client):
		return false
	_is_flushing = true
	var consent_generation := _consent_generation
	while not _retry_batch.is_empty() or not _queue.is_empty():
		var pending: Array[Dictionary] = []
		pending.append_array(_retry_batch)
		pending.append_array(_queue)
		var size := mini(_max_batch_size, pending.size())
		var batch_source := pending.slice(0, size)
		if _context_id.is_empty():
			var has_unbound := batch_source.any(func(event: Dictionary) -> bool:
				return String(event.get("contextId", "")).is_empty()
			)
			if has_unbound:
				_retry_batch.clear()
				_queue = pending
				_is_flushing = false
				return false
		var batch: Array[Dictionary] = []
		for index: int in range(size):
			var event := pending[index].duplicate(true)
			if String(event.get("contextId", "")).is_empty() \
					and String(event.get("sessionId", "")) == _session_id:
				event["contextId"] = _context_id
			batch.append(event)
		_queue.clear()
		for index: int in range(size, pending.size()):
			_queue.append(pending[index])
		_retry_batch.clear()
		_inflight_batch = batch.duplicate(true)
		var response: Variant = await _client.call("upload_events", batch)
		if not _measurement_allowed or consent_generation != _consent_generation:
			# Revocation already removed the old generation. Do not erase events
			# accepted after a later grant while this upload was in flight.
			_inflight_batch.clear()
			_is_flushing = false
			return false
		if not response is Dictionary or not response.get("ok", null) is bool \
				or not response["ok"] or int(response.get("accepted", -1)) != batch.size():
			_retry_batch = _inflight_batch.duplicate(true)
			_inflight_batch.clear()
			_consecutive_failures += 1
			if _consecutive_failures >= 3:
				_has_persisted_queue = true
				_persist_pending()
			_is_flushing = false
			return false
		_inflight_batch.clear()
		_consecutive_failures = 0
		if _has_persisted_queue and not _persist_pending():
			_is_flushing = false
			return false
	if _has_persisted_queue and not _clear_persisted():
		_is_flushing = false
		return false
	_is_flushing = false
	return true


func pending_count() -> int:
	return _retry_batch.size() + _inflight_batch.size() + _queue.size()


func pending_events_for_testing() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append_array(_retry_batch.duplicate(true))
	result.append_array(_inflight_batch.duplicate(true))
	result.append_array(_queue.duplicate(true))
	return result


func _bind_context(events: Array[Dictionary]) -> void:
	for index: int in range(events.size()):
		var event := events[index]
		if String(event.get("contextId", "")).is_empty() \
				and String(event.get("sessionId", "")) == _session_id:
			event["contextId"] = _context_id
			events[index] = event


func _restore_queue() -> bool:
	if _storage == null or not _storage.has_method("load_json_result"):
		return false
	var loaded: Variant = _storage.call("load_json_result", _storage_key)
	if not loaded is Dictionary:
		return false
	var status := String(loaded.get("status", ""))
	if status == GameAlgoJsonStore.STATUS_MISSING:
		return true
	var restored: Variant = loaded.get("value", null)
	if status != GameAlgoJsonStore.STATUS_LOADED or not restored is Array:
		return false
	for value: Variant in restored:
		if not _valid_event(value):
			continue
		var event := value as Dictionary
		if String(event["contextId"]).is_empty() and String(event["sessionId"]) != _session_id:
			continue
		_retry_batch.append(event.duplicate(true))
	_has_persisted_queue = not _retry_batch.is_empty()
	return true


func _valid_event(value: Variant) -> bool:
	if not value is Dictionary or not GameAlgoUtil.valid_json_value(value):
		return false
	var event := value as Dictionary
	for field: String in ["eventId", "contextId", "userId", "sessionId", "eventType", "timestamp", "createdLocalAt"]:
		if not event.get(field, null) is String:
			return false
	if String(event["eventId"]).is_empty() or String(event["userId"]).is_empty() \
			or String(event["sessionId"]).is_empty() or String(event["eventType"]).is_empty() \
			or String(event["timestamp"]).is_empty() or String(event["createdLocalAt"]).is_empty() \
			or not event.get("isDebug", null) is bool \
			or not event.get("payload", null) is Dictionary:
		return false
	if event.has("accountUserId") and not event["accountUserId"] is String:
		return false
	return true


func persist_pending() -> bool:
	if not _measurement_allowed:
		return _clear_persisted()
	return _persist_pending()


func _persist_pending() -> bool:
	if _storage == null or not _storage.has_method("save_json"):
		return false
	var pending: Array[Dictionary] = []
	pending.append_array(_retry_batch)
	pending.append_array(_inflight_batch)
	pending.append_array(_queue)
	if pending.is_empty():
		return _clear_persisted()
	var result: Variant = _storage.call("save_json", _storage_key, pending)
	var saved := result is bool and bool(result)
	# A failed rewrite leaves durable state unproven and schedules reconciliation.
	_has_persisted_queue = true
	return saved


func _clear_persisted() -> bool:
	var result: Variant = _storage.call("remove", _storage_key) \
			if _storage != null and _storage.has_method("remove") else false
	var removed := result is bool and bool(result)
	_has_persisted_queue = not removed
	return removed
