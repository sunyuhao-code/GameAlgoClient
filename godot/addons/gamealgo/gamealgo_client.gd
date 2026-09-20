extends Node

const GameAlgoUtil := preload("res://addons/gamealgo/gamealgo_util.gd")
const GameAlgoHttpTransport := preload("res://addons/gamealgo/internal/http_transport.gd")
const GameAlgoAsyncJsonDecoder := preload("res://addons/gamealgo/internal/async_json_decoder.gd")
const GameAlgoJsonStore := preload("res://addons/gamealgo/internal/json_store.gd")
const GameAlgoEventTracker := preload("res://addons/gamealgo/gamealgo_tracker.gd")
const GameAlgoExperimentExecutor := preload("res://addons/gamealgo/gamealgo_executor.gd")

signal sdk_ready(used_cached_snapshot: bool)
signal config_refreshed(config: Dictionary)
signal assignment_received(key: String, value: Variant, generation: int)
signal assignment_updated(assignment: Dictionary, generation: int)
signal request_failed(code: String)
signal startup_completed(success: bool)
## Emitted for every SDK log line, whatever the logger is set to. Godot
## redirects stdio on iOS, so print() never reaches simctl or the Xcode
## console there; this signal is how an iOS host gets the same information.
signal sdk_log(message: String)

const SDK_VERSION := "1.0.5"
# The Protocol v1 client is platform-neutral. Storage and script execution are
# injected capabilities; no native runtime is required.
## Godot exports to five targets, but GameAlgo only accepts the two mobile
## platforms. A desktop build is refused here rather than sending a value the
## server rejects with 400.
const ALLOWED_PLATFORMS := ["android", "ios"]
const DEFAULT_PRELOAD := "all"

var tracker := GameAlgoEventTracker.new()
var last_error := ""
var status := "unconfigured"

var _game_key := ""
var _base_url := ""
var _platform := "rest"
var _sdk_version := SDK_VERSION
var _app_version := ""
var _account_user_id := ""
var _account_user_created_at := ""
var _integration_version := 0
var _is_debug := false
var _timezone := "UTC"
var _device: Dictionary = {}
var _preload: Variant = DEFAULT_PRELOAD
var _storage: Variant
var _transport: Variant
var _json_decoder: Variant
var _runtime: Variant
var _identity: Dictionary = {}
var _snapshot: Dictionary = {}
var _namespace := ""
var _snapshot_key := ""
var _started := false
var _startup_finished := false
var _startup_success := false
var _ready := false
var _refreshing := false
var _generation := 0
var _cached_request_fingerprint := ""
var _cached_expiry_unix := 0.0
var _prepared_script_hashes: Dictionary = {}
## A Callable taking one String, or null to silence the SDK.
var _logger: Variant = null
var _reported_idfv := false


