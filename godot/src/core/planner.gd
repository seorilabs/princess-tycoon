class_name Planner
extends RefCounted

const SCORE_EPSILON: float = 0.000000001

var _config: Dictionary = {}
var _profile_tags: Dictionary = {}
var _activities: Array[Dictionary] = []


func configure(config_data: Dictionary, profiles: Array[Dictionary] = [], activities: Array[Dictionary] = []) -> void:
	_config = config_data.duplicate(true)
	_activities = activities.duplicate(true)
	_profile_tags.clear()
	for profile: Dictionary in profiles:
		_profile_tags[str(profile.get("id", ""))] = (profile.get("preferredTags", []) as Array).duplicate(true)


func preferred_tags_for_preset(preset_id: String) -> Array:
	return (_profile_tags.get(preset_id, []) as Array).duplicate(true)


func mastery_milestone_count(mastery_value: float) -> int:
	var level: int = maxi(0, int(floor(mastery_value)))
	var configured: Array = _config.get("activityMasteryMilestones", [10, 25, 50, 100]) as Array
	var milestones: Array[int] = []
	for raw_threshold: Variant in configured:
		var threshold: int = maxi(1, int(raw_threshold))
		if not milestones.has(threshold):
			milestones.append(threshold)
	milestones.sort()
	var count: int = 0
	var last_fixed: int = 0
	for threshold: int in milestones:
		last_fixed = maxi(last_fixed, threshold)
		if level >= threshold:
			count += 1
	var repeat_interval: int = maxi(0, int(_config.get("repeatMasteryMilestoneInterval", 100)))
	if repeat_interval > 0 and last_fixed > 0 and level > last_fixed:
		count += int(floor(float(level - last_fixed) / float(repeat_interval)))
	return count


func mastery_modifier(mastery_value: float) -> float:
	var safe_mastery: float = maxf(0.0, mastery_value)
	var base_rate: float = maxf(0.0, float(_config.get("activityMasteryBaseSqrtRate", 0.02)))
	var milestone_rate: float = maxf(0.0, float(_config.get("activityMasteryMilestoneBonusPerStep", 0.03)))
	return 1.0 + base_rate * sqrt(safe_mastery) + milestone_rate * float(mastery_milestone_count(safe_mastery))


func relation_modifier(state: Dictionary, activity: Dictionary) -> float:
	var relation_key: String = "guardian"
	match str(activity.get("kind", "")):
		"education":
			relation_key = "steward"
		"job":
			relation_key = "citizens"
		"adventure":
			relation_key = "steward"
		"challenge":
			relation_key = "rival"
	var relation_value: float = clampf(float((state.get("relations", {}) as Dictionary).get(relation_key, 0.0)), 0.0, 1000.0)
	var rate: float = maxf(0.0, float(_config.get("relationActivityBonusPerPoint", 0.0002)))
	var maximum: float = maxf(1.0, float(_config.get("relationActivityBonusMaximum", 1.2)))
	return minf(maximum, 1.0 + rate * relation_value)


func contract_activity_matches(contract: Dictionary, activity: Dictionary) -> bool:
	var contract_kind: String = str(contract.get("kind", "complete_kind"))
	if contract_kind == "balanced_cycle":
		return true
	if contract_kind == "gain_stat":
		var target_stat: String = str(contract.get("targetStat", ""))
		return not target_stat.is_empty() and (activity.get("gains", {}) as Dictionary).has(target_stat)
	var target_ids: Array = contract.get("targetActivityIds", []) as Array
	if not target_ids.is_empty():
		return target_ids.has(str(activity.get("id", "")))
	var required_tag: String = str(contract.get("requiredTag", ""))
	if not required_tag.is_empty():
		return (activity.get("tags", []) as Array).has(required_tag)
	var target_kind: String = str(contract.get("targetKind", ""))
	return target_kind.is_empty() or target_kind == str(activity.get("kind", ""))


