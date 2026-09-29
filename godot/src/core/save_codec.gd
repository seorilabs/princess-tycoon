class_name SaveCodec
extends RefCounted

const CURRENT_SCHEMA_VERSION: int = 2

const V1_STAT_MAP: Dictionary = {
	"stamina": "stamina",
	"strength": "strength",
	"intelligence": "intelligence",
	"refinement": "refinement",
	"sensitivity": "sensitivity",
	"charm": "style",
	"temperament": "discipline",
	"morals": "morals",
	"faith": "faith",
	"combatSkill": "combat",
	"magicSkill": "magic",
	"etiquette": "etiquette",
	"conversation": "communication",
	"art": "art",
	"cooking": "cooking",
	"housework": "housework",
	"nursing": "nursing",
	"dance": "dance",
}


static func encode(state: Dictionary) -> String:
	# Godot's JSON parser materializes JSON numbers as floats. Canonicalizing
	# integers to JSON floats before the first write makes encode->decode->encode
	# byte-stable while known integer fields are restored by state sanitizers.
	return JSON.stringify(_canonical_json_numbers(StateFactory.ensure_v2_shape(state)), "", true, true)


static func decode(payload: String) -> Dictionary:
	var result: Dictionary = decode_result(payload)
	return (result.get("state", {}) as Dictionary).duplicate(true) if bool(result.get("ok", false)) else {}


static func decode_result(payload: String) -> Dictionary:
	var parser: JSON = JSON.new()
	var parse_error: Error = parser.parse(payload)
	if parse_error != OK:
		return {
			"ok": false,
			"error": "JSON 오류(line %d): %s" % [parser.get_error_line(), parser.get_error_message()],
		}
	if parser.data is not Dictionary:
		return {"ok": false, "error": "세이브 최상위 값은 객체여야 합니다."}
	var raw_state: Dictionary = parser.data as Dictionary
	var migrated: Dictionary = migrate(raw_state)
	if migrated.is_empty():
		return {"ok": false, "error": "지원하지 않는 세이브 버전입니다."}
	return {"ok": true, "state": migrated}


static func migrate(raw_state: Dictionary) -> Dictionary:
	var version: int = int(raw_state.get("schemaVersion", raw_state.get("version", 1)))
	if version <= 1:
		return migrate_v1(raw_state)
	if version == CURRENT_SCHEMA_VERSION:
		return StateFactory.ensure_v2_shape(raw_state)
	return {}


static func migrate_v1(v1_state: Dictionary) -> Dictionary:
	var meta: Dictionary = v1_state.get("meta", {}) as Dictionary
	var player_name: String = str(v1_state.get("playerName", v1_state.get("name", meta.get("daughterName", "수련생"))))
	var migrated: Dictionary = StateFactory.create(int(v1_state.get("seed", 1)), player_name)
	var old_stats: Dictionary = v1_state.get("stats", {}) as Dictionary
	var new_stats: Dictionary = migrated["stats"] as Dictionary
	for old_key: Variant in old_stats.keys():
		var mapped_key: String = str(V1_STAT_MAP.get(str(old_key), ""))
		if not mapped_key.is_empty():
			new_stats[mapped_key] = maxf(0.0, float(old_stats[old_key]))
	var old_meters: Dictionary = v1_state.get("meters", {}) as Dictionary
	var new_meters: Dictionary = migrated["meters"] as Dictionary
	new_meters["stress"] = clampf(float(old_meters.get("stress", 0.0)), 0.0, 100.0)
	new_meters["reputation"] = maxf(0.0, float(old_meters.get("reputation", 50.0)))
	new_meters["integrityViolations"] = maxi(0, int(old_meters.get("sin", 0)))
	var gold: Dictionary = BigValue.from_number(old_meters.get("gold", v1_state.get("gold", 3000)))
	var big_values: Dictionary = migrated["bigValues"] as Dictionary
	big_values["gold"] = BigValue.clone(gold)
	big_values["lifetimeGold"] = BigValue.clone(gold)
	var ending_dex: Array = v1_state.get("endingDex", v1_state.get("codex", [])) as Array
	var titles: Dictionary = migrated["careerTitles"] as Dictionary
	for raw_title: Variant in ending_dex:
		var title_id: String = str(raw_title)
		if not title_id.is_empty():
			titles[title_id] = {"stars": 1, "firstSeason": 0, "lastSeason": 0}
	# Retain an explicit audit copy of legacy-only stat values without feeding
	# unsafe legacy concepts back into modern gameplay calculations.
	(migrated["flags"] as Dictionary)["migratedFromV1"] = true
	(migrated["flags"] as Dictionary)["legacyStatKeys"] = old_stats.keys()
	return StateFactory.ensure_v2_shape(migrated)