func configure(options: Dictionary) -> bool:
	if _started:
		last_error = "already_started"
		return false
	var game_key := GameAlgoUtil.clean(options.get("game_key", ""))
	var base_url := GameAlgoUtil.clean(options.get("base_url", ""))
	var platform := GameAlgoUtil.clean(options.get("platform", _default_platform())).to_lower()
	var integration: Variant = options.get("experiment_integration_version", 0)
	if not GameAlgoUtil.is_game_key(game_key):
		last_error = "invalid_game_key"
		return false
	if not GameAlgoUtil.is_https_base_url(base_url):
		last_error = "invalid_base_url"
		return false
	if platform not in ALLOWED_PLATFORMS:
		last_error = "invalid_platform"
		return false
	if not integration is int or int(integration) <= 0:
		last_error = "invalid_experiment_integration_version"
		return false
	var device_value: Variant = options.get("device", {})
	var measurement_value: Variant = options.get("measurement_allowed", false)
	var measurement_resolved_value: Variant = options.get("measurement_resolved", true)
	if not device_value is Dictionary or not GameAlgoUtil.valid_json_value(device_value):
		last_error = "invalid_device"
		return false
	var preload_value: Variant = options.get("preload_config_files", DEFAULT_PRELOAD)
	if not _valid_preload(preload_value):
		last_error = "invalid_preload_config_files"
		return false
	if not measurement_value is bool or not measurement_resolved_value is bool \
			or (bool(measurement_value) and not bool(measurement_resolved_value)):
		last_error = "invalid_measurement_allowed"
		return false
	_game_key = game_key
	_base_url = base_url
	_platform = platform
	_integration_version = int(integration)
	_sdk_version = GameAlgoUtil.clean(options.get("sdk_version", SDK_VERSION))
	if _sdk_version.is_empty():
		_sdk_version = SDK_VERSION
	_app_version = GameAlgoUtil.clean(options.get(
		"app_version", ProjectSettings.get_setting("application/config/version", "")
	))
	_account_user_id = GameAlgoUtil.clean(options.get("account_user_id", ""))
	_account_user_created_at = GameAlgoUtil.clean(options.get("account_user_created_at", ""))
	_is_debug = bool(options.get("is_debug", false))
	_timezone = GameAlgoUtil.clean(options.get("timezone", GameAlgoUtil.timezone_name()))
	if _timezone.is_empty():
		_timezone = "UTC"
	_device = _default_device()
	_device.merge((device_value as Dictionary).duplicate(true), true)
	_preload = preload_value.duplicate(true) if preload_value is Array else preload_value
	if options.has("logger"):
		var logger_value: Variant = options["logger"]
		if logger_value == null:
			_logger = null
		elif logger_value is Callable and (logger_value as Callable).is_valid():
			_logger = logger_value
		else:
			last_error = "invalid_logger"
			return false
	else:
		_logger = _default_logger
	_storage = options.get("storage", null)
	_transport = options.get("transport", null)
	_json_decoder = options.get("json_decoder", null)
	_runtime = options.get("script_runtime", null)
	if not (_storage is Object) or not _storage.has_method("load_json_result") \
			or not _storage.has_method("save_json") or not _storage.has_method("remove"):
		last_error = "invalid_storage"
		return false
	if _transport != null and (not (_transport is Object) or not _transport.has_method("send")):
		last_error = "invalid_transport"
		return false
	if _json_decoder != null and (not (_json_decoder is Object) \
			or not _json_decoder.has_method("decode_dictionary")):
		last_error = "invalid_json_decoder"
		return false
	if _runtime != null and (not (_runtime is Object) or not _runtime.has_method("prepare") \
			or not _runtime.has_method("execute")):
		last_error = "invalid_script_runtime"
		return false
	_identity = _load_or_create_identity(
		GameAlgoUtil.clean(options.get("user_id", "")),
		GameAlgoUtil.clean(options.get("user_created_at", "")),
		GameAlgoUtil.clean(options.get("user_created_local_at", ""))
	)
	if _identity.is_empty():
		if last_error.is_empty():
			last_error = "identity_persistence_failed"
		return false
	_namespace = GameAlgoUtil.sha256_short(
		"%s:%s:%s" % [_base_url, GameAlgoUtil.sha256_text(_game_key), _identity["userId"]]
	)
	_snapshot_key = "snapshot_" + _namespace
	var tracker_configured := tracker.configure(self, _storage, {
		"storage_key": "events_" + _namespace,
		"milestone_storage_key": "milestones_" + _namespace,
		"max_batch_size": int(options.get("event_max_batch_size", 100)),
		"queue_limit": int(options.get("event_queue_limit", 1000)),
		"flush_interval": float(options.get("event_flush_interval", 30.0)),
		"user_id": _identity["userId"],
		"session_id": GameAlgoUtil.clean(options.get("session_id", "")),
		"platform": _platform,
		"sdk_version": _sdk_version,
		"app_version": _app_version,
		"timezone": _timezone,
		"user_created_at": _identity["userCreatedAt"],
		"account_user_id": _account_user_id,
		"is_debug": _is_debug,
		"measurement_allowed": bool(measurement_value),
		"measurement_resolved": bool(measurement_resolved_value),
	})
	if not tracker_configured:
		last_error = "event_storage_cleanup_failed"
		return false
	last_error = ""
	status = "configured"
	set_process(true)
	_log("userId: %s" % _identity["userId"])
	_log("configured: platform=%s, appVersion=%s, integrationVersion=%d" % [
		_platform, _app_version if not _app_version.is_empty() else "<none>", _integration_version
	])
	return true


func start() -> bool:
	if status == "unconfigured":
		last_error = "not_configured"
		return false
	if _started:
		if _startup_finished:
			return _startup_success
		var completed: Array = await startup_completed
		return bool(completed[0])
	_started = true
	var used_cache := _load_cached_snapshot()
	if used_cache:
		_log("cached snapshot loaded")
		_publish_snapshot_assignments()
		_ready = true
		status = "ready_cached"
		sdk_ready.emit(true)
	var refreshed := await refresh(true)
	_report_identifier_for_vendor()
	if refreshed:
		if not _ready or not used_cache:
			_ready = true
			sdk_ready.emit(false)
		_finish_startup(true)
		return true
	if used_cache:
		status = "degraded"
		_finish_startup(true)
		return true
	status = "failed"
	_finish_startup(false)
	return false


func _finish_startup(success: bool) -> void:
	_startup_success = success
	_startup_finished = true
	startup_completed.emit(success)


func wait_for_ready(timeout_seconds: float = 5.0) -> bool:
	if _ready:
		return true
	if not _started:
		start()
	if _ready:
		return true
	var timer := get_tree().create_timer(maxf(timeout_seconds, 0.0))
	var result: Array = await _wait_for_ready_or_timeout(timer)
	return bool(result[0])


func _wait_for_ready_or_timeout(timer: SceneTreeTimer) -> Array:
	var completed := false
	var succeeded := false
	var on_ready := func(_cached: bool) -> void:
		completed = true
		succeeded = true
	sdk_ready.connect(on_ready, CONNECT_ONE_SHOT)
	while not completed and timer.time_left > 0.0:
		await get_tree().process_frame
	if sdk_ready.is_connected(on_ready):
		sdk_ready.disconnect(on_ready)
	return [succeeded]


