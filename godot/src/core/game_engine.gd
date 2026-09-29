class_name GameEngine
extends RefCounted

const DEFAULT_SAVE_PATH: String = "user://princess_tycoon_save_v2.json"
const OFFLINE_SECONDS_PER_SLOT: int = 60
const OFFLINE_CAP_SECONDS: int = 28800
const SLOTS_PER_SEASON: int = 28
const SEASONS_PER_YEAR: int = 4
const RECENT_ACTIVITY_WINDOW: int = 8
const EVENT_INBOX_MAX: int = 20
const INVENTORY_STACK_MAX: int = 99
const SELL_RATIO: float = 0.5

var _state: Dictionary = {}
var _content_db: ContentDB = ContentDB.new()
var _planner: Planner = Planner.new()
var _generator: ProceduralGenerator = ProceduralGenerator.new()
var _content_report: Dictionary = {}
var _save_path: String = DEFAULT_SAVE_PATH
var _initialized: bool = false
var _now_boundary_unix: int = -1


func initialize(seed_value: int = 1) -> Dictionary:
	_content_report = _content_db.load_all("res://data")
	_planner.configure(_content_db.config, _content_db.profiles, _content_db.activities)
	_state = StateFactory.create(seed_value, "아리아", _content_db.config)
	_apply_policy_preferred_tags()
	_state["contentReport"] = _content_report.duplicate(true)
	# Fix the bootstrap activity before contracts are generated so procedural
	# reachability can account for its real remaining duration and completion.
	_ensure_active_task()
	_state["generatedContent"] = _generator.generate(_state, _content_db)
	_initialized = true
	return get_state()


func initialize_from_state(saved_state: Dictionary) -> Dictionary:
	_content_report = _content_db.load_all("res://data")
	_planner.configure(_content_db.config, _content_db.profiles, _content_db.activities)
	_state = StateFactory.ensure_v2_shape(saved_state)
	_apply_policy_preferred_tags()
	_state["contentReport"] = _content_report.duplicate(true)
	if (state_generated_content()).get("contracts", []).is_empty():
		_state["generatedContent"] = {"contracts": [], "rivals": [], "region": {}, "pinnedContractId": ""}
		_ensure_active_task()
		_state["generatedContent"] = _generator.generate(_state, _content_db)
	_ensure_active_task()
	_initialized = true
	return get_state()


func get_state() -> Dictionary:
	if not _initialized and _state.is_empty():
		return {}
	return _state.duplicate(true)


func get_content_report() -> Dictionary:
	return _content_report.duplicate(true)


func get_content_db() -> ContentDB:
	return _content_db


func set_policy(
	policy_or_preset: Variant,
	weights: Dictionary = {},
	banned_tags: Array = [],
	reserve_gold: Variant = null,
	max_stress: float = -1.0,
	risk_tolerance: float = -1.0
) -> Dictionary:
	_ensure_initialized()
	var current: Dictionary = _state.get("growthPolicy", GrowthPolicy.create()) as Dictionary
	var next_policy: Dictionary
	if policy_or_preset is Dictionary:
		var merged: Dictionary = current.duplicate(true)
		for key: Variant in (policy_or_preset as Dictionary).keys():
			merged[key] = (policy_or_preset as Dictionary)[key]
		next_policy = GrowthPolicy.sanitize(merged)
	else:
		var preset: String = str(policy_or_preset)
		var next_weights: Dictionary = weights
		if next_weights.is_empty() and preset == "custom":
			next_weights = current.get("weights", {}) as Dictionary
		var next_tags: Array = banned_tags if not banned_tags.is_empty() else current.get("bannedTags", []) as Array
		var next_reserve: Variant = reserve_gold if reserve_gold != null else current.get("reserveGold", BigValue.from_number(300))
		var next_max_stress: float = max_stress if max_stress >= 0.0 else float(current.get("maxStress", 72.0))
		var next_risk: float = risk_tolerance if risk_tolerance >= 0.0 else float(current.get("riskTolerance", 0.35))
		next_policy = GrowthPolicy.create(preset, next_weights, next_tags, next_reserve, next_max_stress, next_risk)
	next_policy["preferredTags"] = _planner.preferred_tags_for_preset(str(next_policy.get("preset", "balanced")))
	_state["growthPolicy"] = next_policy
	# The running task is intentionally preserved. The new policy is observed
	# only by the next planner call (AC-PLAN-04).
	var response: Dictionary = _with_state({"policy": next_policy.duplicate(true)})
	# Keep direct policy fields for lightweight callers that used the earlier
	# policy-return convention.
	for key: Variant in next_policy.keys():
		response[key] = next_policy[key]
	return response


func _apply_policy_preferred_tags() -> void:
	var policy: Dictionary = GrowthPolicy.sanitize(_state.get("growthPolicy", {}) as Dictionary)
	policy["preferredTags"] = _planner.preferred_tags_for_preset(str(policy.get("preset", "balanced")))
	_state["growthPolicy"] = policy


func set_player_name(player_name: String) -> void:
	_ensure_initialized()
	var clean_name: String = player_name.strip_edges()
	if clean_name.is_empty():
		return
	_state["playerName"] = clean_name
	_state["traineeName"] = clean_name


func set_trainee_name(player_name: String) -> void:
	set_player_name(player_name)


func set_setting(key: String, value: Variant) -> void:
	_ensure_initialized()
	var settings: Dictionary = _state.get("settings", {}) as Dictionary
	settings[key] = value


func set_auto_run(enabled: bool) -> void:
	set_setting("autoRun", enabled)


func pause() -> void:
	set_auto_run(false)


func resume() -> void:
	set_auto_run(true)


func set_settings(settings: Dictionary) -> void:
	_ensure_initialized()
	for key: Variant in settings.keys():
		(_state.get("settings", {}) as Dictionary)[key] = settings[key]


func queue_activity(activity_id: String) -> Dictionary:
	_ensure_initialized()
	var activity: Dictionary = _content_db.get_activity(activity_id)
	if activity.is_empty():
		return {"ok": false, "error": "존재하지 않는 활동"}
	var queue: Array = _state.get("activityQueue", []) as Array
	queue.append(activity_id)
	return {"ok": true, "queued": activity_id, "queueSize": queue.size()}


func remove_queued_activity(index: int) -> Dictionary:
	_ensure_initialized()
	var queue: Array = _state.get("activityQueue", []) as Array
	if index < 0 or index >= queue.size():
		return {"ok": false, "error": "큐 인덱스 범위 오류", "index": index}
	var removed_id: String = str(queue[index])
	queue.remove_at(index)
	return {"ok": true, "removed": removed_id, "queue": queue.duplicate(true)}


func move_queued_activity(index: int, offset: int) -> Dictionary:
	_ensure_initialized()
	var queue: Array = _state.get("activityQueue", []) as Array
	if index < 0 or index >= queue.size():
		return {"ok": false, "error": "큐 인덱스 범위 오류", "index": index}
	var target_index: int = clampi(index + offset, 0, queue.size() - 1)
	var activity_id: Variant = queue[index]
	if target_index != index:
		queue.remove_at(index)
		queue.insert(target_index, activity_id)
	return {"ok": true, "from": index, "to": target_index, "queue": queue.duplicate(true)}


func clear_activity_queue() -> Dictionary:
	_ensure_initialized()
	var queue: Array = _state.get("activityQueue", []) as Array
	var removed_count: int = queue.size()
	queue.clear()
	return {"ok": true, "removedCount": removed_count, "queue": []}


func preview_next_activity() -> Dictionary:
	_ensure_initialized()
	return _planner.choose(_state, _content_db.activities)


func run_activity(activity_id: String, now_unix: int = -1) -> Dictionary:
	_ensure_initialized()
	var activity: Dictionary = _content_db.get_activity(activity_id)
	if activity.is_empty():
		return {"ok": false, "error": "존재하지 않는 활동", "activityId": activity_id}
	var rejection_reason: String = _planner.rejection_reason(_state, activity)
	if not rejection_reason.is_empty():
		return {"ok": false, "error": rejection_reason, "activityId": activity_id}
	var active: Variant = _state.get("activeTask")
	var active_is_requested: bool = active is Dictionary and str((active as Dictionary).get("activityId", (active as Dictionary).get("id", ""))) == activity_id
	var queue: Array = _state.get("activityQueue", []) as Array
	for index: int in range(queue.size() - 1, -1, -1):
		if str(queue[index]) == activity_id:
			queue.remove_at(index)
	if not active_is_requested:
		queue.push_front(activity_id)
	var guard: int = 0
	while guard < 64:
		var advance_result: Dictionary = advance_slots(1, now_unix)
		guard += 1
		for raw_completed: Variant in advance_result.get("completedActivities", []) as Array:
			if raw_completed is Dictionary and str((raw_completed as Dictionary).get("activityId", "")) == activity_id:
				return _with_state({
					"ok": true,
					"activityId": activity_id,
					"slotsAdvanced": guard,
					"result": (raw_completed as Dictionary).duplicate(true),
				})
		var current_task: Variant = _state.get("activeTask")
		var request_is_active: bool = current_task is Dictionary and str((current_task as Dictionary).get("activityId", (current_task as Dictionary).get("id", ""))) == activity_id
		if not request_is_active and not queue.has(activity_id):
			return _with_state({"ok": false, "error": "선행 활동 후 실행 조건을 충족하지 못함", "activityId": activity_id, "slotsAdvanced": guard})
	return _with_state({"ok": false, "error": "요청 활동 실행 제한 초과", "activityId": activity_id, "slotsAdvanced": guard})


func execute_activity(activity_id: String, now_unix: int = -1) -> Dictionary:
	return run_activity(activity_id, now_unix)


func advance_slots(slot_count: int, now_unix: int = -1) -> Dictionary:
	_ensure_initialized()
	var last_boundary: int = int(_state.get("lastSimulatedAt", 0))
	if now_unix >= 0 and last_boundary > 0 and now_unix < last_boundary:
		_append_warning("CLOCK_ROLLBACK", "기기 시간이 뒤로 이동해 온라인 진행을 0 slot로 처리했습니다.")
		return _with_state({
			"slotsAdvanced": 0,
			"completedActivities": [],
			"seasonReviews": [],
			"clockRollback": true,
		})
	if now_unix >= 0:
		_stamp_unanchored_events(now_unix)
		_resolve_expired_events(now_unix)
		_now_boundary_unix = now_unix
	var requested: int = maxi(0, slot_count)
	var completed: Array[Dictionary] = []
	var reviews: Array[Dictionary] = []
	for _slot_index: int in range(requested):
		var step: Dictionary = _advance_one_slot()
		if step.has("completed"):
			completed.append((step["completed"] as Dictionary).duplicate(true))
		if step.has("seasonReview"):
			reviews.append((step["seasonReview"] as Dictionary).duplicate(true))
	if now_unix >= 0:
		_stamp_unanchored_events(now_unix)
		_resolve_expired_events(now_unix)
		_state["lastSimulatedAt"] = now_unix
		_now_boundary_unix = -1
	return _with_state({
		"slotsAdvanced": requested,
		"completedActivities": completed,
		"seasonReviews": reviews,
	})


func settle_offline(now_unix: int = -1) -> Dictionary:
	_ensure_initialized()
	var now_value: int = now_unix
	if now_value < 0:
		now_value = int(Time.get_unix_time_from_system())
	var last_value: int = int(_state.get("lastSimulatedAt", 0))
	if last_value <= 0:
		_stamp_unanchored_events(now_value)
		_resolve_expired_events(now_value)
		_state["lastSimulatedAt"] = now_value
		return _with_state({"slotsAdvanced": 0, "elapsedSeconds": 0, "capped": false, "clockRollback": false})
	if now_value < last_value:
		_append_warning("CLOCK_ROLLBACK", "기기 시간이 뒤로 이동해 오프라인 진행을 0 slot로 처리했습니다.")
		return _with_state({"slotsAdvanced": 0, "elapsedSeconds": 0, "capped": false, "clockRollback": true})
	_stamp_unanchored_events(last_value)
	var raw_elapsed: int = now_value - last_value
	if not bool((_state.get("settings", {}) as Dictionary).get("autoRun", true)):
		_resolve_expired_events(now_value)
		_state["lastSimulatedAt"] = now_value
		return _with_state({
			"slotsAdvanced": 0,
			"elapsedSeconds": raw_elapsed,
			"rawElapsedSeconds": raw_elapsed,
			"capped": false,
			"clockRollback": false,
			"paused": true,
		})
	var elapsed: int = mini(raw_elapsed, _config_int("offlineCapSeconds", OFFLINE_CAP_SECONDS))
	var seconds_per_slot: int = maxi(1, _config_int("offlineSecondsPerSlot", OFFLINE_SECONDS_PER_SLOT))
	var slots: int = elapsed / seconds_per_slot
	var completed: Array = []
	var reviews: Array = []
	# Expiry is applied at each simulated slot boundary. This keeps choices that
	# expire mid-offline-window in the same reducer order as online progression.
	for slot_index: int in range(slots):
		var boundary_unix: int = last_value + (slot_index + 1) * seconds_per_slot
		var step_result: Dictionary = advance_slots(1, boundary_unix)
		completed.append_array(step_result.get("completedActivities", []) as Array)
		reviews.append_array(step_result.get("seasonReviews", []) as Array)
	_stamp_unanchored_events(now_value)
	_resolve_expired_events(now_value)
	_state["lastSimulatedAt"] = now_value
	return _with_state({
		"slotsAdvanced": slots,
		"elapsedSeconds": elapsed,
		"rawElapsedSeconds": raw_elapsed,
		"capped": raw_elapsed > elapsed,
		"clockRollback": false,
		"completedActivities": completed,
		"seasonReviews": reviews,
	})


