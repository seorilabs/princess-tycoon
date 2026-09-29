extends SceneTree

# GDD에서 논리 slot 1회를 게임 내 하루의 핵심 활동으로 정의한다.
const CHECKPOINT_DAYS: Array[int] = [1, 7, 30]
const SIMULATION_SEED: int = 20260714

var _failures: Array[String] = []
var _passes: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[BALANCE] 1 slot = 1 in-game day, seed=%d" % SIMULATION_SEED)
	var engine: GameEngine = GameEngine.new()
	var initial: Dictionary = engine.initialize(SIMULATION_SEED)
	var previous_day: int = 0
	var previous_activities: int = int((initial.get("lifetimeStats", {}) as Dictionary).get("activities", 0))
	var initial_total_stats: float = _total_stats(initial)

	for day: int in CHECKPOINT_DAYS:
		var delta: int = day - previous_day
		var advance_result: Dictionary = engine.advance_slots(delta)
		var state: Dictionary = engine.get_state()
		var activities: int = int((state.get("lifetimeStats", {}) as Dictionary).get("activities", 0))
		var activity_delta: int = activities - previous_activities

		_check(int(advance_result.get("slotsAdvanced", -1)) == delta, "%d일 요청 slot 진행" % day)
		_check(int((state.get("time", {}) as Dictionary).get("slot", -1)) == day, "%d일 논리 시각 일치" % day)
		_check(not _contains_non_finite(state), "%d일 NaN/INF 없음" % day)
		_check(bool(engine.validate_state().get("ok", false)), "%d일 상태 불변식" % day)
		_check(_valid_big_values(state), "%d일 BigValue 유효" % day)
		if previous_day > 0:
			_check(activity_delta > 0, "%d~%d일 활동 진행 정체 없음" % [previous_day, day])

		var summary: Dictionary = _summary(day, activity_delta, state, engine)
		print("[BALANCE] %s" % JSON.stringify(summary, "", true, true))
		previous_day = day
		previous_activities = activities

	var final_state: Dictionary = engine.get_state()
	_check(int((final_state.get("lifetimeStats", {}) as Dictionary).get("activities", 0)) > 0, "30일 내 활동 완료")
	_check(_total_stats(final_state) > initial_total_stats, "30일 내 총 능력치 성장")
	_check(not (final_state.get("mastery", {}) as Dictionary).is_empty(), "30일 내 활동 숙련 성장")
	_finish()


func _summary(day: int, activity_delta: int, state: Dictionary, engine: GameEngine) -> Dictionary:
	var time: Dictionary = state.get("time", {}) as Dictionary
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var big_values: Dictionary = state.get("bigValues", {}) as Dictionary
	var lifetime: Dictionary = state.get("lifetimeStats", {}) as Dictionary
	var generated: Dictionary = state.get("generatedContent", {}) as Dictionary
	return {
		"day": day,
		"slot": int(time.get("slot", 0)),
		"year": int(time.get("year", 1)),
		"season": int(time.get("season", 1)),
		"completedActivities": int(lifetime.get("activities", 0)),
		"completedActivitiesSincePrevious": activity_delta,
		"worldTier": int(state.get("worldTier", 1)),
		"gold": BigValue.format_short(big_values.get("gold", BigValue.zero()) as Dictionary),
		"renown": BigValue.format_short(big_values.get("renown", BigValue.zero()) as Dictionary),
		"energy": snappedf(float(meters.get("energy", 0.0)), 0.01),
		"stress": snappedf(float(meters.get("stress", 0.0)), 0.01),
		"totalStats": snappedf(_total_stats(state), 0.01),
		"topStats": _top_stats(state, 3),
		"masteredActivities": (state.get("mastery", {}) as Dictionary).size(),
		"contracts": (generated.get("contracts", []) as Array).size(),
		"titles": (state.get("careerTitles", {}) as Dictionary).size(),
		"stateHash": engine.state_hash(),
	}


func _top_stats(state: Dictionary, limit: int) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for raw_key: Variant in (state.get("stats", {}) as Dictionary).keys():
		rows.append({"id": str(raw_key), "value": float((state.get("stats", {}) as Dictionary)[raw_key])})
	rows.sort_custom(_compare_stat_rows)
	if rows.size() > limit:
		rows.resize(limit)
	for row: Dictionary in rows:
		row["value"] = snappedf(float(row.get("value", 0.0)), 0.01)
	return rows


func _compare_stat_rows(left: Dictionary, right: Dictionary) -> bool:
	var left_value: float = float(left.get("value", 0.0))
	var right_value: float = float(right.get("value", 0.0))
	if not is_equal_approx(left_value, right_value):
		return left_value > right_value
	return str(left.get("id", "")) < str(right.get("id", ""))


func _total_stats(state: Dictionary) -> float:
	var result: float = 0.0
	for raw_value: Variant in (state.get("stats", {}) as Dictionary).values():
		result += maxf(0.0, float(raw_value))
	return result


func _valid_big_values(state: Dictionary) -> bool:
	var big_values: Dictionary = state.get("bigValues", {}) as Dictionary
	for key: String in ["gold", "lifetimeGold", "renown", "lifetimeRenown"]:
		if not BigValue.is_valid(big_values.get(key, BigValue.zero()) as Dictionary):
			return false
	return true


func _contains_non_finite(value: Variant) -> bool:
	match typeof(value):
		TYPE_FLOAT:
			return is_nan(float(value)) or is_inf(float(value))
		TYPE_ARRAY:
			for child: Variant in value as Array:
				if _contains_non_finite(child):
					return true
		TYPE_DICTIONARY:
			for child: Variant in (value as Dictionary).values():
				if _contains_non_finite(child):
					return true
	return false


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	if _failures.is_empty():
		print("[BALANCE] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[BALANCE] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	for failure: String in _failures:
		print("[BALANCE]   - %s" % failure)
	quit(1)