func refresh(force_refresh: bool = false) -> bool:
	if status == "unconfigured":
		last_error = "not_configured"
		return false
	if _refreshing:
		last_error = "refresh_in_progress"
		return false
	var request_body := _config_request()
	var fingerprint_body := request_body.duplicate(true)
	fingerprint_body.erase("createdLocalAt")
	var fingerprint := GameAlgoUtil.sha256_text(GameAlgoUtil.canonical_json(fingerprint_body))
	if not force_refresh and fingerprint == _cached_request_fingerprint \
			and _cached_expiry_unix > Time.get_unix_time_from_system() \
			and _snapshot.get("config", null) is Dictionary:
		last_error = ""
		_log("config cache hit: %s" % String(_snapshot["config"].get("configVersion", "")))
		return true
	_refreshing = true
	status = "refreshing"
	var request_session_id := tracker.current_session_id()
	_log("fetching config: userId=%s, platform=%s" % [_identity["userId"], _platform])
	var response := await _request_json("POST", "/v1/config", request_body)
	_refreshing = false
	if request_session_id != tracker.current_session_id():
		last_error = "stale_config_response"
		request_failed.emit(last_error)
		return false
	if not response.get("ok", null) is bool or not response["ok"]:
		last_error = String(response.get("error", "config_request_failed"))
		request_failed.emit(last_error)
		status = "degraded" if _snapshot.get("config", null) is Dictionary else "failed"
		_log("config fetch failed%s: %s" % [
			", using cached config" if status == "degraded" else "", last_error
		])
		return false
	var config := _normalize_config(response.get("value", null))
	if config.is_empty():
		last_error = "invalid_config_response"
		_log("config fetch failed: invalid_config_response")
		request_failed.emit(last_error)
		status = "degraded" if _snapshot.get("config", null) is Dictionary else "failed"
		return false
	_generation += 1
	_snapshot = {
		"schemaVersion": 1,
		"config": config,
		"configFiles": _snapshot.get("configFiles", {}).duplicate(true),
		"updatedAtUnix": Time.get_unix_time_from_system(),
		"userId": _identity["userId"],
	}
	_log("config fetched: version=%s, experiments=%d, configFiles=%d, ttl=%ds" % [
		String(config["configVersion"]), (config["experiments"] as Array).size(),
		(config["configFiles"] as Array).size(), int(config["ttlSeconds"])
	])
	_cached_request_fingerprint = fingerprint
	_cached_expiry_unix = Time.get_unix_time_from_system() + maxf(float(config["ttlSeconds"]), 0.0)
	tracker.set_context_id(String(config["contextId"]))
	var snapshot_saved := _persist_snapshot()
	_prepared_script_hashes.clear()
	var preload_ok := await _preload_config(config)
	_publish_snapshot_assignments()
	for raw_assignment: Variant in config["experiments"]:
		_log("assignment: %s -> %s" % [
			String(raw_assignment.get("key", "")), String(raw_assignment.get("variant", ""))
		])
	_ready = true
	status = "ready" if preload_ok and snapshot_saved else "degraded"
	last_error = "" if preload_ok and snapshot_saved \
			else ("snapshot_persistence_failed" if not snapshot_saved else "preload_failed")
	config_refreshed.emit(config.duplicate(true))
	return true


func new_session(session_id: String = "") -> bool:
	while _refreshing and status != "unconfigured":
		await get_tree().process_frame
	if status == "unconfigured":
		last_error = "not_configured"
		return false
	tracker.new_session(session_id)
	_cached_request_fingerprint = ""
	_cached_expiry_unix = 0.0
	return await refresh(true)


func set_measurement_allowed(allowed: bool) -> bool:
	return tracker.set_measurement_allowed(allowed)


func assignment_script_ready(assignment: Dictionary) -> bool:
	var script: Variant = assignment.get("script", null)
	if not script is Dictionary or _runtime == null or not _runtime.has_method("execute"):
		return false
	var version_id := GameAlgoUtil.clean(script.get("versionId", ""))
	var hash_value := String(script.get("hash", "")).to_lower()
	var file: Variant = _snapshot.get("configFiles", {}).get("script:" + version_id, null)
	var preparation_key := "%s:%s" % [version_id, hash_value]
	return not version_id.is_empty() and _valid_hash(hash_value) and file is Dictionary \
		and file.get("content", null) is String \
		and _content_matches_hash(String(file["content"]), hash_value) \
		and bool(_prepared_script_hashes.get(preparation_key, false))


func snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func config_generation() -> int:
	return _generation


func user_identity() -> Dictionary:
	return _identity.duplicate(true)


func assignment_for_key(key: String) -> Dictionary:
	var config: Variant = _snapshot.get("config", null)
	if not config is Dictionary:
		return {}
	for raw_assignment: Variant in config.get("experiments", []):
		if raw_assignment is Dictionary and String(raw_assignment.get("key", "")) == key:
			return (raw_assignment as Dictionary).duplicate(true)
	return {}


func executor(key: String) -> GameAlgoExperimentExecutor:
	return GameAlgoExperimentExecutor.new(self, key)


func fetch_config_file(name: String) -> Dictionary:
	var normalized := _normalize_file_name(name)
	if normalized.is_empty():
		last_error = "invalid_config_file_name"
		return {}
	var response := await _request_raw("GET", "/v1/config-files/" + normalized.uri_encode())
	if not response.get("ok", null) is bool or not response["ok"]:
		last_error = String(response.get("error", "config_file_request_failed"))
		return {}
	var content: Variant = _body_text(response.get("body", PackedByteArray()))
	if content == null:
		last_error = "config_file_invalid_utf8"
		return {}
	var headers: Dictionary = response.get("headers", {})
	var file := {
		"name": normalized,
		"content": String(content),
		"contentType": String(headers.get("content-type", "application/octet-stream")),
		"etag": String(headers.get("etag", "")),
	}
	if not _store_config_file(normalized, file):
		last_error = "config_file_persistence_failed"
		return {}
	last_error = ""
	return file.duplicate(true)


