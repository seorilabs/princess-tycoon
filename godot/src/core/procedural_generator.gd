class_name ProceduralGenerator
extends RefCounted

const FALLBACK_PREFIXES: Array[String] = [
	"새벽의", "황금빛", "고요한", "용감한", "별을 좇는", "푸른", "찬란한",
	"지혜로운", "성실한", "경계를 넘는", "서약의", "미지의",
]
const FALLBACK_FIELDS: Array[String] = ["무예", "학문", "예술", "돌봄", "탐험", "외교", "생활", "마법"]
const FALLBACK_GOALS: Array[String] = ["수련", "의뢰", "도전", "순례", "연구", "봉사", "개척", "경연", "시험", "축제"]
const FALLBACK_MODIFIERS: Array[String] = ["low_energy", "high_quality", "no_repeat", "risk_bonus", "budget", "mastery", "timed", "balanced"]
const FALLBACK_RIVAL_NAMES: Array[String] = ["아린", "베라", "세온", "다나", "리오", "미라", "유진", "카엘", "노아", "루미"]
const FALLBACK_TRAITS: Array[String] = ["신중함", "대담함", "분석적", "사교적", "끈기", "즉흥적", "원칙적", "호기심"]
const FALLBACK_REGIONS: Array[String] = ["유리숲", "별빛 동굴", "바람 유적", "잿빛 봉우리", "공명 균열"]
const FALLBACK_TEMPLATES: Array[Dictionary] = [
	{"id": "complete_kind", "kind": "complete_kind", "baseReward": 420, "weight": 1.0},
	{"id": "master_activity", "kind": "master_activity", "baseReward": 480, "weight": 1.0},
	{"id": "gain_stat", "kind": "gain_stat", "baseReward": 520, "weight": 1.0},
	{"id": "win_challenge", "kind": "win_challenge", "requiredKind": "challenge", "baseReward": 680, "weight": 0.8},
	{"id": "clear_adventure", "kind": "clear_adventure", "requiredKind": "adventure", "baseReward": 720, "weight": 0.8},
	{"id": "earn_gold", "kind": "earn_gold", "baseReward": 560, "weight": 1.0},
]

var _challenge_feasibility_active: bool = false
var _challenge_feasibility: Dictionary = {}


func generate(state: Dictionary, content_db: ContentDB) -> Dictionary:
	var tier: int = maxi(1, int(state.get("worldTier", 1)))
	var time: Dictionary = state.get("time", {}) as Dictionary
	var seasons_per_year: int = maxi(1, int(content_db.config.get("seasonsPerYear", 4)))
	var season_index: int = (int(time.get("year", 1)) - 1) * seasons_per_year + int(time.get("season", 1))
	var slots_per_season: int = maxi(1, int(content_db.config.get("slotsPerSeason", 28)))
	var next_slot_in_season: int = int(time.get("slot", 0)) % slots_per_season + 1
	var base_seed: int = int(state.get("seed", 1))
	var unlocked: Array[Dictionary] = _unlocked_activities(state, content_db.activities)
	var recent_templates: Array = ((state.get("generatedHistory", {}) as Dictionary).get("recentContractTemplates", []) as Array)

	# Each family uses its own derived seed, so projecting rivals first does not
	# consume or perturb contract RNG. Contracts can then reject scheduled win
	# targets whose exact slot-isolated score cannot beat their real opponent.
	var rivals: Array[Dictionary] = _generate_rivals(base_seed, tier, season_index, state, content_db.procedural, content_db.config, content_db)
	_challenge_feasibility = _challenge_score_feasibility(state, unlocked, rivals, content_db, content_db.config)
	_challenge_feasibility_active = true
	var contracts: Array[Dictionary] = _generate_contracts(base_seed, tier, season_index, next_slot_in_season, unlocked, content_db.procedural, content_db.config, recent_templates, state)
	_challenge_feasibility_active = false
	_challenge_feasibility = {}
	var region: Dictionary = _generate_region(base_seed, tier, season_index, unlocked, content_db.procedural, content_db.config)
	var previous_pin: String = str((state.get("generatedContent", {}) as Dictionary).get("pinnedContractId", ""))
	var valid_pin: String = previous_pin if _result_has_contract_id(contracts, previous_pin) else ""
	return {
		"contracts": contracts,
		"rivals": rivals,
		"region": region,
		"generatedFor": {"seed": base_seed, "worldTier": tier, "seasonIndex": season_index},
		"pinnedContractId": valid_pin,
	}


func generate_region_for_activity(state: Dictionary, content_db: ContentDB, activity_id: String) -> Dictionary:
	var activity: Dictionary = content_db.get_activity(activity_id)
	if activity.is_empty() or str(activity.get("kind", "")) != "adventure":
		return {}
	var planner: Planner = Planner.new()
	if not planner.requirements_met(state, activity.get("requires", {}) as Dictionary):
		return {}
	var tier: int = maxi(1, int(state.get("worldTier", 1)))
	var time: Dictionary = state.get("time", {}) as Dictionary
	var seasons_per_year: int = maxi(1, int(content_db.config.get("seasonsPerYear", 4)))
	var season_index: int = (int(time.get("year", 1)) - 1) * seasons_per_year + int(time.get("season", 1))
	return _generate_region(
		int(state.get("seed", 1)),
		tier,
		season_index,
		_unlocked_activities(state, content_db.activities),
		content_db.procedural,
		content_db.config,
		activity_id
	)


func _generate_contracts(
	base_seed: int,
	tier: int,
	season_index: int,
	next_slot_in_season: int,
	unlocked: Array[Dictionary],
	procedural_data: Dictionary,
	config_data: Dictionary,
	recent_templates: Array,
	state: Dictionary
) -> Array[Dictionary]:
	var local_state: Dictionary = {
		"seed": DeterministicRNG.derive_seed(base_seed, tier, season_index, "contracts"),
		"rngCounter": 0,
	}
	var templates: Array[Dictionary] = _dictionary_array(procedural_data.get("contractTemplates", FALLBACK_TEMPLATES))
	if templates.is_empty():
		templates = FALLBACK_TEMPLATES.duplicate(true)
	var satisfiable: Array[Dictionary] = []
	for template: Dictionary in templates:
		var remaining_attempts: int = _remaining_scheduled_challenge_attempts(unlocked, config_data, next_slot_in_season)
		var template_kind: String = str(template.get("kind", template.get("id", "")))
		var relation_ready: bool = template_kind != "relation_gain" or not _activities_with_tag(_activities_of_kind(unlocked, "job"), "service").is_empty()
		var reachable_targets := _eligible_contract_targets(template, unlocked, config_data, next_slot_in_season, state)
		if _template_satisfiable(template, unlocked) and relation_ready and not reachable_targets.is_empty() and (template_kind != "win_challenge" or remaining_attempts > 0):
			satisfiable.append(template)
	if satisfiable.is_empty():
		# A one-kind balanced contract progresses on the next resolved activity and
		# is the only universal fallback that does not invent a specific unavailable
		# target activity.
		if int(_balanced_completion_plan(state, unlocked, config_data, next_slot_in_season).get("kindCount", 0)) <= 0:
			return []
		satisfiable = [{"id": "balanced_fallback", "kind": "balanced_cycle", "baseTarget": 1, "baseReward": 240, "weight": 1.0}]
	var result: Array[Dictionary] = []
	var contract_count: int = maxi(1, int(config_data.get("generatedContractCount", 3)))
	var recent_weight_multiplier: float = clampf(float(procedural_data.get("recentTemplateWeightMultiplier", 0.2)), 0.0, 1.0)
	for contract_index: int in range(contract_count):
		var weights: Array[float] = []
		for template: Dictionary in satisfiable:
			var weight: float = maxf(0.01, float(template.get("weight", 1.0)))
			if recent_templates.has(str(template.get("id", ""))):
				weight *= recent_weight_multiplier
			if _result_has_template(result, str(template.get("id", ""))):
				weight *= recent_weight_multiplier
			weights.append(weight)
		var chosen_index: int = DeterministicRNG.weighted_index(local_state, weights, "contract_template_%d" % contract_index)
		var chosen: Dictionary = satisfiable[chosen_index]
		result.append(_build_contract(chosen, contract_index, tier, season_index, next_slot_in_season, unlocked, procedural_data, config_data, local_state, state))
	return result