func save(path: String = "", now_unix: int = -1, preserve_last_simulated_at: bool = false) -> Dictionary:
	_ensure_initialized()
	var state_before_save: Dictionary = _state.duplicate(true)
	var now_value: int = now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	_stamp_unanchored_events(now_value)
	_resolve_expired_events(now_value)
	if not preserve_last_simulated_at:
		_state["lastSimulatedAt"] = now_value
	var target_path: String = path if not path.is_empty() else _save_path
	var save_result: Dictionary = SaveCodec.save_atomic(target_path, _state)
	if not bool(save_result.get("ok", false)):
		_state = state_before_save
	return save_result


func save_game(path: String = "", now_unix: int = -1, preserve_last_simulated_at: bool = false) -> Dictionary:
	return save(path, now_unix, preserve_last_simulated_at)


func reset_save(path: String = "") -> Dictionary:
	_ensure_initialized()
	var seed_value: int = int(_state.get("seed", 1))
	delete_save(path)
	return initialize(seed_value)


func delete_save(path: String = "") -> bool:
	var target_path: String = path if not path.is_empty() else _save_path
	var absolute_path: String = ProjectSettings.globalize_path(target_path) if target_path.begins_with("user://") or target_path.begins_with("res://") else target_path
	var removed_any: bool = false
	for candidate: String in [absolute_path, absolute_path + ".bak", absolute_path + ".tmp"]:
		if FileAccess.file_exists(candidate):
			removed_any = DirAccess.remove_absolute(candidate) == OK or removed_any
	return removed_any


func load_save(path: String = "") -> Dictionary:
	var target_path: String = path if not path.is_empty() else _save_path
	var load_result: Dictionary = SaveCodec.load_with_backup(target_path)
	if not bool(load_result.get("ok", false)):
		return load_result
	initialize_from_state(load_result.get("state", {}) as Dictionary)
	load_result["state"] = get_state()
	return load_result


func load_game(path: String = "") -> Dictionary:
	return load_save(path)


func set_save_path(path: String) -> void:
	if not path.strip_edges().is_empty():
		_save_path = path


func _advance_one_slot() -> Dictionary:
	_ensure_active_task()
	var step_result: Dictionary = {}
	var active_task: Variant = _state.get("activeTask")
	if active_task is Dictionary:
		var task: Dictionary = active_task as Dictionary
		task["remainingSlots"] = maxi(0, int(task.get("remainingSlots", 1)) - 1)
		if int(task["remainingSlots"]) <= 0:
			var completed: Dictionary = _resolve_activity(task)
			step_result["completed"] = completed
			_state["activeTask"] = null
	var time: Dictionary = _state.get("time", {}) as Dictionary
	time["slot"] = int(time.get("slot", 0)) + 1
	var slots_per_season: int = maxi(1, _config_int("slotsPerSeason", SLOTS_PER_SEASON))
	if int(time["slot"]) % slots_per_season == 0:
		var completed_period: Dictionary = {"season": int(time.get("season", 1)), "year": int(time.get("year", 1))}
		_update_calendar()
		step_result["seasonReview"] = _review_season(completed_period)
	else:
		_update_calendar()
	_ensure_active_task()
	return step_result


func _ensure_active_task() -> void:
	if _state.get("activeTask") is Dictionary:
		return
	var selected_activity: Dictionary = {}
	var decision: Dictionary = {}
	var queue: Array = _state.get("activityQueue", []) as Array
	var queue_scan_count: int = queue.size()
	while queue_scan_count > 0 and not queue.is_empty() and selected_activity.is_empty():
		queue_scan_count -= 1
		var queued_id: String = str(queue.pop_front())
		var queued_activity: Dictionary = _content_db.get_activity(queued_id)
		var queued_rejection: String = _planner.rejection_reason(_state, queued_activity) if not queued_activity.is_empty() else "존재하지 않는 활동"
		if not queued_activity.is_empty() and queued_rejection.is_empty():
			selected_activity = queued_activity
			decision = {
				"activityId": queued_id,
				"score": 0.0,
				"reasons": ["플레이어가 자동 큐에 지정"],
				"ranked": [],
			}
		elif queued_rejection.begins_with("예정 도전 우선") or queued_rejection.begins_with("시즌 일정 잠금"):
			queue.append(queued_id)
	if selected_activity.is_empty():
		decision = _planner.choose(_state, _content_db.activities)
		selected_activity = decision.get("activity", {}) as Dictionary
	if selected_activity.is_empty():
		return
	var tier: int = maxi(1, int(_state.get("worldTier", 1)))
	var cost: Dictionary = _planner.tier_cost(selected_activity, tier)
	var big_values: Dictionary = _state.get("bigValues", {}) as Dictionary
	var gold: Dictionary = big_values.get("gold", BigValue.zero()) as Dictionary
	if BigValue.compare(gold, cost) < 0:
		if str(selected_activity.get("kind", "")) == "challenge" and _planner.is_allowed(_state, selected_activity):
			cost = BigValue.zero()
			decision["reasons"] = ["시즌 예정 도전 참가 지원"]
		else:
			selected_activity = _content_db.get_activity("REST_HOME")
			cost = BigValue.zero()
			decision = {"activityId": "REST_HOME", "score": -999999.0, "reasons": ["활동 시작 시점의 비용이 부족해 휴식으로 대체"], "ranked": []}
	big_values["gold"] = BigValue.subtract(gold, cost)
	var reasons: Array = decision.get("reasons", []) as Array
	var primary_reason: String = str(reasons[0]) if not reasons.is_empty() else "자동 플래너 선택"
	_state["lastPlannerDecision"] = decision.duplicate(true)
	_state["activeTask"] = {
		"id": str(selected_activity.get("id", "REST_HOME")),
		"activityId": str(selected_activity.get("id", "REST_HOME")),
		"name": str(selected_activity.get("name", "휴식")),
		"reason": primary_reason,
		"startedAtSlot": int((_state.get("time", {}) as Dictionary).get("slot", 0)),
		"durationSlots": maxi(1, int(selected_activity.get("durationSlots", 1))),
		"remainingSlots": maxi(1, int(selected_activity.get("durationSlots", 1))),
		"worldTier": tier,
		"paidCost": cost,
	}


func _resolve_activity(task: Dictionary) -> Dictionary:
	var activity_id: String = str(task.get("activityId", task.get("id", "REST_HOME")))
	var activity: Dictionary = _content_db.get_activity(activity_id)
	if activity.is_empty():
		activity = _content_db.get_activity("REST_HOME")
	var kind: String = str(activity.get("kind", "rest"))
	var stress_before: float = float((_state.get("meters", {}) as Dictionary).get("stress", 0.0))
	var reputation_before: float = float((_state.get("meters", {}) as Dictionary).get("reputation", 0.0))
	var relations_before: float = _relation_total()
	var specialized: Dictionary = {}
	var gain_multiplier: float = 1.0
	if kind == "challenge":
		specialized = _resolve_challenge(activity)
		gain_multiplier = 1.0 if bool(specialized.get("won", false)) else clampf(_config_float("challengeFailureExperienceRatio", 0.30), 0.0, 1.0)
	elif kind == "adventure":
		specialized = _resolve_adventure(activity)
		gain_multiplier = 1.0 if bool(specialized.get("won", false)) else clampf(_config_float("adventureFailureExperienceRatio", 0.30), 0.0, 1.0)
	elif kind == "job":
		specialized = _resolve_job_incident(activity)
	var gains: Dictionary = _apply_activity_growth(activity, gain_multiplier)
	var tier: int = maxi(1, int(task.get("worldTier", _state.get("worldTier", 1))))
	var performance_mod: float = _performance_mod(activity, tier) * maxf(0.0, float(specialized.get("rewardMultiplier", 1.0)))
	var reward: Dictionary = (specialized.get("rewardGold", BigValue.zero()) as Dictionary).duplicate(true) if kind == "challenge" else _planner.tier_reward(activity, tier, performance_mod)
	_grant_gold(reward)
	_apply_fixed_deltas(activity.get("fixedDeltas", {}) as Dictionary)
	_apply_activity_meters(activity)
	_apply_activity_relations(activity)
	specialized["stressBefore"] = stress_before
	specialized["performanceMod"] = performance_mod
	specialized["paidCost"] = (task.get("paidCost", BigValue.zero()) as Dictionary).duplicate(true)
	specialized["durationSlots"] = maxi(1, int(activity.get("durationSlots", 1)))
	specialized["startedAtSlot"] = int(task.get("startedAtSlot", int((_state.get("time", {}) as Dictionary).get("slot", 0)) - maxi(1, int(activity.get("durationSlots", 1))) + 1))
	specialized["completedAtSlot"] = int((_state.get("time", {}) as Dictionary).get("slot", 0)) + 1
	specialized["relationGain"] = maxf(0.0, _relation_total() - relations_before)
	specialized["reputationGain"] = maxf(0.0, float((_state.get("meters", {}) as Dictionary).get("reputation", 0.0)) - reputation_before)
	var mastery: Dictionary = _state.get("mastery", {}) as Dictionary
	var mastery_gain: int = maxi(1, int(specialized.get("masteryExperience", 1))) if kind == "challenge" else 1
	mastery[activity_id] = int(mastery.get(activity_id, 0)) + mastery_gain
	specialized["masteryGained"] = mastery_gain
	var recent: Array = _state.get("recentActivities", []) as Array
	recent.append(activity_id)
	while recent.size() > _config_int("recentActivityWindow", RECENT_ACTIVITY_WINDOW):
		recent.pop_front()
	var lifetime: Dictionary = _state.get("lifetimeStats", {}) as Dictionary
	lifetime["activities"] = int(lifetime.get("activities", 0)) + 1
	_record_growth_vector(gains)
	_update_contracts(activity, gains, specialized, reward)
	_maybe_queue_event(activity, specialized)
	if kind == "rest":
		_state["forceRest"] = false
	var summary: String = _build_result_summary(gains, reward, specialized)
	var result: Dictionary = {
		"activityId": activity_id,
		"kind": kind,
		"title": "%s 완료" % str(activity.get("name", activity_id)),
		"summary": summary,
		"gains": gains,
		"cost": (task.get("paidCost", BigValue.zero()) as Dictionary).duplicate(true),
		"reward": reward,
		"mastery": int(mastery[activity_id]),
		"outcome": specialized,
		"slot": int((_state.get("time", {}) as Dictionary).get("slot", 0)),
	}
	_state["lastResult"] = result
	return result


func _resolve_job_incident(activity: Dictionary) -> Dictionary:
	var risk: float = clampf(float(activity.get("risk", 0.0)), 0.0, 1.0)
	var absolute_slot: int = int((_state.get("time", {}) as Dictionary).get("slot", 0)) + 1
	var roll: float = DeterministicRNG.value_at(
		int(_state.get("seed", 1)),
		absolute_slot,
		0.0,
		1.0,
		"job_incident:%s" % str(activity.get("id", ""))
	)
	var incident: bool = risk > 0.0 and roll < risk
	var result: Dictionary = {
		"type": "job",
		"risk": risk,
		"riskRoll": snappedf(roll, 0.0001),
		"incident": incident,
		"rewardMultiplier": 1.0,
		"event": "평온한 근무",
		"effects": {},
	}
	if not incident:
		return result
	var stress_gain: float = snappedf(4.0 + 12.0 * risk, 0.1)
	var relation_loss: float = snappedf(1.0 + 3.0 * risk, 0.1)
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	meters["stress"] = clampf(float(meters.get("stress", 0.0)) + stress_gain, 0.0, 100.0)
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	var before: float = float(relations.get("citizens", 0.0))
	relations["citizens"] = clampf(before - relation_loss, 0.0, 1000.0)
	result["rewardMultiplier"] = maxf(0.45, 0.82 - 0.35 * risk)
	result["event"] = "작업 중 돌발 사고"
	result["effects"] = {"stress": stress_gain, "citizens": float(relations["citizens"]) - before}
	return result


func _apply_activity_relations(activity: Dictionary) -> void:
	if str(activity.get("kind", "")) != "job":
		return
	var tags: Array = activity.get("tags", []) as Array
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	if tags.has("service"):
		relations["citizens"] = clampf(float(relations.get("citizens", 0.0)) + 1.0, 0.0, 1000.0)
	if tags.has("social"):
		relations["steward"] = clampf(float(relations.get("steward", 0.0)) + 0.5, 0.0, 1000.0)


func _relation_total() -> float:
	var total: float = 0.0
	for raw_value: Variant in (_state.get("relations", {}) as Dictionary).values():
		total += float(raw_value)
	return total