func upload_events(events: Array[Dictionary]) -> Dictionary:
	if events.is_empty() or events.size() > 100:
		return {"ok": false, "accepted": 0, "error": "invalid_event_batch"}
	var response := await _request_json("POST", "/v1/events/batch", {"events": events})
	if not response.get("ok", null) is bool or not response["ok"] \
			or not response.get("value", null) is Dictionary:
		# Config failures already surfaced through request_failed; event uploads
		# were silent, which is the half that matters once a game is live.
		var error := String(response.get("error", "upload_failed"))
		_log("event upload failed: %d events, error=%s" % [events.size(), error])
		request_failed.emit(error)
		return {"ok": false, "accepted": 0, "error": error}
	var value := response["value"] as Dictionary
	if not value.get("ok", null) is bool or not _integer_value(value.get("accepted", null), 0, 100):
		_log("event upload failed: %d events, error=invalid_event_response" % events.size())
		request_failed.emit("invalid_event_response")
		return {"ok": false, "accepted": 0, "error": "invalid_event_response"}
	return {"ok": bool(value["ok"]), "accepted": int(value["accepted"])}


## Uploads install attribution for one provider. Call it after every attribution
## callback; the SDK keeps the acknowledged hash and skips an unchanged upload,
## so the game does not need to track retry state itself.
func set_attribution(
	provider: String, attribution: Dictionary, options: Dictionary = {}
) -> Dictionary:
	var clean_provider := GameAlgoUtil.clean(provider)
	if clean_provider.is_empty():
		last_error = "invalid_attribution_provider"
		return {"ok": false, "accepted": 0, "error": last_error}
	if status == "unconfigured":
		last_error = "not_configured"
		return {"ok": false, "accepted": 0, "error": last_error}
	if not GameAlgoUtil.valid_json_value(attribution):
		last_error = "invalid_attribution"
		return {"ok": false, "accepted": 0, "error": last_error}
	var payload := attribution.duplicate(true)
	var status_value := GameAlgoUtil.attribution_status(
		clean_provider, GameAlgoUtil.clean(options.get("status", "")), payload
	)
	var attributed_at := GameAlgoUtil.clean(options.get("attributed_at", ""))
	var hash_value := GameAlgoUtil.clean(options.get("attribution_hash", ""))
	if hash_value.is_empty():
		hash_value = GameAlgoUtil.sha256_text(GameAlgoUtil.canonical_json({
			"platform": _platform,
			"provider": clean_provider,
			"status": status_value,
			"attribution": payload,
			"attributedAt": attributed_at,
		}))
	var acknowledged := _attribution_acks()
	if String(acknowledged.get(clean_provider, "")) == hash_value:
		last_error = ""
		_log("attribution already synced: provider=%s" % clean_provider)
		return {"ok": true, "accepted": 0, "attributionHash": hash_value}

	var body := {
		"userId": _identity["userId"],
		"userCreatedAt": _identity["userCreatedAt"],
		"sessionId": tracker.current_session_id(),
		"contextId": _context_id(),
		"platform": _platform,
		"provider": clean_provider,
		"status": status_value,
		"attribution": payload,
		"attributedAt": attributed_at if not attributed_at.is_empty() else null,
		"attributionHash": hash_value,
	}
	var response := await _request_json("POST", "/v1/attribution", body)
	if not response.get("ok", null) is bool or not response["ok"] \
			or not response.get("value", null) is Dictionary:
		last_error = String(response.get("error", "attribution_failed"))
		_log("attribution sync failed: provider=%s, error=%s" % [clean_provider, last_error])
		return {"ok": false, "accepted": 0, "error": last_error}
	var value := response["value"] as Dictionary
	var acknowledged_hash := GameAlgoUtil.clean(value.get("attributionHash", ""))
	if not acknowledged_hash.is_empty():
		acknowledged[clean_provider] = acknowledged_hash
		_store_attribution_acks(acknowledged)
	last_error = ""
	_log("attribution synced: provider=%s, accepted=%d" % [
		clean_provider, int(value.get("accepted", 0))
	])
	return {
		"ok": bool(value.get("ok", false)),
		"accepted": int(value.get("accepted", 0)),
		"attributionHash": acknowledged_hash,
	}


func set_adjust_adid(value: Variant, observed_at: String = "") -> Dictionary:
	return await _set_context_identifier("adjust_adid", value, observed_at)


func set_firebase_app_instance_id(value: Variant, observed_at: String = "") -> Dictionary:
	return await _set_context_identifier("firebase_app_instance_id", value, observed_at)


func set_google_advertising_id(value: Variant, observed_at: String = "") -> Dictionary:
	return await _set_context_identifier("gaid", value, observed_at)


func set_idfa(value: Variant, observed_at: String = "") -> Dictionary:
	return await _set_context_identifier("idfa", value, observed_at)


func set_idfv(value: Variant, observed_at: String = "") -> Dictionary:
	return await _set_context_identifier("idfv", value, observed_at)


## Reports one SDK diagnostic without failing the caller. The tracker uses this
## for quota refusals; it never blocks gameplay and never retries.
func report_sdk_diagnostic(diagnostic: Dictionary) -> void:
	if status == "unconfigured" or not GameAlgoUtil.valid_json_value(diagnostic):
		return
	await _request_json("POST", "/v1/diagnostics/sdk", diagnostic)