func _build_contract(
	template: Dictionary,
	contract_index: int,
	tier: int,
	season_index: int,
	next_slot_in_season: int,
	unlocked: Array[Dictionary],
	procedural_data: Dictionary,
	config_data: Dictionary,
	local_state: Dictionary,
	state: Dictionary
) -> Dictionary:
	var prefixes: Array[String] = _string_array(procedural_data.get("prefixes", FALLBACK_PREFIXES), FALLBACK_PREFIXES)
	var fields: Array[String] = _string_array(procedural_data.get("fields", FALLBACK_FIELDS), FALLBACK_FIELDS)
	var goals: Array[String] = _string_array(procedural_data.get("goals", FALLBACK_GOALS), FALLBACK_GOALS)
	var modifiers_pool: Array[String] = _string_array(procedural_data.get("modifiers", FALLBACK_MODIFIERS), FALLBACK_MODIFIERS)
	var prefix: String = prefixes[DeterministicRNG.range_int(local_state, 0, prefixes.size() - 1, "prefix")]
	var field: String = fields[DeterministicRNG.range_int(local_state, 0, fields.size() - 1, "field")]
	var goal: String = goals[DeterministicRNG.range_int(local_state, 0, goals.size() - 1, "goal")]
	var template_kind: String = str(template.get("kind", template.get("id", "complete_kind")))
	var required_kind: String = str(template.get("requiredKind", ""))
	var eligible: Array[Dictionary] = _eligible_contract_targets(template, unlocked, config_data, next_slot_in_season, state)
	if eligible.is_empty():
		eligible = _activities_reachable_before_expiry(unlocked, config_data, next_slot_in_season)
	var target: Dictionary = eligible[DeterministicRNG.range_int(local_state, 0, eligible.size() - 1, "target")]
	var base_target: int = maxi(1, int(template.get("baseTarget", 3)))
	var target_count: int = base_target + mini(17, int(floor(sqrt(float(tier))))) + contract_index
	var slots_per_season: int = maxi(1, int(config_data.get("slotsPerSeason", 28)))
	var remaining_slots: int = maxi(1, slots_per_season - next_slot_in_season + 1)
	var target_duration: int = maxi(1, int(target.get("durationSlots", 1)))
	var completion_plan := _balanced_completion_plan(state, unlocked, config_data, next_slot_in_season) if template_kind == "balanced_cycle" else _target_completion_plan(state, target, unlocked, config_data, next_slot_in_season, template_kind)
	var safe_action_capacity := int(completion_plan.get("actions", 0))
	if template_kind == "balanced_cycle":
		target_count = mini(target_count, int(completion_plan.get("kindCount", 0)))
	elif template_kind == "win_challenge":
		target_count = 1
	elif ["complete_kind", "master_activity"].has(template_kind):
		target_count = mini(target_count, safe_action_capacity)
	elif template_kind == "clear_adventure":
		# Keep one complete retry beyond the authored clear target because combat
		# success is deterministic but outcome-dependent for the saved state.
		target_count = mini(target_count, maxi(1, safe_action_capacity - 1))
	elif template_kind == "relation_gain":
		var safe_relation_progress := int(floor(minf(
			_contract_relation_progress_floor(state, target) * float(safe_action_capacity),
			_contract_relation_total_headroom(state, target)
		)))
		target_count = mini(target_count, mini(safe_relation_progress, maxi(1, int(config_data.get("relationContractMaximumTarget", 8)))))
	elif ["gain_stat", "earn_gold"].has(template_kind):
		# Value targets must be completable before the next season regeneration.
		# Preserve the data-authored target during a normal season, but clamp late
		# contracts to conservative reducer progress across safely available actions.
		var safe_progress := int(floor(_contract_value_progress_floor(template_kind, state, target, config_data) * float(safe_action_capacity)))
		target_count = mini(target_count, safe_progress)
	var compatible_modifiers: Array[String] = []
	for modifier_id: String in modifiers_pool:
		var modifier_detail := _modifier_detail(procedural_data, modifier_id)
		if _modifier_compatible(modifier_id, target, required_kind, template_kind, target_count, state, unlocked, config_data, next_slot_in_season, modifier_detail.get("requirements", {}) as Dictionary, completion_plan):
			compatible_modifiers.append(modifier_id)
	var modifier_count_config: Dictionary = procedural_data.get("modifierCount", {}) as Dictionary
	var modifier_base: int = int(modifier_count_config.get("base", 1))
	var modifier_tier_divisor: int = maxi(1, int(modifier_count_config.get("tierDivisor", 4)))
	# An unmodified contract is preferable to attaching a condition that the
	# remaining season cannot satisfy.
	var modifier_minimum: int = 0 if compatible_modifiers.is_empty() else maxi(0, int(modifier_count_config.get("minimum", 1)))
	var modifier_maximum: int = maxi(modifier_minimum, int(modifier_count_config.get("maximum", 4)))
	var modifier_count: int = mini(compatible_modifiers.size(), clampi(modifier_base + int(floor(float(tier) / float(modifier_tier_divisor))), modifier_minimum, modifier_maximum))
	var modifiers: Array[String] = []
	while modifiers.size() < modifier_count:
		var modifier: String = compatible_modifiers[DeterministicRNG.range_int(local_state, 0, compatible_modifiers.size() - 1, "modifier")]
		if not modifiers.has(modifier):
			modifiers.append(modifier)
	var modifier_requirements: Dictionary = {}
	for modifier_id: String in modifiers:
		modifier_requirements[modifier_id] = (_modifier_detail(procedural_data, modifier_id).get("requirements", {}) as Dictionary).duplicate(true)
	var eligible_regions: Array[Dictionary] = []
	for raw_region: Variant in procedural_data.get("regionDetails", []) as Array:
		if raw_region is Dictionary and int((raw_region as Dictionary).get("minimumWorldTier", 1)) <= tier and (template_kind != "clear_adventure" or str((raw_region as Dictionary).get("baseActivityId", "")) == str(target.get("id", ""))):
			eligible_regions.append(raw_region as Dictionary)
	var region: Dictionary = {}
	if not eligible_regions.is_empty():
		region = eligible_regions[DeterministicRNG.range_int(local_state, 0, eligible_regions.size() - 1, "contract_region")]
	var bonus_objectives: Array[Dictionary] = _dictionary_array(procedural_data.get("bonusObjectives", []))
	var compatible_bonus_objectives: Array[Dictionary] = []
	for objective: Dictionary in bonus_objectives:
		if _bonus_objective_compatible(objective, template_kind, target, target_count, unlocked, config_data, next_slot_in_season, state):
			compatible_bonus_objectives.append(objective)
	var bonus_objective: Dictionary = {}
	if not compatible_bonus_objectives.is_empty():
		bonus_objective = compatible_bonus_objectives[DeterministicRNG.range_int(local_state, 0, compatible_bonus_objectives.size() - 1, "bonus_objective")]
	var reward: Dictionary = BigValue.from_number(template.get("baseReward", 400))
	reward = BigValue.multiply(reward, BigValue.pow_base(maxf(1.0, float(config_data.get("activityRewardTierGrowth", 1.13))), tier - 1))
	reward = BigValue.multiply_float(reward, 1.0 + maxf(0.0, float(procedural_data.get("rewardPerModifier", 0.18))) * float(modifier_count))
	var relation_context: Dictionary = _relation_contract_context(state, config_data)
	if not relation_context.is_empty():
		field = str(relation_context.get("field", field))
		reward = BigValue.multiply_float(reward, maxf(1.0, float(config_data.get("relationContractRewardMultiplier", 1.05))))
	var content_seed: int = int(local_state.get("seed", 1))
	var result: Dictionary = {
		"id": "CON_%d_%d_%d" % [season_index, contract_index, DeterministicRNG.next_u32(local_state, "id")],
		"kind": template_kind,
		"templateId": str(template.get("id", template_kind)),
		"tier": tier,
		"seed": content_seed,
		"name": "%s %s %s" % [prefix, field, goal],
		"description": _contract_description(template, template_kind, target, target_count),
		"region": region.duplicate(true),
		"bonusObjective": bonus_objective.duplicate(true),
		"modifiers": modifiers,
		"modifierRequirements": modifier_requirements,
		"reward": reward,
		"expirySeason": season_index + 1,
		"progress": 0,
		"target": target_count,
		"tracking": {},
		"targetActivityIds": [str(target.get("id", "REST_HOME"))],
		"targetKind": required_kind if not required_kind.is_empty() else str(target.get("kind", "")),
		"targetStat": str(target.get("primaryStat", "")),
		"targetDurationSlots": target_duration,
		"status": "active",
	}
	if not relation_context.is_empty():
		result["relationAffinity"] = str(relation_context.get("axis", ""))
		result["relationField"] = str(relation_context.get("field", ""))
		result["tags"] = ["relation", "relation_%s" % str(relation_context.get("axis", ""))]
	return result


func _modifier_compatible(
	modifier_id: String,
	target: Dictionary,
	required_kind: String,
	template_kind: String,
	target_count: int,
	state: Dictionary,
	unlocked: Array[Dictionary],
	config_data: Dictionary,
	next_slot_in_season: int,
	requirements: Dictionary,
	completion_plan: Dictionary = {}
) -> bool:
	var target_kind: String = required_kind if not required_kind.is_empty() else str(target.get("kind", ""))
	var tags: Array = target.get("tags", []) as Array
	if template_kind == "balanced_cycle":
		return _balanced_modifier_compatible(modifier_id, target, target_count, state, unlocked, config_data, next_slot_in_season, requirements, completion_plan)
	var required_actions := _required_target_actions(template_kind, target_count, state, target, config_data)
	var plan := completion_plan if not completion_plan.is_empty() else _target_completion_plan(state, target, unlocked, config_data, next_slot_in_season, template_kind)
	if template_kind != "balanced_cycle" and (required_actions <= 0 or int(plan.get("actions", 0)) < required_actions):
		return false
	match modifier_id:
		"low_energy":
			return _float_prefix_at_least(plan.get("actionEnergies", []) as Array, required_actions, float(requirements.get("minimumEnergy", 25.0)))
		"risk_bonus":
			var minimum_risk := maxf(0.0, float(requirements.get("minimumRisk", 0.2)))
			# Adventure/challenge success and injury are deterministic for a saved
			# state, but contract generation does not consume or predict those runtime
			# rolls. Do not promise an unrepeatable outcome modifier.
			return not ["adventure", "challenge"].has(target_kind) and float(target.get("risk", 0.0)) >= minimum_risk
		"high_quality":
			var primary_stat: String = str(target.get("primaryStat", ""))
			var current_value: float = float((state.get("stats", {}) as Dictionary).get(primary_stat, (state.get("meters", {}) as Dictionary).get(primary_stat, 0.0)))
			var effective: float = 100.0 * log(1.0 + maxf(0.0, current_value) / 100.0)
			var tier: int = maxi(1, int(state.get("worldTier", 1)))
			var performance_denominator := maxf(1.0, float(config_data.get("performanceStatDenominatorBase", 220.0)) + float(config_data.get("performanceWorldTierDenominatorScale", 40.0)) * float(tier))
			var performance := clampf(
				float(config_data.get("performanceBase", 0.75)) + effective / performance_denominator,
				float(config_data.get("performanceMinimum", 0.75)),
				float(config_data.get("performanceMaximum", 1.75))
			)
			if target_kind == "job" and float(target.get("risk", 0.0)) > 0.0:
				performance *= 0.45
			return performance >= float(requirements.get("minimumPerformance", 1.1))
		"community_bonus":
			var minimum_relation := float(requirements.get("minimumRelationGain", 1.0))
			return (target_kind == "job" and tags.has("service") or template_kind == "relation_gain") and _contract_relation_progress_floor(state, target) >= minimum_relation and _contract_relation_total_headroom(state, target) + 0.0001 >= float(required_actions) * minimum_relation
		"balanced_tags":
			return template_kind == "balanced_cycle" or _distinct_string_count(tags) >= maxi(1, int(requirements.get("distinctTagCount", 3)))
		"no_repeat":
			return template_kind == "balanced_cycle"
		"mastery_focus":
			return not ["gain_stat", "earn_gold"].has(template_kind) and required_actions >= maxi(1, int(requirements.get("masteryGain", 3)))
		"stress_guard":
			var max_stress: float = float((state.get("growthPolicy", {}) as Dictionary).get("maxStress", config_data.get("defaultMaxStress", 72.0)))
			return _float_prefix_at_most(plan.get("actionMaximumStress", []) as Array, required_actions, max_stress)
		"budget_guard":
			return _bool_prefix_all(plan.get("actionBudgetSafe", []) as Array, required_actions)
		"limited_slots":
			var slot_limit := int(ceil(float(target_count) * float(maxi(1, int(target.get("durationSlots", 1)))) * maxf(0.0, float(requirements.get("slotMultiplier", 1.5)))))
			return _integer_at(plan.get("actionTrackingSlots", []) as Array, required_actions - 1, 2147483647) <= slot_limit
	return true


func _required_target_actions(template_kind: String, target_count: int, state: Dictionary, target: Dictionary, config_data: Dictionary) -> int:
	if template_kind == "balanced_cycle":
		return maxi(1, target_count)
	var progress_per_action := 1.0
	if ["gain_stat", "earn_gold"].has(template_kind):
		progress_per_action = _contract_value_progress_floor(template_kind, state, target, config_data)
	elif template_kind == "relation_gain":
		progress_per_action = _contract_relation_progress_floor(state, target)
	if progress_per_action <= 0.0:
		return 0
	return maxi(1, int(ceil(float(target_count) / progress_per_action - 0.000001)))


func _float_prefix_at_least(values: Array, count: int, minimum: float) -> bool:
	if count <= 0 or values.size() < count:
		return false
	for index: int in range(count):
		if float(values[index]) + 0.0001 < minimum:
			return false
	return true


