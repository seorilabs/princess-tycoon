class_name ContentDB
extends RefCounted

const EXPECTED_COUNTS: Dictionary = {
	"activities": 43,
	"events": 26,
	"items": 21,
	"careers": 38,
	"profiles": 8,
}
const EXPECTED_PROFILE_IDS: Array[String] = [
	"balanced", "martial", "scholar", "artist",
	"leader", "care", "explorer", "prosperity",
]
const EXPECTED_ACTIVITY_KINDS: Dictionary = {
	"education": 15,
	"job": 11,
	"rest": 4,
	"adventure": 5,
	"challenge": 8,
}

var config: Dictionary = {}
var procedural: Dictionary = {}
var profiles: Array[Dictionary] = []
var activities: Array[Dictionary] = []
var events: Array[Dictionary] = []
var items: Array[Dictionary] = []
var careers: Array[Dictionary] = []

var _activity_by_id: Dictionary = {}
var _event_by_id: Dictionary = {}
var _item_by_id: Dictionary = {}
var _career_by_id: Dictionary = {}
var _profile_by_id: Dictionary = {}
var _last_report: Dictionary = {"ok": false, "errors": ["아직 로드되지 않음"]}


func load_all(base_path: String = "res://data") -> Dictionary:
	clear()
	var errors: Array[String] = []
	var object_specs: Array[Dictionary] = [
		{"file": "config.json", "target": "config"},
		{"file": "procedural.json", "target": "procedural"},
	]
	for spec: Dictionary in object_specs:
		var object_result: Dictionary = _read_json(base_path.path_join(str(spec["file"])), TYPE_DICTIONARY)
		if not bool(object_result.get("ok", false)):
			errors.append(str(object_result.get("error", "JSON 로드 실패")))
			continue
		set(str(spec["target"]), (object_result["data"] as Dictionary).duplicate(true))

	var array_specs: Array[Dictionary] = [
		{"file": "profiles.json", "target": "profiles"},
		{"file": "activities.json", "target": "activities"},
		{"file": "events.json", "target": "events"},
		{"file": "items.json", "target": "items"},
		{"file": "careers.json", "target": "careers"},
	]
	for spec: Dictionary in array_specs:
		var array_result: Dictionary = _read_json(base_path.path_join(str(spec["file"])), TYPE_ARRAY)
		if not bool(array_result.get("ok", false)):
			errors.append(str(array_result.get("error", "JSON 로드 실패")))
			continue
		var typed_items: Array[Dictionary] = []
		for raw_entry: Variant in array_result["data"] as Array:
			if raw_entry is Dictionary:
				typed_items.append((raw_entry as Dictionary).duplicate(true))
			else:
				errors.append("%s 항목은 객체여야 합니다." % str(spec["file"]))
		set(str(spec["target"]), typed_items)

	GrowthPolicy.configure_profiles(profiles)
	_rebuild_indexes(errors)
	errors.append_array(_validate_schema())
	var count_report: Dictionary = validate_counts()
	for count_error: Variant in count_report.get("errors", []):
		errors.append(str(count_error))
	_last_report = {
		"ok": errors.is_empty(),
		"errors": errors,
		"counts": {
			"activities": activities.size(),
			"events": events.size(),
			"items": items.size(),
			"careers": careers.size(),
			"profiles": profiles.size(),
		},
		"activityKinds": count_report.get("activityKinds", {}),
	}
	return _last_report.duplicate(true)


func clear() -> void:
	config.clear()
	procedural.clear()
	profiles.clear()
	activities.clear()
	events.clear()
	items.clear()
	careers.clear()
	_activity_by_id.clear()
	_event_by_id.clear()
	_item_by_id.clear()
	_career_by_id.clear()
	_profile_by_id.clear()


func get_last_report() -> Dictionary:
	return _last_report.duplicate(true)


func is_ready() -> bool:
	return bool(_last_report.get("ok", false))