func execute_assignment_script(assignment: Dictionary, state: Variant) -> Dictionary:
	if _runtime == null or not _runtime.has_method("execute"):
		last_error = "script_runtime_unavailable"
		return {}
	var script: Variant = assignment.get("script", null)
	if not script is Dictionary:
		return {}
	var version_id := GameAlgoUtil.clean(script.get("versionId", ""))
	if version_id.is_empty():
		return {}
	var files: Variant = _snapshot.get("configFiles", null)
	var cache_key := "script:" + version_id
	if not files is Dictionary or not files.has(cache_key):
		last_error = "script_not_loaded"
		return {}
	var file: Variant = files[cache_key]
	if not file is Dictionary or not file.get("content", null) is String \
			or GameAlgoUtil.sha256_text(String(file["content"])) != String(script.get("hash", "")).to_lower():
		last_error = "script_hash_mismatch"
		return {}
	var config: Dictionary = _snapshot["config"]
	var input := {
		"state": state,
		"config": assignment.get("config", null),
		"meta": {
			"gameId": config["gameId"],
			"userId": _identity["userId"],
			"environment": config["environment"],
			"strategy": assignment["key"],
			"experimentId": assignment["experimentId"],
			"variant": assignment["variant"],
		},
	}
	var raw: Variant = _runtime.call(
		"execute", String(file["content"]), input, version_id, String(script.get("hash", ""))
	)
	var output: Variant = raw
	if raw is Dictionary and raw.get("status", "") == "ok":
		output = raw.get("result", null)
	if not output is Dictionary or not output.has("payload") \
			or not GameAlgoUtil.valid_json_value(output):
		last_error = "script_execution_failed"
		return {}
	var diagnostics: Variant = output.get("diagnostics", {})
	if not diagnostics is Dictionary:
		diagnostics = {}
	last_error = ""
	return {
		"payload": output["payload"],
		"diagnostics": (diagnostics as Dictionary).duplicate(true),
		"assignment": assignment.duplicate(true),
	}


func _process(delta: float) -> void:
	tracker.tick(delta)


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST]:
		tracker.flush()


func _config_request() -> Dictionary:
	return {
		"userId": _identity["userId"],
		"userCreatedAt": _identity["userCreatedAt"],
		"userCreatedLocalAt": _identity["userCreatedLocalAt"],
		"accountUserId": _account_user_id if not _account_user_id.is_empty() else null,
		"accountUserCreatedAt": _account_user_created_at if not _account_user_created_at.is_empty() else null,
		"createdLocalAt": GameAlgoUtil.local_timestamp(),
		"sessionId": tracker.current_session_id(),
		"platform": _platform,
		"sdkVersion": _sdk_version,
		"appVersion": _app_version if not _app_version.is_empty() else null,
		"experimentIntegrationVersion": _integration_version,
		"timezone": _timezone,
		"device": _device.duplicate(true),
		"isDebug": _is_debug,
	}


func _request_json(method: String, path: String, body: Variant = null) -> Dictionary:
	var response := await _request_raw(method, path, body)
	if not response.get("ok", null) is bool or not response["ok"]:
		return {"ok": false, "error": response.get("error", "request_failed")}
	var body_value: Variant = response.get("body", PackedByteArray())
	var response_bytes := PackedByteArray()
	if body_value is PackedByteArray:
		response_bytes = (body_value as PackedByteArray).duplicate()
	elif body_value is String:
		response_bytes = String(body_value).to_utf8_buffer()
	else:
		return {"ok": false, "error": "response_invalid_utf8"}
	if _json_decoder == null:
		_json_decoder = GameAlgoAsyncJsonDecoder.new()
		add_child(_json_decoder)
	var decoded: Variant = await _json_decoder.call(
		"decode_dictionary", response_bytes, 2 * 1024 * 1024
	)
	if not decoded is Dictionary or not decoded.get("ok", null) is bool or not decoded["ok"]:
		var decode_error := String(decoded.get("error", "")) if decoded is Dictionary else ""
		var client_error := "response_invalid_json"
		match decode_error:
			"invalid_utf8": client_error = "response_invalid_utf8"
			"body_too_large": client_error = "response_body_too_large"
			"decoder_unavailable": client_error = "json_decoder_unavailable"
			"worker_failed": client_error = "json_decoder_failed"
		return {"ok": false, "error": client_error}
	return {"ok": true, "value": decoded.get("value", {})}


func _request_raw(
	method: String,
	path: String,
	body: Variant = null,
	body_limit_bytes: int = 2 * 1024 * 1024
) -> Dictionary:
	if _transport == null:
		_transport = GameAlgoHttpTransport.new()
		add_child(_transport)
	var url := path if path.begins_with("https://") else GameAlgoUtil.endpoint(_base_url, path)
	if GameAlgoUtil.origin(url) != GameAlgoUtil.origin(_base_url):
		return {"ok": false, "error": "cross_origin_request_rejected"}
	var headers := {"Accept": "application/json", "X-GameAlgo-Key": _game_key}
	var encoded := ""
	if body != null:
		if not GameAlgoUtil.valid_json_value(body):
			return {"ok": false, "error": "request_invalid_json"}
		headers["Content-Type"] = "application/json"
		encoded = GameAlgoUtil.canonical_json(body)
	var response: Variant = await _transport.call("send", {
		"url": url,
		"method": method,
		"headers": headers,
		"body": encoded,
		"body_limit_bytes": body_limit_bytes,
	})
	return response if response is Dictionary else {"ok": false, "error": "invalid_transport_result"}