func _apply_activity_growth(activity: Dictionary, gain_multiplier: float) -> Dictionary:
	var gains_config: Dictionary = activity.get("gains", {}) as Dictionary
	var gain_keys: Array = gains_config.keys()
	gain_keys.sort()
	var result: Dictionary = {}
	var stats: Dictionary = _state.get("stats", {}) as Dictionary
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	var policy: Dictionary = _state.get("growthPolicy", {}) as Dictionary
	var weights: Dictionary = policy.get("weights", {}) as Dictionary
	var tier: int = maxi(1, int(_state.get("worldTier", 1)))
	var mastery_value: float = maxf(0.0, float((_state.get("mastery", {}) as Dictionary).get(str(activity.get("id", "")), 0)))
	var condition_mod: float = clampf(
		1.0 - float(meters.get("stress", 0.0)) / maxf(1.0, _config_float("growthConditionStressDivisor", 160.0)),
		_config_float("growthConditionStressMinimum", 0.40),
		_config_float("growthConditionStressMaximum", 1.00)
	)
	condition_mod *= clampf(
		_config_float("growthConditionEnergyBase", 0.60) + float(meters.get("energy", 100.0)) / maxf(1.0, _config_float("growthConditionEnergyDivisor", 100.0)),
		_config_float("growthConditionEnergyMinimum", 0.60),
		_config_float("growthConditionEnergyMaximum", 1.60)
	)
	var mastery_mod: float = _planner.mastery_modifier(mastery_value)
	var relation_mod: float = _planner.relation_modifier(_state, activity)
	var tier_mod: float = 1.0 + maxf(0.0, _config_float("growthTierSqrtRate", 0.04)) * sqrt(float(tier - 1))
	for raw_key: Variant in gain_keys:
		var stat_key: String = str(raw_key)
		var current: float = maxf(0.0, float(stats.get(stat_key, meters.get(stat_key, 0.0))))
		var focus_mod: float = _config_float("growthFocusBase", 0.85) + _config_float("growthFocusWeightScale", 0.50) * float(weights.get(stat_key, 0.0))
		var diminish_denominator := maxf(1.0, _config_float("growthDiminishStatBase", 600.0) + _config_float("growthDiminishWorldTierScale", 80.0) * float(tier))
		var diminish_mod: float = _config_float("growthDiminishBase", 0.35) + _config_float("growthDiminishScale", 0.65) / (1.0 + current / diminish_denominator)
		var jitter: float = DeterministicRNG.next_float(
			_state,
			_config_float("growthJitterMin", 0.95),
			_config_float("growthJitterMax", 1.05),
			"%s:%s" % [str(activity.get("id", "")), stat_key]
		)
		var gain: float = float(gains_config[raw_key]) * focus_mod * condition_mod * mastery_mod * relation_mod * diminish_mod * tier_mod * jitter * gain_multiplier
		gain = snappedf(gain, 0.01)
		if is_nan(gain) or is_inf(gain):
			gain = 0.0
		if stats.has(stat_key):
			stats[stat_key] = maxf(0.0, float(stats.get(stat_key, 0.0)) + gain)
		elif meters.has(stat_key):
			meters[stat_key] = maxf(0.0, float(meters.get(stat_key, 0.0)) + gain)
		else:
			stats[stat_key] = maxf(0.0, gain)
		result[stat_key] = gain
	return result


func _apply_activity_meters(activity: Dictionary) -> void:
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	meters["energy"] = clampf(float(meters.get("energy", 100.0)) + float(activity.get("energyDelta", 0.0)), 0.0, 100.0)
	meters["stress"] = clampf(float(meters.get("stress", 0.0)) + float(activity.get("stressDelta", 0.0)), 0.0, 100.0)
	meters["reputation"] = maxf(0.0, float(meters.get("reputation", 0.0)))
	if (activity.get("tags", []) as Array).has("unfair"):
		meters["integrityViolations"] = int(meters.get("integrityViolations", 0)) + 1


func _performance_mod(activity: Dictionary, tier: int) -> float:
	var primary_stat: String = str(activity.get("primaryStat", ""))
	var raw_value: float = _state_numeric(primary_stat)
	var effective: float = 100.0 * log(1.0 + maxf(0.0, raw_value) / 100.0)
	var denominator := maxf(1.0, _config_float("performanceStatDenominatorBase", 220.0) + _config_float("performanceWorldTierDenominatorScale", 40.0) * float(tier))
	return clampf(
		_config_float("performanceBase", 0.75) + effective / denominator,
		_config_float("performanceMinimum", 0.75),
		_config_float("performanceMaximum", 1.75)
	)


func _grant_gold(amount: Dictionary) -> void:
	if BigValue.is_zero(amount):
		return
	var big_values: Dictionary = _state.get("bigValues", {}) as Dictionary
	big_values["gold"] = BigValue.add(big_values.get("gold", BigValue.zero()) as Dictionary, amount)
	big_values["lifetimeGold"] = BigValue.add(big_values.get("lifetimeGold", BigValue.zero()) as Dictionary, amount)


func _spend_gold(amount: Dictionary) -> bool:
	var big_values: Dictionary = _state.get("bigValues", {}) as Dictionary
	var gold: Dictionary = big_values.get("gold", BigValue.zero()) as Dictionary
	if BigValue.compare(gold, amount) < 0:
		return false
	big_values["gold"] = BigValue.subtract(gold, amount)
	return true


func _resolve_challenge(activity: Dictionary) -> Dictionary:
	var weights: Dictionary = activity.get("challengeWeights", {}) as Dictionary
	var weight_keys: Array = weights.keys()
	weight_keys.sort()
	var player_score: float = 0.0
	for raw_key: Variant in weight_keys:
		var key: String = str(raw_key)
		var effective: float = 100.0 * log(1.0 + maxf(0.0, _effective_stat(key)) / 100.0)
		player_score += effective * float(weights[raw_key])
	player_score += _gear_score()
	player_score += 2.0 * sqrt(maxf(0.0, float((_state.get("mastery", {}) as Dictionary).get(str(activity.get("id", "")), 0))))
	player_score += _challenge_season_score_bonus()
	var absolute_completion_slot := int((_state.get("time", {}) as Dictionary).get("slot", 0)) + 1
	player_score += DeterministicRNG.challenge_jitter(
		int(_state.get("seed", 1)),
		absolute_completion_slot,
		str(activity.get("id", "")),
		_config_float("challengeJitterMin", -5.0),
		_config_float("challengeJitterMax", 5.0)
	)
	var tier: int = maxi(1, int(_state.get("worldTier", 1)))
	var current_season: int = _current_season_index()
	var league: Dictionary = _state.get("challengeLeague", {}) as Dictionary
	if int(league.get("seasonIndex", current_season)) != current_season:
		league["seasonIndex"] = current_season
		league["seasonWins"] = 0
		league["seasonLosses"] = 0
	var league_tier: int = clampi(int(league.get("leagueTier", 1)), 1, 5)
	var rival: Dictionary = _rival_for_league(league_tier)
	var base_difficulty: float = maxf(1.0, float(activity.get("baseDifficulty", 100.0)))
	base_difficulty *= 1.0 + maxf(0.0, _config_float("growthTierSqrtRate", 0.04)) * sqrt(float(tier - 1))
	var activity_floor: float = base_difficulty * clampf(_config_float("challengeBaseDifficultyWeight", 0.35), 0.0, 1.0)
	if rival.is_empty():
		rival = {
			"id": "RIVAL_FALLBACK_%d" % league_tier,
			"name": "기록 측정 상대",
			"score": activity_floor,
			"leagueRank": league_tier,
			"leagueTier": league_tier,
			"seasonIndex": current_season,
		}
	var rival_scores: Dictionary = rival.get("scoresByChallenge", {}) as Dictionary
	var rival_score: float = maxf(1.0, float(rival_scores.get(str(activity.get("id", "")), rival.get("score", activity_floor))))
	var difficulty: float = maxf(1.0, maxf(activity_floor, rival_score))
	var ratio: float = maxf(0.0, player_score / difficulty)
	var selected_reward: Dictionary = {}
	var reward_rows: Array = activity.get("rewardTable", []) as Array
	for raw_row: Variant in reward_rows:
		if raw_row is not Dictionary:
			continue
		var row: Dictionary = raw_row as Dictionary
		if ratio >= float(row.get("minScoreRatio", 0.0)):
			if selected_reward.is_empty() or float(row.get("minScoreRatio", 0.0)) > float(selected_reward.get("minScoreRatio", 0.0)):
				selected_reward = row
	var reward_gold: Dictionary = BigValue.from_number(selected_reward.get("gold", 0))
	reward_gold = BigValue.multiply(reward_gold, BigValue.pow_base(maxf(1.0, _config_float("activityRewardTierGrowth", 1.13)), tier - 1))
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	meters["reputation"] = maxf(0.0, float(meters.get("reputation", 0.0)) + float(selected_reward.get("reputation", 0.0)))
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	var won: bool = ratio >= 1.0
	relations["rival"] = clampf(float(relations.get("rival", 0.0)) + (5.0 if won else 2.0), 0.0, 1000.0)
	var previous_best: float = maxf(0.0, float(league.get("bestScore", 0.0)))
	var next_league_tier: int = clampi(league_tier + (1 if won else -1), 1, 5)
	league["leagueTier"] = next_league_tier
	league["bestScore"] = maxf(previous_best, player_score)
	league["lastScore"] = player_score
	league["lastOpponentScore"] = difficulty
	league["lastOpponentId"] = str(rival.get("id", ""))
	league["seasonIndex"] = current_season
	league["seasonWins"] = int(league.get("seasonWins", 0)) + (1 if won else 0)
	league["seasonLosses"] = int(league.get("seasonLosses", 0)) + (0 if won else 1)
	var activity_id: String = str(activity.get("id", ""))
	var challenge_records: Dictionary = _state.get("challengeRecords", {}) as Dictionary
	var activity_record: Dictionary = challenge_records.get(activity_id, {}) as Dictionary
	activity_record["bestScore"] = maxf(float(activity_record.get("bestScore", 0.0)), player_score)
	activity_record["lastScore"] = player_score
	activity_record["lastOpponentScore"] = difficulty
	activity_record["lastOpponentId"] = str(rival.get("id", ""))
	activity_record["lastLeagueTier"] = league_tier
	activity_record["seasonIndex"] = current_season
	activity_record["wins"] = int(activity_record.get("wins", 0)) + (1 if won else 0)
	activity_record["losses"] = int(activity_record.get("losses", 0)) + (0 if won else 1)
	challenge_records[activity_id] = activity_record
	if won:
		var lifetime: Dictionary = _state.get("lifetimeStats", {}) as Dictionary
		lifetime["challengeWins"] = int(lifetime.get("challengeWins", 0)) + 1
		var season_counters: Dictionary = _state.get("seasonCounters", {}) as Dictionary
		season_counters["challengeWins"] = int(season_counters.get("challengeWins", 0)) + 1
	var hint_stat: String = ""
	var hint_priority: float = -INF
	for raw_key: Variant in weight_keys:
		var stat_key: String = str(raw_key)
		var stat_effective: float = 100.0 * log(1.0 + maxf(0.0, _effective_stat(stat_key)) / 100.0)
		var priority: float = float(weights[raw_key]) * maxf(0.0, difficulty - stat_effective)
		if priority > hint_priority:
			hint_priority = priority
			hint_stat = stat_key
	var hint_gap: float = maxf(0.0, difficulty - player_score) / maxf(0.01, float(weights.get(hint_stat, 1.0)))
	var hint: String = "현재 구성으로 다음 리그를 준비할 수 있습니다."
	if not won:
		hint = "%s 유효 점수를 약 %.1f 보강하세요." % [_stat_display_name(hint_stat), hint_gap]
	return {
		"type": "challenge",
		"won": won,
		"playerScore": snappedf(player_score, 0.01),
		"opponentScore": snappedf(difficulty, 0.01),
		"activityDifficultyFloor": snappedf(activity_floor, 0.01),
		"scoreRatio": snappedf(ratio, 0.001),
		"rank": str(selected_reward.get("rank", "participation")),
		"rewardGold": reward_gold,
		"masteryExperience": int(selected_reward.get("mastery", 1)),
		"seasonIndex": current_season,
		"leagueTier": league_tier,
		"nextLeagueTier": next_league_tier,
		"previousBestScore": snappedf(previous_best, 0.01),
		"bestScore": snappedf(float(league.get("bestScore", player_score)), 0.01),
		"rivalId": str(rival.get("id", "")),
		"rivalName": str(rival.get("name", "상대")),
		"rival": rival.duplicate(true),
		"rivalDomain": str((rival.get("challengeDomains", {}) as Dictionary).get(activity_id, "")),
		"rivalTraitModifier": float((rival.get("traitModifiersByChallenge", {}) as Dictionary).get(activity_id, 1.0)),
		"rivalPersonalityModifier": float(rival.get("personalityModifier", 1.0)),
		"hint": hint,
		"hintStat": hint_stat,
		"hintGap": snappedf(hint_gap, 0.1),
	}


func _challenge_season_score_bonus() -> float:
	var season_index: int = _current_season_index()
	var jitter_span: float = maxf(0.1, _config_float("challengeJitterMax", 5.0) - _config_float("challengeJitterMin", -5.0))
	return maxf(0.0, _config_float("challengeSeasonDifficultyRate", 0.01)) * sqrt(float(maxi(0, season_index - 1))) * jitter_span


func _rival_for_league(league_tier: int) -> Dictionary:
	var rivals: Array = ((_state.get("generatedContent", {}) as Dictionary).get("rivals", []) as Array)
	for raw_rival: Variant in rivals:
		if raw_rival is not Dictionary:
			continue
		var rival: Dictionary = raw_rival as Dictionary
		if int(rival.get("leagueTier", rival.get("leagueRank", 0))) == league_tier:
			return rival.duplicate(true)
	return {}


func _stat_display_name(stat_key: String) -> String:
	const DISPLAY_NAMES: Dictionary = {
		"stamina": "체력", "strength": "근력", "intelligence": "지력", "refinement": "기품",
		"sensitivity": "감수성", "style": "스타일", "discipline": "절제", "morals": "도덕",
		"faith": "신앙", "combat": "전투", "magic": "마법", "etiquette": "예절",
		"communication": "소통", "art": "예술", "cooking": "요리", "housework": "생활",
		"nursing": "간호", "dance": "무용", "reputation": "평판",
	}
	return str(DISPLAY_NAMES.get(stat_key, stat_key))