func validate_counts() -> Dictionary:
	var errors: Array[String] = []
	var actual_counts: Dictionary = {
		"activities": activities.size(),
		"events": events.size(),
		"items": items.size(),
		"careers": careers.size(),
		"profiles": profiles.size(),
	}
	for key: String in EXPECTED_COUNTS.keys():
		if int(actual_counts.get(key, -1)) != int(EXPECTED_COUNTS[key]):
			errors.append("%s 개수 불일치: 기대 %d, 실제 %d" % [key, int(EXPECTED_COUNTS[key]), int(actual_counts.get(key, -1))])
	var kind_counts: Dictionary = {}
	for activity: Dictionary in activities:
		var kind: String = str(activity.get("kind", ""))
		kind_counts[kind] = int(kind_counts.get(kind, 0)) + 1
	for kind: String in EXPECTED_ACTIVITY_KINDS.keys():
		if int(kind_counts.get(kind, 0)) != int(EXPECTED_ACTIVITY_KINDS[kind]):
			errors.append("활동 분류 %s 개수 불일치: 기대 %d, 실제 %d" % [kind, int(EXPECTED_ACTIVITY_KINDS[kind]), int(kind_counts.get(kind, 0))])
	return {"ok": errors.is_empty(), "errors": errors, "activityKinds": kind_counts}


func get_activity(content_id: String) -> Dictionary:
	return (_activity_by_id.get(content_id, {}) as Dictionary).duplicate(true)


func get_event(content_id: String) -> Dictionary:
	return (_event_by_id.get(content_id, {}) as Dictionary).duplicate(true)


func get_item(content_id: String) -> Dictionary:
	return (_item_by_id.get(content_id, {}) as Dictionary).duplicate(true)


func get_career(content_id: String) -> Dictionary:
	return (_career_by_id.get(content_id, {}) as Dictionary).duplicate(true)


func get_profile(content_id: String) -> Dictionary:
	return (_profile_by_id.get(content_id, {}) as Dictionary).duplicate(true)


func get_activities() -> Array[Dictionary]:
	return activities.duplicate(true)


func get_events() -> Array[Dictionary]:
	return events.duplicate(true)


func get_items() -> Array[Dictionary]:
	return items.duplicate(true)


func get_careers() -> Array[Dictionary]:
	return careers.duplicate(true)


func _read_json(path: String, expected_type: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "필수 데이터 파일 없음: %s" % path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "데이터 파일 열기 실패: %s" % path}
	var parser: JSON = JSON.new()
	var parse_error: Error = parser.parse(file.get_as_text())
	if parse_error != OK:
		return {
			"ok": false,
			"error": "%s JSON 오류(line %d): %s" % [path, parser.get_error_line(), parser.get_error_message()],
		}
	var data: Variant = parser.data
	if typeof(data) != expected_type:
		var expected_name: String = "객체" if expected_type == TYPE_DICTIONARY else "배열"
		return {"ok": false, "error": "%s 최상위 값은 %s여야 합니다." % [path, expected_name]}
	return {"ok": true, "data": data}


func _rebuild_indexes(errors: Array[String]) -> void:
	_index_entries(activities, _activity_by_id, "activities", errors)
	_index_entries(events, _event_by_id, "events", errors)
	_index_entries(items, _item_by_id, "items", errors)
	_index_entries(careers, _career_by_id, "careers", errors)
	_index_entries(profiles, _profile_by_id, "profiles", errors)


func _index_entries(entries: Array[Dictionary], target: Dictionary, label: String, errors: Array[String]) -> void:
	for entry: Dictionary in entries:
		var content_id: String = str(entry.get("id", ""))
		if content_id.is_empty():
			errors.append("%s에 id가 없는 항목이 있습니다." % label)
		elif target.has(content_id):
			errors.append("%s 중복 id: %s" % [label, content_id])
		else:
			target[content_id] = entry