## Mirrors the iOS and Android SDKs: on by default, prefixed, and silenced by
## passing logger = null. Games ship with it off or routed to their own sink.
## The iOS SDK reports IDFV once per startup; Godot exposes the same value
## through OS.get_unique_id(), which is identifierForVendor on iOS.
##
## Not gated on measurement consent: IDFV needs no ATT authorization, that flag
## governs events here, and neither set_attribution nor the manual identifier
## setters consult it. The iOS SDK reports it unconditionally too.
## Fire and forget: a failure here must never hold up startup.
func _report_identifier_for_vendor() -> void:
	if _reported_idfv or _platform != "ios":
		return
	if _context_id().is_empty():
		return
	_reported_idfv = true
	var idfv := GameAlgoUtil.clean(OS.get_unique_id())
	if idfv.is_empty():
		_log("idfv auto-report skipped: no vendor identifier")
		return
	var result: Dictionary = await _set_context_identifier("idfv", idfv, "")
	if not bool(result.get("ok", false)):
		_log("idfv auto-report failed: %s" % String(result.get("error", "unknown")))


static func _default_logger(message: String) -> void:
	print(message)


func _log(message: String) -> void:
	var line := "[GameAlgoSDK] " + message
	sdk_log.emit(line)
	if _logger == null:
		return
	(_logger as Callable).call(line)


func _context_id() -> String:
	var config: Variant = _snapshot.get("config", null)
	return String(config.get("contextId", "")) if config is Dictionary else ""


func _attribution_acks() -> Dictionary:
	var result: Variant = _storage.call("load_json_result", "attribution_" + _namespace)
	if not result is Dictionary or String(result.get("status", "")) != "loaded":
		return {}
	var value: Variant = result.get("value", null)
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _store_attribution_acks(acknowledged: Dictionary) -> void:
	_storage.call("save_json", "attribution_" + _namespace, acknowledged)


## Maps one advertising or analytics identifier onto the current context. The
## context must exist, because the mapping is what joins GameAlgo identity to
## the attribution provider's own reporting.
func _set_context_identifier(
	identifier_type: String, value: Variant, observed_at: String
) -> Dictionary:
	if status == "unconfigured":
		last_error = "not_configured"
		return {"ok": false, "accepted": 0, "error": last_error}
	var context_id := _context_id()
	if context_id.is_empty():
		last_error = "context_not_ready"
		return {"ok": false, "accepted": 0, "error": last_error}
	var identifier_value: Variant = GameAlgoUtil.normalize_context_identifier(identifier_type, value)
	var observed := GameAlgoUtil.clean(observed_at)
	var body := {
		"userId": _identity["userId"],
		"sessionId": tracker.current_session_id(),
		"contextId": context_id,
		"platform": _platform,
		"identifierType": identifier_type,
		"identifierValue": identifier_value,
		"observedAt": observed if not observed.is_empty() else GameAlgoUtil.utc_timestamp(),
		"identifierHash": GameAlgoUtil.sha256_text(GameAlgoUtil.canonical_json({
			"identifierType": identifier_type,
			"identifierValue": identifier_value,
		})),
	}
	var response := await _request_json("POST", "/v1/context-identifiers", body)
	if not response.get("ok", null) is bool or not response["ok"] \
			or not response.get("value", null) is Dictionary:
		last_error = String(response.get("error", "context_identifier_failed"))
		_log("context identifier sync failed: type=%s, error=%s" % [identifier_type, last_error])
		return {"ok": false, "accepted": 0, "error": last_error}
	var value_dict := response["value"] as Dictionary
	last_error = ""
	_log("context identifier synced: type=%s, accepted=%d" % [
		identifier_type, int(value_dict.get("accepted", 0))
	])
	return {"ok": bool(value_dict.get("ok", false)), "accepted": int(value_dict.get("accepted", 0))}


func _preload_config(config: Dictionary) -> bool:
	var names: Array[String] = []
	if _preload is String and String(_preload) == "all":
		for raw_ref: Variant in config["configFiles"]:
			names.append(String(raw_ref["name"]))
	elif _preload is Array:
		for raw_name: Variant in _preload:
			names.append(String(raw_name))
	if names.is_empty():
		_log("no config files to preload")
	else:
		var sorted_names := names.duplicate()
		sorted_names.sort()
		_log("preloading config files: %s" % ", ".join(sorted_names))
	var ok := true
	for name: String in names:
		var file := await fetch_config_file(name)
		if file.is_empty():
			ok = false
		else:
			_log("config file loaded: %s (%s)" % [file["name"], file["contentType"]])
	if _preload is String and String(_preload) == "all" \
			and _runtime != null and _runtime.has_method("execute"):
		for raw_assignment: Variant in config["experiments"]:
			var script: Variant = raw_assignment.get("script", null)
			if script is Dictionary and not await _fetch_script(script):
				ok = false
	if ok and not names.is_empty():
		_log("all config files loaded")
	return ok