func choose(state: Dictionary, activities: Array[Dictionary]) -> Dictionary:
	var policy: Dictionary = GrowthPolicy.sanitize(state.get("growthPolicy", {}) as Dictionary)
	var recovery_forced: bool = bool(state.get("forceRest", false))
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	recovery_forced = recovery_forced or float(meters.get("energy", 100.0)) < float(_config.get("forcedRecoveryEnergyThreshold", 20.0))
	recovery_forced = recovery_forced or float(meters.get("stress", 0.0)) >= float(policy.get("maxStress", 72.0))
	var candidates: Array[Dictionary] = []
	var rejected: Dictionary = {}
	for activity: Dictionary in activities:
		var rejection: String = _hard_rejection(state, policy, activity, recovery_forced)
		if not rejection.is_empty():
			rejected[str(activity.get("id", ""))] = rejection
			continue
		candidates.append(_score_candidate(state, policy, activity))
	if candidates.is_empty():
		var fallback: Dictionary = _find_activity(activities, "REST_HOME")
		return {
			"activity": fallback,
			"activityId": "REST_HOME",
			"score": -999999.0,
			"reasons": ["가능한 활동이 없어 기본 휴식을 선택"],
			"ranked": [],
			"rejected": rejected,
			"forcedRecovery": recovery_forced,
		}
	candidates.sort_custom(_compare_scored.bind(state))
	var selected: Dictionary = candidates[0]
	var ranked: Array[Dictionary] = []
	for index: int in range(mini(3, candidates.size())):
		var entry: Dictionary = candidates[index]
		ranked.append({
			"activityId": str(entry.get("activityId", "")),
			"score": float(entry.get("score", 0.0)),
			"reasons": (entry.get("reasons", []) as Array).duplicate(true),
		})
	return {
		"activity": (selected["activity"] as Dictionary).duplicate(true),
		"activityId": str(selected["activityId"]),
		"score": float(selected["score"]),
		"masteryModifier": float(selected.get("masteryModifier", 1.0)),
		"relationModifier": float(selected.get("relationModifier", 1.0)),
		"preferredTagBonus": float(selected.get("preferredTagBonus", 0.0)),
		"reasons": (selected["reasons"] as Array).duplicate(true),
		"ranked": ranked,
		"rejected": rejected,
		"forcedRecovery": recovery_forced,
	}


func is_allowed(state: Dictionary, activity: Dictionary) -> bool:
	return rejection_reason(state, activity).is_empty()


func rejection_reason(state: Dictionary, activity: Dictionary) -> String:
	var policy: Dictionary = GrowthPolicy.sanitize(state.get("growthPolicy", {}) as Dictionary)
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var recovery_forced: bool = bool(state.get("forceRest", false))
	recovery_forced = recovery_forced or float(meters.get("energy", 100.0)) < float(_config.get("forcedRecoveryEnergyThreshold", 20.0))
	recovery_forced = recovery_forced or float(meters.get("stress", 0.0)) >= float(policy.get("maxStress", 72.0))
	return _hard_rejection(state, policy, activity, recovery_forced)


func tier_cost(activity: Dictionary, world_tier: int) -> Dictionary:
	var base_cost: Dictionary = BigValue.from_number(activity.get("baseCost", 0))
	var growth_base: float = maxf(1.0, float(_config.get("activityCostTierGrowth", 1.11)))
	return BigValue.multiply(base_cost, BigValue.pow_base(growth_base, maxi(0, world_tier - 1)))


func tier_reward(activity: Dictionary, world_tier: int, performance_mod: float = 1.0) -> Dictionary:
	var base_reward: Dictionary = BigValue.from_number(activity.get("baseReward", 0))
	var growth_base: float = maxf(1.0, float(_config.get("activityRewardTierGrowth", 1.13)))
	var scaled: Dictionary = BigValue.multiply(base_reward, BigValue.pow_base(growth_base, maxi(0, world_tier - 1)))
	return BigValue.multiply_float(scaled, maxf(0.0, performance_mod))


func requirements_met(state: Dictionary, requires: Dictionary) -> bool:
	if requires.is_empty():
		return true
	var gte: Dictionary = requires.get("gte", {}) as Dictionary
	for key: Variant in gte.keys():
		if _state_metric(state, str(key)) < float(gte[key]):
			return false
	var lte: Dictionary = requires.get("lte", {}) as Dictionary
	for key: Variant in lte.keys():
		if _state_metric(state, str(key)) > float(lte[key]):
			return false
	var world_requirement: Variant = requires.get("worldTier", 0)
	if world_requirement is Dictionary:
		if int(state.get("worldTier", 1)) < int((world_requirement as Dictionary).get("gte", 0)):
			return false
		if (world_requirement as Dictionary).has("lte") and int(state.get("worldTier", 1)) > int((world_requirement as Dictionary)["lte"]):
			return false
	elif int(world_requirement) > 0 and int(state.get("worldTier", 1)) < int(world_requirement):
		return false
	var season_requirement: Variant = requires.get("season", 0)
	var season: int = int((state.get("time", {}) as Dictionary).get("season", 1))
	if season_requirement is Dictionary:
		if season < int((season_requirement as Dictionary).get("gte", 0)):
			return false
		if (season_requirement as Dictionary).has("lte") and season > int((season_requirement as Dictionary)["lte"]):
			return false
	elif int(season_requirement) > 0 and season < int(season_requirement):
		return false
	var flag_requirement: Variant = requires.get("flags", {})
	var flags: Dictionary = state.get("flags", {}) as Dictionary
	if flag_requirement is Array:
		for flag: Variant in flag_requirement as Array:
			if not bool(flags.get(str(flag), false)):
				return false
	elif flag_requirement is Dictionary:
		for flag: Variant in (flag_requirement as Dictionary).keys():
			if flags.get(str(flag)) != (flag_requirement as Dictionary)[flag]:
				return false
	return true