func _validate_schema() -> Array[String]:
	var errors: Array[String] = []
	var loaded_profile_ids: Array[String] = []
	for profile: Dictionary in profiles:
		_validate_required_fields(profile, ["id", "name", "description", "weights", "preferredTags"], "profile", errors)
		var profile_id: String = str(profile.get("id", ""))
		loaded_profile_ids.append(profile_id)
		var raw_weights: Variant = profile.get("weights", {})
		if raw_weights is not Dictionary:
			errors.append("profile %s weights는 객체여야 합니다." % profile_id)
			continue
		var total: float = 0.0
		for raw_key: Variant in (raw_weights as Dictionary).keys():
			var weight_key: String = str(raw_key)
			if not GrowthPolicy.ALLOWED_WEIGHT_KEYS.has(weight_key):
				errors.append("profile %s 허용되지 않은 weight 키: %s" % [profile_id, weight_key])
				continue
			var raw_value: Variant = (raw_weights as Dictionary)[raw_key]
			if raw_value is not float and raw_value is not int:
				errors.append("profile %s weight %s는 숫자여야 합니다." % [profile_id, weight_key])
				continue
			var value: float = float(raw_value)
			if is_nan(value) or is_inf(value) or value < 0.0:
				errors.append("profile %s weight %s는 0 이상의 유한수여야 합니다." % [profile_id, weight_key])
				continue
			total += value
		if absf(total - 1.0) > 0.000000001:
			errors.append("profile %s weight 합 불일치: %.12f" % [profile_id, total])
		var preferred_tags: Variant = profile.get("preferredTags", [])
		if preferred_tags is not Array or (preferred_tags as Array).is_empty():
			errors.append("profile %s preferredTags는 비어 있지 않은 배열이어야 합니다." % profile_id)
	for expected_profile_id: String in EXPECTED_PROFILE_IDS:
		if not loaded_profile_ids.has(expected_profile_id):
			errors.append("필수 profile 누락: %s" % expected_profile_id)
	var activity_fields: Array[String] = ["id", "kind", "name", "description", "durationSlots", "baseCost", "baseReward", "energyDelta", "stressDelta", "risk", "primaryStat", "gains", "fixedDeltas", "requires", "tags"]
	for activity: Dictionary in activities:
		_validate_required_fields(activity, activity_fields, "activity", errors)
		var duration_slots: int = int(activity.get("durationSlots", 0))
		var risk: float = float(activity.get("risk", -1.0))
		var energy_delta: float = float(activity.get("energyDelta", -1000.0))
		var stress_delta: float = float(activity.get("stressDelta", -1000.0))
		if duration_slots < 1 or duration_slots > 6:
			errors.append("%s durationSlots 범위 오류" % str(activity.get("id", "?")))
		if risk < 0.0 or risk > 1.0:
			errors.append("%s risk 범위 오류" % str(activity.get("id", "?")))
		if energy_delta < -40.0 or energy_delta > 100.0:
			errors.append("%s energyDelta 범위 오류" % str(activity.get("id", "?")))
		if stress_delta < -100.0 or stress_delta > 30.0:
			errors.append("%s stressDelta 범위 오류" % str(activity.get("id", "?")))
		if str(activity.get("kind", "")) == "challenge":
			_validate_required_fields(activity, ["challengeWeights", "baseDifficulty", "rewardTable"], "challenge", errors)
		elif str(activity.get("kind", "")) == "adventure":
			_validate_required_fields(activity, ["nodes", "enemyPool", "lootTable"], "adventure", errors)
			if int(activity.get("nodes", 0)) != 3:
				errors.append("%s adventure nodes는 3이어야 합니다." % str(activity.get("id", "?")))
	for event: Dictionary in events:
		_validate_required_fields(event, ["id", "type", "once", "priority", "weight", "trigger", "choices", "defaultChoice", "cooldownSlots"], "event", errors)
	for item: Dictionary in items:
		_validate_required_fields(item, ["id", "name", "category", "basePrice", "stackable", "equipSlot", "modifiers", "useEffects", "tags"], "item", errors)
	for career: Dictionary in careers:
		_validate_required_fields(career, ["id", "name", "category", "weights", "gate", "baseRenown", "description"], "career", errors)
	return errors


func _validate_required_fields(entry: Dictionary, fields: Array[String], label: String, errors: Array[String]) -> void:
	for field: String in fields:
		if not entry.has(field):
			errors.append("%s %s 필드 누락: %s" % [label, str(entry.get("id", "?")), field])
