class_name GrowthPolicy
extends RefCounted

const ALLOWED_WEIGHT_KEYS: Array[String] = [
	"stamina", "strength", "intelligence", "refinement", "sensitivity",
	"style", "discipline", "morals", "faith", "combat", "magic",
	"etiquette", "communication", "art", "cooking", "housework",
	"nursing", "dance", "reputation", "gold",
]
const DEFAULT_PROFILES_PATH: String = "res://data/profiles.json"

static var _preset_weights_by_id: Dictionary = {}
static var _profiles_configured: bool = false


static func configure_profiles(profiles: Array[Dictionary]) -> void:
	_preset_weights_by_id.clear()
	for profile: Dictionary in profiles:
		var preset_id: String = str(profile.get("id", "")).strip_edges()
		var raw_weights: Variant = profile.get("weights", {})
		if preset_id.is_empty() or preset_id == "custom" or raw_weights is not Dictionary:
			continue
		var normalized: Dictionary = _normalize_positive_weights(raw_weights as Dictionary)
		if _has_positive_weight(normalized):
			_preset_weights_by_id[preset_id] = normalized
	_profiles_configured = true


static func has_preset(preset_id: String) -> bool:
	_ensure_profiles_configured()
	return _preset_weights_by_id.has(preset_id)


static func get_preset_weights(preset_id: String) -> Dictionary:
	_ensure_profiles_configured()
	var resolved_id: String = preset_id if _preset_weights_by_id.has(preset_id) else "balanced"
	return (_preset_weights_by_id.get(resolved_id, _complete_weights({})) as Dictionary).duplicate(true)


static func normalize_weights(raw_weights: Dictionary) -> Dictionary:
	var result: Dictionary = _normalize_positive_weights(raw_weights)
	if not _has_positive_weight(result):
		return get_preset_weights("balanced")
	return result


static func create(
	preset: String = "balanced",
	weights: Dictionary = {},
	banned_tags: Array = [],
	reserve_gold: Variant = 300,
	max_stress: float = 72.0,
	risk_tolerance: float = 0.35,
	preferred_tags: Array = []
) -> Dictionary:
	var resolved_preset: String = preset if preset == "custom" or has_preset(preset) else "balanced"
	var resolved_weights: Dictionary
	if resolved_preset == "custom":
		if _has_positive_weight(weights):
			resolved_weights = normalize_weights(weights)
		else:
			resolved_preset = "balanced"
			resolved_weights = get_preset_weights("balanced")
	else:
		# Preset policies always rehydrate from profiles.json. Saved or caller-
		# supplied weights must not shadow the content data source of truth.
		resolved_weights = get_preset_weights(resolved_preset)
	var clean_tags: Array[String] = []
	for raw_tag: Variant in banned_tags:
		var tag: String = str(raw_tag).strip_edges()
		if not tag.is_empty() and not clean_tags.has(tag):
			clean_tags.append(tag)
	clean_tags.sort()
	var clean_preferred_tags: Array[String] = []
	for raw_tag: Variant in preferred_tags:
		var tag: String = str(raw_tag).strip_edges()
		if not tag.is_empty() and not clean_preferred_tags.has(tag):
			clean_preferred_tags.append(tag)
	clean_preferred_tags.sort()
	return {
		"preset": resolved_preset,
		"weights": resolved_weights,
		"bannedTags": clean_tags,
		"reserveGold": BigValue.from_number(reserve_gold),
		"maxStress": clampf(max_stress, 0.0, 100.0),
		"riskTolerance": clampf(risk_tolerance, 0.0, 1.0),
		"preferredTags": clean_preferred_tags,
	}


static func sanitize(policy: Dictionary) -> Dictionary:
	return create(
		str(policy.get("preset", "balanced")),
		policy.get("weights", {}) as Dictionary,
		policy.get("bannedTags", []) as Array,
		policy.get("reserveGold", BigValue.from_number(300)),
		float(policy.get("maxStress", 72.0)),
		float(policy.get("riskTolerance", 0.35)),
		policy.get("preferredTags", []) as Array
	)


static func _complete_weights(raw_weights: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in ALLOWED_WEIGHT_KEYS:
		var value: float = float(raw_weights.get(key, 0.0))
		if is_nan(value) or is_inf(value) or value < 0.0:
			value = 0.0
		result[key] = value
	return result


static func _normalize_positive_weights(raw_weights: Dictionary) -> Dictionary:
	var result: Dictionary = _complete_weights(raw_weights)
	var total: float = 0.0
	for key: String in ALLOWED_WEIGHT_KEYS:
		total += float(result[key])
	if total <= 0.0:
		return result
	for key: String in ALLOWED_WEIGHT_KEYS:
		result[key] = float(result[key]) / total
	return result


static func _ensure_profiles_configured() -> void:
	if _profiles_configured:
		return
	_profiles_configured = true
	if not FileAccess.file_exists(DEFAULT_PROFILES_PATH):
		return
	var file: FileAccess = FileAccess.open(DEFAULT_PROFILES_PATH, FileAccess.READ)
	if file == null:
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or parser.data is not Array:
		return
	var profiles: Array[Dictionary] = []
	for raw_profile: Variant in parser.data as Array:
		if raw_profile is Dictionary:
			profiles.append((raw_profile as Dictionary).duplicate(true))
	configure_profiles(profiles)


static func _has_positive_weight(raw_weights: Dictionary) -> bool:
	for key: String in ALLOWED_WEIGHT_KEYS:
		var value: float = float(raw_weights.get(key, 0.0))
		if not is_nan(value) and not is_inf(value) and value > 0.0:
			return true
	return false