func _hard_rejection(state: Dictionary, policy: Dictionary, activity: Dictionary, recovery_forced: bool) -> String:
	if not requirements_met(state, activity.get("requires", {}) as Dictionary):
		return "잠금 조건 미충족"
	var activity_kind: String = str(activity.get("kind", ""))
	var scheduled_now: bool = false
	if activity_kind == "challenge":
		var schedule: Dictionary = _config.get("challengeScheduleSlots", {}) as Dictionary
		var activity_id: String = str(activity.get("id", ""))
		if schedule.has(activity_id):
			var scheduled_slot: int = maxi(1, int(schedule[activity_id]))
			var slots_per_season: int = maxi(1, int(_config.get("slotsPerSeason", 28)))
			var next_slot_in_season: int = int(state.get("time", {}).get("slot", 0)) % slots_per_season + 1
			if next_slot_in_season != scheduled_slot:
				return "시즌 일정 잠금: %d번 슬롯 참가" % scheduled_slot
			scheduled_now = true
	else:
		var next_schedule: Dictionary = _next_unlocked_challenge_schedule(state)
		if not next_schedule.is_empty():
			var duration: int = maxi(1, int(activity.get("durationSlots", 1)))
			if int(next_schedule.get("distance", duration)) < duration:
				return "예정 도전 우선: %d번 슬롯" % int(next_schedule.get("slot", -1))
	var banned_tags: Array = policy.get("bannedTags", []) as Array
	if not scheduled_now:
		for tag: Variant in activity.get("tags", []) as Array:
			if banned_tags.has(str(tag)):
				return "성장 정책에서 제외한 특성이 포함된 활동"
	if recovery_forced and not _is_recovery(activity) and not scheduled_now:
		return "회복 활동 강제"
	var cost: Dictionary = tier_cost(activity, int(state.get("worldTier", 1)))
	if not BigValue.is_zero(cost) and not scheduled_now:
		var gold: Dictionary = ((state.get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary)
		if BigValue.compare(gold, cost) < 0:
			return "비용 지불 불가"
		var remaining: Dictionary = BigValue.subtract(gold, cost)
		var reserve: Dictionary = policy.get("reserveGold", BigValue.zero()) as Dictionary
		if BigValue.compare(remaining, reserve) < 0:
			return "최소 보유금 위반"
	return ""


func _next_unlocked_challenge_schedule(state: Dictionary) -> Dictionary:
	if _activities.is_empty():
		return {}
	var schedule: Dictionary = _config.get("challengeScheduleSlots", {}) as Dictionary
	var slots_per_season: int = maxi(1, int(_config.get("slotsPerSeason", 28)))
	var total_slot: int = maxi(0, int((state.get("time", {}) as Dictionary).get("slot", 0)))
	var next_absolute_slot: int = total_slot + 1
	var current_season_base: int = total_slot / slots_per_season * slots_per_season
	var selected_distance: int = 2147483647
	var selected_slot: int = -1
	for activity: Dictionary in _activities:
		var activity_id: String = str(activity.get("id", ""))
		if str(activity.get("kind", "")) != "challenge" or not schedule.has(activity_id):
			continue
		if not requirements_met(state, activity.get("requires", {}) as Dictionary):
			continue
		var scheduled_slot: int = int(schedule[activity_id])
		var scheduled_absolute: int = current_season_base + scheduled_slot
		if scheduled_absolute < next_absolute_slot:
			scheduled_absolute += slots_per_season
		var distance: int = scheduled_absolute - next_absolute_slot
		if distance < selected_distance:
			selected_distance = distance
			selected_slot = scheduled_slot
	return {} if selected_slot < 0 else {"slot": selected_slot, "distance": selected_distance}


func _score_candidate(state: Dictionary, policy: Dictionary, activity: Dictionary) -> Dictionary:
	var weights: Dictionary = policy.get("weights", {}) as Dictionary
	var stats: Dictionary = state.get("stats", {}) as Dictionary
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var mastery: Dictionary = state.get("mastery", {}) as Dictionary
	var tier: int = maxi(1, int(state.get("worldTier", 1)))
	var activity_mastery: float = maxf(0.0, float(mastery.get(str(activity.get("id", "")), 0.0)))
	var condition_mod: float = clampf(
		1.0 - float(meters.get("stress", 0.0)) / maxf(1.0, float(_config.get("growthConditionStressDivisor", 160.0))),
		float(_config.get("growthConditionStressMinimum", 0.40)),
		float(_config.get("growthConditionStressMaximum", 1.00))
	)
	condition_mod *= clampf(
		float(_config.get("growthConditionEnergyBase", 0.60)) + float(meters.get("energy", 100.0)) / maxf(1.0, float(_config.get("growthConditionEnergyDivisor", 100.0))),
		float(_config.get("growthConditionEnergyMinimum", 0.60)),
		float(_config.get("growthConditionEnergyMaximum", 1.60))
	)
	var mastery_mod: float = mastery_modifier(activity_mastery)
	var relation_mod: float = relation_modifier(state, activity)
	var tier_mod: float = 1.0 + maxf(0.0, float(_config.get("growthTierSqrtRate", 0.04))) * sqrt(float(tier - 1))
	var stat_value: float = 0.0
	for raw_key: Variant in (activity.get("gains", {}) as Dictionary).keys():
		var stat_key: String = str(raw_key)
		var current_stat: float = maxf(0.0, float(stats.get(stat_key, meters.get(stat_key, 0.0))))
		var focus_mod: float = float(_config.get("growthFocusBase", 0.85)) + float(_config.get("growthFocusWeightScale", 0.50)) * float(weights.get(stat_key, 0.0))
		var diminish_denominator := maxf(1.0, float(_config.get("growthDiminishStatBase", 600.0)) + float(_config.get("growthDiminishWorldTierScale", 80.0)) * float(tier))
		var diminish_mod: float = float(_config.get("growthDiminishBase", 0.35)) + float(_config.get("growthDiminishScale", 0.65)) / (1.0 + current_stat / diminish_denominator)
		var expected_gain: float = float((activity.get("gains", {}) as Dictionary)[raw_key]) * focus_mod * condition_mod * mastery_mod * relation_mod * diminish_mod * tier_mod
		stat_value += float(weights.get(stat_key, 0.0)) * expected_gain / (1.0 + sqrt(current_stat / maxf(1.0, float(_config.get("plannerStatDiminishScale", 100.0)))))
	var cost: Dictionary = tier_cost(activity, tier)
	var reward: Dictionary = tier_reward(activity, tier)
	var net_reward: Dictionary = BigValue.subtract(reward, cost)
	var reserve: Dictionary = policy.get("reserveGold", BigValue.from_number(300)) as Dictionary
	var denominator: Dictionary = reserve
	var minimum_denominator := BigValue.from_number(maxf(1.0, float(_config.get("plannerGoldMinimumDenominator", 100.0))))
	if BigValue.compare(denominator, minimum_denominator) < 0:
		denominator = minimum_denominator
	var gold_value: float = BigValue.ratio_clamped(net_reward, denominator, maxf(1.0, float(_config.get("plannerGoldRatioClamp", 1000.0)))) * float(weights.get("gold", 0.0)) * maxf(0.0, float(_config.get("plannerGoldValueScale", 25.0)))
	var quest_bonus: float = maxf(0.0, float(_config.get("plannerQuestBonus", 0.18))) if _advances_pinned_contract(state, activity) else 0.0
	var preferred_tags: Array = policy.get("preferredTags", []) as Array
	if preferred_tags.is_empty():
		preferred_tags = preferred_tags_for_preset(str(policy.get("preset", "balanced")))
	var preferred_tag_matches: int = 0
	for raw_tag: Variant in activity.get("tags", []) as Array:
		if preferred_tags.has(str(raw_tag)):
			preferred_tag_matches += 1
	var preferred_tag_bonus: float = minf(
		maxf(0.0, float(_config.get("plannerPreferredTagBonusMaximum", 0.12))),
		float(preferred_tag_matches) * maxf(0.0, float(_config.get("plannerPreferredTagBonusPerMatch", 0.04)))
	)
	var same_count: int = 0
	for recent_id: Variant in state.get("recentActivities", []) as Array:
		if str(recent_id) == str(activity.get("id", "")):
			same_count += 1
	var novelty_bonus: float = maxf(0.0, float(_config.get("plannerNoveltyBonus", 0.08))) / (1.0 + float(same_count))
	var risk_penalty: float = float(activity.get("risk", 0.0)) * (1.0 - float(policy.get("riskTolerance", 0.35))) * maxf(0.0, float(_config.get("plannerRiskPenaltyScale", 0.75)))
	var stress_after: float = float(meters.get("stress", 0.0)) + float(activity.get("stressDelta", 0.0))
	var stress_penalty: float = maxf(0.0, stress_after - float(policy.get("maxStress", 72.0))) / maxf(0.01, float(_config.get("plannerStressPenaltyDivisor", 20.0)))
	var score: float = stat_value + gold_value + quest_bonus + preferred_tag_bonus + novelty_bonus - risk_penalty - stress_penalty
	if is_nan(score) or is_inf(score):
		score = -999999.0
	var contributions: Array[Dictionary] = [
		{"label": "성장 방향", "value": stat_value},
		{"label": "재화 효율", "value": gold_value},
		{"label": "고정 계약", "value": quest_bonus},
		{"label": "프리셋 선호", "value": preferred_tag_bonus},
		{"label": "활동 다양성", "value": novelty_bonus},
		{"label": "위험 부담", "value": -risk_penalty},
		{"label": "스트레스 초과", "value": -stress_penalty},
	]
	contributions.sort_custom(_compare_contribution)
	var reasons: Array[String] = []
	for index: int in range(mini(3, contributions.size())):
		var contribution: Dictionary = contributions[index]
		reasons.append("%s %+.3f" % [str(contribution["label"]), float(contribution["value"])])
	return {
		"activity": activity,
		"activityId": str(activity.get("id", "")),
		"score": score,
		"masteryModifier": mastery_mod,
		"relationModifier": relation_mod,
		"preferredTagBonus": preferred_tag_bonus,
		"reasons": reasons,
	}


func _compare_scored(left: Dictionary, right: Dictionary, state: Dictionary) -> bool:
	var left_score: float = float(left.get("score", 0.0))
	var right_score: float = float(right.get("score", 0.0))
	if absf(left_score - right_score) > SCORE_EPSILON:
		return left_score > right_score
	var seed_value: int = int(state.get("seed", 1))
	var counter: int = int(state.get("rngCounter", 0))
	var left_hash: int = DeterministicRNG.stable_hash(seed_value, counter, str(left.get("activityId", "")))
	var right_hash: int = DeterministicRNG.stable_hash(seed_value, counter, str(right.get("activityId", "")))
	return left_hash < right_hash


func _compare_contribution(left: Dictionary, right: Dictionary) -> bool:
	var left_abs: float = absf(float(left.get("value", 0.0)))
	var right_abs: float = absf(float(right.get("value", 0.0)))
	if not is_equal_approx(left_abs, right_abs):
		return left_abs > right_abs
	return str(left.get("label", "")) < str(right.get("label", ""))


func _is_recovery(activity: Dictionary) -> bool:
	return str(activity.get("kind", "")) == "rest" and (float(activity.get("energyDelta", 0.0)) > 0.0 or float(activity.get("stressDelta", 0.0)) < 0.0)


func _advances_pinned_contract(state: Dictionary, activity: Dictionary) -> bool:
	var generated: Dictionary = state.get("generatedContent", {}) as Dictionary
	var pinned_id: String = str(generated.get("pinnedContractId", state.get("pinnedContractId", "")))
	if pinned_id.is_empty():
		return false
	for contract: Variant in generated.get("contracts", []) as Array:
		if contract is not Dictionary or str((contract as Dictionary).get("id", "")) != pinned_id:
			continue
		return contract_activity_matches(contract as Dictionary, activity)
	return false


func _state_metric(state: Dictionary, key: String) -> float:
	if (state.get("stats", {}) as Dictionary).has(key):
		return float((state.get("stats", {}) as Dictionary).get(key, 0.0))
	if (state.get("meters", {}) as Dictionary).has(key):
		return float((state.get("meters", {}) as Dictionary).get(key, 0.0))
	if (state.get("mastery", {}) as Dictionary).has(key):
		return float((state.get("mastery", {}) as Dictionary).get(key, 0.0))
	if key == "worldTier":
		return float(state.get("worldTier", 1))
	if (state.get("lifetimeStats", {}) as Dictionary).has(key):
		return float((state.get("lifetimeStats", {}) as Dictionary).get(key, 0.0))
	return 0.0


func _find_activity(activities: Array[Dictionary], activity_id: String) -> Dictionary:
	for activity: Dictionary in activities:
		if str(activity.get("id", "")) == activity_id:
			return activity.duplicate(true)
	return {}
