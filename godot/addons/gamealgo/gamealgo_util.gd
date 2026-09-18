extends RefCounted

const MAX_JSON_DEPTH := 32


static func clean(value: Variant) -> String:
	return String(value).strip_edges() if value is String else ""


static func uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	if bytes.size() != 16:
		return "%s-%s" % [str(Time.get_ticks_usec()), str(randi())]
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var encoded := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		encoded.substr(0, 8), encoded.substr(8, 4), encoded.substr(12, 4),
		encoded.substr(16, 4), encoded.substr(20, 12),
	]


static func sha256_text(value: String) -> String:
	return "sha256:" + _sha256(value).hex_encode()


static func sha256_short(value: String) -> String:
	return _sha256(value).hex_encode()


static func _sha256(value: String) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	if context.update(value.to_utf8_buffer()) != OK:
		return PackedByteArray()
	return context.finish()


static func canonical_json(value: Variant) -> String:
	return JSON.stringify(value, "", true, true)


static func utc_timestamp(unix_time: float = Time.get_unix_time_from_system()) -> String:
	var milliseconds := int(floor(unix_time * 1000.0)) % 1000
	var base := Time.get_datetime_string_from_unix_time(int(floor(unix_time)), true)
	return "%s.%03dZ" % [base, milliseconds]


static func local_timestamp(unix_time: float = Time.get_unix_time_from_system()) -> String:
	var zone := Time.get_time_zone_from_system()
	var bias_minutes := int(zone.get("bias", 0))
	var local_unix := unix_time + float(bias_minutes * 60)
	var milliseconds := int(floor(local_unix * 1000.0)) % 1000
	var base := Time.get_datetime_string_from_unix_time(int(floor(local_unix)), true)
	var sign_text := "+" if bias_minutes >= 0 else "-"
	var absolute_bias: int = absi(bias_minutes)
	return "%s.%03d%s%02d:%02d" % [
		base, milliseconds, sign_text, absolute_bias / 60, absolute_bias % 60,
	]


static func timezone_name() -> String:
	var zone := Time.get_time_zone_from_system()
	return clean(zone.get("name", "")) if clean(zone.get("name", "")) != "" else "UTC"


static func is_game_key(value: String) -> bool:
	if value != value.strip_edges() or not value.begins_with("ga_live_"):
		return false
	if value.length() < 11 or value.length() > 512:
		return false
	const EXTRA := "._:/+~=-"
	for index: int in range(8, value.length()):
		var code := value.unicode_at(index)
		var ascii_alphanumeric := (code >= 48 and code <= 57) \
			or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if not ascii_alphanumeric and not EXTRA.contains(String.chr(code)):
			return false
	return true


static func is_https_base_url(value: String) -> bool:
	if value != value.strip_edges() or not value.begins_with("https://"):
		return false
	if value.contains("#") or value.contains("?") or value.contains("@") \
			or value.contains("\\"):
		return false
	for index: int in range(value.length()):
		var code := value.unicode_at(index)
		if code < 32 or code == 127:
			return false
	var rest := value.trim_prefix("https://")
	if rest.is_empty() or rest.begins_with("/"):
		return false
	var authority := rest.get_slice("/", 0)
	if authority.count(":") > 1:
		return false
	var host := authority.get_slice(":", 0)
	if authority.contains(":") and authority.get_slice(":", 1) != "443":
		return false
	return _valid_hostname(host)


static func _valid_hostname(value: String) -> bool:
	if value.is_empty() or value.length() > 253:
		return false
	var labels := value.split(".", false)
	if labels.size() < 2:
		return false
	for label_index: int in range(labels.size()):
		var label := String(labels[label_index])
		if label.is_empty() or label.length() > 63 \
				or label.begins_with("-") or label.ends_with("-"):
			return false
		for index: int in range(label.length()):
			var code := label.unicode_at(index)
			var ascii_alphanumeric := (code >= 48 and code <= 57) \
				or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
			if not ascii_alphanumeric and code != 45:
				return false
	var suffix := String(labels[-1])
	if suffix.length() < 2:
		return false
	for index: int in range(suffix.length()):
		var code := suffix.unicode_at(index)
		if not ((code >= 65 and code <= 90) or (code >= 97 and code <= 122)):
			return false
	return true


static func endpoint(base_url: String, path: String) -> String:
	return base_url.trim_suffix("/") + "/" + path.trim_prefix("/")