func _float_prefix_at_most(values: Array, count: int, maximum: float) -> bool:
	if count <= 0 or values.size() < count:
		return false
	for index: int in range(count):
		if float(values[index]) > maximum + 0.0001:
			return false
	return true


func _bool_prefix_all(values: Array, count: int) -> bool:
	if count <= 0 or values.size() < count:
		return false
	for index: int in range(count):
		if not bool(values[index]):
			return false
	return true


func _integer_at(values: Array, index: int, fallback: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else fallback


func _distinct_string_count(values: Array) -> int:
	var distinct: Dictionary = {}
	for raw_value: Variant in values:
		distinct[str(raw_value)] = true
	return distinct.size()


func _remaining_scheduled_challenge_attempts(unlocked: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int, only_high_risk: bool = false) -> int:
	var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
	var remaining: int = 0
	for activity: Dictionary in unlocked:
		if str(activity.get("kind", "")) != "challenge":
			continue
		if only_high_risk and float(activity.get("risk", 0.0)) < 0.2:
			continue
		var activity_id: String = str(activity.get("id", ""))
		if schedule.has(activity_id) and int(schedule[activity_id]) >= next_slot_in_season:
			remaining += 1
	return remaining


func _remaining_scheduled_challenges(challenges: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int) -> Array[Dictionary]:
	var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
	var result: Array[Dictionary] = []
	for activity: Dictionary in challenges:
		var activity_id: String = str(activity.get("id", ""))
		if schedule.has(activity_id) and int(schedule[activity_id]) >= next_slot_in_season:
			result.append(activity)
	return result


func _eligible_contract_targets(template: Dictionary, unlocked: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int, state: Dictionary) -> Array[Dictionary]:
	var required_kind: String = str(template.get("requiredKind", ""))
	var template_kind: String = str(template.get("kind", template.get("id", "complete_kind")))
	var eligible: Array[Dictionary] = unlocked
	if not required_kind.is_empty():
		eligible = _activities_of_kind(eligible, required_kind)
	if template_kind == "relation_gain":
		eligible = _activities_with_tag(eligible, "service")
	elif template_kind == "win_challenge":
		eligible = _remaining_scheduled_challenges(eligible, config_data, next_slot_in_season)
	if template_kind == "balanced_cycle":
		var balanced_plan := _balanced_completion_plan(state, unlocked, config_data, next_slot_in_season)
		var planned_targets: Array[Dictionary] = []
		for raw_id: Variant in balanced_plan.get("activityIds", []) as Array:
			var planned_activity := _activity_by_id(unlocked, str(raw_id))
			if not planned_activity.is_empty() and not planned_targets.has(planned_activity):
				planned_targets.append(planned_activity)
		return planned_targets
	var reachable := _activities_reachable_before_expiry(eligible, config_data, next_slot_in_season)
	var capacity_reachable: Array[Dictionary] = []
	for activity: Dictionary in reachable:
		var action_capacity := _target_action_capacity(state, activity, unlocked, config_data, next_slot_in_season, template_kind)
		if action_capacity <= 0:
			continue
		if template_kind == "clear_adventure" and action_capacity < 2:
			continue
		if template_kind == "win_challenge":
			var scheduled_slot := int((config_data.get("challengeScheduleSlots", {}) as Dictionary).get(str(activity.get("id", "")), -1))
			# A contract generated on the challenge's start slot has no preparation
			# or retry window. The deterministic result may already make it impossible.
			if scheduled_slot <= next_slot_in_season:
				continue
			if _challenge_feasibility_active and not bool(_challenge_feasibility.get(str(activity.get("id", "")), false)):
				continue
		if ["gain_stat", "earn_gold"].has(template_kind) and int(floor(_contract_value_progress_floor(template_kind, state, activity, config_data) * float(action_capacity))) < 1:
			continue
		if template_kind == "relation_gain" and int(floor(minf(_contract_relation_progress_floor(state, activity) * float(action_capacity), _contract_relation_total_headroom(state, activity)))) < 1:
			continue
		capacity_reachable.append(activity)
	return capacity_reachable


func _activities_reachable_before_expiry(activities: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int) -> Array[Dictionary]:
	var remaining_slots := _remaining_contract_slots(config_data, next_slot_in_season)
	var reachable: Array[Dictionary] = []
	for activity: Dictionary in activities:
		if maxi(1, int(activity.get("durationSlots", 1))) <= remaining_slots:
			reachable.append(activity)
	return reachable


func _remaining_contract_slots(config_data: Dictionary, next_slot_in_season: int) -> int:
	var slots_per_season := maxi(1, int(config_data.get("slotsPerSeason", 28)))
	return maxi(1, slots_per_season - next_slot_in_season + 1)


func _target_action_capacity(state: Dictionary, activity: Dictionary, unlocked: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int, template_kind: String) -> int:
	return int(_target_completion_plan(state, activity, unlocked, config_data, next_slot_in_season, template_kind).get("actions", 0))


func _target_completion_plan(state: Dictionary, activity: Dictionary, unlocked: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int, template_kind: String) -> Dictionary:
	var slots_per_season := maxi(1, int(config_data.get("slotsPerSeason", 28)))
	var target_duration := maxi(1, int(activity.get("durationSlots", 1)))
	var target_id := str(activity.get("id", ""))
	var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
	var active_task: Variant = state.get("activeTask", null)
	var active_end := next_slot_in_season - 1
	if active_task is Dictionary:
		active_end = next_slot_in_season + maxi(0, int((active_task as Dictionary).get("remainingSlots", 0))) - 1
	var banned_tags: Array = (state.get("growthPolicy", {}) as Dictionary).get("bannedTags", []) as Array
	if str(activity.get("kind", "")) != "challenge":
		for raw_tag: Variant in activity.get("tags", []) as Array:
			if banned_tags.has(str(raw_tag)):
				return {"actions": 0}
	var occupied: Dictionary = {}
	var start_events: Dictionary = {}
	var completion_events: Dictionary = {}
	if active_task is Dictionary and active_end >= next_slot_in_season:
		for occupied_slot: int in range(next_slot_in_season, mini(slots_per_season, active_end) + 1):
			occupied[occupied_slot] = true
		var active_activity := _activity_by_id(unlocked, str((active_task as Dictionary).get("activityId", (active_task as Dictionary).get("id", ""))))
		if not active_activity.is_empty() and active_end <= slots_per_season:
			_add_timeline_event(completion_events, active_end, {
				"activity": active_activity,
				"trackedDuration": maxi(1, int(active_activity.get("durationSlots", 1))),
				"target": str(active_activity.get("id", "")) == target_id,
			})
	for challenge: Dictionary in unlocked:
		var challenge_id := str(challenge.get("id", ""))
		if str(challenge.get("kind", "")) != "challenge" or not schedule.has(challenge_id):
			continue
		var challenge_start := int(schedule[challenge_id])
		if challenge_start < next_slot_in_season or active_end >= challenge_start:
			continue
		var challenge_duration := maxi(1, int(challenge.get("durationSlots", 1)))
		var challenge_end := challenge_start + challenge_duration - 1
		if challenge_end > slots_per_season:
			continue
		for occupied_slot: int in range(challenge_start, challenge_end + 1):
			occupied[occupied_slot] = true
		_add_timeline_event(start_events, challenge_start, challenge)
		_add_timeline_event(completion_events, challenge_end, {
			"activity": challenge,
			"trackedDuration": challenge_duration,
			"target": challenge_id == target_id,
		})
	var free_slots := 0
	for season_slot: int in range(next_slot_in_season, slots_per_season + 1):
		if not occupied.has(season_slot):
			free_slots += 1
	var slot_budget_ratio := clampf(float(config_data.get("contractTargetSlotBudgetRatio", 0.75)), 0.1, 1.0)
	var hard_capacity := 0
	if free_slots >= target_duration:
		hard_capacity = maxi(1, int(floor(float(free_slots) * slot_budget_ratio / float(target_duration))))
	# An already-running task or a scheduled target can add one completion even
	# when no free target action can be started.
	hard_capacity += 1
	var recovery := _activity_by_id(unlocked, "REST_HOME")
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var force_rest := bool(state.get("forceRest", false))
	var energy_threshold := float(config_data.get("forcedRecoveryEnergyThreshold", 20.0))
	var max_stress := float((state.get("growthPolicy", {}) as Dictionary).get("maxStress", config_data.get("defaultMaxStress", 72.0)))
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var unit_cost := BigValue.multiply(
		BigValue.from_number(activity.get("baseCost", 0)),
		BigValue.pow_base(maxf(1.0, float(config_data.get("activityCostTierGrowth", 1.11))), tier - 1)
	)
	var reserve_gold: Dictionary = ((state.get("growthPolicy", {}) as Dictionary).get("reserveGold", BigValue.zero()) as Dictionary).duplicate(true)
	var simulation: Dictionary = {
		"energy": clampf(float(meters.get("energy", 100.0)), 0.0, 100.0),
		"stress": clampf(float(meters.get("stress", 0.0)), 0.0, 100.0),
		"maximumStress": 0.0,
		"gold": ((state.get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary).duplicate(true),
		"trackingSlots": 0,
		"actions": 0,
		"actionEnergies": [],
		"actionTrackingSlots": [],
		"actionMaximumStress": [],
		"actionBudgetSafe": [],
	}
	var cursor := next_slot_in_season
	while cursor <= slots_per_season and int(simulation.get("actions", 0)) < hard_capacity:
		for raw_start_event: Variant in start_events.get(cursor, []) as Array:
			_apply_scheduled_cost(simulation, raw_start_event as Dictionary, tier, config_data)
		if occupied.has(cursor):
			for raw_event: Variant in completion_events.get(cursor, []) as Array:
				var event := raw_event as Dictionary
				_apply_plan_completion(simulation, event.get("activity", {}) as Dictionary, state, config_data, int(event.get("trackedDuration", 1)), bool(event.get("target", false)), reserve_gold)
			cursor += 1
			continue
		# Scheduled challenges are the only legal way to start a challenge target.
		if str(activity.get("kind", "")) == "challenge":
			if recovery.is_empty():
				cursor += 1
				continue
			_apply_plan_completion(simulation, recovery, state, config_data, maxi(1, int(recovery.get("durationSlots", 1))), false, reserve_gold)
			force_rest = false
			cursor += maxi(1, int(recovery.get("durationSlots", 1)))
			continue
		var recovery_forced := force_rest or bool(simulation.get("forceRestNext", false)) or float(simulation.get("energy", 100.0)) < energy_threshold or float(simulation.get("stress", 0.0)) >= max_stress
		if recovery_forced:
			if recovery.is_empty():
				break
			var recovery_duration := maxi(1, int(recovery.get("durationSlots", 1)))
			if not _slot_range_available(occupied, cursor, recovery_duration, slots_per_season):
				cursor += 1
				continue
			var recovery_is_target := str(recovery.get("id", "")) == target_id
			_apply_plan_completion(simulation, recovery, state, config_data, recovery_duration, recovery_is_target, reserve_gold)
			force_rest = false
			simulation["forceRestNext"] = false
			cursor += recovery_duration
			continue
		if not _slot_range_available(occupied, cursor, target_duration, slots_per_season):
			# The runtime never idles. Use the safe one-slot home recovery while
			# waiting for the scheduled window so tracking and meter effects remain
			# conservative for modifiers.
			if recovery.is_empty():
				cursor += 1
				continue
			var filler_duration := maxi(1, int(recovery.get("durationSlots", 1)))
			if not _slot_range_available(occupied, cursor, filler_duration, slots_per_season):
				cursor += 1
				continue
			_apply_plan_completion(simulation, recovery, state, config_data, filler_duration, str(recovery.get("id", "")) == target_id, reserve_gold)
			cursor += filler_duration
			continue
		if not BigValue.is_zero(unit_cost):
			var available_gold: Dictionary = simulation.get("gold", BigValue.zero()) as Dictionary
			if BigValue.compare(available_gold, unit_cost) < 0:
				break
			var after_cost := BigValue.subtract(available_gold, unit_cost)
			if BigValue.compare(after_cost, reserve_gold) < 0:
				break
			simulation["gold"] = after_cost
		_apply_plan_completion(simulation, activity, state, config_data, target_duration, true, reserve_gold)
		cursor += target_duration
	return simulation


func _balanced_completion_plan(state: Dictionary, unlocked: Array[Dictionary], config_data: Dictionary, next_slot_in_season: int) -> Dictionary:
	var slots_per_season := maxi(1, int(config_data.get("slotsPerSeason", 28)))
	var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
	var occupied: Dictionary = {}
	var start_events: Dictionary = {}
	var completion_events: Dictionary = {}
	var active_task: Variant = state.get("activeTask", null)
	var active_end := next_slot_in_season - 1
	if active_task is Dictionary:
		active_end = next_slot_in_season + maxi(0, int((active_task as Dictionary).get("remainingSlots", 0))) - 1
		for occupied_slot: int in range(next_slot_in_season, mini(slots_per_season, active_end) + 1):
			occupied[occupied_slot] = true
		var active_activity := _activity_by_id(unlocked, str((active_task as Dictionary).get("activityId", (active_task as Dictionary).get("id", ""))))
		if not active_activity.is_empty() and active_end <= slots_per_season:
			_add_timeline_event(completion_events, active_end, {"activity": active_activity, "trackedDuration": maxi(1, int(active_activity.get("durationSlots", 1)))})
	for challenge: Dictionary in unlocked:
		var challenge_id := str(challenge.get("id", ""))
		if str(challenge.get("kind", "")) != "challenge" or not schedule.has(challenge_id):
			continue
		var challenge_start := int(schedule[challenge_id])
		if challenge_start < next_slot_in_season or active_end >= challenge_start:
			continue
		var challenge_duration := maxi(1, int(challenge.get("durationSlots", 1)))
		var challenge_end := challenge_start + challenge_duration - 1
		if challenge_end > slots_per_season:
			continue
		for occupied_slot: int in range(challenge_start, challenge_end + 1):
			occupied[occupied_slot] = true
		_add_timeline_event(start_events, challenge_start, challenge)
		_add_timeline_event(completion_events, challenge_end, {"activity": challenge, "trackedDuration": challenge_duration})
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var simulation: Dictionary = {
		"energy": clampf(float(meters.get("energy", 100.0)), 0.0, 100.0),
		"stress": clampf(float(meters.get("stress", 0.0)), 0.0, 100.0),
		"maximumStress": 0.0,
		"gold": ((state.get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary).duplicate(true),
		"trackingSlots": 0,
		"activityCount": 0,
		"lastActivityId": "",
		"consecutiveSame": 0,
		"maximumConsecutiveSame": 0,
		"kinds": [],
		"tags": [],
		"activityIds": [],
		"kindEnergies": [],
		"kindTrackingSlots": [],
		"kindMaximumStress": [],
		"kindBudgetSafe": [],
		"kindDistinctTags": [],
		"kindMaximumConsecutiveSame": [],
		"kindActivityCounts": [],
	}
	var reserve_gold: Dictionary = ((state.get("growthPolicy", {}) as Dictionary).get("reserveGold", BigValue.zero()) as Dictionary).duplicate(true)
	var recovery := _activity_by_id(unlocked, "REST_HOME")
	var force_rest := bool(state.get("forceRest", false))
	var energy_threshold := float(config_data.get("forcedRecoveryEnergyThreshold", 20.0))
	var max_stress := float((state.get("growthPolicy", {}) as Dictionary).get("maxStress", config_data.get("defaultMaxStress", 72.0)))
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var cursor := next_slot_in_season
	while cursor <= slots_per_season and (simulation.get("kinds", []) as Array).size() < 5:
		for raw_start_event: Variant in start_events.get(cursor, []) as Array:
			_apply_scheduled_cost(simulation, raw_start_event as Dictionary, tier, config_data)
		if occupied.has(cursor):
			for raw_event: Variant in completion_events.get(cursor, []) as Array:
				var event := raw_event as Dictionary
				_apply_balanced_completion(simulation, event.get("activity", {}) as Dictionary, state, config_data, int(event.get("trackedDuration", 1)), reserve_gold)
			cursor += 1
			continue
		var chosen: Dictionary = {}
		var recovery_forced := force_rest or bool(simulation.get("forceRestNext", false)) or float(simulation.get("energy", 100.0)) < energy_threshold or float(simulation.get("stress", 0.0)) >= max_stress
		if recovery_forced:
			chosen = recovery
		else:
			chosen = _balanced_next_kind_activity(simulation, unlocked, occupied, cursor, slots_per_season, state, config_data, reserve_gold)
		if chosen.is_empty():
			chosen = recovery
		if chosen.is_empty():
			cursor += 1
			continue
		var duration := maxi(1, int(chosen.get("durationSlots", 1)))
		if not _slot_range_available(occupied, cursor, duration, slots_per_season):
			cursor += 1
			continue
		var cost := BigValue.multiply(
			BigValue.from_number(chosen.get("baseCost", 0)),
			BigValue.pow_base(maxf(1.0, float(config_data.get("activityCostTierGrowth", 1.11))), tier - 1)
		)
		if not BigValue.is_zero(cost):
			var gold: Dictionary = simulation.get("gold", BigValue.zero()) as Dictionary
			if BigValue.compare(gold, cost) < 0 or BigValue.compare(BigValue.subtract(gold, cost), reserve_gold) < 0:
				chosen = recovery
				duration = maxi(1, int(chosen.get("durationSlots", 1))) if not chosen.is_empty() else 1
			else:
				simulation["gold"] = BigValue.subtract(gold, cost)
		_apply_balanced_completion(simulation, chosen, state, config_data, duration, reserve_gold)
		if str(chosen.get("kind", "")) == "rest":
			force_rest = false
			simulation["forceRestNext"] = false
		cursor += duration
	simulation["kindCount"] = (simulation.get("kinds", []) as Array).size()
	return simulation


func _balanced_next_kind_activity(
	simulation: Dictionary,
	unlocked: Array[Dictionary],
	occupied: Dictionary,
	cursor: int,
	slots_per_season: int,
	state: Dictionary,
	config_data: Dictionary,
	reserve_gold: Dictionary
) -> Dictionary:
	var seen_kinds: Array = simulation.get("kinds", []) as Array
	var banned_tags: Array = (state.get("growthPolicy", {}) as Dictionary).get("bannedTags", []) as Array
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var best_by_kind: Dictionary = {}
	for activity: Dictionary in unlocked:
		var kind := str(activity.get("kind", ""))
		if kind.is_empty() or kind == "challenge" or seen_kinds.has(kind):
			continue
		var banned := false
		for raw_tag: Variant in activity.get("tags", []) as Array:
			if banned_tags.has(str(raw_tag)):
				banned = true
				break
		if banned:
			continue
		var duration := maxi(1, int(activity.get("durationSlots", 1)))
		if not _slot_range_available(occupied, cursor, duration, slots_per_season):
			continue
		var cost := BigValue.multiply(
			BigValue.from_number(activity.get("baseCost", 0)),
			BigValue.pow_base(maxf(1.0, float(config_data.get("activityCostTierGrowth", 1.11))), tier - 1)
		)
		var gold: Dictionary = simulation.get("gold", BigValue.zero()) as Dictionary
		if not BigValue.is_zero(cost) and (BigValue.compare(gold, cost) < 0 or BigValue.compare(BigValue.subtract(gold, cost), reserve_gold) < 0):
			continue
		var previous: Dictionary = best_by_kind.get(kind, {}) as Dictionary
		if previous.is_empty() or duration < maxi(1, int(previous.get("durationSlots", 1))) or (duration == maxi(1, int(previous.get("durationSlots", 1))) and float(activity.get("stressDelta", 0.0)) < float(previous.get("stressDelta", 0.0))):
			best_by_kind[kind] = activity
	var chosen: Dictionary = {}
	# Long kinds have fewer windows in the fixed challenge calendar. Schedule
	# their shortest representative first, then use one-slot gaps for the rest.
	for raw_candidate: Variant in best_by_kind.values():
		var candidate := raw_candidate as Dictionary
		var duration := maxi(1, int(candidate.get("durationSlots", 1)))
		if chosen.is_empty() or duration > maxi(1, int(chosen.get("durationSlots", 1))) or (duration == maxi(1, int(chosen.get("durationSlots", 1))) and str(candidate.get("id", "")) < str(chosen.get("id", ""))):
			chosen = candidate
	return chosen


func _apply_balanced_completion(simulation: Dictionary, activity: Dictionary, state: Dictionary, config_data: Dictionary, tracked_duration: int, reserve_gold: Dictionary) -> void:
	if activity.is_empty():
		return
	var reward := _guaranteed_activity_reward(activity, state, config_data)
	simulation["gold"] = BigValue.add(simulation.get("gold", BigValue.zero()) as Dictionary, reward)
	simulation["energy"] = clampf(float(simulation.get("energy", 100.0)) + float(activity.get("energyDelta", 0.0)), 0.0, 100.0)
	var stress_delta := float(activity.get("stressDelta", 0.0))
	if str(activity.get("kind", "")) == "job" and float(activity.get("risk", 0.0)) > 0.0:
		stress_delta += 4.0 + 12.0 * clampf(float(activity.get("risk", 0.0)), 0.0, 1.0)
	elif str(activity.get("kind", "")) == "adventure":
		stress_delta += maxf(0.0, float(config_data.get("adventureInjuryStressPenalty", 12.0)))
		simulation["forceRestNext"] = true
	simulation["stress"] = clampf(float(simulation.get("stress", 0.0)) + stress_delta, 0.0, 100.0)
	simulation["maximumStress"] = maxf(float(simulation.get("maximumStress", 0.0)), float(simulation.get("stress", 0.0)))
	simulation["trackingSlots"] = int(simulation.get("trackingSlots", 0)) + maxi(1, tracked_duration)
	simulation["activityCount"] = int(simulation.get("activityCount", 0)) + 1
	var activity_id := str(activity.get("id", ""))
	var consecutive := int(simulation.get("consecutiveSame", 0)) + 1 if str(simulation.get("lastActivityId", "")) == activity_id else 1
	simulation["lastActivityId"] = activity_id
	simulation["consecutiveSame"] = consecutive
	simulation["maximumConsecutiveSame"] = maxi(int(simulation.get("maximumConsecutiveSame", 0)), consecutive)
	var tags: Array = simulation.get("tags", []) as Array
	for raw_tag: Variant in activity.get("tags", []) as Array:
		var tag := str(raw_tag)
		if not tags.has(tag):
			tags.append(tag)
	var kind := str(activity.get("kind", ""))
	var kinds: Array = simulation.get("kinds", []) as Array
	if kinds.has(kind):
		return
	kinds.append(kind)
	(simulation.get("activityIds", []) as Array).append(activity_id)
	(simulation.get("kindEnergies", []) as Array).append(float(simulation.get("energy", 0.0)))
	(simulation.get("kindTrackingSlots", []) as Array).append(int(simulation.get("trackingSlots", 0)))
	(simulation.get("kindMaximumStress", []) as Array).append(float(simulation.get("maximumStress", 0.0)))
	(simulation.get("kindBudgetSafe", []) as Array).append(BigValue.compare(simulation.get("gold", BigValue.zero()) as Dictionary, reserve_gold) >= 0)
	(simulation.get("kindDistinctTags", []) as Array).append(tags.size())
	(simulation.get("kindMaximumConsecutiveSame", []) as Array).append(int(simulation.get("maximumConsecutiveSame", 0)))
	(simulation.get("kindActivityCounts", []) as Array).append(int(simulation.get("activityCount", 0)))


func _balanced_modifier_compatible(
	modifier_id: String,
	target: Dictionary,
	target_count: int,
	state: Dictionary,
	unlocked: Array[Dictionary],
	config_data: Dictionary,
	next_slot_in_season: int,
	requirements: Dictionary,
	completion_plan: Dictionary = {}
) -> bool:
	var plan := completion_plan if not completion_plan.is_empty() else _balanced_completion_plan(state, unlocked, config_data, next_slot_in_season)
	if int(plan.get("kindCount", 0)) < target_count or target_count <= 0:
		return false
	var index := target_count - 1
	match modifier_id:
		"low_energy":
			return float((plan.get("kindEnergies", []) as Array)[index]) >= float(requirements.get("minimumEnergy", 25.0))
		"no_repeat":
			return int((plan.get("kindMaximumConsecutiveSame", []) as Array)[index]) <= maxi(1, int(requirements.get("maximumConsecutiveSame", 1)))
		"budget_guard":
			return bool((plan.get("kindBudgetSafe", []) as Array)[index])
		"mastery_focus":
			return int((plan.get("kindActivityCounts", []) as Array)[index]) >= maxi(1, int(requirements.get("masteryGain", 3)))
		"limited_slots":
			var slot_limit := int(ceil(float(target_count) * float(maxi(1, int(target.get("durationSlots", 1)))) * maxf(0.0, float(requirements.get("slotMultiplier", 1.5)))))
			return int((plan.get("kindTrackingSlots", []) as Array)[index]) <= slot_limit
		"balanced_tags":
			return int((plan.get("kindDistinctTags", []) as Array)[index]) >= maxi(1, int(requirements.get("distinctTagCount", 3)))
		"stress_guard":
			var max_stress := float((state.get("growthPolicy", {}) as Dictionary).get("maxStress", config_data.get("defaultMaxStress", 72.0)))
			return float((plan.get("kindMaximumStress", []) as Array)[index]) <= max_stress
	# Outcome/performance/relation modifiers depend on the exact activity that
	# closes the distinct-kind target, not on the decorative selected target.
	return false


func _activity_by_id(activities: Array[Dictionary], activity_id: String) -> Dictionary:
	for activity: Dictionary in activities:
		if str(activity.get("id", "")) == activity_id:
			return activity
	return {}


func _add_timeline_event(events: Dictionary, slot: int, event: Variant) -> void:
	if not events.has(slot):
		events[slot] = []
	(events[slot] as Array).append(event)


func _apply_scheduled_cost(simulation: Dictionary, activity: Dictionary, tier: int, config_data: Dictionary) -> void:
	var cost := BigValue.multiply(
		BigValue.from_number(activity.get("baseCost", 0)),
		BigValue.pow_base(maxf(1.0, float(config_data.get("activityCostTierGrowth", 1.11))), tier - 1)
	)
	var gold: Dictionary = simulation.get("gold", BigValue.zero()) as Dictionary
	# Runtime pays a scheduled challenge whenever it can, even when that crosses
	# the reserve. Only an actually unaffordable challenge receives free support.
	if BigValue.compare(gold, cost) >= 0:
		simulation["gold"] = BigValue.subtract(gold, cost)


func _apply_plan_completion(
	simulation: Dictionary,
	activity: Dictionary,
	state: Dictionary,
	config_data: Dictionary,
	tracked_duration: int,
	is_target: bool,
	reserve_gold: Dictionary
) -> void:
	var reward := _guaranteed_activity_reward(activity, state, config_data)
	simulation["gold"] = BigValue.add(simulation.get("gold", BigValue.zero()) as Dictionary, reward)
	simulation["energy"] = clampf(float(simulation.get("energy", 100.0)) + float(activity.get("energyDelta", 0.0)), 0.0, 100.0)
	var stress_delta := float(activity.get("stressDelta", 0.0))
	if str(activity.get("kind", "")) == "job" and float(activity.get("risk", 0.0)) > 0.0:
		stress_delta += 4.0 + 12.0 * clampf(float(activity.get("risk", 0.0)), 0.0, 1.0)
	elif str(activity.get("kind", "")) == "adventure":
		stress_delta += maxf(0.0, float(config_data.get("adventureInjuryStressPenalty", 12.0)))
		simulation["forceRestNext"] = true
	simulation["stress"] = clampf(float(simulation.get("stress", 0.0)) + stress_delta, 0.0, 100.0)
	simulation["maximumStress"] = maxf(float(simulation.get("maximumStress", 0.0)), float(simulation.get("stress", 0.0)))
	simulation["trackingSlots"] = int(simulation.get("trackingSlots", 0)) + maxi(1, tracked_duration)
	if not is_target:
		return
	simulation["actions"] = int(simulation.get("actions", 0)) + 1
	(simulation.get("actionEnergies", []) as Array).append(float(simulation.get("energy", 0.0)))
	(simulation.get("actionTrackingSlots", []) as Array).append(int(simulation.get("trackingSlots", 0)))
	(simulation.get("actionMaximumStress", []) as Array).append(float(simulation.get("maximumStress", 0.0)))
	(simulation.get("actionBudgetSafe", []) as Array).append(BigValue.compare(simulation.get("gold", BigValue.zero()) as Dictionary, reserve_gold) >= 0)


func _guaranteed_activity_reward(activity: Dictionary, state: Dictionary, config_data: Dictionary) -> Dictionary:
	if str(activity.get("kind", "")) != "job":
		return BigValue.zero()
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var reward := BigValue.multiply(
		BigValue.from_number(activity.get("baseReward", 0)),
		BigValue.pow_base(maxf(1.0, float(config_data.get("activityRewardTierGrowth", 1.13))), tier - 1)
	)
	var incident_floor := 0.45 if float(activity.get("risk", 0.0)) > 0.0 else 1.0
	return BigValue.multiply_float(reward, maxf(0.0, float(config_data.get("performanceMinimum", 0.75))) * incident_floor)


func _slot_range_available(occupied: Dictionary, start_slot: int, duration: int, slots_per_season: int) -> bool:
	if start_slot + duration - 1 > slots_per_season:
		return false
	for slot: int in range(start_slot, start_slot + duration):
		if occupied.has(slot):
			return false
	return true


func _contract_value_progress_floor(template_kind: String, state: Dictionary, activity: Dictionary, config_data: Dictionary) -> float:
	var tier := maxi(1, int(state.get("worldTier", 1)))
	if template_kind == "earn_gold":
		var reward := BigValue.multiply(
			BigValue.from_number(activity.get("baseReward", 0)),
			BigValue.pow_base(maxf(1.0, float(config_data.get("activityRewardTierGrowth", 1.13))), tier - 1)
		)
		var performance_floor := maxf(0.0, float(config_data.get("performanceMinimum", 0.75)))
		# Job incidents never reduce reward below the reducer's absolute 0.45 floor.
		var incident_floor := 0.45 if float(activity.get("risk", 0.0)) > 0.0 else 1.0
		return maxf(0.0, BigValue.to_float(BigValue.multiply_float(reward, performance_floor * incident_floor), 1.0e12))
	if template_kind != "gain_stat":
		return 0.0
	var stat_key := str(activity.get("primaryStat", ""))
	var gains: Dictionary = activity.get("gains", {}) as Dictionary
	if stat_key.is_empty() or not gains.has(stat_key):
		return 0.0
	# Use global formula minima rather than the current meter snapshot so the
	# lower bound remains valid after repeated target and scheduled activities.
	var condition_mod := maxf(0.0, float(config_data.get("growthConditionStressMinimum", 0.40))) * maxf(0.0, float(config_data.get("growthConditionEnergyMinimum", 0.60)))
	var mastery_mod := 1.0
	var relation_mod := 1.0
	var tier_mod := 1.0 + maxf(0.0, float(config_data.get("growthTierSqrtRate", 0.04))) * sqrt(float(tier - 1))
	var focus_mod := maxf(0.0, float(config_data.get("growthFocusBase", 0.85)))
	var diminish_mod := maxf(0.0, float(config_data.get("growthDiminishBase", 0.35)))
	var jitter_floor := maxf(0.0, minf(float(config_data.get("growthJitterMin", 0.95)), float(config_data.get("growthJitterMax", 1.05))))
	var minimum_gain := float(gains[stat_key]) * focus_mod * condition_mod * mastery_mod * relation_mod * diminish_mod * tier_mod * jitter_floor
	return maxf(0.0, floor(minimum_gain * 100.0) / 100.0)


func _contract_relation_progress_floor(state: Dictionary, activity: Dictionary) -> float:
	if str(activity.get("kind", "")) != "job":
		return 0.0
	var tags: Array = activity.get("tags", []) as Array
	if not tags.has("service"):
		return 0.0
	var relations: Dictionary = state.get("relations", {}) as Dictionary
	var citizens := clampf(float(relations.get("citizens", 0.0)), 0.0, 1000.0)
	var steward := clampf(float(relations.get("steward", 0.0)), 0.0, 1000.0)
	var peaceful_gain := minf(1.0, 1000.0 - citizens)
	if tags.has("social"):
		peaceful_gain += minf(0.5, 1000.0 - steward)
	# A risky service job can deterministically lose more relation than it gains.
	# Relation contracts use only a stable per-run lower bound.
	if float(activity.get("risk", 0.0)) > 0.0:
		return 0.0
	return maxf(0.0, peaceful_gain)


func _contract_relation_total_headroom(state: Dictionary, activity: Dictionary) -> float:
	var tags: Array = activity.get("tags", []) as Array
	if str(activity.get("kind", "")) != "job" or not tags.has("service"):
		return 0.0
	var relations: Dictionary = state.get("relations", {}) as Dictionary
	var total := maxf(0.0, 1000.0 - clampf(float(relations.get("citizens", 0.0)), 0.0, 1000.0))
	if tags.has("social"):
		total += maxf(0.0, 1000.0 - clampf(float(relations.get("steward", 0.0)), 0.0, 1000.0))
	return total


func _bonus_objective_compatible(
	objective: Dictionary,
	template_kind: String,
	target: Dictionary,
	target_count: int,
	unlocked: Array[Dictionary],
	config_data: Dictionary,
	next_slot_in_season: int,
	state: Dictionary
) -> bool:
	match str(objective.get("id", "")):
		"bonus_fast":
			# Count-based contracts need at least one slot per progress point, so 80%
			# is only reachable for value-based progress metrics.
			return ["gain_stat", "earn_gold"].has(template_kind)
		"bonus_mastery":
			# Completion happens as soon as the base target is reached; 140% cannot
			# be accumulated afterwards.
			return false
		"bonus_thrifty":
			return float(target.get("baseCost", 0.0)) <= 0.0
		"bonus_challenge":
			var required_wins: int = int(ceil(float(objective.get("targetScale", 1.0))))
			if template_kind != "win_challenge":
				return _remaining_scheduled_challenge_attempts(unlocked, config_data, next_slot_in_season) >= required_wins
			# A win contract completes on its selected challenge. Only challenges up to
			# that slot can contribute to the bonus before completion.
			var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
			var target_slot: int = int(schedule.get(str(target.get("id", "")), -1))
			if target_slot < next_slot_in_season:
				return false
			var attempts_before_completion: int = 0
			for activity: Dictionary in unlocked:
				if str(activity.get("kind", "")) != "challenge":
					continue
				var activity_slot: int = int(schedule.get(str(activity.get("id", "")), -1))
				if activity_slot >= next_slot_in_season and activity_slot <= target_slot:
					attempts_before_completion += 1
			return attempts_before_completion >= required_wins
		"bonus_reputation":
			return _remaining_scheduled_challenge_attempts(unlocked, config_data, next_slot_in_season) >= 1
		"bonus_relation":
			return not _activities_with_tag(unlocked, "service").is_empty()
		"bonus_variety":
			return unlocked.size() >= int(ceil(float(objective.get("targetScale", 1.0))))
		"bonus_calm":
			var max_stress: float = float((state.get("growthPolicy", {}) as Dictionary).get("maxStress", config_data.get("defaultMaxStress", 72.0)))
			return _stress_path_reachable(state, unlocked, target, template_kind, target_count, config_data, next_slot_in_season, max_stress * maxf(0.0, float(objective.get("targetScale", 1.0))))
	return true


func _stress_path_reachable(
	state: Dictionary,
	unlocked: Array[Dictionary],
	target: Dictionary,
	template_kind: String,
	target_count: int,
	config_data: Dictionary,
	next_slot_in_season: int,
	stress_limit: float
) -> bool:
	if not ["complete_kind", "master_activity", "win_challenge", "clear_adventure", "relation_gain"].has(template_kind):
		return false
	var remaining_slots := _remaining_contract_slots(config_data, next_slot_in_season)
	var required_targets := maxi(1, target_count)
	var frontier: Array[Dictionary] = [{
		"slots": 0,
		"targets": 0,
		"stress": clampf(float((state.get("meters", {}) as Dictionary).get("stress", 0.0)), 0.0, 100.0),
	}]
	var best_stress: Dictionary = {"0:0": float(frontier[0]["stress"])}
	var cursor := 0
	while cursor < frontier.size():
		var current: Dictionary = frontier[cursor]
		cursor += 1
		if int(current["targets"]) >= required_targets:
			return true
		var actions: Array[Dictionary] = [{"activity": target, "target": true}]
		for activity: Dictionary in unlocked:
			if str(activity.get("id", "")) != str(target.get("id", "")) and float(activity.get("stressDelta", 0.0)) < 0.0:
				actions.append({"activity": activity, "target": false})
		for action: Dictionary in actions:
			var activity: Dictionary = action["activity"] as Dictionary
			var next_slots := int(current["slots"]) + maxi(1, int(activity.get("durationSlots", 1)))
			if next_slots > remaining_slots:
				continue
			var next_stress := clampf(float(current["stress"]) + float(activity.get("stressDelta", 0.0)), 0.0, 100.0)
			if next_stress > stress_limit + 0.0001:
				continue
			var next_targets := int(current["targets"]) + (1 if bool(action["target"]) else 0)
			var key := "%d:%d" % [next_slots, next_targets]
			if best_stress.has(key) and float(best_stress[key]) <= next_stress:
				continue
			best_stress[key] = next_stress
			frontier.append({"slots": next_slots, "targets": next_targets, "stress": next_stress})
	return false


func _relation_contract_context(state: Dictionary, config_data: Dictionary) -> Dictionary:
	var threshold: float = maxf(0.0, float(config_data.get("relationContractVariantThreshold", 500.0)))
	var relation_fields: Dictionary = {
		"guardian": "돌봄",
		"steward": "생활",
		"rival": "무예",
		"citizens": "외교",
	}
	var selected_axis: String = ""
	var selected_value: float = threshold - 1.0
	var relations: Dictionary = state.get("relations", {}) as Dictionary
	for raw_axis: Variant in relation_fields.keys():
		var axis: String = str(raw_axis)
		var value: float = float(relations.get(axis, 0.0))
		if value > selected_value:
			selected_axis = axis
			selected_value = value
	if selected_axis.is_empty():
		return {}
	return {"axis": selected_axis, "field": str(relation_fields[selected_axis]), "value": selected_value}


func _unlocked_distinct_kind_count(unlocked: Array[Dictionary]) -> int:
	var kinds: Dictionary = {}
	for activity: Dictionary in unlocked:
		kinds[str(activity.get("kind", ""))] = true
	return maxi(1, kinds.size())


func _generate_rivals(
	base_seed: int,
	tier: int,
	season_index: int,
	state: Dictionary,
	procedural_data: Dictionary,
	config_data: Dictionary,
	content_db: ContentDB
) -> Array[Dictionary]:
	var local_state: Dictionary = {
		"seed": DeterministicRNG.derive_seed(base_seed, tier, season_index, "rivals"),
		"rngCounter": 0,
	}
	var names: Array[String] = _string_array(procedural_data.get("rivalNames", FALLBACK_RIVAL_NAMES), FALLBACK_RIVAL_NAMES)
	var traits: Array[String] = _string_array(procedural_data.get("rivalTraits", FALLBACK_TRAITS), FALLBACK_TRAITS)
	var domains: Array[String] = []
	for challenge_activity: Dictionary in content_db.activities:
		if str(challenge_activity.get("kind", "")) != "challenge":
			continue
		var domain: String = _challenge_domain(challenge_activity)
		if not domains.has(domain):
			domains.append(domain)
	if domains.size() < 2:
		domains = FALLBACK_FIELDS.duplicate()
	var challenge_league: Dictionary = state.get("challengeLeague", {}) as Dictionary
	var previous_best: float = maxf(0.0, float(challenge_league.get("bestScore", 0.0)))
	var previous_best_weight: float = clampf(float(config_data.get("challengePreviousBestWeight", 0.94)), 0.0, 1.5)
	var challenge_baselines: Dictionary = {}
	var previous_best_by_challenge: Dictionary = {}
	for activity: Dictionary in content_db.activities:
		if str(activity.get("kind", "")) != "challenge":
			continue
		var activity_id: String = str(activity.get("id", ""))
		var activity_record: Dictionary = (state.get("challengeRecords", {}) as Dictionary).get(activity_id, {}) as Dictionary
		var activity_previous_best: float = maxf(0.0, float(activity_record.get("bestScore", 0.0)))
		var effective_previous_best: float = activity_previous_best if activity_previous_best > 0.0 else previous_best
		var activity_baseline: float = _challenge_player_score(state, activity, content_db, config_data)
		activity_baseline = maxf(activity_baseline, maxf(effective_previous_best * previous_best_weight, 20.0 + 2.0 * sqrt(float(tier - 1))))
		challenge_baselines[activity_id] = activity_baseline
		previous_best_by_challenge[activity_id] = effective_previous_best
	var runtime_jitter_min: float = float(config_data.get("challengeJitterMin", -5.0))
	var runtime_jitter_max: float = float(config_data.get("challengeJitterMax", 5.0))
	var runtime_jitter_span: float = maxf(0.1, runtime_jitter_max - runtime_jitter_min)
	var effective_win_rate_minimum: float = clampf(float(config_data.get("challengeEffectiveWinRateMinimum", 0.40)), 0.35, 0.80)
	var effective_win_rate_maximum: float = clampf(float(config_data.get("challengeEffectiveWinRateMaximum", 0.75)), effective_win_rate_minimum, 0.80)
	var easiest_score_delta: float = runtime_jitter_max - effective_win_rate_maximum * runtime_jitter_span
	var hardest_score_delta: float = runtime_jitter_max - effective_win_rate_minimum * runtime_jitter_span
	var season_pressure_points: float = _challenge_season_score_bonus(state, config_data)
	var raw_win_rates: Array = config_data.get("challengeLeagueWinRates", [0.80, 0.68, 0.58, 0.46, 0.35]) as Array
	var fallback_win_rates: Array[float] = [0.80, 0.68, 0.58, 0.46, 0.35]
	var trait_score_delta: float = maxf(0.0, float(config_data.get("challengeRivalTraitScoreDelta", 0.6)))
	var result: Array[Dictionary] = []
	var rival_count: int = clampi(int(config_data.get("generatedRivalCount", 5)), 1, 5)
	for rival_index: int in range(rival_count):
		var name: String = names[DeterministicRNG.range_int(local_state, 0, names.size() - 1, "rival_name_%d" % rival_index)]
		var strength: String = domains[DeterministicRNG.range_int(local_state, 0, domains.size() - 1, "strength")]
		var weakness: String = domains[DeterministicRNG.range_int(local_state, 0, domains.size() - 1, "weakness")]
		if weakness == strength:
			weakness = domains[(domains.find(weakness) + 1) % domains.size()]
		var personality: String = traits[DeterministicRNG.range_int(local_state, 0, traits.size() - 1, "trait")]
		var personality_index: int = maxi(0, traits.find(personality))
		var personality_score_delta: float = float(personality_index % 5 - 2) * 0.12
		var personality_modifier: float = 1.0 + personality_score_delta / 100.0
		var target_win_rate: float = clampf(float(raw_win_rates[rival_index]) if rival_index < raw_win_rates.size() else fallback_win_rates[rival_index], 0.0, 1.0)
		var league_score_delta: float = runtime_jitter_max - target_win_rate * runtime_jitter_span
		var jitter: float = DeterministicRNG.next_float(local_state, -0.2, 0.2, "score")
		var scores_by_challenge: Dictionary = {}
		var domains_by_challenge: Dictionary = {}
		var trait_modifiers_by_challenge: Dictionary = {}
		var score_total: float = 0.0
		for activity_id: Variant in challenge_baselines.keys():
			var challenge_activity: Dictionary = content_db.get_activity(str(activity_id))
			var challenge_domain: String = _challenge_domain(challenge_activity)
			var trait_delta: float = trait_score_delta if challenge_domain == strength else (-trait_score_delta if challenge_domain == weakness else 0.0)
			var specialized_score: float = maxf(1.0, float(challenge_baselines[activity_id]) + league_score_delta + trait_delta + personality_score_delta + jitter)
			var trait_modifier: float = specialized_score / maxf(1.0, float(challenge_baselines[activity_id]) + league_score_delta + jitter)
			scores_by_challenge[str(activity_id)] = snappedf(specialized_score, 0.01)
			domains_by_challenge[str(activity_id)] = challenge_domain
			trait_modifiers_by_challenge[str(activity_id)] = snappedf(trait_modifier, 0.0001)
			score_total += specialized_score
		var score: float = score_total / float(maxi(1, scores_by_challenge.size()))
		result.append({
			"id": "RIVAL_%d_%d" % [season_index, rival_index],
			"kind": "rival",
			"templateId": "league_rival",
			"name": name,
			"tier": tier,
			"seed": int(local_state.get("seed", 1)),
			"modifiers": [personality, strength, weakness],
			"reward": BigValue.zero(),
			"expirySeason": season_index + 1,
			"personality": personality,
			"personalityModifier": snappedf(personality_modifier, 0.0001),
			"targetWinRate": target_win_rate,
			"seasonScoreBonus": snappedf(season_pressure_points, 0.01),
			"strength": strength,
			"weakness": weakness,
			"score": snappedf(score, 0.01),
			"scoresByChallenge": scores_by_challenge,
			"challengeDomains": domains_by_challenge,
			"traitModifiersByChallenge": trait_modifiers_by_challenge,
			"leagueRank": rival_index + 1,
			"leagueTier": rival_index + 1,
			"seasonIndex": season_index,
			"previousBestScore": snappedf(previous_best, 0.01),
			"previousBestByChallenge": previous_best_by_challenge.duplicate(true),
		})
	# Traits remain mechanical, but their final score must still honor both the
	# strict league order and the configured real win-rate band.
	for activity_id: Variant in challenge_baselines.keys():
		var previous_score: float = 0.0
		var maximum_feasible_step: float = maxf(0.01, (hardest_score_delta - easiest_score_delta) / float(maxi(1, result.size() - 1)))
		var minimum_step: float = minf(maxf(0.01, float(config_data.get("challengeLeagueMinimumScoreStep", 0.25))), maximum_feasible_step)
		for rival_index: int in range(result.size()):
			var rival: Dictionary = result[rival_index]
			var rival_scores: Dictionary = rival.get("scoresByChallenge", {}) as Dictionary
			var current_score: float = float(rival_scores.get(str(activity_id), 1.0))
			var baseline: float = float(challenge_baselines[activity_id])
			var feasible_minimum: float = maxf(1.0, baseline + easiest_score_delta + float(rival_index) * minimum_step)
			var feasible_maximum: float = maxf(feasible_minimum, baseline + hardest_score_delta - float(result.size() - 1 - rival_index) * minimum_step)
			current_score = clampf(current_score, feasible_minimum, feasible_maximum)
			if previous_score > 0.0:
				current_score = maxf(current_score, previous_score + minimum_step)
			rival_scores[str(activity_id)] = snappedf(current_score, 0.01)
			var effective_rates: Dictionary = rival.get("effectiveWinRatesByChallenge", {}) as Dictionary
			var effective_rate: float = clampf((runtime_jitter_max - (current_score - baseline)) / runtime_jitter_span, 0.0, 1.0)
			effective_rates[str(activity_id)] = snappedf(effective_rate, 0.001)
			rival["effectiveWinRatesByChallenge"] = effective_rates
			previous_score = current_score
	for rival: Dictionary in result:
		var total: float = 0.0
		for raw_score: Variant in (rival.get("scoresByChallenge", {}) as Dictionary).values():
			total += float(raw_score)
		rival["score"] = snappedf(total / float(maxi(1, (rival.get("scoresByChallenge", {}) as Dictionary).size())), 0.01)
	return result


func _generate_region(
	base_seed: int,
	tier: int,
	season_index: int,
	unlocked: Array[Dictionary],
	procedural_data: Dictionary,
	config_data: Dictionary,
	preferred_activity_id: String = ""
) -> Dictionary:
	var local_state: Dictionary = {
		"seed": DeterministicRNG.derive_seed(base_seed, tier, season_index, "region:%s" % preferred_activity_id),
		"rngCounter": 0,
	}
	var prefixes: Array[String] = _string_array(procedural_data.get("prefixes", FALLBACK_PREFIXES), FALLBACK_PREFIXES)
	var traits: Array[String] = _string_array(procedural_data.get("regionTraits", FALLBACK_TRAITS), FALLBACK_TRAITS)
	var adventures: Array[Dictionary] = _activities_of_kind(unlocked, "adventure")
	var unlocked_adventure_ids: Dictionary = {}
	for adventure: Dictionary in adventures:
		unlocked_adventure_ids[str(adventure.get("id", ""))] = true
	var eligible_regions: Array[Dictionary] = []
	for raw_region: Variant in procedural_data.get("regionDetails", []) as Array:
		if raw_region is Dictionary and int((raw_region as Dictionary).get("minimumWorldTier", 1)) <= tier and unlocked_adventure_ids.has(str((raw_region as Dictionary).get("baseActivityId", ""))):
			eligible_regions.append(raw_region as Dictionary)
	var selected_region: Dictionary = {}
	if not preferred_activity_id.is_empty():
		for candidate: Dictionary in eligible_regions:
			if str(candidate.get("baseActivityId", "")) == preferred_activity_id:
				selected_region = candidate
				break
	if selected_region.is_empty() and not eligible_regions.is_empty() and preferred_activity_id.is_empty():
		selected_region = eligible_regions[DeterministicRNG.range_int(local_state, 0, eligible_regions.size() - 1, "region_base")]
	var base_activity_id: String = ""
	if not selected_region.is_empty():
		base_activity_id = str(selected_region.get("baseActivityId", base_activity_id))
	elif not preferred_activity_id.is_empty() and unlocked_adventure_ids.has(preferred_activity_id):
		base_activity_id = preferred_activity_id
	elif not adventures.is_empty():
		base_activity_id = str(adventures[DeterministicRNG.range_int(local_state, 0, adventures.size() - 1, "region_activity")].get("id", base_activity_id))
	var base_region_id: String = str(selected_region.get("id", "REG_%s" % base_activity_id if not base_activity_id.is_empty() else "REG_LOCKED"))
	var base_region_name: String = str(selected_region.get("name", FALLBACK_REGIONS[0] if not base_activity_id.is_empty() else "미해금 탐사 구역"))
	var trait_index: int = DeterministicRNG.range_int(local_state, 0, traits.size() - 1, "region_trait")
	var trait_name: String = traits[trait_index]
	var region_profiles: Array[Dictionary] = _dictionary_array(procedural_data.get("regionModifierProfiles", []))
	if region_profiles.is_empty():
		region_profiles = [{"enemyScale": 1.0, "rewardScale": 1.0, "lootBonusRolls": 0}]
	var modifier_profile: Dictionary = region_profiles[trait_index % region_profiles.size()].duplicate(true)
	var enemy_name_parts: Dictionary = procedural_data.get("enemyNameParts", {}) as Dictionary
	var enemy_prefixes := _string_array(enemy_name_parts.get("prefixes", []), ["미지의"])
	var enemy_cores := _string_array(enemy_name_parts.get("cores", []), ["수호체"])
	var enemy_titles := _string_array(enemy_name_parts.get("titles", []), ["개체"])
	var enemy_variant_name := "%s %s %s" % [
		enemy_prefixes[DeterministicRNG.range_int(local_state, 0, enemy_prefixes.size() - 1, "enemy_prefix")],
		enemy_cores[DeterministicRNG.range_int(local_state, 0, enemy_cores.size() - 1, "enemy_core")],
		enemy_titles[DeterministicRNG.range_int(local_state, 0, enemy_titles.size() - 1, "enemy_title")],
	]
	var enemy_traits: Array[Dictionary] = _dictionary_array(procedural_data.get("enemyTraits", []))
	var enemy_trait: Dictionary = enemy_traits[DeterministicRNG.range_int(local_state, 0, enemy_traits.size() - 1, "enemy_trait")].duplicate(true) if not enemy_traits.is_empty() else {}
	var reward_fragments := _string_array(procedural_data.get("rewardFragments", []), ["탐사 보급품"])
	var reward_fragment: String = reward_fragments[DeterministicRNG.range_int(local_state, 0, reward_fragments.size() - 1, "reward_fragment")]
	return {
		"id": "REGION_%d_%d" % [season_index, tier],
		"kind": "region_variant",
		"templateId": base_activity_id,
		"baseRegionId": base_region_id,
		"baseRegionName": base_region_name,
		"tier": tier,
		"seed": int(local_state.get("seed", 1)),
		"name": "%s %s" % [prefixes[DeterministicRNG.range_int(local_state, 0, prefixes.size() - 1, "region_prefix")], base_region_name],
		"modifiers": [trait_name],
		"modifierProfile": modifier_profile,
		"enemyVariant": {
			"name": enemy_variant_name,
			"traitId": str(enemy_trait.get("id", "")),
			"traitName": str(enemy_trait.get("name", "")),
			"hpMultiplier": float(enemy_trait.get("hpMultiplier", 1.0)),
			"attackMultiplier": float(enemy_trait.get("attackMultiplier", 1.0)),
			"magicMultiplier": float(enemy_trait.get("magicMultiplier", 1.0)),
			"defenseMultiplier": float(enemy_trait.get("defenseMultiplier", 1.0)),
			"magicDefenseMultiplier": float(enemy_trait.get("magicDefenseMultiplier", 1.0)),
			"rewardMultiplier": float(enemy_trait.get("rewardMultiplier", 1.0)),
		},
		"rewardFragment": reward_fragment,
		"active": not base_activity_id.is_empty(),
		"reward": BigValue.multiply(BigValue.from_number(600), BigValue.pow_base(maxf(1.0, float(config_data.get("activityRewardTierGrowth", 1.13))), tier - 1)),
		"expirySeason": season_index + 1,
		"nodes": 3,
	}


func _unlocked_activities(state: Dictionary, activities: Array[Dictionary]) -> Array[Dictionary]:
	var planner: Planner = Planner.new()
	var result: Array[Dictionary] = []
	for activity: Dictionary in activities:
		if planner.requirements_met(state, activity.get("requires", {}) as Dictionary):
			result.append(activity)
	if result.is_empty():
		for activity: Dictionary in activities:
			if str(activity.get("id", "")) == "REST_HOME":
				result.append(activity)
				break
	return result


func _template_satisfiable(template: Dictionary, unlocked: Array[Dictionary]) -> bool:
	if unlocked.is_empty():
		return false
	var required_kind: String = str(template.get("requiredKind", ""))
	return required_kind.is_empty() or not _activities_of_kind(unlocked, required_kind).is_empty()


func _modifier_detail(procedural_data: Dictionary, modifier_id: String) -> Dictionary:
	for raw_detail: Variant in procedural_data.get("modifierDetails", []) as Array:
		if raw_detail is Dictionary and str((raw_detail as Dictionary).get("id", "")) == modifier_id:
			return raw_detail as Dictionary
	return {}


func _activities_of_kind(activities: Array[Dictionary], kind: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for activity: Dictionary in activities:
		if str(activity.get("kind", "")) == kind:
			result.append(activity)
	return result


func _activities_with_tag(activities: Array[Dictionary], tag: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for activity: Dictionary in activities:
		if (activity.get("tags", []) as Array).has(tag):
			result.append(activity)
	return result


func _result_has_template(entries: Array[Dictionary], template_id: String) -> bool:
	for entry: Dictionary in entries:
		if str(entry.get("templateId", "")) == template_id:
			return true
	return false


func _result_has_contract_id(entries: Array[Dictionary], contract_id: String) -> bool:
	if contract_id.is_empty():
		return false
	for entry: Dictionary in entries:
		if str(entry.get("id", "")) == contract_id:
			return true
	return false


func _contract_description(template: Dictionary, template_kind: String, target: Dictionary, target_count: int) -> String:
	var target_name: String = str(target.get("name", "선택 활동"))
	var detail: String
	match template_kind:
		"gain_stat":
			detail = "%s로 %s 성장량 %d을 달성한다." % [target_name, _stat_display_name(str(target.get("primaryStat", ""))), target_count]
		"earn_gold":
			detail = "%s로 골드 %d을 획득한다." % [target_name, target_count]
		"relation_gain":
			detail = "%s로 관계 점수 %d을 높인다." % [target_name, target_count]
		"balanced_cycle":
			detail = "서로 다른 활동 종류 %d개를 조합한다." % target_count
		"win_challenge":
			detail = "%s에서 %d회 승리한다." % [target_name, target_count]
		"clear_adventure":
			detail = "%s를 %d회 클리어한다." % [target_name, target_count]
		"master_activity":
			detail = "%s 숙련을 %d회 누적한다." % [target_name, target_count]
		_:
			detail = "%s 활동을 %d회 완수한다." % [target_name, target_count]
	var template_description: String = str(template.get("descriptionTemplate", "")).strip_edges()
	return detail if template_description.is_empty() else "%s %s" % [template_description, detail]


func _stat_display_name(stat_key: String) -> String:
	const DISPLAY_NAMES: Dictionary = {
		"stamina": "체력", "strength": "근력", "intelligence": "지력", "refinement": "기품",
		"sensitivity": "감수성", "style": "스타일", "discipline": "절제", "morals": "도덕",
		"faith": "신앙", "combat": "전투", "magic": "마법", "etiquette": "예절",
		"communication": "소통", "art": "예술", "cooking": "요리", "housework": "생활",
		"nursing": "간호", "dance": "무용", "reputation": "평판",
	}
	return str(DISPLAY_NAMES.get(stat_key, "능력치" if stat_key.is_empty() else stat_key))


func _dictionary_array(raw: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if raw is Array:
		for entry: Variant in raw as Array:
			if entry is Dictionary:
				result.append((entry as Dictionary).duplicate(true))
	return result


func _string_array(raw: Variant, fallback: Array[String]) -> Array[String]:
	var result: Array[String] = []
	if raw is Array:
		for entry: Variant in raw as Array:
			var text: String = str(entry).strip_edges()
			if not text.is_empty():
				result.append(text)
	return result if not result.is_empty() else fallback.duplicate()


func _player_effective_score(state: Dictionary) -> float:
	var score: float = 0.0
	var stats: Dictionary = state.get("stats", {}) as Dictionary
	for raw_value: Variant in stats.values():
		var value: float = maxf(0.0, float(raw_value))
		score += 100.0 * log(1.0 + value / 100.0)
	return maxf(20.0, score / float(maxi(1, stats.size())))


func _challenge_player_score(state: Dictionary, activity: Dictionary, content_db: ContentDB, config_data: Dictionary) -> float:
	var score: float = 0.0
	for raw_key: Variant in (activity.get("challengeWeights", {}) as Dictionary).keys():
		var key: String = str(raw_key)
		var raw_value: float = 0.0
		if (state.get("stats", {}) as Dictionary).has(key):
			raw_value = float((state.get("stats", {}) as Dictionary).get(key, 0.0))
		elif (state.get("meters", {}) as Dictionary).has(key):
			raw_value = float((state.get("meters", {}) as Dictionary).get(key, 0.0))
		score += 100.0 * log(1.0 + maxf(0.0, raw_value) / 100.0) * float((activity.get("challengeWeights", {}) as Dictionary)[raw_key])
	score += _state_gear_score(state, content_db, config_data)
	score += 2.0 * sqrt(maxf(0.0, float((state.get("mastery", {}) as Dictionary).get(str(activity.get("id", "")), 0.0))))
	score += _challenge_season_score_bonus(state, config_data)
	return maxf(1.0, score)


func _challenge_score_feasibility(state: Dictionary, unlocked: Array[Dictionary], rivals: Array[Dictionary], content_db: ContentDB, config_data: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var league_tier := clampi(int((state.get("challengeLeague", {}) as Dictionary).get("leagueTier", 1)), 1, 5)
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var tier_scale := 1.0 + maxf(0.0, float(config_data.get("growthTierSqrtRate", 0.04))) * sqrt(float(tier - 1))
	var base_weight := clampf(float(config_data.get("challengeBaseDifficultyWeight", 0.35)), 0.0, 1.0)
	var schedule: Dictionary = config_data.get("challengeScheduleSlots", {}) as Dictionary
	var slots_per_season := maxi(1, int(config_data.get("slotsPerSeason", 28)))
	var total_slot := maxi(0, int((state.get("time", {}) as Dictionary).get("slot", 0)))
	var season_base := int(total_slot / slots_per_season) * slots_per_season
	var next_slot_in_season := total_slot % slots_per_season + 1
	for activity: Dictionary in unlocked:
		if str(activity.get("kind", "")) != "challenge":
			continue
		var activity_id := str(activity.get("id", ""))
		if not schedule.has(activity_id):
			result[activity_id] = false
			continue
		var completion_slot := season_base + int(schedule[activity_id]) + maxi(1, int(activity.get("durationSlots", 1))) - 1
		var exact_jitter := DeterministicRNG.challenge_jitter(
			int(state.get("seed", 1)),
			completion_slot,
			activity_id,
			float(config_data.get("challengeJitterMin", -5.0)),
			float(config_data.get("challengeJitterMax", 5.0))
		)
		var player_floor := _challenge_player_score(state, activity, content_db, config_data) + exact_jitter
		var activity_floor := maxf(1.0, float(activity.get("baseDifficulty", 100.0))) * tier_scale * base_weight
		# Every resolved challenge moves the league by one tier. A later target must
		# therefore survive any opponent tier reachable through the scheduled
		# challenges before it, not only the tier held when contracts are generated.
		var prior_challenges := 0
		var target_schedule_slot := int(schedule[activity_id])
		for candidate: Dictionary in unlocked:
			if str(candidate.get("kind", "")) != "challenge":
				continue
			var candidate_id := str(candidate.get("id", ""))
			if schedule.has(candidate_id):
				var candidate_slot := int(schedule[candidate_id])
				if candidate_slot >= next_slot_in_season and candidate_slot < target_schedule_slot:
					prior_challenges += 1
		var minimum_league := maxi(1, league_tier - prior_challenges)
		var maximum_league := mini(5, league_tier + prior_challenges)
		var rival_score := activity_floor
		for rival: Dictionary in rivals:
			var rival_league := int(rival.get("leagueTier", rival.get("leagueRank", 0)))
			if rival_league < minimum_league or rival_league > maximum_league:
				continue
			var rival_scores: Dictionary = rival.get("scoresByChallenge", {}) as Dictionary
			rival_score = maxf(rival_score, float(rival_scores.get(activity_id, rival.get("score", activity_floor))))
		var difficulty := maxf(1.0, maxf(activity_floor, rival_score))
		result[activity_id] = player_floor + 0.0001 >= difficulty
	return result


func _challenge_season_score_bonus(state: Dictionary, config_data: Dictionary) -> float:
	var time: Dictionary = state.get("time", {}) as Dictionary
	var seasons_per_year: int = maxi(1, int(config_data.get("seasonsPerYear", 4)))
	var season_index: int = (int(time.get("year", 1)) - 1) * seasons_per_year + int(time.get("season", 1))
	var jitter_span: float = maxf(0.1, float(config_data.get("challengeJitterMax", 5.0)) - float(config_data.get("challengeJitterMin", -5.0)))
	return maxf(0.0, float(config_data.get("challengeSeasonDifficultyRate", 0.01))) * sqrt(float(maxi(0, season_index - 1))) * jitter_span


func _challenge_domain(activity: Dictionary) -> String:
	var weights: Dictionary = activity.get("challengeWeights", {}) as Dictionary
	var domain_scores: Dictionary = {
		"무예": float(weights.get("strength", 0.0)) + float(weights.get("combat", 0.0)) + float(weights.get("stamina", 0.0)) * 0.7,
		"학문": float(weights.get("intelligence", 0.0)) + float(weights.get("discipline", 0.0)) * 0.4,
		"예술": float(weights.get("art", 0.0)) + float(weights.get("dance", 0.0)) + float(weights.get("style", 0.0)) + float(weights.get("sensitivity", 0.0)) * 0.5,
		"돌봄": float(weights.get("nursing", 0.0)) + float(weights.get("morals", 0.0)) * 0.4,
		"탐험": float(weights.get("stamina", 0.0)) * 0.4 + float(weights.get("combat", 0.0)) * 0.3,
		"외교": float(weights.get("communication", 0.0)) + float(weights.get("etiquette", 0.0)) + float(weights.get("refinement", 0.0)),
		"생활": float(weights.get("cooking", 0.0)) + float(weights.get("housework", 0.0)),
		"마법": float(weights.get("magic", 0.0)) + float(weights.get("faith", 0.0)) * 0.3,
	}
	var selected: String = "학문"
	var selected_score: float = -1.0
	for raw_domain: Variant in domain_scores.keys():
		var domain: String = str(raw_domain)
		var score: float = float(domain_scores[raw_domain])
		if score > selected_score:
			selected = domain
			selected_score = score
	return selected


func _state_gear_score(state: Dictionary, content_db: ContentDB, config_data: Dictionary) -> float:
	var total: float = 0.0
	for raw_id: Variant in (state.get("equipment", {}) as Dictionary).values():
		if raw_id == null:
			continue
		var item_id: String = str(raw_id)
		var enhancement_level: int = 1
		for raw_stack: Variant in state.get("inventory", []) as Array:
			if raw_stack is Dictionary and str((raw_stack as Dictionary).get("id", "")) == item_id:
				enhancement_level = maxi(1, int((raw_stack as Dictionary).get("enhancementLevel", 1)))
				break
		var enhancement_scale: float = 1.0 + maxf(0.0, float(config_data.get("equipmentModifierSqrtRate", 0.08))) * sqrt(float(enhancement_level - 1))
		total += float((content_db.get_item(item_id).get("modifiers", {}) as Dictionary).get("gearScore", 0.0)) * enhancement_scale
	return total