func _resolve_adventure(activity: Dictionary) -> Dictionary:
	var enemy_pool: Array[Dictionary] = []
	for raw_enemy: Variant in activity.get("enemyPool", []) as Array:
		if raw_enemy is Dictionary:
			enemy_pool.append(raw_enemy as Dictionary)
	var node_results: Array[Dictionary] = []
	var tier: int = maxi(1, int(_state.get("worldTier", 1)))
	var region: Dictionary = ((_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary).duplicate(true)
	if not bool(region.get("active", false)) or str(region.get("templateId", "")) != str(activity.get("id", "")):
		var lazy_region: Dictionary = _generator.generate_region_for_activity(_state, _content_db, str(activity.get("id", "")))
		if not lazy_region.is_empty():
			region = lazy_region
			(_state.get("generatedContent", {}) as Dictionary)["region"] = lazy_region.duplicate(true)
	var region_applied: bool = bool(region.get("active", true)) and str(region.get("templateId", "")) == str(activity.get("id", ""))
	var region_key: String = str(region.get("baseRegionId", region.get("templateId", ""))) if region_applied else ""
	var region_label: String = str(region.get("name", activity.get("name", "미지의 지역"))) if region_applied else str(activity.get("name", "기본 탐사 구역"))
	var region_progress_all: Dictionary = _state.get("regionProgress", {}) as Dictionary
	var region_progress: Dictionary = region_progress_all.get(region_key, {}) as Dictionary if region_applied else {}
	var clear_count_before: int = maxi(0, int(region_progress.get("clearCount", 0)))
	var clears_per_tier: int = maxi(1, _config_int("regionClearsPerTier", 3))
	var region_tier: int = 1 + clear_count_before / clears_per_tier
	var modifier_profile: Dictionary = region.get("modifierProfile", {}) as Dictionary if region_applied else {}
	var enemy_variant: Dictionary = region.get("enemyVariant", {}) as Dictionary if region_applied else {}
	var trait_enemy_scale: float = maxf(0.1, float(modifier_profile.get("enemyScale", 1.0)))
	var region_difficulty_scale: float = 1.0 + maxf(0.0, _config_float("regionDifficultySqrtRate", 0.04)) * sqrt(float(region_tier - 1))
	var player_hp: float = 100.0 + _effective_stat("stamina") * 2.0
	var player_attack: float = 12.0 + _effective_stat("strength") + _effective_stat("combat") * 0.8
	var player_magic_attack: float = 12.0 + _effective_stat("intelligence") * 0.5 + _effective_stat("magic")
	var player_defense: float = 8.0 + _effective_stat("stamina") * 0.4 + _equipment_modifier("defense")
	var player_magic_defense: float = 8.0 + _effective_stat("faith") * 0.4 + _equipment_modifier("magicDefense")
	var cleared_nodes: int = 0
	var won: bool = true
	for node_index: int in range(3):
		if node_index == 0:
			var exploration_roll: float = DeterministicRNG.next_float(_state, 0.0, 1.0, "adventure_exploration")
			var exploration_event: String = "지도 조각 발견" if exploration_roll < 0.5 else "거친 우회로"
			var exploration_effect: Dictionary = {"reputation": 1.0} if exploration_roll < 0.5 else {"energy": -2.0}
			var meters: Dictionary = _state.get("meters", {}) as Dictionary
			meters["energy"] = clampf(float(meters.get("energy", 100.0)) + float(exploration_effect.get("energy", 0.0)), 0.0, 100.0)
			meters["reputation"] = maxf(0.0, float(meters.get("reputation", 0.0)) + float(exploration_effect.get("reputation", 0.0)))
			node_results.append({"node": 1, "type": "exploration", "event": exploration_event, "effect": exploration_effect, "won": true, "rounds": 0, "remainingHp": snappedf(player_hp, 0.01)})
			cleared_nodes += 1
			continue
		if node_index == 1 and DeterministicRNG.next_float(_state, 0.0, 1.0, "adventure_middle_branch") < 0.35:
			var event_roll: float = DeterministicRNG.next_float(_state, 0.0, 1.0, "adventure_middle_event")
			var event_name: String = "회복의 샘" if event_roll < 0.5 else "낙석 지대"
			var event_effect: Dictionary = {}
			if event_roll < 0.5:
				var healed: float = minf(20.0, maxf(0.0, 100.0 + _effective_stat("stamina") * 2.0 - player_hp))
				player_hp += healed
				event_effect = {"hp": healed, "stress": -2.0}
			else:
				var safe_damage: float = minf(player_hp * 0.15, 8.0 + sqrt(float(tier)))
				player_hp -= safe_damage
				event_effect = {"hp": -safe_damage, "stress": 2.0}
			var event_meters: Dictionary = _state.get("meters", {}) as Dictionary
			event_meters["stress"] = clampf(float(event_meters.get("stress", 0.0)) + float(event_effect.get("stress", 0.0)), 0.0, 100.0)
			node_results.append({"node": 2, "type": "event", "event": event_name, "effect": event_effect, "won": true, "rounds": 0, "remainingHp": snappedf(player_hp, 0.01)})
			cleared_nodes += 1
			continue
		var combat_result: Dictionary = _resolve_adventure_combat_node(
			enemy_pool,
			node_index == 2,
			node_index,
			player_hp,
			player_attack,
			player_magic_attack,
			player_defense,
			player_magic_defense,
			(1.0 + 0.045 * sqrt(float(tier - 1))) * (1.0 + 0.18 * float(node_index)) * region_difficulty_scale * trait_enemy_scale,
			region_label,
			enemy_variant
		)
		player_hp = float(combat_result.get("playerHp", player_hp))
		var node_won: bool = bool(combat_result.get("won", false))
		node_results.append(combat_result.get("nodeResult", {}) as Dictionary)
		if not node_won:
			won = false
			break
		cleared_nodes += 1
	var loot: Array[Dictionary] = []
	var region_reward: Dictionary = BigValue.zero()
	if won:
		var lifetime: Dictionary = _state.get("lifetimeStats", {}) as Dictionary
		lifetime["adventures"] = int(lifetime.get("adventures", 0)) + 1
		var relations: Dictionary = _state.get("relations", {}) as Dictionary
		relations["steward"] = clampf(float(relations.get("steward", 0.0)) + 1.0, 0.0, 1000.0)
		var bonus_loot_rolls: int = maxi(0, int(modifier_profile.get("lootBonusRolls", 0)))
		for loot_index: int in range(maxi(1, cleared_nodes) + bonus_loot_rolls):
			var drop: Dictionary = _pick_loot(activity.get("lootTable", []) as Array, "loot_%d" % loot_index)
			if drop.is_empty():
				continue
			var count: int = DeterministicRNG.range_int(_state, int(drop.get("min", 1)), int(drop.get("max", 1)), "loot_count")
			if _add_inventory(str(drop.get("itemId", "")), count):
				loot.append({"itemId": str(drop.get("itemId", "")), "count": count})
		if region_applied:
			region_progress["clearCount"] = clear_count_before + 1
			region_progress["tier"] = 1 + int(region_progress["clearCount"]) / clears_per_tier
			region_progress["lastClearedSeason"] = _current_season_index()
			region_progress["lastVariantId"] = str(region.get("id", ""))
			region_progress_all[region_key] = region_progress
			var reward_growth: float = maxf(1.0, _config_float("regionRewardGrowthPerTier", 1.05))
			region_reward = BigValue.multiply(
				(region.get("reward", BigValue.zero()) as Dictionary),
				BigValue.pow_base(reward_growth, region_tier - 1)
			)
			region_reward = BigValue.multiply_float(region_reward, maxf(0.0, float(modifier_profile.get("rewardScale", 1.0))))
			region_reward = BigValue.multiply_float(region_reward, maxf(0.0, float(enemy_variant.get("rewardMultiplier", 1.0))))
			_grant_gold(region_reward)
	else:
		if region_applied:
			region_progress["clearCount"] = clear_count_before
			region_progress["tier"] = region_tier
			region_progress["attemptCount"] = int(region_progress.get("attemptCount", 0)) + 1
			region_progress["lastVariantId"] = str(region.get("id", ""))
			region_progress_all[region_key] = region_progress
		var stats: Dictionary = _state.get("stats", {}) as Dictionary
		stats["stamina"] = maxf(0.0, float(stats.get("stamina", 0.0)) - maxf(0.0, _config_float("adventureInjuryStaminaPenalty", 20.0)))
		var meters: Dictionary = _state.get("meters", {}) as Dictionary
		meters["stress"] = clampf(float(meters.get("stress", 0.0)) + maxf(0.0, _config_float("adventureInjuryStressPenalty", 12.0)), 0.0, 100.0)
		(_state.get("flags", {}) as Dictionary)["injured"] = true
		_state["forceRest"] = true
	return {
		"type": "adventure",
		"won": won,
		"clearedNodes": cleared_nodes,
		"nodes": node_results,
		"loot": loot,
		"injured": not won,
		"regionApplied": region_applied,
		"regionId": str(region.get("id", "")) if region_applied else "",
		"baseRegionId": region_key,
		"regionName": region_label,
		"regionModifiers": (region.get("modifiers", []) as Array).duplicate(true) if region_applied else [],
		"regionTier": region_tier if region_applied else 0,
		"regionTierAfter": int(region_progress.get("tier", region_tier)) if region_applied else 0,
		"regionClearCount": int(region_progress.get("clearCount", clear_count_before)),
		"regionReward": region_reward,
		"rewardFragment": str(region.get("rewardFragment", "")) if region_applied else "",
		"enemyVariant": enemy_variant.duplicate(true),
		"region": region,
	}


func _resolve_adventure_combat_node(
	enemy_pool: Array[Dictionary],
	boss: bool,
	node_index: int,
	starting_player_hp: float,
	player_attack: float,
	player_magic_attack: float,
	player_defense: float,
	player_magic_defense: float,
	enemy_scale: float,
	region_name: String,
	enemy_variant: Dictionary = {}
) -> Dictionary:
	var enemy: Dictionary = _pick_enemy(enemy_pool, boss, "adventure_enemy_%d" % node_index)
	if enemy.is_empty():
		enemy = {"id": "EN_FALLBACK", "name": "훈련용 수호체", "hp": 55, "attack": 18, "defense": 10, "magicAttack": 12, "magicDefense": 10, "traits": []}
	var player_hp: float = starting_player_hp
	var enemy_hp: float = maxf(1.0, float(enemy.get("hp", 50.0)) * enemy_scale * maxf(0.1, float(enemy_variant.get("hpMultiplier", 1.0))))
	var enemy_attack: float = float(enemy.get("attack", 15.0)) * enemy_scale * maxf(0.1, float(enemy_variant.get("attackMultiplier", 1.0)))
	var enemy_magic_attack: float = float(enemy.get("magicAttack", 0.0)) * enemy_scale * maxf(0.1, float(enemy_variant.get("magicMultiplier", 1.0)))
	var enemy_defense: float = float(enemy.get("defense", 8.0)) * enemy_scale * maxf(0.1, float(enemy_variant.get("defenseMultiplier", 1.0)))
	var enemy_magic_defense: float = float(enemy.get("magicDefense", 8.0)) * enemy_scale * maxf(0.1, float(enemy_variant.get("magicDefenseMultiplier", 1.0)))
	var damage_jitter_min := _config_float("combatDamageJitterMin", 0.85)
	var damage_jitter_max := maxf(damage_jitter_min, _config_float("combatDamageJitterMax", 1.15))
	var rounds: int = 0
	while player_hp > 0.0 and enemy_hp > 0.0 and rounds < 30:
		var physical_damage: int = maxi(1, int(floor((player_attack - enemy_defense) * DeterministicRNG.next_float(_state, damage_jitter_min, damage_jitter_max, "player_physical"))))
		var magic_damage: int = maxi(1, int(floor((player_magic_attack - enemy_magic_defense) * DeterministicRNG.next_float(_state, damage_jitter_min, damage_jitter_max, "player_magic"))))
		enemy_hp -= float(maxi(physical_damage, magic_damage))
		if enemy_hp <= 0.0:
			break
		var incoming_physical: int = maxi(1, int(floor((enemy_attack - player_defense) * DeterministicRNG.next_float(_state, damage_jitter_min, damage_jitter_max, "enemy_physical"))))
		var incoming_magic: int = maxi(1, int(floor((enemy_magic_attack - player_magic_defense) * DeterministicRNG.next_float(_state, damage_jitter_min, damage_jitter_max, "enemy_magic"))))
		var incoming: int = maxi(incoming_physical, incoming_magic)
		player_hp -= float(incoming)
		rounds += 1
	var node_won: bool = enemy_hp <= 0.0 and player_hp > 0.0
	var damage_taken: float = maxf(0.0, starting_player_hp - player_hp)
	return {
		"won": node_won,
		"playerHp": player_hp,
		"nodeResult": {
			"node": node_index + 1,
			"type": "boss" if boss else "encounter",
			"event": "지역 보스" if boss else "적 조우",
			"effect": {"hp": -snappedf(damage_taken, 0.01)},
			"enemyId": str(enemy.get("id", "")),
			"enemyName": "%s · %s" % [region_name, str(enemy_variant.get("name", enemy.get("name", "적")))],
			"enemyTraitId": str(enemy_variant.get("traitId", "")),
			"enemyTraitName": str(enemy_variant.get("traitName", "")),
			"won": node_won,
			"rounds": rounds + 1,
			"remainingHp": maxf(0.0, snappedf(player_hp, 0.01)),
		},
	}


func _pick_enemy(enemy_pool: Array[Dictionary], boss: bool, salt: String) -> Dictionary:
	if enemy_pool.is_empty():
		return {}
	var candidates: Array[Dictionary] = []
	for enemy: Dictionary in enemy_pool:
		var is_boss: bool = (enemy.get("traits", []) as Array).has("boss")
		if is_boss == boss:
			candidates.append(enemy)
	if candidates.is_empty():
		candidates = enemy_pool
	var weights: Array[float] = []
	for enemy: Dictionary in candidates:
		weights.append(maxf(0.01, float(enemy.get("weight", 1.0))))
	var selected_index: int = DeterministicRNG.weighted_index(_state, weights, salt)
	return candidates[selected_index]


func _pick_loot(loot_table: Array, salt: String) -> Dictionary:
	var entries: Array[Dictionary] = []
	var weights: Array[float] = []
	for raw_entry: Variant in loot_table:
		if raw_entry is Dictionary:
			entries.append(raw_entry as Dictionary)
			weights.append(maxf(0.01, float((raw_entry as Dictionary).get("weight", 1.0))))
	if entries.is_empty():
		return {}
	return entries[DeterministicRNG.weighted_index(_state, weights, salt)]


func _effective_stat(key: String) -> float:
	var base_value: float = _state_numeric(key)
	return maxf(0.0, base_value + _equipment_modifier(key))


func _equipment_modifier(key: String) -> float:
	var total: float = 0.0
	var equipment: Dictionary = _state.get("equipment", {}) as Dictionary
	for raw_id: Variant in equipment.values():
		if raw_id == null:
			continue
		var item_id: String = str(raw_id)
		var item: Dictionary = _content_db.get_item(item_id)
		var enhancement_level: int = _equipment_enhancement_level(item_id)
		var enhancement_scale: float = 1.0 + maxf(0.0, _config_float("equipmentModifierSqrtRate", 0.08)) * sqrt(float(maxi(0, enhancement_level - 1)))
		total += float((item.get("modifiers", {}) as Dictionary).get(key, 0.0)) * enhancement_scale
	return total


func _equipment_enhancement_level(item_id: String) -> int:
	for raw_stack: Variant in _state.get("inventory", []) as Array:
		if raw_stack is Dictionary and str((raw_stack as Dictionary).get("id", "")) == item_id:
			return maxi(1, int((raw_stack as Dictionary).get("enhancementLevel", 1)))
	return 1


func _gear_score() -> float:
	return _equipment_modifier("gearScore")


func _apply_fixed_deltas(deltas: Dictionary) -> void:
	if deltas.is_empty():
		return
	if deltas.has("stats") or deltas.has("meters") or deltas.has("relations") or deltas.has("bigValues") or deltas.has("flags"):
		_apply_effects(deltas)
		return
	var stats: Dictionary = _state.get("stats", {}) as Dictionary
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	for raw_key: Variant in deltas.keys():
		var key: String = str(raw_key)
		if stats.has(key):
			stats[key] = maxf(0.0, float(stats.get(key, 0.0)) + float(deltas[raw_key]))
		elif meters.has(key):
			meters[key] = maxf(0.0, float(meters.get(key, 0.0)) + float(deltas[raw_key]))
	meters["energy"] = clampf(float(meters.get("energy", 100.0)), 0.0, 100.0)
	meters["stress"] = clampf(float(meters.get("stress", 0.0)), 0.0, 100.0)


func resolve_event(event_or_instance_id: String, choice_id: String = "") -> Dictionary:
	_ensure_initialized()
	var inbox: Array = _state.get("eventInbox", []) as Array
	for index: int in range(inbox.size()):
		if inbox[index] is not Dictionary:
			continue
		var instance: Dictionary = inbox[index] as Dictionary
		if str(instance.get("instanceId", "")) != event_or_instance_id and str(instance.get("id", "")) != event_or_instance_id:
			continue
		var selected_choice_id: String = choice_id
		if selected_choice_id.is_empty():
			selected_choice_id = str(instance.get("defaultChoice", ""))
		var selected_choice: Dictionary = {}
		for raw_choice: Variant in instance.get("choices", []) as Array:
			if raw_choice is Dictionary and str((raw_choice as Dictionary).get("id", "")) == selected_choice_id:
				selected_choice = raw_choice as Dictionary
				break
		if selected_choice.is_empty():
			return {"ok": false, "error": "이벤트 선택지를 찾을 수 없음"}
		_apply_effects(selected_choice.get("effects", selected_choice.get("effect", {})) as Dictionary)
		inbox.remove_at(index)
		var event_id: String = str(instance.get("id", ""))
		var history: Dictionary = _state.get("eventHistory", {}) as Dictionary
		var old_entry: Dictionary = history.get(event_id, {}) as Dictionary
		history[event_id] = {
			"count": int(old_entry.get("count", 0)) + 1,
			"lastSlot": int((_state.get("time", {}) as Dictionary).get("slot", 0)),
			"lastChoice": selected_choice_id,
		}
		return _with_state({"ok": true, "eventId": event_id, "choiceId": selected_choice_id, "effects": selected_choice.get("effects", {})})
	return {"ok": false, "error": "이벤트를 찾을 수 없음"}


func resolve_default_event(event_or_instance_id: String) -> Dictionary:
	return resolve_event(event_or_instance_id, "")


func _maybe_queue_event(activity: Dictionary, context: Dictionary) -> Dictionary:
	var inbox: Array = _state.get("eventInbox", []) as Array
	if inbox.size() >= _config_int("eventInboxMax", EVENT_INBOX_MAX):
		return {}
	var eligible: Array[Dictionary] = []
	var highest_priority: int = -2147483648
	for event: Dictionary in _content_db.events:
		if not _event_available(event):
			continue
		var trigger_context: Dictionary = context.duplicate(true)
		trigger_context["eventWeight"] = float(event.get("weight", 50.0))
		if not _event_trigger_met(event.get("trigger", {}) as Dictionary, activity, trigger_context):
			continue
		var priority: int = int(event.get("priority", 0))
		if priority > highest_priority:
			highest_priority = priority
			eligible.clear()
		if priority == highest_priority:
			eligible.append(event)
	if eligible.is_empty():
		return {}
	var weights: Array[float] = []
	for event: Dictionary in eligible:
		weights.append(maxf(0.01, float(event.get("weight", 1.0))))
	var selected: Dictionary = eligible[DeterministicRNG.weighted_index(_state, weights, "event_pick")]
	var event_id: String = str(selected.get("id", ""))
	var total_slot: int = int((_state.get("time", {}) as Dictionary).get("slot", 0))
	var queued_at_unix: int = _now_boundary_unix if _now_boundary_unix >= 0 else int(_state.get("lastSimulatedAt", 0))
	var instance: Dictionary = selected.duplicate(true)
	instance["instanceId"] = "%s_%d_%d" % [event_id, total_slot, int(_state.get("rngCounter", 0))]
	instance["name"] = str(selected.get("title", selected.get("name", event_id)))
	instance["queuedAtSlot"] = total_slot
	instance["queuedAtUnix"] = queued_at_unix
	instance["expiresAtUnix"] = queued_at_unix + _config_int("eventChoiceTimeoutSeconds", 86400) if queued_at_unix > 0 else 0
	inbox.append(instance)
	var cooldowns: Dictionary = _state.get("eventCooldowns", {}) as Dictionary
	cooldowns[event_id] = total_slot
	return instance.duplicate(true)


func _event_available(event: Dictionary) -> bool:
	var event_id: String = str(event.get("id", ""))
	var history: Dictionary = _state.get("eventHistory", {}) as Dictionary
	if bool(event.get("once", false)) and history.has(event_id):
		return false
	for queued: Variant in _state.get("eventInbox", []) as Array:
		if queued is Dictionary and str((queued as Dictionary).get("id", "")) == event_id:
			return false
	var cooldown_slots: int = maxi(0, int(event.get("cooldownSlots", 0)))
	var last_queued: int = int((_state.get("eventCooldowns", {}) as Dictionary).get(event_id, -1000000000))
	var current_slot: int = int((_state.get("time", {}) as Dictionary).get("slot", 0))
	return current_slot - last_queued >= cooldown_slots


func _event_trigger_met(trigger: Dictionary, _activity: Dictionary, context: Dictionary) -> bool:
	var kind: String = str(trigger.get("kind", "random"))
	var time: Dictionary = _state.get("time", {}) as Dictionary
	var total_slot: int = int(time.get("slot", 0)) + 1
	var slots_per_season: int = maxi(1, _config_int("slotsPerSeason", SLOTS_PER_SEASON))
	var slot_in_season: int = ((total_slot - 1) % slots_per_season) + 1
	var season_of_year: int = int(time.get("season", 1))
	match kind:
		"season_start":
			return _crossed_calendar_slot(
				int(context.get("startedAtSlot", total_slot - 1)),
				int(context.get("completedAtSlot", total_slot)),
				int(trigger.get("seasonOfYear", season_of_year)),
				1
			)
		"season_slot":
			return _crossed_calendar_slot(
				int(context.get("startedAtSlot", total_slot - 1)),
				int(context.get("completedAtSlot", total_slot)),
				int(trigger.get("seasonOfYear", season_of_year)),
				int(trigger.get("slot", -1))
			)
		"mastery_reached":
			var threshold: int = int(trigger.get("threshold", 10))
			for value: Variant in (_state.get("mastery", {}) as Dictionary).values():
				if int(value) >= threshold:
					return true
			return false
		"world_tier_up":
			return bool(context.get("worldTierUp", false)) or bool((_state.get("flags", {}) as Dictionary).get("justWorldTierUp", false))
		"career_title_gained":
			return bool(context.get("careerTitleGained", false)) or bool((_state.get("flags", {}) as Dictionary).get("justCareerTitleGained", false))
		"relation_reached", "relation_periodic":
			return float((_state.get("relations", {}) as Dictionary).get(str(trigger.get("relation", "")), 0.0)) >= float(trigger.get("value", trigger.get("minimum", 0.0)))
		"relation_reached_repeat":
			var relation_value: float = float((_state.get("relations", {}) as Dictionary).get(str(trigger.get("relation", "")), 0.0))
			var step: float = maxf(1.0, float(trigger.get("step", 100.0)))
			var history_count: int = int(((_state.get("eventHistory", {}) as Dictionary).get("EV_CITIZEN_THANKS", {}) as Dictionary).get("count", 0))
			return relation_value >= step * float(history_count + 1)
		"stat_gte":
			return float((_state.get("stats", {}) as Dictionary).get(str(trigger.get("stat", "")), 0.0)) >= float(trigger.get("value", 0.0))
		"meter_gte":
			return float((_state.get("meters", {}) as Dictionary).get(str(trigger.get("meter", "")), 0.0)) >= float(trigger.get("value", 0.0))
		"recovered":
			return float(context.get("stressBefore", 0.0)) >= float(trigger.get("fromStress", 80.0)) and float((_state.get("meters", {}) as Dictionary).get("stress", 100.0)) <= float(trigger.get("toStress", 35.0))
		"balanced_stats":
			var qualified: Array[float] = []
			var minimum: float = float(trigger.get("minimum", 0.0))
			for raw_value: Variant in (_state.get("stats", {}) as Dictionary).values():
				if float(raw_value) >= minimum:
					qualified.append(float(raw_value))
			if qualified.size() < int(trigger.get("minimumCount", 1)):
				return false
			qualified.sort()
			return qualified[qualified.size() - 1] - qualified[0] <= float(trigger.get("maximumSpread", 999999.0))
		"random":
			if int(_state.get("worldTier", 1)) < int(trigger.get("minimumWorldTier", 1)):
				return false
			if float((_state.get("meters", {}) as Dictionary).get("energy", 0.0)) < float(trigger.get("minimumEnergy", 0.0)):
				return false
			if float((_state.get("meters", {}) as Dictionary).get("stress", 0.0)) > float(trigger.get("maximumStress", 100.0)):
				return false
			if float((_state.get("stats", {}) as Dictionary).get("discipline", 0.0)) < float(trigger.get("minimumDiscipline", 0.0)):
				return false
			# Data weight is 0..100 and doubles as a per-mille occurrence gate.
			return DeterministicRNG.next_float(_state, 0.0, 1000.0, "random_event_gate") < float(context.get("eventWeight", 50.0))
	return false


func _crossed_calendar_slot(start_total_slot: int, completed_total_slot: int, target_season_of_year: int, target_slot_in_season: int) -> bool:
	var slots_per_season: int = maxi(1, _config_int("slotsPerSeason", SLOTS_PER_SEASON))
	var seasons_per_year: int = maxi(1, _config_int("seasonsPerYear", SEASONS_PER_YEAR))
	if target_slot_in_season < 1 or target_slot_in_season > slots_per_season:
		return false
	for absolute_slot: int in range(maxi(1, start_total_slot + 1), maxi(start_total_slot + 1, completed_total_slot + 1)):
		var season_index_zero: int = (absolute_slot - 1) / slots_per_season
		var season_at_slot: int = season_index_zero % seasons_per_year + 1
		var slot_at_slot: int = (absolute_slot - 1) % slots_per_season + 1
		if season_at_slot == target_season_of_year and slot_at_slot == target_slot_in_season:
			return true
	return false


func _resolve_expired_events(now_unix: int) -> void:
	var pending_ids: Array[String] = []
	for raw_event: Variant in _state.get("eventInbox", []) as Array:
		if raw_event is not Dictionary:
			continue
		var event: Dictionary = raw_event as Dictionary
		var expires_at: int = int(event.get("expiresAtUnix", 0))
		if expires_at > 0 and now_unix >= expires_at:
			pending_ids.append(str(event.get("instanceId", event.get("id", ""))))
	for instance_id: String in pending_ids:
		resolve_default_event(instance_id)


func _stamp_unanchored_events(anchor_unix: int) -> void:
	if anchor_unix <= 0:
		return
	var timeout_seconds: int = maxi(1, _config_int("eventChoiceTimeoutSeconds", 86400))
	for raw_event: Variant in _state.get("eventInbox", []) as Array:
		if raw_event is not Dictionary:
			continue
		var event: Dictionary = raw_event as Dictionary
		var queued_at: int = int(event.get("queuedAtUnix", 0))
		if queued_at <= 0:
			queued_at = anchor_unix
			event["queuedAtUnix"] = queued_at
		if int(event.get("expiresAtUnix", 0)) <= 0:
			event["expiresAtUnix"] = queued_at + timeout_seconds


func _apply_effects(effects: Dictionary) -> void:
	var stats: Dictionary = _state.get("stats", {}) as Dictionary
	for raw_key: Variant in (effects.get("stats", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		stats[key] = maxf(0.0, float(stats.get(key, 0.0)) + float((effects.get("stats", {}) as Dictionary)[raw_key]))
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	for raw_key: Variant in (effects.get("meters", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		meters[key] = float(meters.get(key, 0.0)) + float((effects.get("meters", {}) as Dictionary)[raw_key])
	meters["energy"] = clampf(float(meters.get("energy", 100.0)), 0.0, 100.0)
	meters["stress"] = clampf(float(meters.get("stress", 0.0)), 0.0, 100.0)
	meters["reputation"] = maxf(0.0, float(meters.get("reputation", 0.0)))
	var big_values: Dictionary = _state.get("bigValues", {}) as Dictionary
	var renown_increased: bool = false
	var world_tier_before: int = int(_state.get("worldTier", 1))
	for raw_key: Variant in (effects.get("bigValues", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		var delta: Variant = (effects.get("bigValues", {}) as Dictionary)[raw_key]
		var current: Dictionary = big_values.get(key, BigValue.zero()) as Dictionary
		if delta is int or delta is float:
			if float(delta) >= 0.0:
				var positive_amount: Dictionary = BigValue.from_number(delta)
				if key == "gold":
					_grant_gold(positive_amount)
				elif key == "renown":
					_grant_renown(positive_amount)
					renown_increased = not BigValue.is_zero(positive_amount)
				else:
					big_values[key] = BigValue.add(current, positive_amount)
			else:
				big_values[key] = BigValue.subtract(current, BigValue.from_number(-float(delta)))
		elif delta is Dictionary:
			if key == "gold":
				_grant_gold(delta as Dictionary)
			elif key == "renown":
				_grant_renown(delta as Dictionary)
				renown_increased = not BigValue.is_zero(delta as Dictionary)
			else:
				big_values[key] = BigValue.add(current, delta as Dictionary)
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	for raw_key: Variant in (effects.get("relations", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		relations[key] = clampf(float(relations.get(key, 0.0)) + float((effects.get("relations", {}) as Dictionary)[raw_key]), 0.0, 1000.0)
	var flags: Dictionary = _state.get("flags", {}) as Dictionary
	for raw_key: Variant in (effects.get("flags", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		var value: Variant = (effects.get("flags", {}) as Dictionary)[raw_key]
		flags[key] = value
		if key == "forceRest":
			_state["forceRest"] = bool(value)
	if renown_increased:
		_state["worldTier"] = _world_tier_from_renown(big_values.get("lifetimeRenown", BigValue.zero()) as Dictionary)
		flags["justWorldTierUp"] = int(_state.get("worldTier", 1)) > world_tier_before


func pin_contract(contract_id: String) -> bool:
	_ensure_initialized()
	var generated: Dictionary = state_generated_content()
	if contract_id.is_empty():
		generated["pinnedContractId"] = ""
		return true
	for contract: Variant in generated.get("contracts", []) as Array:
		if contract is Dictionary and str((contract as Dictionary).get("id", "")) == contract_id:
			generated["pinnedContractId"] = contract_id
			return true
	return false


func _update_contracts(activity: Dictionary, gains: Dictionary, specialized: Dictionary, activity_reward: Dictionary) -> void:
	var generated: Dictionary = state_generated_content()
	for raw_contract: Variant in generated.get("contracts", []) as Array:
		if raw_contract is not Dictionary:
			continue
		var contract: Dictionary = raw_contract as Dictionary
		if str(contract.get("status", "active")) != "active":
			continue
		var contract_kind: String = str(contract.get("kind", "complete_kind"))
		var target_match: bool = _planner.contract_activity_matches(contract, activity)
		var tracking: Dictionary = _update_contract_tracking(contract, activity, specialized, target_match)
		contract["tracking"] = tracking
		var progress_delta: float = 0.0
		match contract_kind:
			"complete_kind", "master_activity":
				progress_delta = 1.0 if target_match else 0.0
			"balanced_cycle":
				progress_delta = maxf(0.0, float((tracking.get("distinctKinds", []) as Array).size()) - float(contract.get("progress", 0.0)))
			"gain_stat":
				progress_delta = float(gains.get(str(contract.get("targetStat", "")), 0.0))
			"win_challenge":
				progress_delta = 1.0 if target_match and str(activity.get("kind", "")) == "challenge" and bool(specialized.get("won", false)) else 0.0
			"clear_adventure":
				progress_delta = 1.0 if target_match and str(activity.get("kind", "")) == "adventure" and bool(specialized.get("won", false)) else 0.0
			"earn_gold":
				progress_delta = BigValue.to_float(activity_reward, 1.0e12) if target_match else 0.0
			"relation_gain":
				progress_delta = float(specialized.get("relationGain", 0.0)) if target_match else 0.0
		var contract_region: Dictionary = contract.get("region", {}) as Dictionary
		var region_matched: bool = target_match and not contract_region.is_empty() and str(activity.get("kind", "")) == "adventure" and str(contract_region.get("id", "")) == str(specialized.get("baseRegionId", ""))
		if region_matched:
			progress_delta *= 1.25
			tracking["regionMatches"] = int(tracking.get("regionMatches", 0)) + 1
		var modifier_status: Dictionary = _contract_modifier_status(contract, activity, specialized, tracking, false)
		contract["modifierStatus"] = modifier_status
		for raw_modifier: Variant in contract.get("modifiers", []) as Array:
			var modifier_id: String = str(raw_modifier)
			if not bool(modifier_status.get(modifier_id, false)) and not ["mastery_focus", "limited_slots", "balanced_tags"].has(modifier_id):
				progress_delta = 0.0
				break
		if progress_delta <= 0.0:
			progress_delta = 0.0
		else:
			contract["progress"] = minf(float(contract.get("target", 1.0)), float(contract.get("progress", 0.0)) + progress_delta)
		if float(contract["progress"]) >= float(contract.get("target", 1.0)):
			modifier_status = _contract_modifier_status(contract, activity, specialized, tracking, true)
			contract["modifierStatus"] = modifier_status
			var all_modifiers_met: bool = true
			for raw_modifier: Variant in contract.get("modifiers", []) as Array:
				if not bool(modifier_status.get(str(raw_modifier), false)):
					all_modifiers_met = false
					break
			if not all_modifiers_met:
				continue
			contract["status"] = "completed"
			var reward: Dictionary = contract.get("reward", BigValue.zero()) as Dictionary
			var bonus_achieved: bool = _contract_bonus_achieved(contract, tracking)
			var bonus_objective: Dictionary = contract.get("bonusObjective", {}) as Dictionary
			var reward_multiplier: float = float(bonus_objective.get("rewardMultiplier", 1.0)) if bonus_achieved else 1.0
			var granted_reward: Dictionary = BigValue.multiply_float(reward, reward_multiplier)
			contract["bonusAchieved"] = bonus_achieved
			contract["rewardMultiplier"] = reward_multiplier
			contract["rewardGranted"] = granted_reward
			_grant_gold(granted_reward)
			var lifetime: Dictionary = _state.get("lifetimeStats", {}) as Dictionary
			lifetime["contracts"] = int(lifetime.get("contracts", 0)) + 1
			var counters: Dictionary = _state.get("seasonCounters", {}) as Dictionary
			counters["completedContracts"] = int(counters.get("completedContracts", 0)) + 1
			var contract_relation_gain: float = maxf(0.0, _config_float("contractCompletionRelationGain", 1.0))
			var relations: Dictionary = _state.get("relations", {}) as Dictionary
			relations["citizens"] = clampf(float(relations.get("citizens", 0.0)) + contract_relation_gain, 0.0, 1000.0)
			contract["completionRelationGain"] = contract_relation_gain


func _update_contract_tracking(contract: Dictionary, activity: Dictionary, specialized: Dictionary, target_match: bool) -> Dictionary:
	var tracking: Dictionary = (contract.get("tracking", {}) as Dictionary).duplicate(true)
	tracking["slotsUsed"] = int(tracking.get("slotsUsed", 0)) + maxi(1, int(specialized.get("durationSlots", activity.get("durationSlots", 1))))
	tracking["maximumStress"] = maxf(float(tracking.get("maximumStress", 0.0)), float((_state.get("meters", {}) as Dictionary).get("stress", 0.0)))
	tracking["goldSpent"] = float(tracking.get("goldSpent", 0.0)) + BigValue.to_float(specialized.get("paidCost", BigValue.zero()) as Dictionary, 1.0e12)
	tracking["masteryGained"] = int(tracking.get("masteryGained", 0)) + (int(specialized.get("masteryGained", 1)) if target_match else 0)
	tracking["reputationGained"] = float(tracking.get("reputationGained", 0.0)) + float(specialized.get("reputationGain", 0.0))
	tracking["relationGained"] = float(tracking.get("relationGained", 0.0)) + float(specialized.get("relationGain", 0.0))
	tracking["injuries"] = int(tracking.get("injuries", 0)) + (1 if bool(specialized.get("injured", false)) else 0)
	tracking["challengeWins"] = int(tracking.get("challengeWins", 0)) + (1 if str(activity.get("kind", "")) == "challenge" and bool(specialized.get("won", false)) else 0)
	tracking["maximumPerformance"] = maxf(float(tracking.get("maximumPerformance", 0.0)), float(specialized.get("performanceMod", 0.0)))
	tracking["policyFit"] = _calculate_policy_fit()
	var activity_id: String = str(activity.get("id", ""))
	var last_activity_id: String = str(tracking.get("lastActivityId", ""))
	var consecutive_same: int = int(tracking.get("consecutiveSame", 0)) + 1 if last_activity_id == activity_id else 1
	tracking["lastActivityId"] = activity_id
	tracking["consecutiveSame"] = consecutive_same
	tracking["maximumConsecutiveSame"] = maxi(int(tracking.get("maximumConsecutiveSame", 0)), consecutive_same)
	for field_name: String in ["distinctActivities", "distinctKinds", "distinctTags"]:
		if not tracking.has(field_name) or tracking[field_name] is not Array:
			tracking[field_name] = []
	var distinct_activities: Array = tracking["distinctActivities"] as Array
	if not distinct_activities.has(activity_id):
		distinct_activities.append(activity_id)
	var distinct_kinds: Array = tracking["distinctKinds"] as Array
	var activity_kind: String = str(activity.get("kind", ""))
	if not distinct_kinds.has(activity_kind):
		distinct_kinds.append(activity_kind)
	var distinct_tags: Array = tracking["distinctTags"] as Array
	for raw_tag: Variant in activity.get("tags", []) as Array:
		var tag: String = str(raw_tag)
		if not distinct_tags.has(tag):
			distinct_tags.append(tag)
	return tracking


func _contract_modifier_status(contract: Dictionary, activity: Dictionary, specialized: Dictionary, tracking: Dictionary, completion_check: bool) -> Dictionary:
	var status: Dictionary = {}
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	var policy: Dictionary = _state.get("growthPolicy", {}) as Dictionary
	var requirements_by_modifier: Dictionary = contract.get("modifierRequirements", {}) as Dictionary
	for raw_modifier: Variant in contract.get("modifiers", []) as Array:
		var modifier_id: String = str(raw_modifier)
		var requirements: Dictionary = requirements_by_modifier.get(modifier_id, {}) as Dictionary
		match modifier_id:
			"low_energy":
				status[modifier_id] = float(meters.get("energy", 0.0)) >= float(requirements.get("minimumEnergy", 25.0))
			"high_quality":
				status[modifier_id] = float(specialized.get("performanceMod", 0.0)) >= float(requirements.get("minimumPerformance", 1.1))
			"no_repeat":
				status[modifier_id] = int(tracking.get("maximumConsecutiveSame", 1)) <= maxi(1, int(requirements.get("maximumConsecutiveSame", 1)))
			"risk_bonus":
				var injury_allowed := bool(requirements.get("allowInjury", false))
				status[modifier_id] = float(activity.get("risk", 0.0)) >= float(requirements.get("minimumRisk", 0.2)) and (injury_allowed or not bool(specialized.get("injured", false))) and bool(specialized.get("won", true))
			"budget_guard":
				var gold: Dictionary = ((_state.get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary)
				var reserve: Dictionary = policy.get("reserveGold", BigValue.zero()) as Dictionary
				status[modifier_id] = BigValue.compare(gold, reserve) >= 0
			"mastery_focus":
				status[modifier_id] = not completion_check or int(tracking.get("masteryGained", 0)) >= maxi(1, int(requirements.get("masteryGain", 3)))
			"limited_slots":
				var slot_limit: int = int(ceil(float(contract.get("target", 1.0)) * float(contract.get("targetDurationSlots", 1)) * maxf(0.0, float(requirements.get("slotMultiplier", 1.5)))))
				status[modifier_id] = not completion_check or int(tracking.get("slotsUsed", 0)) <= slot_limit
			"balanced_tags":
				status[modifier_id] = not completion_check or (tracking.get("distinctTags", []) as Array).size() >= maxi(1, int(requirements.get("distinctTagCount", 3)))
			"stress_guard":
				status[modifier_id] = float(tracking.get("maximumStress", 0.0)) <= float(policy.get("maxStress", 72.0))
			"community_bonus":
				status[modifier_id] = float(specialized.get("relationGain", 0.0)) >= float(requirements.get("minimumRelationGain", 1.0))
			_:
				status[modifier_id] = true
	return status


func _contract_bonus_achieved(contract: Dictionary, tracking: Dictionary) -> bool:
	var objective: Dictionary = contract.get("bonusObjective", {}) as Dictionary
	if objective.is_empty():
		return false
	var metric: String = str(objective.get("metric", ""))
	var scale: float = maxf(0.0, float(objective.get("targetScale", 1.0)))
	var target: float = maxf(1.0, float(contract.get("target", 1.0)))
	match metric:
		"slotsUsed":
			return float(tracking.get("slotsUsed", INF)) <= target * scale
		"maximumStress":
			return float(tracking.get("maximumStress", INF)) <= float((_state.get("growthPolicy", {}) as Dictionary).get("maxStress", 72.0)) * scale
		"goldSpent":
			return float(tracking.get("goldSpent", INF)) <= BigValue.to_float(contract.get("reward", BigValue.zero()) as Dictionary, 1.0e12) * scale
		"masteryGained":
			return float(tracking.get("masteryGained", 0)) >= target * scale
		"reputationGained":
			return float(tracking.get("reputationGained", 0.0)) >= scale
		"relationGained":
			return float(tracking.get("relationGained", 0.0)) >= scale
		"distinctActivities":
			return (tracking.get("distinctActivities", []) as Array).size() >= int(ceil(scale))
		"injuries":
			return float(tracking.get("injuries", 0)) <= scale
		"policyFit":
			return float(tracking.get("policyFit", 0.0)) >= scale
		"challengeWins":
			return int(tracking.get("challengeWins", 0)) >= int(ceil(scale))
	return false


func buy_item(item_id: String, count: int = 1) -> Dictionary:
	_ensure_initialized()
	var item: Dictionary = _content_db.get_item(item_id)
	if item.is_empty():
		return {"ok": false, "error": "존재하지 않는 아이템"}
	var requested: int = maxi(1, count)
	if not bool(item.get("stackable", false)):
		requested = 1
		if _inventory_count(item_id) > 0:
			return {"ok": false, "error": "이미 보유한 장비"}
	var available_space: int = _config_int("inventoryStackMax", INVENTORY_STACK_MAX) - _inventory_count(item_id)
	requested = mini(requested, available_space)
	if requested <= 0:
		return {"ok": false, "error": "인벤토리 중첩 한도"}
	var unit_price: Dictionary = BigValue.multiply(BigValue.from_number(item.get("basePrice", 0)), BigValue.pow_base(maxf(1.0, _config_float("activityCostTierGrowth", 1.11)), maxi(0, int(_state.get("worldTier", 1)) - 1)))
	var total_price: Dictionary = BigValue.multiply_float(unit_price, float(requested))
	if not _spend_gold(total_price):
		return {"ok": false, "error": "골드 부족", "price": total_price}
	var enhancement_level: int = maxi(1, int(_state.get("worldTier", 1))) if not bool(item.get("stackable", false)) else 1
	_add_inventory(item_id, requested, enhancement_level)
	return {"ok": true, "itemId": item_id, "count": requested, "price": total_price, "enhancementLevel": enhancement_level}


func purchase_item(item_id: String, count: int = 1) -> Dictionary:
	return buy_item(item_id, count)


func sell_item(item_id: String, count: int = 1) -> Dictionary:
	_ensure_initialized()
	var item: Dictionary = _content_db.get_item(item_id)
	var owned: int = _inventory_count(item_id)
	if item.is_empty() or owned <= 0:
		return {"ok": false, "error": "판매할 아이템이 없음"}
	var sold: int = mini(maxi(1, count), owned)
	var sold_enhancement_level: int = _equipment_enhancement_level(item_id) if not bool(item.get("stackable", false)) else maxi(1, int(_state.get("worldTier", 1)))
	_remove_inventory(item_id, sold)
	var unit_price: Dictionary = BigValue.multiply(BigValue.from_number(item.get("basePrice", 0)), BigValue.pow_base(maxf(1.0, _config_float("activityCostTierGrowth", 1.11)), maxi(0, sold_enhancement_level - 1)))
	var proceeds: Dictionary = BigValue.multiply_float(unit_price, float(sold) * _config_float("sellRatio", SELL_RATIO))
	_grant_gold(proceeds)
	var equipment: Dictionary = _state.get("equipment", {}) as Dictionary
	for slot: Variant in equipment.keys():
		if str(equipment[slot]) == item_id and _inventory_count(item_id) <= 0:
			equipment[slot] = null
	return {"ok": true, "itemId": item_id, "count": sold, "proceeds": proceeds, "enhancementLevel": sold_enhancement_level}


func equip_item(item_id: String) -> Dictionary:
	_ensure_initialized()
	var item: Dictionary = _content_db.get_item(item_id)
	if item.is_empty() or _inventory_count(item_id) <= 0:
		return {"ok": false, "error": "보유하지 않은 장비"}
	var slot: String = str(item.get("equipSlot", ""))
	if not ["outfit", "weapon", "armor", "accessory"].has(slot):
		return {"ok": false, "error": "장착할 수 없는 아이템"}
	(_state.get("equipment", {}) as Dictionary)[slot] = item_id
	return {"ok": true, "itemId": item_id, "slot": slot, "enhancementLevel": _equipment_enhancement_level(item_id)}


func unequip(slot: String) -> bool:
	_ensure_initialized()
	var equipment: Dictionary = _state.get("equipment", {}) as Dictionary
	if not equipment.has(slot):
		return false
	equipment[slot] = null
	return true


func use_item(item_id: String) -> Dictionary:
	_ensure_initialized()
	var item: Dictionary = _content_db.get_item(item_id)
	if item.is_empty() or not bool(item.get("stackable", false)) or _inventory_count(item_id) <= 0:
		return {"ok": false, "error": "사용할 수 없는 아이템"}
	_apply_effects(item.get("useEffects", {}) as Dictionary)
	_remove_inventory(item_id, 1)
	return {"ok": true, "itemId": item_id, "effects": item.get("useEffects", {})}


func gift_item(item_id: String, relation_id: String) -> Dictionary:
	_ensure_initialized()
	if not ["guardian", "steward", "rival", "citizens"].has(relation_id):
		return {"ok": false, "error": "허용되지 않은 관계 축", "relationId": relation_id}
	var item: Dictionary = _content_db.get_item(item_id)
	if item.is_empty() or not bool(item.get("stackable", false)) or not (item.get("tags", []) as Array).has("consumable") or _inventory_count(item_id) <= 0:
		return {"ok": false, "error": "선물할 소비품이 없음", "itemId": item_id}
	var affinity_tags: Dictionary = {
		"guardian": ["recovery", "healing", "food"],
		"steward": ["study", "academic", "magic"],
		"rival": ["adventure", "energy", "injury"],
		"citizens": ["food", "stress", "recovery"],
	}
	var item_tags: Array = item.get("tags", []) as Array
	var affinity_bonus: float = 0.0
	for raw_tag: Variant in affinity_tags.get(relation_id, []) as Array:
		if item_tags.has(str(raw_tag)):
			affinity_bonus = 2.0
			break
	var relation_gain: float = 3.0 + affinity_bonus
	_remove_inventory(item_id, 1)
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	var before: float = float(relations.get(relation_id, 0.0))
	relations[relation_id] = clampf(before + relation_gain, 0.0, 1000.0)
	return {
		"ok": true,
		"itemId": item_id,
		"relationId": relation_id,
		"relationGain": float(relations[relation_id]) - before,
		"affinityBonus": affinity_bonus,
		"remainingCount": _inventory_count(item_id),
	}


func _add_inventory(item_id: String, count: int, enhancement_level: int = -1) -> bool:
	if item_id.is_empty() or count <= 0 or _content_db.get_item(item_id).is_empty():
		return false
	var inventory: Array = _state.get("inventory", []) as Array
	var item: Dictionary = _content_db.get_item(item_id)
	for raw_stack: Variant in inventory:
		if raw_stack is Dictionary and str((raw_stack as Dictionary).get("id", "")) == item_id:
			var maximum: int = _config_int("inventoryStackMax", INVENTORY_STACK_MAX) if bool(item.get("stackable", false)) else 1
			(raw_stack as Dictionary)["count"] = mini(maximum, int((raw_stack as Dictionary).get("count", 0)) + count)
			return true
	var initial_count: int = mini(count, _config_int("inventoryStackMax", INVENTORY_STACK_MAX)) if bool(item.get("stackable", false)) else 1
	var new_stack: Dictionary = {"id": item_id, "count": initial_count}
	if not bool(item.get("stackable", false)):
		new_stack["enhancementLevel"] = maxi(1, enhancement_level if enhancement_level > 0 else int(_state.get("worldTier", 1)))
	inventory.append(new_stack)
	return true


func _remove_inventory(item_id: String, count: int) -> bool:
	var inventory: Array = _state.get("inventory", []) as Array
	for index: int in range(inventory.size()):
		if inventory[index] is not Dictionary or str((inventory[index] as Dictionary).get("id", "")) != item_id:
			continue
		var remaining: int = int((inventory[index] as Dictionary).get("count", 0)) - count
		if remaining <= 0:
			inventory.remove_at(index)
		else:
			(inventory[index] as Dictionary)["count"] = remaining
		return true
	return false


func _inventory_count(item_id: String) -> int:
	for raw_stack: Variant in _state.get("inventory", []) as Array:
		if raw_stack is Dictionary and str((raw_stack as Dictionary).get("id", "")) == item_id:
			return int((raw_stack as Dictionary).get("count", 0))
	return 0


func _review_season(completed_period: Dictionary) -> Dictionary:
	var counters: Dictionary = _state.get("seasonCounters", {}) as Dictionary
	var policy_fit: float = _calculate_policy_fit()
	var challenge_wins: int = int(counters.get("challengeWins", 0))
	var completed_contracts: int = int(counters.get("completedContracts", 0))
	var renown_gain: int = int(floor(
		_season_review_float("baseRenown", 20.0)
		+ float(challenge_wins) * _season_review_float("challengeWinRenown", 8.0)
		+ float(completed_contracts) * _season_review_float("completedContractRenown", 5.0)
		+ policy_fit * _season_review_float("policyFitRenown", 30.0)
	))
	_grant_renown(BigValue.from_number(renown_gain))
	var previous_tier: int = int(_state.get("worldTier", 1))
	_state["worldTier"] = _world_tier_from_renown((_state.get("bigValues", {}) as Dictionary).get("lifetimeRenown", BigValue.zero()) as Dictionary)
	var title_result: Dictionary = _evaluate_career_titles()
	# Title rewards are granted during evaluation and may cross another tier
	# boundary in the same review.
	_state["worldTier"] = _world_tier_from_renown((_state.get("bigValues", {}) as Dictionary).get("lifetimeRenown", BigValue.zero()) as Dictionary)
	var tier_up: bool = int(_state.get("worldTier", 1)) > previous_tier
	var flags: Dictionary = _state.get("flags", {}) as Dictionary
	flags["justWorldTierUp"] = tier_up
	flags["justCareerTitleGained"] = int(title_result.get("gained", 0)) > 0
	var review: Dictionary = {
		"year": int(completed_period.get("year", 1)),
		"season": int(completed_period.get("season", 1)),
		"endingSlot": int((_state.get("time", {}) as Dictionary).get("slot", 0)),
		"challengeWins": challenge_wins,
		"completedContracts": completed_contracts,
		"policyFit": snappedf(policy_fit, 0.001),
		"renownGained": renown_gain,
		"worldTierBefore": previous_tier,
		"worldTierAfter": int(_state.get("worldTier", 1)),
		"titles": title_result.get("awarded", []),
		"nearTitles": title_result.get("near", []),
	}
	var history: Array = _state.get("seasonHistory", []) as Array
	history.append(review)
	while history.size() > 256:
		history.pop_front()
	_record_contract_template_history()
	# Old contracts and their pin must not bias the first planner decision of the
	# new season. Select that task first, then generate contracts against it.
	_state["generatedContent"] = {"contracts": [], "rivals": [], "region": {}, "pinnedContractId": ""}
	_ensure_active_task()
	_state["generatedContent"] = _generator.generate(_state, _content_db)
	_state["seasonCounters"] = {"challengeWins": 0, "completedContracts": 0}
	return review


func _calculate_policy_fit() -> float:
	var actual: Dictionary = {}
	for raw_vector: Variant in _state.get("recentGrowthVectors", []) as Array:
		if raw_vector is not Dictionary:
			continue
		for raw_key: Variant in (raw_vector as Dictionary).keys():
			actual[str(raw_key)] = float(actual.get(str(raw_key), 0.0)) + maxf(0.0, float((raw_vector as Dictionary)[raw_key]))
	var weights: Dictionary = ((_state.get("growthPolicy", {}) as Dictionary).get("weights", {}) as Dictionary)
	var numerator: float = 0.0
	var actual_square: float = 0.0
	var weight_square: float = 0.0
	for key: String in GrowthPolicy.ALLOWED_WEIGHT_KEYS:
		if key == "gold":
			continue
		var actual_value: float = float(actual.get(key, 0.0))
		var weight_value: float = float(weights.get(key, 0.0))
		numerator += actual_value * weight_value
		actual_square += actual_value * actual_value
		weight_square += weight_value * weight_value
	if actual_square <= 0.0 or weight_square <= 0.0:
		return 0.0
	return clampf(numerator / (sqrt(actual_square) * sqrt(weight_square)), 0.0, 1.0)


func _evaluate_career_titles() -> Dictionary:
	var titles: Dictionary = _state.get("careerTitles", {}) as Dictionary
	var awarded: Array[Dictionary] = []
	var near: Array[Dictionary] = []
	for career: Dictionary in _content_db.careers:
		var career_id: String = str(career.get("id", ""))
		var owned: Dictionary = titles.get(career_id, {}) as Dictionary
		var stars: int = int(owned.get("stars", 0))
		var threshold_scale: float = pow(maxf(1.0, _season_review_float("careerGateStarGrowth", 1.35)), float(maxi(0, stars)))
		var gate_result: Dictionary = _career_gate_result(career.get("gate", {}) as Dictionary, threshold_scale)
		if bool(gate_result.get("met", false)):
			var next_stars: int = stars + 1
			var season_index: int = _current_season_index()
			var relation_variant: Dictionary = _career_relation_variant(str(career.get("name", career_id)))
			titles[career_id] = {
				"name": str(career.get("name", career_id)),
				"variant": str(relation_variant.get("id", "base")),
				"variantName": str(relation_variant.get("name", career.get("name", career_id))),
				"category": str(career.get("category", "")),
				"stars": next_stars,
				"firstSeason": int(owned.get("firstSeason", season_index)),
				"lastSeason": season_index,
			}
			var title_renown: Dictionary = BigValue.from_number(career.get("baseRenown", 0))
			_grant_renown(title_renown)
			awarded.append({
				"id": career_id,
				"name": str(relation_variant.get("name", career.get("name", career_id))),
				"variant": str(relation_variant.get("id", "base")),
				"stars": next_stars,
				"rank": career_rank_text(next_stars),
			})
		else:
			near.append({
				"id": career_id,
				"name": str(career.get("name", career_id)),
				"progress": float(gate_result.get("progress", 0.0)),
				"missing": gate_result.get("missing", []),
			})
	near.sort_custom(_compare_near_title)
	if near.size() > 3:
		near.resize(3)
	return {"gained": awarded.size(), "awarded": awarded, "near": near}


func _career_relation_variant(base_name: String) -> Dictionary:
	var threshold: float = maxf(0.0, _config_float("careerRelationVariantThreshold", 500.0))
	var labels: Dictionary = {
		"guardian": "후견의",
		"steward": "궁정의",
		"rival": "경쟁의",
		"citizens": "민중의",
	}
	var selected: String = ""
	var selected_value: float = threshold - 1.0
	var relations: Dictionary = _state.get("relations", {}) as Dictionary
	for raw_axis: Variant in labels.keys():
		var axis: String = str(raw_axis)
		var value: float = float(relations.get(axis, 0.0))
		if value > selected_value:
			selected = axis
			selected_value = value
	if selected.is_empty():
		return {"id": "base", "name": base_name}
	return {"id": selected, "name": "%s %s" % [str(labels[selected]), base_name], "relation": selected_value}


func _career_gate_result(gate: Dictionary, scale: float) -> Dictionary:
	var ratios: Array[float] = []
	var missing: Array[String] = []
	for bucket_name: String in ["stats", "meters", "relations", "mastery", "lifetimeStats"]:
		var requirements: Dictionary = gate.get(bucket_name, {}) as Dictionary
		var source: Dictionary = _state.get(bucket_name, {}) as Dictionary
		for raw_key: Variant in requirements.keys():
			var required: float = float(requirements[raw_key]) * scale
			var actual: float = float(source.get(str(raw_key), 0.0))
			var ratio: float = 1.0 if required <= 0.0 else clampf(actual / required, 0.0, 1.0)
			ratios.append(ratio)
			if actual < required:
				missing.append("%s %.1f/%.1f" % [_career_metric_display_name(bucket_name, str(raw_key)), actual, required])
	if gate.has("worldTier"):
		var required_tier: float = float(gate.get("worldTier", 1)) * scale
		var actual_tier: float = float(_state.get("worldTier", 1))
		ratios.append(clampf(actual_tier / maxf(1.0, required_tier), 0.0, 1.0))
		if actual_tier < required_tier:
			missing.append("세계 티어 %.0f/%.0f" % [actual_tier, required_tier])
	var big_requirements: Dictionary = gate.get("bigValues", {}) as Dictionary
	for raw_key: Variant in big_requirements.keys():
		var required_big: Dictionary = BigValue.multiply_float(BigValue.from_number(big_requirements[raw_key]), scale)
		var actual_big: Dictionary = ((_state.get("bigValues", {}) as Dictionary).get(str(raw_key), BigValue.zero()) as Dictionary)
		var ratio_big: float = clampf(BigValue.ratio_clamped(actual_big, required_big, 1.0), 0.0, 1.0)
		ratios.append(ratio_big)
		if ratio_big < 1.0:
			missing.append("%s %s/%s" % [_career_metric_display_name("bigValues", str(raw_key)), BigValue.format_short(actual_big), BigValue.format_short(required_big)])
	var progress: float = 0.0
	if not ratios.is_empty():
		for ratio: float in ratios:
			progress += ratio
		progress /= float(ratios.size())
	return {"met": missing.is_empty() and not ratios.is_empty(), "progress": progress, "missing": missing}


func _career_metric_display_name(bucket_name: String, key: String) -> String:
	if bucket_name == "stats":
		return _stat_display_name(key)
	if bucket_name == "mastery":
		var activity: Dictionary = _content_db.get_activity(key)
		return "%s 숙련" % str(activity.get("name", key))
	const DISPLAY_NAMES: Dictionary = {
		"energy": "에너지", "stress": "스트레스", "reputation": "평판", "integrityViolations": "규칙 위반",
		"guardian": "후견인 관계", "steward": "비서 관계", "rival": "라이벌 관계", "citizens": "시민 관계",
		"activities": "누적 활동", "challengeWins": "도전 승리", "contracts": "계약 완료", "adventures": "모험 클리어",
		"gold": "골드", "lifetimeGold": "누적 골드", "renown": "명성", "lifetimeRenown": "누적 명성",
	}
	return str(DISPLAY_NAMES.get(key, key))


func career_rank_text(stars: int) -> String:
	if stars <= 0:
		return "미획득"
	if stars <= 5:
		return "%d성" % stars
	return "명인 +%d" % (stars - 5)


func _compare_near_title(left: Dictionary, right: Dictionary) -> bool:
	var left_progress: float = float(left.get("progress", 0.0))
	var right_progress: float = float(right.get("progress", 0.0))
	if not is_equal_approx(left_progress, right_progress):
		return left_progress > right_progress
	return str(left.get("id", "")) < str(right.get("id", ""))


func _grant_renown(amount: Dictionary) -> void:
	if BigValue.is_zero(amount):
		return
	var big_values: Dictionary = _state.get("bigValues", {}) as Dictionary
	big_values["renown"] = BigValue.add(big_values.get("renown", BigValue.zero()) as Dictionary, amount)
	big_values["lifetimeRenown"] = BigValue.add(big_values.get("lifetimeRenown", BigValue.zero()) as Dictionary, amount)


func _world_tier_from_renown(lifetime_renown: Dictionary) -> int:
	if BigValue.is_zero(lifetime_renown):
		return 1
	var log_value: float = BigValue.log10_value(lifetime_renown)
	var renown_divisor: float = maxf(1.0, _config_float("worldTierRenownDivisor", 250.0))
	var log_two_value: float
	if log_value < 12.0:
		var native_value: float = BigValue.to_float(lifetime_renown, 1.0e12)
		log_two_value = log(1.0 + native_value / renown_divisor) / log(2.0)
	else:
		log_two_value = (log_value - log(renown_divisor) / log(10.0)) * log(10.0) / log(2.0)
	if is_nan(log_two_value) or is_inf(log_two_value):
		return maxi(1, int(_state.get("worldTier", 1)))
	return maxi(1, 1 + int(floor(log_two_value)))


func _record_contract_template_history() -> void:
	var history: Dictionary = _state.get("generatedHistory", {}) as Dictionary
	var recent: Array = history.get("recentContractTemplates", []) as Array
	for raw_contract: Variant in state_generated_content().get("contracts", []) as Array:
		if raw_contract is Dictionary:
			recent.append(str((raw_contract as Dictionary).get("templateId", "")))
	var recent_window := maxi(0, int(_content_db.procedural.get("recentTemplateWindow", 8)))
	while recent.size() > recent_window:
		recent.pop_front()


func _record_growth_vector(gains: Dictionary) -> void:
	var vectors: Array = _state.get("recentGrowthVectors", []) as Array
	vectors.append(gains.duplicate(true))
	while vectors.size() > _config_int("slotsPerSeason", SLOTS_PER_SEASON):
		vectors.pop_front()


func _update_calendar() -> void:
	var time: Dictionary = _state.get("time", {}) as Dictionary
	var total_slot: int = maxi(0, int(time.get("slot", 0)))
	var season_index_zero: int = total_slot / maxi(1, _config_int("slotsPerSeason", SLOTS_PER_SEASON))
	var seasons_per_year: int = maxi(1, _config_int("seasonsPerYear", SEASONS_PER_YEAR))
	time["season"] = season_index_zero % seasons_per_year + 1
	time["year"] = season_index_zero / seasons_per_year + 1


func _current_season_index() -> int:
	var time: Dictionary = _state.get("time", {}) as Dictionary
	return (int(time.get("year", 1)) - 1) * _config_int("seasonsPerYear", SEASONS_PER_YEAR) + int(time.get("season", 1))


func _build_result_summary(gains: Dictionary, reward: Dictionary, specialized: Dictionary) -> String:
	var parts: Array[String] = []
	var gain_keys: Array = gains.keys()
	gain_keys.sort()
	for raw_key: Variant in gain_keys:
		var value: float = float(gains[raw_key])
		if value != 0.0:
			parts.append("%s %+0.2f" % [_stat_display_name(str(raw_key)), value])
	if not BigValue.is_zero(reward):
		parts.append("골드 +%s" % BigValue.format_short(reward))
	if specialized.has("won"):
		parts.append("성공" if bool(specialized.get("won", false)) else "도전 경험 30%")
	if parts.is_empty():
		parts.append("일정을 안전하게 마쳤습니다")
	return " · ".join(parts)


func state_generated_content() -> Dictionary:
	return _state.get("generatedContent", {}) as Dictionary


func state_hash() -> String:
	_ensure_initialized()
	return SaveCodec.encode(_state).sha256_text()


func validate_state() -> Dictionary:
	_ensure_initialized()
	var errors: Array[String] = []
	_validate_finite_recursive(_state, "state", errors)
	var meters: Dictionary = _state.get("meters", {}) as Dictionary
	if float(meters.get("energy", -1.0)) < 0.0 or float(meters.get("energy", 101.0)) > 100.0:
		errors.append("energy 범위 오류")
	if float(meters.get("stress", -1.0)) < 0.0 or float(meters.get("stress", 101.0)) > 100.0:
		errors.append("stress 범위 오류")
	for key: String in ["gold", "lifetimeGold", "renown", "lifetimeRenown"]:
		if not BigValue.is_valid(((_state.get("bigValues", {}) as Dictionary).get(key, BigValue.zero()) as Dictionary)):
			errors.append("BigValue 형식 오류: %s" % key)
	return {"ok": errors.is_empty(), "errors": errors}


func _validate_finite_recursive(value: Variant, path: String, errors: Array[String]) -> void:
	if value is float:
		if is_nan(float(value)) or is_inf(float(value)):
			errors.append("유효하지 않은 수: %s" % path)
	elif value is Dictionary:
		for key: Variant in (value as Dictionary).keys():
			_validate_finite_recursive((value as Dictionary)[key], "%s.%s" % [path, str(key)], errors)
	elif value is Array:
		for index: int in range((value as Array).size()):
			_validate_finite_recursive((value as Array)[index], "%s[%d]" % [path, index], errors)


func _state_numeric(key: String) -> float:
	if (_state.get("stats", {}) as Dictionary).has(key):
		return float((_state.get("stats", {}) as Dictionary).get(key, 0.0))
	if (_state.get("meters", {}) as Dictionary).has(key):
		return float((_state.get("meters", {}) as Dictionary).get(key, 0.0))
	if (_state.get("relations", {}) as Dictionary).has(key):
		return float((_state.get("relations", {}) as Dictionary).get(key, 0.0))
	return 0.0


func _append_warning(code: String, message: String) -> void:
	var warnings: Array = _state.get("warnings", []) as Array
	warnings.append({"code": code, "message": message, "slot": int((_state.get("time", {}) as Dictionary).get("slot", 0))})
	while warnings.size() > 20:
		warnings.pop_front()


func _config_int(key: String, fallback: int) -> int:
	var constants: Dictionary = _content_db.config.get("constants", _content_db.config) as Dictionary
	return int(constants.get(key, fallback))


func _config_float(key: String, fallback: float) -> float:
	var constants: Dictionary = _content_db.config.get("constants", _content_db.config) as Dictionary
	return float(constants.get(key, fallback))


func _season_review_float(key: String, fallback: float) -> float:
	var review: Dictionary = _content_db.config.get("seasonReview", {}) as Dictionary
	return float(review.get(key, fallback))


func _ensure_initialized() -> void:
	if not _initialized:
		initialize(1)


func _with_state(metadata: Dictionary) -> Dictionary:
	var snapshot: Dictionary = get_state()
	for key: Variant in metadata.keys():
		snapshot[key] = metadata[key]
	# Explicit nested state keeps the reducer result convenient for tests and
	# non-UI callers, while top-level state keys support legacy UI adapters.
	snapshot["state"] = get_state()
	return snapshot