static func origin(value: String) -> String:
	if not value.begins_with("https://"):
		return ""
	var rest := value.trim_prefix("https://")
	var authority := rest.get_slice("/", 0).to_lower()
	if authority.is_empty() or authority.contains("@"):
		return ""
	if authority.ends_with(":443"):
		authority = authority.trim_suffix(":443")
	return "https://" + authority if not authority.is_empty() else ""


static func resolve_url(base_url: String, candidate: String) -> String:
	if candidate.begins_with("https://"):
		return candidate
	if candidate.begins_with("/"):
		return origin(base_url) + candidate
	return base_url.trim_suffix("/") + "/" + candidate


static func valid_json_value(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is String or value is bool or value is int:
		return true
	if value is float:
		return is_finite(float(value))
	if value is Array:
		for child: Variant in value:
			if not valid_json_value(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not key is String or not valid_json_value(value[key], depth + 1):
				return false
		return true
	return false


static func normalize_payload(payload: Variant) -> Dictionary:
	if not payload is Dictionary:
		return {}
	var normalized: Dictionary = {}
	for raw_key: Variant in payload:
		if not raw_key is String or String(raw_key).is_empty():
			continue
		var value: Variant = payload[raw_key]
		if value == null or value is String or value is bool or value is int:
			normalized[raw_key] = value
		elif value is float:
			if is_finite(float(value)):
				normalized[raw_key] = value
		elif (value is Array or value is Dictionary) and valid_json_value(value):
			normalized[raw_key] = canonical_json(value)
	return normalized


static func dictionary_path(source: Variant, path: String, fallback: Variant = null) -> Variant:
	if path.is_empty():
		return source
	var current: Variant = source
	for segment: String in path.split("."):
		if current is Dictionary:
			if not (current as Dictionary).has(segment):
				return fallback
			current = (current as Dictionary)[segment]
		elif current is Array and segment.is_valid_int():
			var index := int(segment)
			if index < 0 or index >= (current as Array).size():
				return fallback
			current = (current as Array)[index]
		else:
			return fallback
	return current


const UNKNOWN_ATTRIBUTION_VALUES := ["unknown", "unattr", "unattributed", "no user consent"]


## Folds case, separators and repeated whitespace so provider spellings compare
## the same way they do in the other SDKs.
static func canonical_attribution_value(value: Variant) -> String:
	if not value is String:
		return ""
	var folded := String(value).strip_edges().to_lower()
	var result := ""
	var previous_space := false
	for index: int in range(folded.length()):
		var character := folded[index]
		var is_separator := character == "_" or character == "-" \
			or character == " " or character == "\t" or character == "\n" or character == "\r"
		if is_separator:
			previous_space = true
			continue
		if previous_space and not result.is_empty():
			result += " "
		previous_space = false
		result += character
	return result


static func is_unknown_attribution_value(value: String) -> bool:
	return value in UNKNOWN_ATTRIBUTION_VALUES


static func canonical_attribution_field(attribution: Dictionary, field: String) -> String:
	return canonical_attribution_value(attribution.get(field, null))


## Adjust reports "organic" and "unknown" through several fields; collapse them
## so downstream reporting does not treat them as real networks.
static func attribution_status(
	provider: String, raw_status: String, attribution: Dictionary
) -> String:
	var status := canonical_attribution_value(raw_status)
	if status == "organic":
		return "organic"
	if is_unknown_attribution_value(status):
		return "unknown"
	if provider.to_lower() == "adjust":
		var network := canonical_attribution_field(attribution, "network")
		var tracker_name := canonical_attribution_field(attribution, "tracker_name")
		if tracker_name.is_empty():
			tracker_name = canonical_attribution_field(attribution, "trackerName")
		var tracker_token := canonical_attribution_field(attribution, "tracker_token")
		if tracker_token.is_empty():
			tracker_token = canonical_attribution_field(attribution, "trackerToken")
		for value: String in [network, tracker_name, tracker_token]:
			if is_unknown_attribution_value(value):
				return "unknown"
		for value: String in [network, tracker_name, tracker_token]:
			if value == "organic":
				return "organic"
	return raw_status if not raw_status.is_empty() else "attributed"


## A zeroed GAID or IDFA means the user opted out; it is reported as a cleared
## mapping rather than a real identifier.
static func normalize_context_identifier(identifier_type: String, value: Variant) -> Variant:
	var cleaned := clean(value)
	if cleaned.is_empty():
		return null
	if identifier_type == "gaid" or identifier_type == "idfa":
		var zeroed := RegEx.create_from_string("^0{8}-0{4}-0{4}-0{4}-0{12}$")
		if zeroed != null and zeroed.search(cleaned.to_lower()) != null:
			return null
	return cleaned