static func save_atomic(path: String, state: Dictionary) -> Dictionary:
	if path.strip_edges().is_empty():
		return {"ok": false, "error": "세이브 경로가 비어 있음"}
	var absolute_path: String = _absolute_path(path)
	var directory: String = absolute_path.get_base_dir()
	var mkdir_error: Error = DirAccess.make_dir_recursive_absolute(directory)
	if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": "세이브 디렉터리 생성 실패: %s" % error_string(mkdir_error)}
	var temporary_path: String = absolute_path + ".tmp"
	var backup_path: String = absolute_path + ".bak"
	var file: FileAccess = FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "임시 세이브 파일 열기 실패"}
	file.store_string(encode(state))
	file.flush()
	file.close()
	var verify_file: FileAccess = FileAccess.open(temporary_path, FileAccess.READ)
	if verify_file == null:
		return {"ok": false, "error": "임시 세이브 검증 파일 열기 실패"}
	var verify_result: Dictionary = decode_result(verify_file.get_as_text())
	verify_file.close()
	if not bool(verify_result.get("ok", false)):
		return {"ok": false, "error": "임시 세이브 검증 실패: %s" % str(verify_result.get("error", ""))}
	if FileAccess.file_exists(absolute_path):
		if FileAccess.file_exists(backup_path):
			DirAccess.remove_absolute(backup_path)
		var backup_error: Error = DirAccess.copy_absolute(absolute_path, backup_path)
		if backup_error != OK:
			return {"ok": false, "error": "백업 생성 실패: %s" % error_string(backup_error)}
	var rename_error: Error = DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		# Some platforms do not replace an existing destination. The old file is
		# already safe in .bak, so remove it and retry the same-filesystem rename.
		if FileAccess.file_exists(absolute_path):
			var remove_error: Error = DirAccess.remove_absolute(absolute_path)
			if remove_error != OK:
				return {"ok": false, "error": "기존 세이브 교체 실패: %s" % error_string(remove_error)}
		rename_error = DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		return {"ok": false, "error": "원자 교체 실패: %s" % error_string(rename_error)}
	return {"ok": true, "path": absolute_path, "backupPath": backup_path}


static func load_with_backup(path: String) -> Dictionary:
	var absolute_path: String = _absolute_path(path)
	var backup_path: String = absolute_path + ".bak"
	var main_result: Dictionary = _load_file(absolute_path)
	if bool(main_result.get("ok", false)):
		main_result["source"] = "main"
		main_result["recovered"] = false
		return main_result
	var backup_result: Dictionary = _load_file(backup_path)
	if bool(backup_result.get("ok", false)):
		backup_result["source"] = "backup"
		backup_result["recovered"] = true
		backup_result["mainError"] = str(main_result.get("error", ""))
		# Do not overwrite or delete the corrupted main file: the exact bytes stay
		# available for diagnosis while the caller receives the valid backup state.
		backup_result["corruptMainPreservedAt"] = absolute_path
		return backup_result
	return {
		"ok": false,
		"error": "본 파일 및 백업 로드 실패",
		"mainError": str(main_result.get("error", "")),
		"backupError": str(backup_result.get("error", "")),
	}


static func _load_file(absolute_path: String) -> Dictionary:
	if not FileAccess.file_exists(absolute_path):
		return {"ok": false, "error": "파일 없음: %s" % absolute_path}
	var file: FileAccess = FileAccess.open(absolute_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "파일 열기 실패: %s" % absolute_path}
	var payload: String = file.get_as_text()
	file.close()
	return decode_result(payload)


static func _absolute_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("user://" + path)


static func _canonical_json_numbers(value: Variant) -> Variant:
	if value is int:
		return float(value)
	if value is Dictionary:
		var dict_result: Dictionary = {}
		for key: Variant in (value as Dictionary).keys():
			dict_result[key] = _canonical_json_numbers((value as Dictionary)[key])
		return dict_result
	if value is Array:
		var array_result: Array = []
		for child: Variant in value as Array:
			array_result.append(_canonical_json_numbers(child))
		return array_result
	return value