func _fetch_script(script: Dictionary) -> bool:
	var version_id := GameAlgoUtil.clean(script.get("versionId", ""))
	var hash_value := String(script.get("hash", "")).to_lower()
	var url_value := GameAlgoUtil.clean(script.get("url", ""))
	if version_id.is_empty() or not _valid_hash(hash_value) or url_value.is_empty():
		return false
	var resolved := GameAlgoUtil.resolve_url(_base_url, url_value)
	var response := await _request_raw("GET", resolved, null, 10 * 1024 * 1024)
	if not response.get("ok", null) is bool or not response["ok"]:
		return false
	var content: Variant = _body_text(response.get("body", PackedByteArray()))
	if content == null or not _content_matches_hash(String(content), hash_value):
		return false
	if not _prepare_script(version_id, hash_value, String(content)):
		return false
	return _store_config_file("script:" + version_id, {
		"name": "script:" + version_id,
		"content": String(content),
		"contentType": String(response.get("headers", {}).get(
			"content-type", script.get("contentType", "application/javascript")
		)),
		"etag": String(response.get("headers", {}).get("etag", "")),
	})


func _publish_snapshot_assignments() -> void:
	var config: Variant = _snapshot.get("config", null)
	if not config is Dictionary:
		return
	for raw_assignment: Variant in config["experiments"]:
		var assignment := raw_assignment as Dictionary
		assignment_updated.emit(assignment.duplicate(true), _generation)
		if assignment.get("script", null) == null:
			assignment_received.emit(
				String(assignment["key"]), assignment.get("config", null), _generation
			)


func _load_cached_snapshot() -> bool:
	var loaded := _load_json_result(_snapshot_key)
	if loaded.get("status", "") != GameAlgoJsonStore.STATUS_LOADED:
		return false
	var cached: Variant = loaded.get("value", null)
	if not _valid_snapshot(cached):
		return false
	if String(cached["userId"]) != String(_identity["userId"]):
		return false
	var config := _normalize_config(cached["config"])
	if config.is_empty():
		return false
	_snapshot = (cached as Dictionary).duplicate(true)
	_snapshot["config"] = config
	_prepared_script_hashes.clear()
	_prepare_cached_scripts(config)
	_generation += 1
	tracker.set_context_id(String(config["contextId"]))
	return true


func _prepare_cached_scripts(config: Dictionary) -> void:
	for raw_assignment: Variant in config.get("experiments", []):
		var script: Variant = raw_assignment.get("script", null)
		if not script is Dictionary:
			continue
		var version_id := GameAlgoUtil.clean(script.get("versionId", ""))
		var hash_value := String(script.get("hash", "")).to_lower()
		var file: Variant = _snapshot.get("configFiles", {}).get("script:" + version_id, null)
		if version_id.is_empty() or not _valid_hash(hash_value) or not file is Dictionary \
				or not file.get("content", null) is String:
			continue
		var content := String(file["content"])
		if _content_matches_hash(content, hash_value):
			_prepare_script(version_id, hash_value, content)


func _prepare_script(version_id: String, hash_value: String, content: String) -> bool:
	if _runtime == null or not _runtime.has_method("prepare"):
		return false
	var prepared: Variant = _runtime.call("prepare", content, version_id, hash_value)
	if not (prepared is bool and bool(prepared)) \
			and not (prepared is Dictionary and prepared.get("status", "") == "ok"):
		return false
	_prepared_script_hashes["%s:%s" % [version_id, hash_value]] = true
	return true


func _persist_snapshot() -> bool:
	var saved: Variant = _storage.call("save_json", _snapshot_key, _snapshot)
	return saved is bool and saved


func _store_config_file(key: String, file: Dictionary) -> bool:
	if not _snapshot.get("configFiles", null) is Dictionary:
		_snapshot["configFiles"] = {}
	_snapshot["configFiles"][key] = file.duplicate(true)
	_snapshot["updatedAtUnix"] = Time.get_unix_time_from_system()
	return _persist_snapshot()


func _load_or_create_identity(
	explicit_user_id: String,
	explicit_created_at: String,
	explicit_created_local_at: String
) -> Dictionary:
	var loaded := _load_json_result("identity")
	var status := String(loaded.get("status", ""))
	var stored: Variant = loaded.get("value", null)
	if status == GameAlgoJsonStore.STATUS_LOADED:
		if not stored is Dictionary or GameAlgoUtil.clean(stored.get("userId", "")).is_empty() \
				or GameAlgoUtil.clean(stored.get("userCreatedAt", "")).is_empty() \
				or GameAlgoUtil.clean(stored.get("userCreatedLocalAt", "")).is_empty():
			last_error = "identity_storage_invalid"
			return {}
		if explicit_user_id.is_empty() or explicit_user_id == stored["userId"]:
			return (stored as Dictionary).duplicate(true)
	elif status != GameAlgoJsonStore.STATUS_MISSING:
		last_error = "identity_storage_read_failed"
		return {}
	var identity := {
		"userId": explicit_user_id if not explicit_user_id.is_empty() else GameAlgoUtil.uuid(),
		"userCreatedAt": explicit_created_at \
			if not explicit_created_at.is_empty() else GameAlgoUtil.utc_timestamp(),
		"userCreatedLocalAt": explicit_created_local_at \
			if not explicit_created_local_at.is_empty() else GameAlgoUtil.local_timestamp(),
	}
	var saved: Variant = _storage.call("save_json", "identity", identity)
	if not saved is bool or not saved:
		return {}
	return identity


func _load_json_result(key: String) -> Dictionary:
	var result: Variant = _storage.call("load_json_result", key)
	if not result is Dictionary:
		return {"status": GameAlgoJsonStore.STATUS_ERROR, "value": null}
	var status := String(result.get("status", ""))
	if status not in [GameAlgoJsonStore.STATUS_LOADED, GameAlgoJsonStore.STATUS_MISSING]:
		return {"status": GameAlgoJsonStore.STATUS_ERROR, "value": null}
	return {"status": status, "value": result.get("value", null)}


func _normalize_config(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var config := value as Dictionary
	for field: String in ["contextId", "gameId", "environment", "configVersion", "serverTime"]:
		if not config.get(field, null) is String or String(config[field]).is_empty():
			return {}
	if String(config["environment"]) not in ["test", "live"] \
			or not _integer_value(config.get("ttlSeconds", null), 0) \
			or not config.get("experiments", null) is Array \
			or not config.get("configFiles", null) is Array:
		return {}
	var experiments: Array[Dictionary] = []
	for raw_assignment: Variant in config["experiments"]:
		var assignment := _normalize_assignment(raw_assignment)
		if assignment.is_empty():
			return {}
		experiments.append(assignment)
	var files: Array[Dictionary] = []
	for raw_file: Variant in config["configFiles"]:
		var file := _normalize_file_reference(raw_file, false)
		if file.is_empty():
			return {}
		files.append(file)
	return {
		"contextId": String(config["contextId"]),
		"gameId": String(config["gameId"]),
		"environment": String(config["environment"]),
		"configVersion": String(config["configVersion"]),
		"ttlSeconds": int(config["ttlSeconds"]),
		"serverTime": String(config["serverTime"]),
		"experiments": experiments,
		"configFiles": files,
	}


func _normalize_assignment(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var assignment := value as Dictionary
	for field: String in ["key", "experimentId", "variant"]:
		if not assignment.get(field, null) is String or String(assignment[field]).is_empty():
			return {}
	if not assignment.has("config") or not GameAlgoUtil.valid_json_value(assignment["config"]):
		return {}
	var script: Variant = null
	if assignment.has("script") and assignment["script"] != null:
		script = _normalize_file_reference(assignment["script"], true)
		if (script as Dictionary).is_empty():
			return {}
	return {
		"key": String(assignment["key"]),
		"experimentId": String(assignment["experimentId"]),
		"variant": String(assignment["variant"]),
		"config": assignment["config"],
		"script": script,
	}


func _normalize_file_reference(value: Variant, require_version: bool) -> Dictionary:
	if not value is Dictionary:
		return {}
	var reference := value as Dictionary
	for field: String in ["name", "url", "hash"]:
		if not reference.get(field, null) is String or String(reference[field]).is_empty():
			return {}
	if _normalize_file_name(String(reference["name"])).is_empty():
		return {}
	var version_id := GameAlgoUtil.clean(reference.get("versionId", ""))
	# Protocol v1 requires the sha256 form only for executable script refs.
	# Ordinary configFiles retain their opaque server hash, matching 1.0.5.
	if require_version and (version_id.is_empty() \
			or not _valid_hash(String(reference["hash"]).to_lower())):
		return {}
	return {
		"versionId": version_id if not version_id.is_empty() else null,
		"name": String(reference["name"]),
		"url": String(reference["url"]),
		"hash": String(reference["hash"]).to_lower(),
		"contentType": String(reference.get("contentType", "")),
		"updatedAt": String(reference.get("updatedAt", "")),
	}


func _valid_snapshot(value: Variant) -> bool:
	return value is Dictionary and int(value.get("schemaVersion", 0)) == 1 \
		and value.get("config", null) is Dictionary \
		and value.get("configFiles", null) is Dictionary \
		and (value.get("updatedAtUnix", null) is int or value.get("updatedAtUnix", null) is float) \
		and value.get("userId", null) is String \
		and GameAlgoUtil.valid_json_value(value)


func _valid_preload(value: Variant) -> bool:
	if value is String:
		return value in ["all", "none"]
	if value is Array:
		for raw_name: Variant in value:
			if not raw_name is String or _normalize_file_name(String(raw_name)).is_empty():
				return false
		return true
	return false


func _normalize_file_name(value: String) -> String:
	var normalized := value.strip_edges()
	if normalized.is_empty() or normalized != value or normalized.contains(".."):
		return ""
	var regex := RegEx.new()
	regex.compile("^[A-Za-z0-9][A-Za-z0-9_.-]*$")
	return normalized if regex.search(normalized) != null else ""


func _valid_hash(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^sha256:[a-f0-9]{64}$")
	return regex.search(value) != null


func _content_matches_hash(content: String, expected: String) -> bool:
	return GameAlgoUtil.sha256_text(content) == String(expected).to_lower()


func _body_text(body: Variant) -> Variant:
	if body is String:
		return body
	if body is PackedByteArray:
		var bytes := body as PackedByteArray
		var decoded := bytes.get_string_from_utf8()
		return decoded if decoded.to_utf8_buffer() == bytes else null
	return null


func _integer_value(value: Variant, minimum: int, maximum: int = 2147483647) -> bool:
	if value is int:
		return int(value) >= minimum and int(value) <= maximum
	return value is float and is_finite(float(value)) and floor(float(value)) == float(value) \
		and float(value) >= minimum and float(value) <= maximum


func _default_platform() -> String:
	return OS.get_name().to_lower()


func _default_device() -> Dictionary:
	return {
		"runtime": "godot",
		"godotVersion": String(Engine.get_version_info().get("string", "")),
		"osName": OS.get_name(),
		"osVersion": OS.get_version(),
		"model": OS.get_model_name(),
		"locale": TranslationServer.get_locale(),
	}
