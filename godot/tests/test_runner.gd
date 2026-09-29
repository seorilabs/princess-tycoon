extends SceneTree

const EXPECTED_ACTIVITY_KINDS: Dictionary = {
	"education": 15,
	"job": 11,
	"rest": 4,
	"adventure": 5,
	"challenge": 8,
}

var _failures: Array[String] = []
var _passes: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[TEST] Princess Tycoon core acceptance suite")
	var content_db: ContentDB = ContentDB.new()
	var report: Dictionary = content_db.load_all("res://data")
	_check(bool(report.get("ok", false)), "AC-ACT/CONTENT 데이터베이스 스키마 로드")

	_test_content_counts(content_db)
	_test_growth_profile_ssot(content_db)
	_test_big_value(content_db)
	_test_rng_and_thousand_slot_determinism()
	_test_planner_constraints(content_db)
	_test_challenge_schedule_and_hints(content_db)
	_test_mastery_milestones(content_db)
	_test_manual_activity_execution()
	_test_offline_cap_and_rollback()
	_test_event_expiry_boundary(content_db)
	_test_save_codec()
	_test_procedural_generation(content_db)
	_test_adventure_and_challenge(content_db)
	_test_contract_semantics(content_db)
	_test_extended_infinite_rules(content_db)
	_test_audit_regressions(content_db)
	_test_relationship_system(content_db)
	_test_shop_non_terminal()
	_test_career_non_terminal()

	_finish()


func _test_audit_regressions(content_db: ContentDB) -> void:
	var challenge_mastery_tables_valid := true
	for activity: Dictionary in content_db.get_activities():
		if str(activity.get("kind", "")) != "challenge":
			continue
		var mastery_values: Array[int] = []
		for raw_reward: Variant in activity.get("rewardTable", []) as Array:
			if raw_reward is Dictionary:
				mastery_values.append(int((raw_reward as Dictionary).get("mastery", 0)))
		challenge_mastery_tables_valid = challenge_mastery_tables_valid and mastery_values == [1, 3, 5]
	_check(challenge_mastery_tables_valid, "도전 8종 rewardTable 숙련 경험치 1/3/5 정합")

	var fresh_state := StateFactory.create(701001, "기본 상태", content_db.config)
	var repaired_state := StateFactory.ensure_v2_shape({"schemaVersion": 2, "seed": 701002, "generatedContent": {}})
	_check(str((fresh_state.get("generatedContent", {}) as Dictionary).get("pinnedContractId", "missing")) == "" and str((repaired_state.get("generatedContent", {}) as Dictionary).get("pinnedContractId", "missing")) == "", "StateFactory generatedContent pin 기본·보정")

	var generator := ProceduralGenerator.new()
	var descriptor_state := _rich_state(701003, "descriptor")
	var generated := generator.generate(descriptor_state, content_db)
	var descriptor_fields := ["kind", "templateId", "tier", "seed", "modifiers", "reward", "expirySeason"]
	var descriptors_valid := true
	for raw_contract: Variant in generated.get("contracts", []) as Array:
		if raw_contract is not Dictionary:
			descriptors_valid = false
			continue
		var contract := raw_contract as Dictionary
		descriptors_valid = descriptors_valid and contract.has("tracking") and contract.has("modifierRequirements")
		for field_name: String in descriptor_fields:
			descriptors_valid = descriptors_valid and contract.has(field_name)
	for raw_rival: Variant in generated.get("rivals", []) as Array:
		if raw_rival is not Dictionary:
			descriptors_valid = false
			continue
		for field_name: String in descriptor_fields:
			descriptors_valid = descriptors_valid and (raw_rival as Dictionary).has(field_name)
	var region_descriptor := generated.get("region", {}) as Dictionary
	var enemy_variant := region_descriptor.get("enemyVariant", {}) as Dictionary
	_check(descriptors_valid, "생성 계약·라이벌 공통 descriptor와 계약 tracking 즉시 생성")
	_check(not str(enemy_variant.get("name", "")).is_empty() and not str(enemy_variant.get("traitName", "")).is_empty() and not str(region_descriptor.get("rewardFragment", "")).is_empty(), "지역 적 이름·특성·보상 조각 결정적 descriptor")

	var count_db := ContentDB.new()
	count_db.load_all("res://data")
	count_db.config["generatedContractCount"] = 2
	count_db.config["generatedRivalCount"] = 3
	var counted := generator.generate(StateFactory.create(701004, "count", count_db.config), count_db)
	_check((counted.get("contracts", []) as Array).size() == 2 and (counted.get("rivals", []) as Array).size() == 3, "생성 계약·라이벌 수 config SSOT")

	var planner_config := content_db.config.duplicate(true)
	planner_config["activityCostTierGrowth"] = 2.0
	planner_config["activityRewardTierGrowth"] = 3.0
	var planner := Planner.new()
	planner.configure(planner_config)
	_check(absf(BigValue.to_float(planner.tier_cost({"baseCost": 10}, 3)) - 40.0) < 0.001 and absf(BigValue.to_float(planner.tier_reward({"baseReward": 10}, 3)) - 90.0) < 0.001, "비용·보상 tier growth config SSOT")

	var late_state := _rich_state(701005, "late contract")
	(late_state.get("time", {}) as Dictionary)["slot"] = 27
	var late_generated := generator.generate(late_state, content_db)
	var late_targets_fit := true
	for raw_contract: Variant in late_generated.get("contracts", []) as Array:
		late_targets_fit = late_targets_fit and int((raw_contract as Dictionary).get("targetDurationSlots", 99)) <= 1
	_check(late_targets_fit, "시즌 잔여 1 slot보다 긴 계약 목표 제외")

	var final_low_state := _rich_state(701051, "final low modifier")
	(final_low_state.get("time", {}) as Dictionary)["slot"] = 27
	(final_low_state.get("meters", {}) as Dictionary)["energy"] = 20.0
	var final_magic := content_db.get_activity("EDU_MAGIC")
	var final_magic_plan: Dictionary = generator.call("_target_completion_plan", final_low_state, final_magic, content_db.activities, content_db.config, 28, "gain_stat")
	var final_low_compatible: bool = bool(generator.call("_modifier_compatible", "low_energy", final_magic, "education", "gain_stat", 1, final_low_state, content_db.activities, content_db.config, 28, {"minimumEnergy": 25}, final_magic_plan))
	_check(not final_low_compatible, "final slot 목표 종료 에너지 미달 low_energy 조합 제외")

	var expedition_state := _rich_state(701052, "expedition modifier")
	var expedition := content_db.get_activity("CH_LEAGUE_EXPEDITION")
	var expedition_plan: Dictionary = generator.call("_target_completion_plan", expedition_state, expedition, content_db.activities, content_db.config, 1, "win_challenge")
	var expedition_low: bool = bool(generator.call("_modifier_compatible", "low_energy", expedition, "challenge", "win_challenge", 1, expedition_state, content_db.activities, content_db.config, 1, {"minimumEnergy": 25}, expedition_plan))
	var expedition_stress: bool = bool(generator.call("_modifier_compatible", "stress_guard", expedition, "challenge", "win_challenge", 1, expedition_state, content_db.activities, content_db.config, 1, {"respectMaxStress": true}, expedition_plan))
	var expedition_limited: bool = bool(generator.call("_modifier_compatible", "limited_slots", expedition, "challenge", "win_challenge", 1, expedition_state, content_db.activities, content_db.config, 1, {"slotMultiplier": 1.5}, expedition_plan))
	var expedition_risk: bool = bool(generator.call("_modifier_compatible", "risk_bonus", expedition, "challenge", "win_challenge", 1, expedition_state, content_db.activities, content_db.config, 1, {"minimumRisk": 0.2, "allowInjury": false}, expedition_plan))
	_check(not expedition_low and not expedition_stress and not expedition_limited and not expedition_risk, "예정 도전 연쇄의 low/stress/limited/risk 불가 modifier 제외")

	var capped_relation_state := _rich_state(701053, "relation cap")
	for relation_axis: String in ["guardian", "steward", "rival", "citizens"]:
		(capped_relation_state.get("relations", {}) as Dictionary)[relation_axis] = 1000.0
	var relation_template := {"id": "community_support", "kind": "relation_gain", "requiredKind": "job", "baseTarget": 20}
	var capped_relation_targets: Array = generator.call("_eligible_contract_targets", relation_template, content_db.activities, content_db.config, 1, capped_relation_state) as Array
	_check(capped_relation_targets.is_empty(), "관계 4축 cap 상태 relation_gain 목표 제외")

	var same_day_win_state := _rich_state(701054, "same day challenge")
	(same_day_win_state.get("time", {}) as Dictionary)["slot"] = 3
	var same_day_targets: Array = generator.call("_eligible_contract_targets", {"id": "win_challenge", "kind": "win_challenge", "requiredKind": "challenge"}, content_db.activities, content_db.config, 4, same_day_win_state) as Array
	_check(not same_day_targets.has(content_db.get_activity("CH_EXAM_ACADEMY")), "생성 당일 단일 시도 win_challenge 제외")
	var exact_win_state := StateFactory.create(81006, "exact challenge", content_db.config)
	(exact_win_state.get("bigValues", {}) as Dictionary)["gold"] = BigValue.from_number(1000)
	(exact_win_state.get("growthPolicy", {}) as Dictionary)["reserveGold"] = BigValue.from_number(900)
	exact_win_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	var exact_generated: Dictionary = generator.generate(exact_win_state, content_db)
	var academy_contract: Dictionary = {}
	for raw_contract: Variant in exact_generated.get("contracts", []) as Array:
		if raw_contract is Dictionary:
			var contract := raw_contract as Dictionary
			if str(contract.get("kind", "")) == "win_challenge" and (contract.get("targetActivityIds", []) as Array).has("CH_EXAM_ACADEMY"):
				academy_contract = contract
				break
	exact_win_state["generatedContent"] = exact_generated
	(exact_win_state.get("generatedContent", {}) as Dictionary)["pinnedContractId"] = str(academy_contract.get("id", ""))
	var academy_won := false
	for _step: int in range(5):
		exact_win_state["activityQueue"] = ["CH_EXAM_ACADEMY"]
		var exact_engine := GameEngine.new()
		exact_engine.initialize_from_state(exact_win_state)
		var exact_advance := exact_engine.advance_slots(1)
		for raw_completed: Variant in exact_advance.get("completedActivities", []) as Array:
			if raw_completed is Dictionary and str((raw_completed as Dictionary).get("activityId", "")) == "CH_EXAM_ACADEMY":
				academy_won = bool(((raw_completed as Dictionary).get("outcome", {}) as Dictionary).get("won", false))
		exact_win_state = exact_engine.get_state()
	var academy_contract_completed := false
	for raw_contract: Variant in (exact_win_state.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array:
		if raw_contract is Dictionary and str((raw_contract as Dictionary).get("id", "")) == str(academy_contract.get("id", "")):
			academy_contract_completed = str((raw_contract as Dictionary).get("status", "")) == "completed"
	_check(not academy_contract.is_empty() and academy_won and academy_contract_completed, "예정 완료 slot exact jitter 판정과 실제 도전 승리 계약 완료 일치")

	var late_clear_state := StateFactory.create(701055, "late clear", content_db.config)
	(late_clear_state.get("time", {}) as Dictionary)["slot"] = 25
	(late_clear_state.get("stats", {}) as Dictionary)["stamina"] = 70.0
	var late_unlocked: Array[Dictionary] = generator.call("_unlocked_activities", late_clear_state, content_db.activities)
	var late_clear_targets: Array = generator.call("_eligible_contract_targets", {"id": "clear_adventure", "kind": "clear_adventure", "requiredKind": "adventure"}, late_unlocked, content_db.config, 26, late_clear_state) as Array
	_check(late_clear_targets.is_empty(), "시즌 내 단일 시도만 남은 clear_adventure 제외")
	var no_completion_state := _rich_state(7010551, "no completion window")
	(no_completion_state.get("time", {}) as Dictionary)["slot"] = 27
	no_completion_state["activeTask"] = _manual_task("ADV_RIFT", 6, 1)
	var no_completion_contracts: Array = generator.generate(no_completion_state, content_db).get("contracts", []) as Array
	_check(no_completion_contracts.is_empty(), "시즌 내 완료 activity가 없으면 target0 fallback 계약을 만들지 않음")

	var forced_db := ContentDB.new()
	forced_db.load_all("res://data")
	forced_db.config["generatedContractCount"] = 1
	forced_db.procedural["contractTemplates"] = [{"id": "forced_rest", "kind": "complete_kind", "requiredKind": "rest", "baseTarget": 1, "baseReward": 100, "weight": 1.0}]
	forced_db.procedural["modifiers"] = ["low_energy"]
	forced_db.procedural["modifierCount"] = {"base": 1, "tierDivisor": 999999, "minimum": 1, "maximum": 1}
	forced_db.procedural["bonusObjectives"] = []
	var forced_state := StateFactory.create(701056, "forced reducer", forced_db.config)
	(forced_state.get("time", {}) as Dictionary)["slot"] = 27
	(forced_state.get("meters", {}) as Dictionary)["energy"] = 20.0
	forced_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	forced_state["generatedContent"] = generator.generate(forced_state, forced_db)
	var forced_contract := (((forced_state.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array)[0] as Dictionary)
	var forced_engine := GameEngine.new()
	forced_engine.initialize_from_state(forced_state)
	forced_engine.get_content_db().procedural = forced_db.procedural.duplicate(true)
	var forced_advance := forced_engine.advance_slots(1)
	var forced_reviews: Array = forced_advance.get("seasonReviews", []) as Array
	_check((forced_contract.get("modifiers", []) as Array).has("low_energy") and not forced_reviews.is_empty() and int((forced_reviews[0] as Dictionary).get("completedContracts", 0)) == 1, "final slot low_energy 계약 실제 reducer 1회 완주")

	var value_db := ContentDB.new()
	value_db.load_all("res://data")
	value_db.config["generatedContractCount"] = 1
	value_db.procedural["contractTemplates"] = [{"id": "forced_gold", "kind": "earn_gold", "requiredKind": "job", "baseTarget": 600, "baseReward": 100, "weight": 1.0}]
	value_db.procedural["modifiers"] = []
	value_db.procedural["modifierCount"] = {"base": 0, "tierDivisor": 1, "minimum": 0, "maximum": 0}
	value_db.procedural["bonusObjectives"] = []
	var value_state := _rich_state(701057, "normal value")
	value_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	var value_contract := ((generator.generate(value_state, value_db).get("contracts", []) as Array)[0] as Dictionary)
	var value_activity := value_db.get_activity(str((value_contract.get("targetActivityIds", []) as Array)[0]))
	var one_action_gold := float(generator.call("_contract_value_progress_floor", "earn_gold", value_state, value_activity, value_db.config))
	_check(float(value_contract.get("target", 0.0)) > one_action_gold, "정상 시즌 value 계약은 안전 범위에서 1회 목표로 과도 축소하지 않음")

	var generated_matrix_reachable := true
	for reach_seed: int in range(64):
		var reach_state := _rich_state(702000 + reach_seed, "reachability matrix")
		match reach_seed % 4:
			0:
				(reach_state.get("time", {}) as Dictionary)["slot"] = 27
				(reach_state.get("meters", {}) as Dictionary)["energy"] = 20.0 + float(reach_seed % 12)
			1:
				for relation_axis: String in ["guardian", "steward", "rival", "citizens"]:
					(reach_state.get("relations", {}) as Dictionary)[relation_axis] = 1000.0
			2:
				(reach_state.get("growthPolicy", {}) as Dictionary)["bannedTags"] = ["study", "job", "rest", "adventure"]
			3:
				(reach_state.get("growthPolicy", {}) as Dictionary)["maxStress"] = 0.0
		var reach_generated := generator.generate(reach_state, content_db)
		for raw_contract: Variant in reach_generated.get("contracts", []) as Array:
			if raw_contract is not Dictionary or not _contract_reachable_by_generator_plan(raw_contract as Dictionary, reach_state, content_db, generator):
				if generated_matrix_reachable:
					print("[TEST] reachability mismatch seed=%d contract=%s" % [702000 + reach_seed, JSON.stringify(raw_contract)])
				generated_matrix_reachable = false
	_check(generated_matrix_reachable, "64 seed/state 생성 계약 base·modifier completion plan 도달 가능")
	var stress_state := _rich_state(701006, "stress contract")
	(stress_state.get("time", {}) as Dictionary)["slot"] = 26
	(stress_state.get("meters", {}) as Dictionary)["stress"] = 96.0
	(stress_state.get("growthPolicy", {}) as Dictionary)["maxStress"] = 72.0
	var stress_target := {"id": "TEST_STRESS", "durationSlots": 1, "stressDelta": 30.0}
	var stress_reachable: bool = bool(generator.call("_stress_path_reachable", stress_state, content_db.activities, stress_target, "complete_kind", 1, content_db.config, 27, 72.0))
	_check(not stress_reachable, "stress_guard는 목표·회복 전체 완료 경로를 검사")

	var event_state := StateFactory.create(701007, "event", content_db.config)
	(event_state.get("bigValues", {}) as Dictionary)["gold"] = BigValue.from_number(100)
	(event_state.get("bigValues", {}) as Dictionary)["lifetimeGold"] = BigValue.from_number(100)
	(event_state.get("bigValues", {}) as Dictionary)["renown"] = BigValue.from_number(250)
	(event_state.get("bigValues", {}) as Dictionary)["lifetimeRenown"] = BigValue.from_number(250)
	event_state["worldTier"] = 2
	var event_engine := GameEngine.new()
	event_engine.initialize_from_state(event_state)
	event_engine.call("_apply_effects", {"bigValues": {"gold": 50, "renown": 500}})
	var event_positive := event_engine.get_state()
	event_engine.call("_apply_effects", {"bigValues": {"gold": -25}})
	var event_negative := event_engine.get_state()
	_check(absf(BigValue.to_float((event_positive.get("bigValues", {}) as Dictionary).get("lifetimeGold", BigValue.zero()) as Dictionary) - 150.0) < 0.001 and absf(BigValue.to_float((event_positive.get("bigValues", {}) as Dictionary).get("lifetimeRenown", BigValue.zero()) as Dictionary) - 750.0) < 0.001 and int(event_positive.get("worldTier", 0)) == 3, "이벤트 양수 골드·명성 lifetime 및 세계 티어 동시 반영")
	_check(absf(BigValue.to_float((event_negative.get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary) - 125.0) < 0.001 and absf(BigValue.to_float((event_negative.get("bigValues", {}) as Dictionary).get("lifetimeGold", BigValue.zero()) as Dictionary) - 150.0) < 0.001, "이벤트 음수 골드는 현재값만 차감")

	var title_state := StateFactory.create(701008, "title tier", content_db.config)
	(title_state.get("bigValues", {}) as Dictionary)["renown"] = BigValue.from_number(250)
	(title_state.get("bigValues", {}) as Dictionary)["lifetimeRenown"] = BigValue.from_number(250)
	title_state["worldTier"] = 2
	(title_state.get("time", {}) as Dictionary)["slot"] = 27
	title_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	var title_engine := GameEngine.new()
	title_engine.initialize_from_state(title_state)
	title_engine.get_content_db().careers = [{"id": "TEST_TITLE", "name": "경계 칭호", "category": "test", "gate": {"stats": {"stamina": 0}}, "baseRenown": 500}]
	var title_review_config := title_engine.get_content_db().config.get("seasonReview", {}) as Dictionary
	for review_key: String in ["baseRenown", "challengeWinRenown", "completedContractRenown", "policyFitRenown"]:
		title_review_config[review_key] = 0
	var title_advance := title_engine.advance_slots(1)
	var title_reviews := title_advance.get("seasonReviews", []) as Array
	_check(not title_reviews.is_empty() and int((title_reviews[0] as Dictionary).get("worldTierAfter", 0)) == 3 and int(title_engine.get_state().get("worldTier", 0)) == 3, "칭호 명성 지급 직후 같은 심사에서 세계 티어 재계산")

	var modifier_state := StateFactory.create(701009, "modifier", content_db.config)
	var modifier_engine := GameEngine.new()
	modifier_engine.initialize_from_state(modifier_state)
	var no_repeat_status: Dictionary = modifier_engine.call("_contract_modifier_status", {"modifiers": ["no_repeat"], "modifierRequirements": {"no_repeat": {"maximumConsecutiveSame": 1}}}, {}, {}, {"maximumConsecutiveSame": 2}, true)
	_check(not bool(no_repeat_status.get("no_repeat", true)), "no_repeat는 누적 maximumConsecutiveSame 위반을 유지")

	var rolling_state := StateFactory.create(701010, "rolling", content_db.config)
	(rolling_state.get("time", {}) as Dictionary)["slot"] = 27
	rolling_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	var rolling_vectors: Array = []
	for vector_index: int in range(28):
		rolling_vectors.append({"intelligence": float(vector_index + 1)})
	rolling_state["recentGrowthVectors"] = rolling_vectors
	var rolling_engine := GameEngine.new()
	rolling_engine.initialize_from_state(rolling_state)
	rolling_engine.advance_slots(1)
	_check((rolling_engine.get_state().get("recentGrowthVectors", []) as Array).size() == 28, "시즌 심사 후에도 최근 28회 성장 벡터 rolling 유지")

	var magic_damage_taken: Array[float] = []
	for magic_defense: float in [0.0, 1000.0]:
		var combat_engine := GameEngine.new()
		combat_engine.initialize_from_state(StateFactory.create(701011, "combat", content_db.config))
		var magic_enemies: Array[Dictionary] = [{"id": "MAGIC", "name": "마법체", "hp": 1000, "attack": 0, "defense": 0, "magicAttack": 100, "magicDefense": 0}]
		var combat_result: Dictionary = combat_engine.call("_resolve_adventure_combat_node", magic_enemies, false, 1, 500.0, 1.0, 1.0, 1000.0, magic_defense, 1.0, "시험 지역", {})
		magic_damage_taken.append(500.0 - float(combat_result.get("playerHp", 500.0)))
	_check(magic_damage_taken[0] > magic_damage_taken[1], "적 magicAttack은 player magicDefense와 분리 판정")


func _test_content_counts(content_db: ContentDB) -> void:
	var counts: Dictionary = content_db.validate_counts()
	_check(bool(counts.get("ok", false)), "AC-ACT-01/AC-CONTENT-01 콘텐츠 수량 검증")
	_check(content_db.get_activities().size() == 43, "활동 43개")
	_check(content_db.get_events().size() == 26, "이벤트 26개")
	_check(content_db.get_items().size() == 21, "상점 품목 21개")
	_check(content_db.get_careers().size() == 38, "진로 칭호 38개")

	var kind_counts: Dictionary = {}
	var ids: Dictionary = {}
	for activity: Dictionary in content_db.get_activities():
		var activity_id: String = str(activity.get("id", ""))
		_check(not activity_id.is_empty() and not ids.has(activity_id), "활동 ID 고유성: %s" % activity_id)
		ids[activity_id] = true
		var kind: String = str(activity.get("kind", ""))
		kind_counts[kind] = int(kind_counts.get(kind, 0)) + 1
	_check(kind_counts == EXPECTED_ACTIVITY_KINDS, "AC-ACT-05 활동 분류 15/11/4/5/8")
	_check(_all_unique_ids(content_db.get_events()), "이벤트 ID 고유성")
	_check(_all_unique_ids(content_db.get_items()), "상점 품목 ID 고유성")
	_check(_all_unique_ids(content_db.get_careers()), "진로 칭호 ID 고유성")

	var challenge_signatures: Dictionary = {}
	for activity: Dictionary in content_db.get_activities():
		if str(activity.get("kind", "")) != "challenge":
			continue
		var signature: String = JSON.stringify(activity.get("challengeWeights", {}), "", true, true)
		challenge_signatures[signature] = true
	_check(challenge_signatures.size() == 8, "AC-WORLD-02 도전 8종 평가 가중치 분리")


func _test_growth_profile_ssot(content_db: ContentDB) -> void:
	_check(content_db.profiles.size() == 8, "성장 프리셋 profiles.json 8종 로드")
	for profile: Dictionary in content_db.profiles:
		var preset_id: String = str(profile.get("id", ""))
		var policy: Dictionary = GrowthPolicy.create(preset_id, {"gold": 1.0})
		_check(
			_weights_match(policy.get("weights", {}) as Dictionary, profile.get("weights", {}) as Dictionary),
			"profiles.json weights 런타임 SSOT: %s" % preset_id
		)

	var injected_profiles: Array[Dictionary] = content_db.profiles.duplicate(true)
	for profile: Dictionary in injected_profiles:
		if str(profile.get("id", "")) == "scholar":
			profile["weights"] = {"gold": 1.0}
	GrowthPolicy.configure_profiles(injected_profiles)
	var injected_scholar: Dictionary = GrowthPolicy.create("scholar", {"combat": 1.0})
	_check(
		is_equal_approx(float((injected_scholar.get("weights", {}) as Dictionary).get("gold", 0.0)), 1.0)
		and is_zero_approx(float((injected_scholar.get("weights", {}) as Dictionary).get("combat", 0.0))),
		"주입된 profile weights가 저장/caller weights보다 우선"
	)
	GrowthPolicy.configure_profiles(content_db.profiles)

	var balanced_data: Dictionary = content_db.get_profile("balanced").get("weights", {}) as Dictionary
	var zero_custom: Dictionary = GrowthPolicy.create("custom", {"intelligence": 0.0, "combat": -3.0})
	_check(
		str(zero_custom.get("preset", "")) == "balanced"
		and _weights_match(zero_custom.get("weights", {}) as Dictionary, balanced_data),
		"custom 가중치 합 0은 profiles.json balanced 데이터로 fallback"
	)


func _test_big_value(content_db: ContentDB) -> void:
	var normalized: Dictionary = BigValue.from_number(3141592.0)
	_check(BigValue.is_valid(normalized), "BigValue 정규화 유효성")
	_check(int(normalized.get("exponent", -1)) == 6, "BigValue 정규화 지수")

	var added: Dictionary = BigValue.add(BigValue.from_number(900), BigValue.from_number(200))
	_check(absf(BigValue.to_float(added) - 1100.0) < 0.000001, "BigValue 덧셈")
	var subtracted: Dictionary = BigValue.subtract(BigValue.from_number(10), BigValue.from_number(20))
	_check(BigValue.is_zero(subtracted), "BigValue 뺄셈 음수 방지")

	var planner: Planner = Planner.new()
	var cost_activity: Dictionary = content_db.get_activity("EDU_LITERATURE")
	var reward_activity: Dictionary = content_db.get_activity("JOB_DIPLOMACY")
	var tier_cost: Dictionary = planner.tier_cost(cost_activity, 10000)
	var tier_reward: Dictionary = planner.tier_reward(reward_activity, 10000, 1.75)
	_check(BigValue.is_valid(tier_cost) and not BigValue.is_zero(tier_cost), "AC-CORE-04 티어 10000 비용 유효")
	_check(BigValue.is_valid(tier_reward) and not BigValue.is_zero(tier_reward), "AC-CORE-04 티어 10000 보상 유효")
	_check(_finite_number(float(tier_cost.get("mantissa", NAN))), "티어 10000 비용 mantissa finite")
	_check(_finite_number(float(tier_reward.get("mantissa", NAN))), "티어 10000 보상 mantissa finite")
	_check(not _has_invalid_number_text(BigValue.format_short(tier_cost)), "티어 10000 비용 표기")
	_check(not _has_invalid_number_text(BigValue.format_short(tier_reward)), "티어 10000 보상 표기")

	var round_trip: Dictionary = BigValue.normalize({"mantissa": 3.141592653589793, "exponent": 42})
	var decoded: Dictionary = SaveCodec.decode(SaveCodec.encode({"bigValues": {"gold": round_trip}}))
	var decoded_gold: Dictionary = (decoded.get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary
	var relative_error: float = absf(float(decoded_gold.get("mantissa", 0.0)) - float(round_trip.get("mantissa", 0.0))) / float(round_trip.get("mantissa", 1.0))
	_check(relative_error <= 1.0e-9 and int(decoded_gold.get("exponent", 0)) == 42, "BigValue 세이브 왕복 상대 오차")


func _test_rng_and_thousand_slot_determinism() -> void:
	var stream_a: Dictionary = {"seed": 773377, "rngCounter": 0}
	var stream_b: Dictionary = {"seed": 773377, "rngCounter": 0}
	var values_a: Array[int] = []
	var values_b: Array[int] = []
	for index: int in range(128):
		values_a.append(DeterministicRNG.next_u32(stream_a, "raw_%d" % index))
		values_b.append(DeterministicRNG.next_u32(stream_b, "raw_%d" % index))
	_check(values_a == values_b and int(stream_a.get("rngCounter", -1)) == 128, "PRNG 동일 seed/counter 결정성")

	var first: GameEngine = GameEngine.new()
	var second: GameEngine = GameEngine.new()
	first.initialize(424242)
	second.initialize(424242)
	first.advance_slots(1000)
	second.advance_slots(1000)
	var first_state: Dictionary = first.get_state()
	var second_state: Dictionary = second.get_state()
	_check(_canonical(first_state) == _canonical(second_state), "AC-CORE-01 같은 seed로 1000 slot 상태 일치")
	_check(int((first_state.get("time", {}) as Dictionary).get("slot", -1)) == 1000, "1000 slot 시간 진행")
	_check(not _contains_non_finite(first_state), "AC-CORE-02 1000 slot 상태 NaN/INF 없음")
	var meters: Dictionary = first_state.get("meters", {}) as Dictionary
	_check(float(meters.get("energy", -1.0)) >= 0.0 and float(meters.get("energy", 101.0)) <= 100.0, "AC-CORE-03 에너지 clamp")
	_check(float(meters.get("stress", -1.0)) >= 0.0 and float(meters.get("stress", 101.0)) <= 100.0, "AC-CORE-03 스트레스 clamp")
	var validation: Dictionary = first.validate_state()
	_check(bool(validation.get("ok", false)), "GameEngine 상태 불변식 검사")


func _test_planner_constraints(content_db: ContentDB) -> void:
	var planner: Planner = Planner.new()
	var state: Dictionary = StateFactory.create(1001, "플래너")
	var literature: Dictionary = content_db.get_activity("EDU_LITERATURE")
	var home: Dictionary = content_db.get_activity("REST_HOME")

	state["growthPolicy"] = GrowthPolicy.create("balanced", {}, ["study"], 300, 72.0, 0.35)
	_check(not planner.is_allowed(state, literature), "AC-PLAN-01 금지 태그 제외")

	var locked: Dictionary = literature.duplicate(true)
	locked["id"] = "TEST_LOCKED"
	locked["requires"] = {"worldTier": 9999}
	_check(not planner.is_allowed(state, locked), "AC-PLAN-01 잠금 조건 제외")

	state["growthPolicy"] = GrowthPolicy.create("balanced", {}, [], 300, 72.0, 0.35)
	(state["bigValues"] as Dictionary)["gold"] = BigValue.from_number(350)
	_check(not planner.is_allowed(state, literature), "AC-PLAN-01 최소 보유금 제약")

	(state["meters"] as Dictionary)["energy"] = 19.0
	(state["bigValues"] as Dictionary)["gold"] = BigValue.from_number(3000)
	var recovery_decision: Dictionary = planner.choose(state, content_db.get_activities())
	var recovery_activity: Dictionary = recovery_decision.get("activity", {}) as Dictionary
	_check(bool(recovery_decision.get("forcedRecovery", false)), "AC-PLAN-02 저에너지 회복 강제")
	_check(str(recovery_activity.get("kind", "")) == "rest", "AC-PLAN-02 회복 활동 선택")

	(state["meters"] as Dictionary)["energy"] = 100.0
	(state["meters"] as Dictionary)["stress"] = 0.0
	state["growthPolicy"] = GrowthPolicy.create("balanced", {}, ["study", "safe", "indoor"], 300, 72.0, 0.35)
	var impossible_only: Array[Dictionary] = [locked]
	var fallback: Dictionary = planner.choose(state, impossible_only)
	_check(str(fallback.get("activityId", "")) == "REST_HOME", "AC-PLAN-03 후보 없음 REST_HOME fallback")

	state["growthPolicy"] = GrowthPolicy.create("balanced")
	var normal: Dictionary = planner.choose(state, [literature, home])
	_check((normal.get("reasons", []) as Array).size() <= 3 and not (normal.get("reasons", []) as Array).is_empty(), "AC-PLAN-05 선택 이유 최대 3개")
	var zero_custom: Dictionary = GrowthPolicy.create("custom", {"intelligence": 0.0, "combat": -3.0})
	_check(str(zero_custom.get("preset", "")) == "balanced" and is_equal_approx(float((zero_custom.get("weights", {}) as Dictionary).get("intelligence", 0.0)), float((GrowthPolicy.get_preset_weights("balanced")).get("intelligence", 0.0))), "custom 가중치 합 0은 preset/weights 모두 balanced fallback")


func _test_challenge_schedule_and_hints(content_db: ContentDB) -> void:
	var planner: Planner = Planner.new()
	planner.configure(content_db.config, content_db.profiles, content_db.activities)
	var schedule: Dictionary = content_db.config.get("challengeScheduleSlots", {}) as Dictionary
	var scheduled_slots: Dictionary = {}
	for raw_slot: Variant in schedule.values():
		scheduled_slots[int(raw_slot)] = true
	_check(schedule.size() == 8 and scheduled_slots.size() == 8, "도전 8종 결정적 시즌 slot 일정 고유성")
	var state: Dictionary = _rich_state(771001, "도전 일정")
	var challenge: Dictionary = content_db.get_activity("CH_EXAM_ACADEMY")
	_check(not planner.is_allowed(state, challenge) and planner.rejection_reason(state, challenge).contains("4번 슬롯"), "도전은 일정 외 자동 후보/수동 실행 잠금")
	(state["time"] as Dictionary)["slot"] = 3
	_check(planner.is_allowed(state, challenge), "도전은 시즌 지정 slot의 자동 후보로 해금")
	(state["time"] as Dictionary)["slot"] = 2
	_check(not planner.is_allowed(state, content_db.get_activity("EDU_PROTOCOL")) and planner.rejection_reason(state, content_db.get_activity("EDU_PROTOCOL")).contains("예정 도전 우선"), "장기 활동은 다음 예정 도전 slot을 건너뛰지 않음")
	(state["time"] as Dictionary)["slot"] = 27
	state["worldTier"] = 10
	_check(not planner.is_allowed(state, content_db.get_activity("ADV_RIFT")) and planner.rejection_reason(state, content_db.get_activity("ADV_RIFT")).contains("4번 슬롯"), "시즌 경계 장기 활동은 다음 시즌 예정 도전을 건너뛰지 않음")
	(state["time"] as Dictionary)["slot"] = 3
	state["activeTask"] = null
	var auto_engine: GameEngine = GameEngine.new()
	auto_engine.initialize_from_state(state)
	_check(str((auto_engine.get_state().get("activeTask", {}) as Dictionary).get("activityId", "")) == "CH_EXAM_ACADEMY", "예정 slot에는 해금 도전을 자동 선택")

	var outside_engine: GameEngine = GameEngine.new()
	outside_engine.initialize_from_state(_rich_state(771002, "일정 밖"))
	var outside_result: Dictionary = outside_engine.run_activity("CH_EXAM_ACADEMY")
	_check(not bool(outside_result.get("ok", true)) and str(outside_result.get("error", "")).contains("시즌 일정 잠금"), "수동 도전 일정 밖 구체 잠금 이유")

	var weak_state: Dictionary = StateFactory.create(771003, "도전 힌트")
	weak_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 1)
	var weak_engine: GameEngine = GameEngine.new()
	weak_engine.initialize_from_state(weak_state)
	var weak_result: Dictionary = weak_engine.advance_slots(1)
	var weak_completed: Dictionary = ((weak_result.get("completedActivities", []) as Array)[0] as Dictionary)
	var weak_outcome: Dictionary = weak_completed.get("outcome", {}) as Dictionary
	_check(not bool(weak_outcome.get("won", true)) and not str(weak_outcome.get("hintStat", "")).is_empty() and float(weak_outcome.get("hintGap", 0.0)) > 0.0, "도전 실패 outcome 스탯 기반 구체 hint")


func _test_mastery_milestones(content_db: ContentDB) -> void:
	var planner: Planner = Planner.new()
	planner.configure(content_db.config)
	_check(planner.mastery_milestone_count(9) == 0, "숙련 10 이전 마일스톤 없음")
	_check(planner.mastery_milestone_count(10) == 1 and planner.mastery_milestone_count(25) == 2, "숙련 10/25 마일스톤 누적")
	_check(planner.mastery_milestone_count(100) == 4 and planner.mastery_milestone_count(199) == 4, "숙련 50/100 고정 마일스톤")
	_check(planner.mastery_milestone_count(200) == 5 and planner.mastery_milestone_count(10000) == 103, "숙련 100 이후 매 100레벨 무한 마일스톤")

	var activity_id: String = "EDU_LITERATURE"
	var gains: Array[float] = []
	for mastery_level: int in [9, 10]:
		var state: Dictionary = _rich_state(777001, "숙련")
		(state["mastery"] as Dictionary)[activity_id] = mastery_level
		state["activeTask"] = _manual_task(activity_id, 1, int(state.get("worldTier", 1)))
		var engine: GameEngine = GameEngine.new()
		engine.initialize_from_state(state)
		var result: Dictionary = engine.advance_slots(1)
		var completed: Dictionary = ((result.get("completedActivities", []) as Array)[0] as Dictionary)
		gains.append(float((completed.get("gains", {}) as Dictionary).get("intelligence", 0.0)))
		var decision_state: Dictionary = state.duplicate(true)
		var decision: Dictionary = planner.choose(decision_state, [content_db.get_activity(activity_id)])
		_check(is_equal_approx(float(decision.get("masteryModifier", 0.0)), planner.mastery_modifier(float(mastery_level))), "Planner 숙련 배율과 공통 공식 일치 L%d" % mastery_level)
	var actual_ratio: float = gains[1] / gains[0]
	var expected_ratio: float = planner.mastery_modifier(10.0) / planner.mastery_modifier(9.0)
	_check(absf(actual_ratio - expected_ratio) < 0.003, "활동 성장 reducer와 Planner 숙련 마일스톤 배율 일치")


func _test_manual_activity_execution() -> void:
	var state: Dictionary = _rich_state(778001, "수동 실행")
	state["activeTask"] = _manual_task("REST_HOME", 2, 1)
	var engine: GameEngine = GameEngine.new()
	engine.initialize_from_state(state)
	var executed: Dictionary = engine.run_activity("EDU_LITERATURE")
	_check(bool(executed.get("ok", false)) and str((executed.get("result", {}) as Dictionary).get("activityId", "")) == "EDU_LITERATURE", "수동 실행은 선행 activeTask 뒤 요청 ID 실제 완료를 반환")
	_check(int(executed.get("slotsAdvanced", 0)) == 3, "수동 실행 선행 2 slot + 요청 1 slot 처리")

	var locked_state: Dictionary = StateFactory.create(778002, "잠금")
	var locked_engine: GameEngine = GameEngine.new()
	locked_engine.initialize_from_state(locked_state)
	var before_count: int = int((locked_engine.get_state().get("lifetimeStats", {}) as Dictionary).get("activities", 0))
	var rejected: Dictionary = locked_engine.run_activity("ADV_RIFT")
	_check(not bool(rejected.get("ok", true)) and int((locked_engine.get_state().get("lifetimeStats", {}) as Dictionary).get("activities", -1)) == before_count, "수동 실행 잠금/예산 실패는 진행 없이 ok=false")

	engine.clear_activity_queue()
	engine.queue_activity("REST_HOME")
	engine.queue_activity("JOB_CARE")
	engine.queue_activity("EDU_LITERATURE")
	var moved: Dictionary = engine.move_queued_activity(0, 99)
	_check(bool(moved.get("ok", false)) and (moved.get("queue", []) as Array) == ["JOB_CARE", "EDU_LITERATURE", "REST_HOME"], "자동 큐 이동 offset bounds clamp")
	var removed: Dictionary = engine.remove_queued_activity(1)
	_check(bool(removed.get("ok", false)) and str(removed.get("removed", "")) == "EDU_LITERATURE", "자동 큐 인덱스 제거")
	var cleared: Dictionary = engine.clear_activity_queue()
	_check(int(cleared.get("removedCount", 0)) == 2 and (engine.get_state().get("activityQueue", []) as Array).is_empty(), "자동 큐 전체 비우기")


func _test_offline_cap_and_rollback() -> void:
	var cap_state: Dictionary = StateFactory.create(9001, "오프라인")
	cap_state["lastSimulatedAt"] = 100000
	var cap_engine: GameEngine = GameEngine.new()
	cap_engine.initialize_from_state(cap_state)
	var cap_result: Dictionary = cap_engine.settle_offline(140000)
	_check(int(cap_result.get("slotsAdvanced", -1)) == 480, "AC-IDLE-01 8시간/480 slot 상한")
	_check(int(cap_result.get("elapsedSeconds", -1)) == 28800 and bool(cap_result.get("capped", false)), "AC-IDLE-01 오프라인 28,800초 cap")

	var rollback_state: Dictionary = StateFactory.create(9002, "역행")
	rollback_state["lastSimulatedAt"] = 200000
	var rollback_engine: GameEngine = GameEngine.new()
	rollback_engine.initialize_from_state(rollback_state)
	var before: Dictionary = rollback_engine.get_state()
	var rollback_result: Dictionary = rollback_engine.settle_offline(199999)
	var after: Dictionary = rollback_engine.get_state()
	_check(int(rollback_result.get("slotsAdvanced", -1)) == 0 and bool(rollback_result.get("clockRollback", false)), "AC-IDLE-02 시계 역행 0 slot")
	_check(int(after.get("lastSimulatedAt", -1)) == 200000, "AC-IDLE-02 역행 시 저장 시각 보존")
	_check(_canonical(before.get("stats", {})) == _canonical(after.get("stats", {})), "AC-IDLE-02 역행 시 스탯 손실 없음")
	_check((after.get("warnings", []) as Array).size() == (before.get("warnings", []) as Array).size() + 1, "AC-IDLE-02 역행 경고 기록")

	var parity_state: Dictionary = StateFactory.create(9003, "동일 리듀서")
	parity_state["lastSimulatedAt"] = 300000
	var online: GameEngine = GameEngine.new()
	var offline: GameEngine = GameEngine.new()
	online.initialize_from_state(parity_state)
	offline.initialize_from_state(parity_state)
	for parity_slot: int in range(20):
		online.advance_slots(1, 300000 + (parity_slot + 1) * 60)
	offline.settle_offline(301200)
	var online_state: Dictionary = online.get_state()
	var offline_state: Dictionary = offline.get_state()
	_check(_canonical(online_state) == _canonical(offline_state), "AC-IDLE-03 온라인/오프라인 동일 reducer")

	var paused_state: Dictionary = StateFactory.create(9004, "일시정지")
	paused_state["lastSimulatedAt"] = 500000
	(paused_state["settings"] as Dictionary)["autoRun"] = false
	var paused_engine: GameEngine = GameEngine.new()
	paused_engine.initialize_from_state(paused_state)
	var paused_slot_before: int = int((paused_engine.get_state().get("time", {}) as Dictionary).get("slot", -1))
	var paused_result: Dictionary = paused_engine.settle_offline(500600)
	_check(int(paused_result.get("slotsAdvanced", -1)) == 0 and bool(paused_result.get("paused", false)) and int((paused_engine.get_state().get("time", {}) as Dictionary).get("slot", -2)) == paused_slot_before and int(paused_engine.get_state().get("lastSimulatedAt", 0)) == 500600, "autoRun=false 오프라인은 slot 진행 없이 boundary만 갱신")

	var boundary_event: Dictionary = {
		"id": "TEST_OFFLINE_BOUNDARY",
		"instanceId": "TEST_OFFLINE_BOUNDARY_1",
		"queuedAtUnix": 400000,
		"expiresAtUnix": 400090,
		"defaultChoice": "safe",
		"choices": [{"id": "safe", "effects": {"stats": {"intelligence": 100.0}}}],
	}
	var boundary_state: Dictionary = StateFactory.create(9005, "경계 만료")
	boundary_state["lastSimulatedAt"] = 400000
	boundary_state["eventInbox"] = [boundary_event]
	boundary_state["activeTask"] = _manual_task("EDU_LITERATURE", 1, 1)
	boundary_state["activityQueue"] = ["EDU_LITERATURE"]
	var boundary_online: GameEngine = GameEngine.new()
	var boundary_offline: GameEngine = GameEngine.new()
	boundary_online.initialize_from_state(boundary_state)
	boundary_offline.initialize_from_state(boundary_state)
	boundary_online.advance_slots(1, 400060)
	boundary_online.advance_slots(1, 400120)
	boundary_offline.settle_offline(400120)
	_check(_canonical(boundary_online.get_state()) == _canonical(boundary_offline.get_state()), "오프라인 이벤트 만료가 60초 slot boundary별 온라인 순서와 parity")


func _test_event_expiry_boundary(content_db: ContentDB) -> void:
	var event: Dictionary = content_db.get_events()[0].duplicate(true)
	event["instanceId"] = "TEST_EVENT_EXPIRY"
	event["queuedAtUnix"] = 0
	event["expiresAtUnix"] = 0
	var state: Dictionary = StateFactory.create(779001, "이벤트 만료")
	state["eventInbox"] = [event]
	var first: GameEngine = GameEngine.new()
	first.initialize_from_state(state)
	first.advance_slots(0, 100000)
	var anchored: Dictionary = ((first.get_state().get("eventInbox", []) as Array)[0] as Dictionary)
	_check(int(anchored.get("queuedAtUnix", 0)) == 100000 and int(anchored.get("expiresAtUnix", 0)) == 186400, "queuedAtUnix=0 이벤트를 명시 now 경계에서 24시간 만료로 앵커")
	first.advance_slots(0, 186399)
	_check((first.get_state().get("eventInbox", []) as Array).size() == 1, "이벤트 24시간 직전 유지")
	first.advance_slots(0, 186400)
	var expired_state: Dictionary = first.get_state()
	_check((expired_state.get("eventInbox", []) as Array).is_empty(), "AC-CONTENT-03 온라인 명시 now 24시간 경과 시 기본 선택 자동 해결")
	var history: Dictionary = expired_state.get("eventHistory", {}) as Dictionary
	var event_history: Dictionary = history.get(str(event.get("id", "")), {}) as Dictionary
	_check(str(event_history.get("lastChoice", "")) == str(event.get("defaultChoice", "")), "AC-CONTENT-03 만료 이벤트 기본 안전 선택 기록")

	var second: GameEngine = GameEngine.new()
	second.initialize_from_state(state)
	second.advance_slots(0, 100000)
	second.advance_slots(0, 186400)
	_check(_canonical(second.get_state()) == _canonical(expired_state), "이벤트 explicit now 입력의 동일 상태 결정성")


func _test_save_codec() -> void:
	var state: Dictionary = StateFactory.create(5555, "세이브 왕복")
	(state["stats"] as Dictionary)["intelligence"] = 1234.56789
	(state["careerTitles"] as Dictionary)["END_WRITER"] = {"stars": 7, "firstSeason": 1, "lastSeason": 8}
	var encoded: String = SaveCodec.encode(state)
	var decoded: Dictionary = SaveCodec.decode(encoded)
	_check(not decoded.is_empty() and SaveCodec.encode(decoded) == encoded, "AC-SAVE-01 v2 canonical roundtrip")
	_check(not bool((decoded.get("settings", {}) as Dictionary).get("highContrast", true)), "v2 기본 상태에 고대비 접근성 설정 포함")
	var legacy_v2: Dictionary = state.duplicate(true)
	(legacy_v2.get("settings", {}) as Dictionary).erase("highContrast")
	var filled_v2: Dictionary = StateFactory.ensure_v2_shape(legacy_v2)
	_check(not bool((filled_v2.get("settings", {}) as Dictionary).get("highContrast", true)), "기존 v2 세이브에 고대비 기본값 보충")

	var v1: Dictionary = {
		"schemaVersion": 1,
		"seed": 77,
		"name": "리나",
		"stats": {"intelligence": 321.5, "charm": 44.0, "combatSkill": 88.0},
		"meters": {"stress": 31, "reputation": 72, "sin": 2},
		"gold": 9876,
		"endingDex": ["END_WRITER", "END_KNIGHT"],
	}
	var migrated: Dictionary = SaveCodec.migrate(v1)
	_check(int(migrated.get("schemaVersion", 0)) == 2, "AC-SAVE-03 v1 -> v2 schema")
	_check(str(migrated.get("playerName", "")) == "리나", "AC-SAVE-03 이름 보존")
	_check(is_equal_approx(float((migrated.get("stats", {}) as Dictionary).get("intelligence", 0.0)), 321.5), "AC-SAVE-03 스탯 보존")
	_check(is_equal_approx(float((migrated.get("stats", {}) as Dictionary).get("style", 0.0)), 44.0), "AC-SAVE-03 legacy charm 치환")
	_check(BigValue.compare((migrated.get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary, BigValue.from_number(9876)) == 0, "AC-SAVE-03 골드 보존")
	_check((migrated.get("careerTitles", {}) as Dictionary).size() == 2, "AC-SAVE-03 도감 보존")

	var test_path: String = "user://princess_tycoon_test_save_codec.json"
	_cleanup_save_path(test_path)
	var backup_state: Dictionary = StateFactory.create(8080, "백업 원본")
	var first_save: Dictionary = SaveCodec.save_atomic(test_path, backup_state)
	var newer_state: Dictionary = backup_state.duplicate(true)
	newer_state["playerName"] = "손상 대상"
	newer_state["traineeName"] = "손상 대상"
	var second_save: Dictionary = SaveCodec.save_atomic(test_path, newer_state)
	_check(bool(first_save.get("ok", false)) and bool(second_save.get("ok", false)), "SaveCodec 원자 저장과 백업 생성")
	var absolute_path: String = ProjectSettings.globalize_path(test_path)
	var corrupt_file: FileAccess = FileAccess.open(absolute_path, FileAccess.WRITE)
	if corrupt_file != null:
		corrupt_file.store_string("{corrupted-json")
		corrupt_file.close()
	var recovered: Dictionary = SaveCodec.load_with_backup(test_path)
	_check(bool(recovered.get("ok", false)) and bool(recovered.get("recovered", false)), "AC-SAVE-02 손상 본 파일에서 .bak 복구")
	_check(str((recovered.get("state", {}) as Dictionary).get("playerName", "")) == "백업 원본", "AC-SAVE-02 백업 상태 보존")
	_check(FileAccess.get_file_as_string(absolute_path) == "{corrupted-json", "AC-SAVE-02 손상본 보존")
	_cleanup_save_path(test_path)

	var failure_event: Dictionary = {
		"id": "TEST_SAVE_FAILURE_EVENT",
		"instanceId": "TEST_SAVE_FAILURE_EVENT_1",
		"queuedAtUnix": 600000,
		"expiresAtUnix": 700000,
		"defaultChoice": "safe",
		"choices": [{"id": "safe", "effects": {"stats": {"intelligence": 10.0}}}],
	}
	var failure_state: Dictionary = StateFactory.create(8081, "저장 실패")
	failure_state["lastSimulatedAt"] = 650000
	failure_state["eventInbox"] = [failure_event]
	var failure_engine: GameEngine = GameEngine.new()
	failure_engine.initialize_from_state(failure_state)
	var failure_before: Dictionary = failure_engine.get_state()
	var failure_result: Dictionary = failure_engine.save("   ", 800000)
	_check(not bool(failure_result.get("ok", true)) and _canonical(failure_engine.get_state()) == _canonical(failure_before), "GameEngine.save atomic write 실패 시 lastSim/event 상태 원복")

	var preserve_path: String = "user://princess_tycoon_preserve_boundary_test.json"
	_cleanup_save_path(preserve_path)
	var preserve_event: Dictionary = failure_event.duplicate(true)
	preserve_event["instanceId"] = "TEST_PRESERVE_EVENT_1"
	preserve_event["expiresAtUnix"] = 850000
	var preserve_state: Dictionary = StateFactory.create(8082, "역행 경계 저장")
	preserve_state["lastSimulatedAt"] = 900000
	preserve_state["eventInbox"] = [preserve_event]
	var preserve_engine: GameEngine = GameEngine.new()
	preserve_engine.initialize_from_state(preserve_state)
	var preserve_result: Dictionary = preserve_engine.save(preserve_path, 800000, true)
	var preserved_state: Dictionary = preserve_engine.get_state()
	_check(bool(preserve_result.get("ok", false)) and int(preserved_state.get("lastSimulatedAt", 0)) == 900000 and (preserved_state.get("eventInbox", []) as Array).size() == 1, "save preserve_last_simulated_at은 future boundary 보존·event now 분리")
	_cleanup_save_path(preserve_path)


func _test_procedural_generation(content_db: ContentDB) -> void:
	var generator: ProceduralGenerator = ProceduralGenerator.new()
	var original: Dictionary = StateFactory.create(24681357, "생성")
	original["worldTier"] = 12
	(original["time"] as Dictionary)["season"] = 3
	(original["challengeLeague"] as Dictionary)["bestScore"] = 420.0
	var first: Dictionary = generator.generate(original, content_db)
	var serialized: Dictionary = SaveCodec.decode(SaveCodec.encode(original))
	var second: Dictionary = generator.generate(serialized, content_db)
	_check(_canonical(first) == _canonical(second), "AC-WORLD-03 동일 seed/tier/season 절차 생성 결정성")
	_check((first.get("contracts", []) as Array).size() == 3, "절차 계약 3개")
	_check((first.get("rivals", []) as Array).size() == 5, "절차 라이벌 5명")
	_check(int((first.get("region", {}) as Dictionary).get("nodes", 0)) == 3, "절차 지역 3노드")
	var rivals: Array = first.get("rivals", []) as Array
	var league_ordered: bool = true
	var traits_mechanical: bool = true
	for rival_index: int in range(rivals.size()):
		var rival: Dictionary = rivals[rival_index] as Dictionary
		league_ordered = league_ordered and int(rival.get("leagueTier", 0)) == rival_index + 1
		if rival_index > 0:
			league_ordered = league_ordered and float(rival.get("score", 0.0)) > float((rivals[rival_index - 1] as Dictionary).get("score", 0.0))
		var domains: Dictionary = rival.get("challengeDomains", {}) as Dictionary
		var trait_modifiers: Dictionary = rival.get("traitModifiersByChallenge", {}) as Dictionary
		var has_strength: bool = false
		var has_weakness: bool = false
		for raw_activity_id: Variant in domains.keys():
			has_strength = has_strength or str(domains[raw_activity_id]) == str(rival.get("strength", ""))
			has_weakness = has_weakness or str(domains[raw_activity_id]) == str(rival.get("weakness", ""))
		traits_mechanical = traits_mechanical and has_strength and has_weakness and not trait_modifiers.is_empty()
	_check(league_ordered and is_equal_approx(float((rivals[0] as Dictionary).get("previousBestScore", 0.0)), 420.0), "라이벌 5단계 리그가 시즌·직전 최고 기록으로 난이도 정렬")
	_check(is_equal_approx(float(((rivals[0] as Dictionary).get("previousBestByChallenge", {}) as Dictionary).get("CH_EXAM_ACADEMY", 0.0)), 420.0), "도전별 기록이 없으면 global league best를 라이벌 baseline으로 fallback")
	_check(traits_mechanical, "라이벌 strength/weakness/personality가 도전별 상대 점수에 연결")
	var generated_region: Dictionary = first.get("region", {}) as Dictionary
	_check(not str(generated_region.get("baseRegionId", "")).is_empty() and not (generated_region.get("modifierProfile", {}) as Dictionary).is_empty(), "생성 지역 stable ID·실효 modifier profile")

	var planner: Planner = Planner.new()
	var all_achievable: bool = true
	for raw_contract: Variant in first.get("contracts", []) as Array:
		if raw_contract is not Dictionary:
			all_achievable = false
			continue
		var contract: Dictionary = raw_contract as Dictionary
		var target_ids: Array = contract.get("targetActivityIds", []) as Array
		if target_ids.is_empty():
			all_achievable = false
		for raw_id: Variant in target_ids:
			var target: Dictionary = content_db.get_activity(str(raw_id))
			if target.is_empty() or not planner.requirements_met(original, target.get("requires", {}) as Dictionary):
				all_achievable = false
		var target_activity: Dictionary = content_db.get_activity(str(target_ids[0])) if not target_ids.is_empty() else {}
		for raw_modifier: Variant in contract.get("modifiers", []) as Array:
			var modifier_id: String = str(raw_modifier)
			if modifier_id == "risk_bonus" and float(target_activity.get("risk", 0.0)) < 0.2 and not ["adventure", "challenge"].has(str(target_activity.get("kind", ""))):
				all_achievable = false
			if modifier_id == "community_bonus" and not (target_activity.get("tags", []) as Array).has("service") and str(contract.get("kind", "")) != "relation_gain":
				all_achievable = false
		if str(contract.get("kind", "")) == "balanced_cycle" and int(contract.get("target", 99)) > 5:
			all_achievable = false
	_check(all_achievable, "AC-WORLD-04 생성 계약 현재 상태에서 달성 가능")
	var matrix_compatible: bool = true
	for matrix_seed: int in range(24):
		for matrix_tier: int in [1, 4, 16, 100, 10000]:
			var matrix_state: Dictionary = _rich_state(880000 + matrix_seed, "계약 조합")
			matrix_state["worldTier"] = matrix_tier
			(matrix_state["time"] as Dictionary)["year"] = matrix_seed % 20 + 1
			(matrix_state["time"] as Dictionary)["season"] = matrix_seed % 4 + 1
			var matrix_generated: Dictionary = generator.generate(matrix_state, content_db)
			for raw_contract: Variant in matrix_generated.get("contracts", []) as Array:
				if raw_contract is not Dictionary or not _contract_definition_compatible(raw_contract as Dictionary, content_db):
					matrix_compatible = false
	_check(matrix_compatible, "절차 계약 120 seed/tier 조합 modifier-target 달성 가능성")

	var initial_contracts_compatible: bool = true
	for initial_seed: int in range(40):
		var initial_state: Dictionary = StateFactory.create(890000 + initial_seed, "초기 계약", content_db.config)
		var initial_generated: Dictionary = generator.generate(initial_state, content_db)
		for raw_contract: Variant in initial_generated.get("contracts", []) as Array:
			if raw_contract is not Dictionary:
				initial_contracts_compatible = false
				continue
			var contract: Dictionary = raw_contract as Dictionary
			var target: Dictionary = content_db.get_activity(str((contract.get("targetActivityIds", []) as Array)[0]))
			var bonus_id: String = str((contract.get("bonusObjective", {}) as Dictionary).get("id", ""))
			initial_contracts_compatible = initial_contracts_compatible and not target.is_empty() and planner.requirements_met(initial_state, target.get("requires", {}) as Dictionary)
			initial_contracts_compatible = initial_contracts_compatible and not (contract.get("modifiers", []) as Array).has("high_quality")
			initial_contracts_compatible = initial_contracts_compatible and bonus_id != "bonus_mastery"
			if bonus_id == "bonus_fast":
				initial_contracts_compatible = initial_contracts_compatible and ["gain_stat", "earn_gold"].has(str(contract.get("kind", "")))
			if bonus_id == "bonus_thrifty":
				initial_contracts_compatible = initial_contracts_compatible and float(target.get("baseCost", 0.0)) <= 0.0
	_check(initial_contracts_compatible, "초기 상태 계약 modifier/bonusObjective 구조적 도달 가능")

	var high_relation_state: Dictionary = _rich_state(890100, "관계 계약 후보")
	(high_relation_state["relations"] as Dictionary)["citizens"] = 900.0
	var high_relation_contracts: Array = generator.generate(high_relation_state, content_db).get("contracts", []) as Array
	var relation_variants_opened: bool = not high_relation_contracts.is_empty()
	for raw_contract: Variant in high_relation_contracts:
		relation_variants_opened = relation_variants_opened and raw_contract is Dictionary and str((raw_contract as Dictionary).get("relationAffinity", "")) == "citizens" and (raw_contract as Dictionary).get("tags", []) is Array
	_check(relation_variants_opened, "높은 관계가 절차 계약 field/tag 후보 변형을 개방")

	var description_target: Dictionary = content_db.get_activity("JOB_FARM")
	var description_template: Dictionary = {"descriptionTemplate": "정확한 목표를 따른다."}
	var gain_description: String = str(generator.call("_contract_description", description_template, "gain_stat", description_target, 40))
	var gold_description: String = str(generator.call("_contract_description", description_template, "earn_gold", description_target, 600))
	var relation_description: String = str(generator.call("_contract_description", description_template, "relation_gain", description_target, 8))
	var balanced_description: String = str(generator.call("_contract_description", description_template, "balanced_cycle", description_target, 5))
	_check(gain_description.contains("체력 성장량 40") and not gain_description.contains("stamina") and not gain_description.contains("40회"), "gain_stat 계약 설명이 한국어 능력치 성장량을 명시")
	_check(gold_description.contains("골드 600") and relation_description.contains("관계 점수 8") and balanced_description.contains("활동 종류 5개"), "골드·관계·균형 계약 종류별 설명")

	var rollover_state: Dictionary = _rich_state(890200, "고정 계약 교체")
	rollover_state["generatedContent"] = generator.generate(rollover_state, content_db)
	var stale_contract_id: String = str((((rollover_state.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array)[0] as Dictionary).get("id", ""))
	(rollover_state["generatedContent"] as Dictionary)["pinnedContractId"] = stale_contract_id
	(rollover_state["time"] as Dictionary)["slot"] = int(content_db.config.get("slotsPerSeason", 28)) - 1
	rollover_state["activeTask"] = _manual_task("REST_HOME", 1, 1)
	var rollover_engine: GameEngine = GameEngine.new()
	rollover_engine.initialize_from_state(rollover_state)
	rollover_engine.advance_slots(1)
	var rolled_content: Dictionary = rollover_engine.get_state().get("generatedContent", {}) as Dictionary
	var rolled_contract_ids: Array[String] = []
	for raw_contract: Variant in rolled_content.get("contracts", []) as Array:
		if raw_contract is Dictionary:
			rolled_contract_ids.append(str((raw_contract as Dictionary).get("id", "")))
	_check(not rolled_contract_ids.has(stale_contract_id) and str(rolled_content.get("pinnedContractId", "")) == "", "시즌 재생성 후 사라진 pinnedContractId 자동 해제")


func _test_adventure_and_challenge(content_db: ContentDB) -> void:
	var adventure_state: Dictionary = _rich_state(33001, "생성 지역")
	adventure_state["generatedContent"] = ProceduralGenerator.new().generate(adventure_state, content_db)
	var adventure_id: String = str(((adventure_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary).get("templateId", "ADV_FOREST"))
	var adventure: Dictionary = content_db.get_activity(adventure_id)
	adventure_state["activeTask"] = _manual_task(adventure_id, 1, 1)
	var adventure_engine: GameEngine = GameEngine.new()
	adventure_engine.initialize_from_state(adventure_state)
	var adventure_result: Dictionary = adventure_engine.advance_slots(int(adventure.get("durationSlots", 1)))
	var completed_adventures: Array = adventure_result.get("completedActivities", []) as Array
	_check(not completed_adventures.is_empty(), "모험 활동 완료 결과 생성")
	if not completed_adventures.is_empty():
		var completed: Dictionary = completed_adventures[0] as Dictionary
		var outcome: Dictionary = completed.get("outcome", {}) as Dictionary
		_check(str(completed.get("kind", "")) == "adventure" and str(outcome.get("type", "")) == "adventure", "AC-WORLD-01 모험 reducer 사용")
		_check((outcome.get("nodes", []) as Array).size() == 3, "AC-WORLD-01 모험 3노드")
		var nodes: Array = outcome.get("nodes", []) as Array
		_check(str((nodes[0] as Dictionary).get("type", "")) == "exploration" and ["event", "encounter"].has(str((nodes[1] as Dictionary).get("type", ""))) and str((nodes[2] as Dictionary).get("type", "")) == "boss", "모험 노드 탐색 → 조우/사건 → 보스 구조")
		var node_metadata_complete: bool = true
		for raw_node: Variant in nodes:
			node_metadata_complete = node_metadata_complete and raw_node is Dictionary and (raw_node as Dictionary).has("event") and (raw_node as Dictionary).get("effect", {}) is Dictionary
		_check(node_metadata_complete, "모험 각 node_results type/event/effect 기록")
		_check(not str(outcome.get("baseRegionId", "")).is_empty() and not (outcome.get("regionModifiers", []) as Array).is_empty(), "생성 지역 변형 이름·특성이 모험 reducer에 연결")
		_check(BigValue.is_valid(outcome.get("regionReward", BigValue.zero()) as Dictionary) and not BigValue.is_zero(outcome.get("regionReward", BigValue.zero()) as Dictionary), "생성 지역 BigValue 보상 지급")
	_check(_state_is_non_terminal(adventure_engine.get_state()), "모험 승패가 게임을 종료하지 않음")
	var rolling_state: Dictionary = adventure_engine.get_state()
	for _repeat: int in range(2):
		rolling_state["activeTask"] = _manual_task(adventure_id, 1, int(rolling_state.get("worldTier", 1)))
		rolling_state["activityQueue"] = []
		var repeat_engine: GameEngine = GameEngine.new()
		repeat_engine.initialize_from_state(rolling_state)
		repeat_engine.advance_slots(1)
		rolling_state = repeat_engine.get_state()
	var region_progress: Dictionary = rolling_state.get("regionProgress", {}) as Dictionary
	var active_region: Dictionary = (rolling_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary
	var active_region_key: String = str(active_region.get("baseRegionId", active_region.get("templateId", "")))
	var active_region_progress: Dictionary = region_progress.get(active_region_key, {}) as Dictionary
	_check(int(active_region_progress.get("clearCount", 0)) == 3 and int(active_region_progress.get("tier", 0)) == 2, "지역 clearCount 누적과 3회당 무한 tier 증가")
	var middle_branches: Dictionary = {}
	for branch_seed: int in range(24):
		var branch_state: Dictionary = _rich_state(990000 + branch_seed, "분기")
		branch_state["generatedContent"] = ProceduralGenerator.new().generate(branch_state, content_db)
		var branch_activity_id: String = str(((branch_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary).get("templateId", "ADV_FOREST"))
		branch_state["activeTask"] = _manual_task(branch_activity_id, 1, 1)
		var branch_engine: GameEngine = GameEngine.new()
		branch_engine.initialize_from_state(branch_state)
		var branch_result: Dictionary = branch_engine.advance_slots(1)
		var branch_completed: Dictionary = ((branch_result.get("completedActivities", []) as Array)[0] as Dictionary)
		var branch_nodes: Array = ((branch_completed.get("outcome", {}) as Dictionary).get("nodes", []) as Array)
		middle_branches[str((branch_nodes[1] as Dictionary).get("type", ""))] = true
	_check(middle_branches.has("event") and middle_branches.has("encounter"), "같은 규칙에서 seed에 따른 중간 조우/사건 결정적 분기")
	var mismatch_state: Dictionary = _rich_state(990100, "지역 불일치")
	mismatch_state["generatedContent"] = ProceduralGenerator.new().generate(mismatch_state, content_db)
	var generated_template: String = str(((mismatch_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary).get("templateId", ""))
	var mismatch_activity_id: String = ""
	for candidate_id: String in ["ADV_FOREST", "ADV_CAVE", "ADV_RUINS", "ADV_VOLCANO", "ADV_RIFT"]:
		if candidate_id != generated_template:
			mismatch_activity_id = candidate_id
			break
	mismatch_state["activeTask"] = _manual_task(mismatch_activity_id, 1, 1)
	var mismatch_engine: GameEngine = GameEngine.new()
	mismatch_engine.initialize_from_state(mismatch_state)
	var mismatch_result: Dictionary = mismatch_engine.advance_slots(1)
	var mismatch_completed: Dictionary = ((mismatch_result.get("completedActivities", []) as Array)[0] as Dictionary)
	var mismatch_outcome: Dictionary = mismatch_completed.get("outcome", {}) as Dictionary
	_check(bool(mismatch_outcome.get("regionApplied", false)) and str((mismatch_outcome.get("region", {}) as Dictionary).get("templateId", "")) == mismatch_activity_id, "생성 region template과 다른 해금 adventure는 deterministic lazy 변형 적용")

	var defeat_state: Dictionary = StateFactory.create(33003, "모험 패배")
	defeat_state["worldTier"] = 10000
	defeat_state["activeTask"] = {
		"id": "ADV_RIFT",
		"activityId": "ADV_RIFT",
		"remainingSlots": 1,
		"durationSlots": 1,
		"worldTier": 10000,
		"paidCost": BigValue.zero(),
	}
	var defeat_engine: GameEngine = GameEngine.new()
	defeat_engine.initialize_from_state(defeat_state)
	var defeat_result: Dictionary = defeat_engine.advance_slots(1)
	var defeat_completed: Array = defeat_result.get("completedActivities", []) as Array
	var defeat_outcome: Dictionary = {}
	if not defeat_completed.is_empty():
		defeat_outcome = (defeat_completed[0] as Dictionary).get("outcome", {}) as Dictionary
	var defeat_after: Dictionary = defeat_engine.get_state()
	_check(not bool(defeat_outcome.get("won", true)) and bool(defeat_outcome.get("injured", false)), "AC-WORLD-01 모험 패배/부상 분기")
	var forced_activity_id: String = str((defeat_after.get("activeTask", {}) as Dictionary).get("activityId", ""))
	var forced_activity: Dictionary = content_db.get_activity(forced_activity_id)
	_check(str(forced_activity.get("kind", "")) == "rest" and bool(defeat_after.get("forceRest", false)), "AC-WORLD-01 패배 후 강제 휴식")
	_check(_state_is_non_terminal(defeat_after), "모험 패배 후에도 비종결")

	var challenge: Dictionary = content_db.get_activity("CH_EXAM_ACADEMY")
	var challenge_engine: GameEngine = _engine_with_queued_activity("CH_EXAM_ACADEMY", 33002)
	var challenge_result: Dictionary = challenge_engine.advance_slots(int(challenge.get("durationSlots", 1)))
	var completed_challenges: Array = challenge_result.get("completedActivities", []) as Array
	_check(not completed_challenges.is_empty(), "도전 활동 완료 결과 생성")
	if not completed_challenges.is_empty():
		var completed: Dictionary = completed_challenges[0] as Dictionary
		var outcome: Dictionary = completed.get("outcome", {}) as Dictionary
		_check(str(completed.get("kind", "")) == "challenge" and str(outcome.get("type", "")) == "challenge", "도전 공통 reducer 사용")
		_check(outcome.has("won") and _finite_number(float(outcome.get("playerScore", NAN))), "도전 승패와 점수 결과")
		_check(not str(outcome.get("rivalId", "")).is_empty() and int(outcome.get("leagueTier", 0)) >= 1, "도전 결과에 생성 rival·league tier 기록")
	_check(_state_is_non_terminal(challenge_engine.get_state()), "시험/스포츠/대회 결과가 게임을 종료하지 않음")

	var league_state: Dictionary = _rich_state(33004, "리그 5단계")
	league_state["worldTier"] = 7
	(league_state["time"] as Dictionary)["year"] = 2
	(league_state["time"] as Dictionary)["season"] = 4
	(league_state["challengeLeague"] as Dictionary)["leagueTier"] = 5
	(league_state["challengeLeague"] as Dictionary)["bestScore"] = 777.0
	(league_state["challengeLeague"] as Dictionary)["seasonIndex"] = 8
	league_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 7)
	var league_engine: GameEngine = GameEngine.new()
	league_engine.initialize_from_state(league_state)
	var generated_rivals: Array = ((league_engine.get_state().get("generatedContent", {}) as Dictionary).get("rivals", []) as Array)
	var league_result: Dictionary = league_engine.advance_slots(1)
	var league_completed: Dictionary = ((league_result.get("completedActivities", []) as Array)[0] as Dictionary)
	var league_outcome: Dictionary = league_completed.get("outcome", {}) as Dictionary
	_check(int(league_outcome.get("leagueTier", 0)) == 5 and str(league_outcome.get("rivalId", "")) == str((generated_rivals[4] as Dictionary).get("id", "")), "리그 5단계가 generated rival rank 5를 실제 상대에 사용")
	_check(is_equal_approx(float(league_outcome.get("previousBestScore", 0.0)), 777.0) and int(league_outcome.get("seasonIndex", 0)) == 8, "도전 난이도/기록에 시즌·직전 최고 반영")


func _test_contract_semantics(content_db: ContentDB) -> void:
	var state: Dictionary = _rich_state(66001, "계약 의미")
	var generated: Dictionary = ProceduralGenerator.new().generate(state, content_db)
	generated["contracts"] = [{
		"id": "TEST_BALANCED",
		"kind": "balanced_cycle",
		"templateId": "balanced_cycle",
		"target": 3,
		"progress": 0,
		"targetActivityIds": ["EDU_LITERATURE"],
		"targetDurationSlots": 1,
		"modifiers": [],
		"bonusObjective": {"id": "bonus_no_injury", "metric": "injuries", "targetScale": 0.0, "rewardMultiplier": 1.18},
		"region": {},
		"reward": BigValue.from_number(100),
		"status": "active",
	}]
	state["generatedContent"] = generated
	for activity_id: String in ["EDU_LITERATURE", "JOB_CARE", "REST_HOME"]:
		state["activeTask"] = _manual_task(activity_id, 1, int(state.get("worldTier", 1)))
		state["activityQueue"] = []
		var engine: GameEngine = GameEngine.new()
		engine.initialize_from_state(state)
		engine.advance_slots(1)
		state = engine.get_state()
	var balanced: Dictionary = ((((state.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array)[0]) as Dictionary)
	_check(str(balanced.get("status", "")) == "completed" and int(balanced.get("progress", 0)) == 3, "balanced_cycle은 서로 다른 kind 3종으로 실제 progress")
	_check(bool(balanced.get("bonusAchieved", false)) and is_equal_approx(float(balanced.get("rewardMultiplier", 0.0)), 1.18), "bonusObjective 달성 시 실제 계약 보상 배율")

	var relation_state: Dictionary = _rich_state(66002, "관계 계약")
	var relation_generated: Dictionary = ProceduralGenerator.new().generate(relation_state, content_db)
	relation_generated["contracts"] = [{
		"id": "TEST_RELATION",
		"kind": "relation_gain",
		"templateId": "community_support",
		"target": 1,
		"progress": 0,
		"targetActivityIds": ["JOB_CARE"],
		"targetDurationSlots": 1,
		"modifiers": ["community_bonus"],
		"bonusObjective": {"id": "bonus_relation", "metric": "relationGained", "targetScale": 1.0, "rewardMultiplier": 1.13},
		"region": {},
		"reward": BigValue.from_number(100),
		"status": "active",
	}]
	relation_state["generatedContent"] = relation_generated
	relation_state["activeTask"] = _manual_task("JOB_CARE", 1, 1)
	var relation_before: float = float((relation_state.get("relations", {}) as Dictionary).get("citizens", 0.0))
	var relation_engine: GameEngine = GameEngine.new()
	relation_engine.initialize_from_state(relation_state)
	relation_engine.advance_slots(1)
	var relation_after: Dictionary = relation_engine.get_state()
	var relation_contract: Dictionary = (((relation_after.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array)[0] as Dictionary)
	_check(float((relation_after.get("relations", {}) as Dictionary).get("citizens", 0.0)) > relation_before and str(relation_contract.get("status", "")) == "completed", "relation_gain은 실제 관계 증가량으로 진행")
	_check(bool((relation_contract.get("modifierStatus", {}) as Dictionary).get("community_bonus", false)), "community_bonus modifier가 실제 relation gain을 검증")
	_check(is_equal_approx(float(relation_contract.get("completionRelationGain", 0.0)), 1.0), "계약 완료 시민 관계 +1 실제 반영")

	var region_state: Dictionary = _rich_state(66003, "지역 계약")
	var region_generated: Dictionary = ProceduralGenerator.new().generate(region_state, content_db)
	var region_info: Dictionary = region_generated.get("region", {}) as Dictionary
	var region_activity_id: String = str(region_info.get("templateId", "ADV_FOREST"))
	region_generated["contracts"] = [{
		"id": "TEST_REGION",
		"kind": "clear_adventure",
		"templateId": "clear_adventure",
		"target": 2,
		"progress": 0,
		"targetActivityIds": [region_activity_id],
		"targetDurationSlots": 1,
		"modifiers": [],
		"bonusObjective": {},
		"region": {"id": str(region_info.get("baseRegionId", ""))},
		"reward": BigValue.from_number(100),
		"status": "active",
	}]
	region_state["generatedContent"] = region_generated
	region_state["activeTask"] = _manual_task(region_activity_id, 1, 1)
	var region_engine: GameEngine = GameEngine.new()
	region_engine.initialize_from_state(region_state)
	region_engine.advance_slots(1)
	var region_contract: Dictionary = ((((region_engine.get_state().get("generatedContent", {}) as Dictionary).get("contracts", []) as Array)[0]) as Dictionary)
	_check(is_equal_approx(float(region_contract.get("progress", 0.0)), 1.25) and int(((region_contract.get("tracking", {}) as Dictionary).get("regionMatches", 0))) == 1, "계약 region 일치가 실제 progress 25% 보너스에 반영")

	var target_state: Dictionary = _rich_state(66004, "계약 대상 일치")
	var target_generated: Dictionary = ProceduralGenerator.new().generate(target_state, content_db)
	for raw_rival: Variant in target_generated.get("rivals", []) as Array:
		if raw_rival is Dictionary:
			var rival_scores: Dictionary = (raw_rival as Dictionary).get("scoresByChallenge", {}) as Dictionary
			rival_scores["CH_EXAM_ACADEMY"] = 1.0
			(raw_rival as Dictionary)["score"] = 1.0
	target_generated["contracts"] = [
		{
			"id": "TEST_TARGET_CHALLENGE", "kind": "win_challenge", "target": 1, "progress": 0,
			"targetActivityIds": ["CH_EXAM_MAGIC"], "targetKind": "challenge", "modifiers": [],
			"bonusObjective": {}, "region": {}, "reward": BigValue.from_number(100), "status": "active",
		},
		{
			"id": "TEST_TARGET_ADVENTURE", "kind": "clear_adventure", "target": 1, "progress": 0,
			"targetActivityIds": ["ADV_CAVE"], "targetKind": "adventure", "modifiers": [],
			"bonusObjective": {}, "region": {}, "reward": BigValue.from_number(100), "status": "active",
		},
	]
	target_state["generatedContent"] = target_generated
	target_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 1)
	var target_engine: GameEngine = GameEngine.new()
	target_engine.initialize_from_state(target_state)
	var wrong_challenge_completed: Dictionary = ((target_engine.advance_slots(1).get("completedActivities", []) as Array)[0] as Dictionary)
	var target_after_challenge: Dictionary = target_engine.get_state()
	var contracts_after_challenge: Array = (target_after_challenge.get("generatedContent", {}) as Dictionary).get("contracts", []) as Array
	_check(bool((wrong_challenge_completed.get("outcome", {}) as Dictionary).get("won", false)) and is_zero_approx(float((contracts_after_challenge[0] as Dictionary).get("progress", 0.0))), "win_challenge는 다른 도전 승리로 진행되지 않음")
	target_after_challenge["activeTask"] = _manual_task("ADV_FOREST", 1, 1)
	target_after_challenge["activityQueue"] = []
	var wrong_adventure_engine: GameEngine = GameEngine.new()
	wrong_adventure_engine.initialize_from_state(target_after_challenge)
	var wrong_adventure_completed: Dictionary = ((wrong_adventure_engine.advance_slots(1).get("completedActivities", []) as Array)[0] as Dictionary)
	var contracts_after_adventure: Array = (wrong_adventure_engine.get_state().get("generatedContent", {}) as Dictionary).get("contracts", []) as Array
	_check(bool((wrong_adventure_completed.get("outcome", {}) as Dictionary).get("won", false)) and is_zero_approx(float((contracts_after_adventure[1] as Dictionary).get("progress", 0.0))), "clear_adventure는 다른 모험 클리어로 진행되지 않음")

	var match_planner: Planner = Planner.new()
	match_planner.configure(content_db.config, content_db.profiles, content_db.activities)
	var exact_challenge_contract: Dictionary = {"kind": "win_challenge", "targetActivityIds": ["CH_EXAM_MAGIC"], "targetKind": "challenge"}
	var cross_kind_stat_contract: Dictionary = {"kind": "gain_stat", "targetActivityIds": ["EDU_LITERATURE"], "targetStat": "stamina"}
	_check(not match_planner.contract_activity_matches(exact_challenge_contract, content_db.get_activity("CH_EXAM_ACADEMY")) and match_planner.contract_activity_matches(cross_kind_stat_contract, content_db.get_activity("JOB_FARM")), "Planner와 reducer가 공유하는 계약 대상 predicate: 정확 ID·gain_stat 교차 kind")
	var pinned_stat_state: Dictionary = StateFactory.create(66005, "플래너 계약", content_db.config)
	pinned_stat_state["generatedContent"] = {"contracts": [{"id": "PIN_STAT", "kind": "gain_stat", "targetActivityIds": ["EDU_LITERATURE"], "targetStat": "stamina", "status": "active"}], "pinnedContractId": "PIN_STAT"}
	var pinned_stat_score: float = float(match_planner.choose(pinned_stat_state, [content_db.get_activity("JOB_FARM")]).get("score", 0.0))
	(pinned_stat_state["generatedContent"] as Dictionary)["pinnedContractId"] = ""
	var unpinned_stat_score: float = float(match_planner.choose(pinned_stat_state, [content_db.get_activity("JOB_FARM")]).get("score", 0.0))
	_check(absf((pinned_stat_score - unpinned_stat_score) - 0.18) < 0.000001, "gain_stat 교차 kind 활동에 Planner 고정 계약 보너스 적용")


func _test_extended_infinite_rules(content_db: ContentDB) -> void:
	var event_state: Dictionary = StateFactory.create(67001, "일정 이벤트", content_db.config)
	(event_state["time"] as Dictionary)["slot"] = 11
	for relation_id: Variant in (event_state.get("relations", {}) as Dictionary).keys():
		(event_state["relations"] as Dictionary)[relation_id] = 0.0
	event_state["activeTask"] = _manual_task("EDU_LITERATURE", 3, 1)
	(event_state["activeTask"] as Dictionary)["startedAtSlot"] = 11
	var event_engine: GameEngine = GameEngine.new()
	event_engine.initialize_from_state(event_state)
	event_engine.advance_slots(3)
	var caught_scheduled_event: bool = false
	for raw_event: Variant in event_engine.get_state().get("eventInbox", []) as Array:
		caught_scheduled_event = caught_scheduled_event or raw_event is Dictionary and str((raw_event as Dictionary).get("id", "")) == "EV_SPRING_FAIR"
	_check(caught_scheduled_event, "장기 활동 완료가 지나온 season_slot 이벤트를 catch-up하고 최대 1개 큐잉")
	_check((event_engine.get_state().get("eventInbox", []) as Array).size() == 1, "한 활동 완료당 이벤트 최대 1개")

	var locked_engine: GameEngine = GameEngine.new()
	locked_engine.initialize_from_state(StateFactory.create(67002, "해금 전"))
	var unlock_state: Dictionary = locked_engine.get_state()
	var initially_locked_region: bool = not bool(((unlock_state.get("generatedContent", {}) as Dictionary).get("region", {}) as Dictionary).get("active", true))
	(unlock_state["stats"] as Dictionary)["stamina"] = 120.0
	unlock_state["activeTask"] = _manual_task("ADV_FOREST", 2, 1)
	(unlock_state["activeTask"] as Dictionary)["startedAtSlot"] = int((unlock_state.get("time", {}) as Dictionary).get("slot", 0))
	var unlock_engine: GameEngine = GameEngine.new()
	unlock_engine.initialize_from_state(unlock_state)
	var unlock_result: Dictionary = unlock_engine.advance_slots(2)
	var unlock_completed: Dictionary = ((unlock_result.get("completedActivities", []) as Array)[0] as Dictionary)
	var unlock_outcome: Dictionary = unlock_completed.get("outcome", {}) as Dictionary
	_check(initially_locked_region and bool(unlock_outcome.get("regionApplied", false)) and str((unlock_outcome.get("region", {}) as Dictionary).get("templateId", "")) == "ADV_FOREST", "시즌 중 첫 모험 해금 시 REG_LOCKED를 현재 activity lazy variant로 교체")

	var incident_count: int = 0
	var normal_count: int = 0
	var deterministic_incident: bool = true
	for incident_seed: int in range(32):
		var outcomes: Array[Dictionary] = []
		for repeat_index: int in range(2):
			var incident_state: Dictionary = _rich_state(67100 + incident_seed, "위험 업무")
			incident_state["activeTask"] = _manual_task("JOB_RANGER", 1, 1)
			var incident_engine: GameEngine = GameEngine.new()
			incident_engine.initialize_from_state(incident_state)
			var incident_result: Dictionary = incident_engine.advance_slots(1)
			var incident_completed: Dictionary = ((incident_result.get("completedActivities", []) as Array)[0] as Dictionary)
			outcomes.append(incident_completed.get("outcome", {}) as Dictionary)
		deterministic_incident = deterministic_incident and bool(outcomes[0].get("incident", false)) == bool(outcomes[1].get("incident", false)) and is_equal_approx(float(outcomes[0].get("riskRoll", -1.0)), float(outcomes[1].get("riskRoll", -2.0)))
		if bool(outcomes[0].get("incident", false)):
			incident_count += 1
			deterministic_incident = deterministic_incident and float(outcomes[0].get("rewardMultiplier", 1.0)) < 1.0 and float((outcomes[0].get("effects", {}) as Dictionary).get("stress", 0.0)) > 0.0
		else:
			normal_count += 1
	_check(deterministic_incident and incident_count > 0 and normal_count > 0, "job risk가 seed/slot 격리 난수로 결정적 incident·정상 분기 및 보상/스트레스 효과")

	var safe_job_state: Dictionary = _rich_state(67200, "안전 업무")
	safe_job_state["activeTask"] = _manual_task("JOB_SANCTUARY", 1, 1)
	var safe_job_engine: GameEngine = GameEngine.new()
	safe_job_engine.initialize_from_state(safe_job_state)
	var safe_job_completed: Dictionary = ((safe_job_engine.advance_slots(1).get("completedActivities", []) as Array)[0] as Dictionary)
	_check(not bool((safe_job_completed.get("outcome", {}) as Dictionary).get("incident", true)), "risk 0 업무는 incident 없음")

	var preferred_planner: Planner = Planner.new()
	preferred_planner.configure(content_db.config, content_db.profiles, content_db.activities)
	var preferred_state: Dictionary = StateFactory.create(67300, "선호 태그", content_db.config)
	preferred_state["growthPolicy"] = GrowthPolicy.create("scholar")
	var candidate_base: Dictionary = {
		"kind": "education", "name": "동일 후보", "durationSlots": 1, "baseCost": 0, "baseReward": 0,
		"energyDelta": 0, "stressDelta": 0, "risk": 0.0, "primaryStat": "intelligence",
		"gains": {"intelligence": 10}, "requires": {},
	}
	var academic_candidate: Dictionary = candidate_base.duplicate(true)
	academic_candidate["id"] = "TEST_ACADEMIC"
	academic_candidate["tags"] = ["academic"]
	var martial_candidate: Dictionary = candidate_base.duplicate(true)
	martial_candidate["id"] = "TEST_MARTIAL"
	martial_candidate["tags"] = ["martial"]
	var preferred_decision: Dictionary = preferred_planner.choose(preferred_state, [martial_candidate, academic_candidate])
	_check(str(preferred_decision.get("activityId", "")) == "TEST_ACADEMIC" and float(preferred_decision.get("preferredTagBonus", 0.0)) > 0.0, "profiles preferredTags가 Planner 후보 점수와 이유에 실제 반영")

	var reward_state: Dictionary = _rich_state(67400, "도전 단일 보상")
	(reward_state["bigValues"] as Dictionary)["gold"] = BigValue.zero()
	(reward_state["bigValues"] as Dictionary)["lifetimeGold"] = BigValue.zero()
	reward_state["forceRest"] = true
	reward_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 1)
	reward_state["generatedContent"] = {"contracts": [{"id": "TEST_NOOP", "status": "completed"}], "rivals": [], "region": {}, "pinnedContractId": ""}
	var reward_engine: GameEngine = GameEngine.new()
	reward_engine.initialize_from_state(reward_state)
	var reward_before: Dictionary = (reward_engine.get_state().get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary
	var reward_completed: Dictionary = ((reward_engine.advance_slots(1).get("completedActivities", []) as Array)[0] as Dictionary)
	var reward_after: Dictionary = (reward_engine.get_state().get("bigValues", {}) as Dictionary).get("gold", BigValue.zero()) as Dictionary
	var next_task: Variant = reward_engine.get_state().get("activeTask", null)
	var next_paid_cost: Dictionary = (next_task as Dictionary).get("paidCost", BigValue.zero()) as Dictionary if next_task is Dictionary else BigValue.zero()
	var reward_delta: Dictionary = BigValue.subtract(BigValue.add(reward_after, next_paid_cost), reward_before)
	var challenge_reward: Dictionary = ((reward_completed.get("outcome", {}) as Dictionary).get("rewardGold", BigValue.zero()) as Dictionary)
	_check(BigValue.compare(reward_delta, challenge_reward) == 0 and BigValue.compare(reward_completed.get("reward", BigValue.zero()) as Dictionary, challenge_reward) == 0, "challenge rewardTable 골드는 공통 baseReward와 중복 지급되지 않음")
	_check(int(reward_completed.get("mastery", 0)) == int((reward_completed.get("outcome", {}) as Dictionary).get("masteryExperience", 0)), "challenge rewardTable mastery 1/3/5가 실제 숙련 누적")

	var win_targets_valid: bool = true
	var season_rates_valid: bool = true
	for sampled_season_index: int in [1, 10000, 1000000]:
		var wins_by_league: Array[int] = [0, 0, 0, 0, 0]
		var samples_per_league: int = 60
		for sample_index: int in range(samples_per_league):
			var sample_seed: int = 67500 + sampled_season_index * 1000 + sample_index
			var sample_state: Dictionary = _rich_state(sample_seed, "승률 표본")
			(sample_state["time"] as Dictionary)["year"] = int((sampled_season_index - 1) / 4) + 1
			(sample_state["time"] as Dictionary)["season"] = (sampled_season_index - 1) % 4 + 1
			(sample_state["challengeLeague"] as Dictionary)["leagueTier"] = 1
			(sample_state["challengeLeague"] as Dictionary)["seasonIndex"] = sampled_season_index
			sample_state["generatedContent"] = ProceduralGenerator.new().generate(sample_state, content_db)
			var sampled_rivals: Array = (sample_state.get("generatedContent", {}) as Dictionary).get("rivals", []) as Array
			for league_index: int in range(sampled_rivals.size()):
				var target_rival: Dictionary = sampled_rivals[league_index] as Dictionary
				var effective_rate: float = float((target_rival.get("effectiveWinRatesByChallenge", {}) as Dictionary).get("CH_EXAM_ACADEMY", -1.0))
				win_targets_valid = win_targets_valid and float(target_rival.get("targetWinRate", 0.0)) >= 0.35 and float(target_rival.get("targetWinRate", 1.0)) <= 0.80 and effective_rate >= 0.35 and effective_rate <= 0.80
			sample_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 1)
			var sample_engine: GameEngine = GameEngine.new()
			sample_engine.initialize_from_state(sample_state)
			var sample_completed: Dictionary = ((sample_engine.advance_slots(1).get("completedActivities", []) as Array)[0] as Dictionary)
			var sample_outcome: Dictionary = sample_completed.get("outcome", {}) as Dictionary
			var player_score: float = float(sample_outcome.get("playerScore", 0.0))
			var activity_floor: float = float(sample_outcome.get("activityDifficultyFloor", 0.0))
			for league_index: int in range(sampled_rivals.size()):
				var rival_score: float = float(((sampled_rivals[league_index] as Dictionary).get("scoresByChallenge", {}) as Dictionary).get("CH_EXAM_ACADEMY", 0.0))
				if player_score >= maxf(activity_floor, rival_score):
					wins_by_league[league_index] += 1
		for league_index: int in range(wins_by_league.size()):
			var sampled_win_rate: float = float(wins_by_league[league_index]) / float(samples_per_league)
			print("[TEST] rival season %d league %d sampled win rate=%.3f (%d/%d)" % [sampled_season_index, league_index + 1, sampled_win_rate, wins_by_league[league_index], samples_per_league])
			season_rates_valid = season_rates_valid and sampled_win_rate >= 0.35 and sampled_win_rate <= 0.80
	_check(win_targets_valid and season_rates_valid, "5단계 각 라이벌의 초기·장기 시즌 seeded 실승률 35~80% 범위")

	var sale_state: Dictionary = _rich_state(67600, "강화 판매")
	sale_state["worldTier"] = 1
	var sale_engine: GameEngine = GameEngine.new()
	sale_engine.initialize_from_state(sale_state)
	sale_engine.buy_item("OUTFIT_PLAIN", 1)
	var high_tier_sale_state: Dictionary = sale_engine.get_state()
	high_tier_sale_state["worldTier"] = 100
	var high_tier_sale_engine: GameEngine = GameEngine.new()
	high_tier_sale_engine.initialize_from_state(high_tier_sale_state)
	var sale_result: Dictionary = high_tier_sale_engine.sell_item("OUTFIT_PLAIN", 1)
	_check(int(sale_result.get("enhancementLevel", 0)) == 1 and absf(BigValue.to_float(sale_result.get("proceeds", BigValue.zero()) as Dictionary) - 120.0) < 0.0001, "장비 판매가는 현재 tier가 아닌 저장 enhancementLevel 기준 50%")


func _test_relationship_system(content_db: ContentDB) -> void:
	var gift_engine: GameEngine = GameEngine.new()
	gift_engine.initialize_from_state(_rich_state(66101, "선물"))
	gift_engine.buy_item("ITEM_TEA", 1)
	var invalid_gift: Dictionary = gift_engine.gift_item("ITEM_TEA", "unknown")
	_check(not bool(invalid_gift.get("ok", true)) and _inventory_count(gift_engine.get_state(), "ITEM_TEA") == 1, "선물은 4개 관계 축 외 거부하고 아이템 보존")
	var guardian_before: float = float((gift_engine.get_state().get("relations", {}) as Dictionary).get("guardian", 0.0))
	var gift: Dictionary = gift_engine.gift_item("ITEM_TEA", "guardian")
	_check(bool(gift.get("ok", false)) and is_equal_approx(float(gift.get("relationGain", 0.0)), 5.0) and _inventory_count(gift_engine.get_state(), "ITEM_TEA") == 0, "gift_item 소비품 1개 제거 + 기본3/tag affinity2 관계 증가")
	_check(is_equal_approx(float((gift_engine.get_state().get("relations", {}) as Dictionary).get("guardian", 0.0)), guardian_before + 5.0), "선물 관계 상태 반영")

	var gains_by_relation: Array[float] = []
	for steward_relation: int in [0, 1000]:
		var relation_state: Dictionary = _rich_state(66102, "관계 활동")
		(relation_state["relations"] as Dictionary)["steward"] = steward_relation
		relation_state["activeTask"] = _manual_task("EDU_LITERATURE", 1, 1)
		var relation_engine: GameEngine = GameEngine.new()
		relation_engine.initialize_from_state(relation_state)
		var activity_result: Dictionary = relation_engine.advance_slots(1)
		var completed: Dictionary = ((activity_result.get("completedActivities", []) as Array)[0] as Dictionary)
		gains_by_relation.append(float((completed.get("gains", {}) as Dictionary).get("intelligence", 0.0)))
	var planner: Planner = Planner.new()
	planner.configure(content_db.config)
	var planner_state: Dictionary = _rich_state(66103, "관계 공식")
	(planner_state["relations"] as Dictionary)["steward"] = 1000
	_check(is_equal_approx(planner.relation_modifier(planner_state, content_db.get_activity("EDU_LITERATURE")), 1.2), "관계 활동 배율 1+0.0002×relation, 최대1.2")
	_check(absf(gains_by_relation[1] / gains_by_relation[0] - 1.2) < 0.003, "관계 기반 활동 보너스가 실제 성장 reducer에 반영")


func _test_shop_non_terminal() -> void:
	var state: Dictionary = _rich_state(44001, "상점")
	var engine: GameEngine = GameEngine.new()
	engine.initialize_from_state(state)
	var before_activities: int = int((engine.get_state().get("lifetimeStats", {}) as Dictionary).get("activities", -1))
	var buy_stack: Dictionary = engine.buy_item("ITEM_TEA", 150)
	_check(bool(buy_stack.get("ok", false)), "AC-CONTENT-04 소비품 구매")
	_check(_inventory_count(engine.get_state(), "ITEM_TEA") == 99, "AC-CONTENT-04 소비품 최대 중첩 99")
	var sell_stack: Dictionary = engine.sell_item("ITEM_TEA", 1)
	var proceeds: Dictionary = sell_stack.get("proceeds", BigValue.zero()) as Dictionary
	_check(bool(sell_stack.get("ok", false)) and _inventory_count(engine.get_state(), "ITEM_TEA") == 98, "AC-CONTENT-04 판매와 중첩 감소")
	_check(absf(BigValue.to_float(proceeds) - 47.5) < 0.000001, "AC-CONTENT-04 판매가 50%")

	var buy_equipment: Dictionary = engine.buy_item("OUTFIT_PLAIN", 1)
	var equip: Dictionary = engine.equip_item("OUTFIT_PLAIN")
	_check(bool(buy_equipment.get("ok", false)) and bool(equip.get("ok", false)), "장비 구매와 장착")
	_check(str((engine.get_state().get("equipment", {}) as Dictionary).get("outfit", "")) == "OUTFIT_PLAIN", "AC-CONTENT-04 장비 슬롯 규칙")
	var use_result: Dictionary = engine.use_item("ITEM_TEA")
	_check(bool(use_result.get("ok", false)), "소비품 사용")
	var after_state: Dictionary = engine.get_state()
	_check(int((after_state.get("lifetimeStats", {}) as Dictionary).get("activities", -2)) == before_activities, "상점 동작이 진행 상태를 초기화하지 않음")
	_check(_state_is_non_terminal(after_state), "상점 동작 비종결")

	var tier_state: Dictionary = _rich_state(44002, "강화 장비")
	tier_state["worldTier"] = 64
	(tier_state["bigValues"] as Dictionary)["gold"] = BigValue.from_log10(100.0)
	var tier_engine: GameEngine = GameEngine.new()
	tier_engine.initialize_from_state(tier_state)
	var tier_buy: Dictionary = tier_engine.buy_item("OUTFIT_PLAIN", 1)
	var tier_inventory: Array = tier_engine.get_state().get("inventory", []) as Array
	_check(bool(tier_buy.get("ok", false)) and int(tier_buy.get("enhancementLevel", 0)) == 64 and int((tier_inventory[0] as Dictionary).get("enhancementLevel", 0)) == 64, "장비 구매 시 worldTier 강화 레벨 저장")

	var score_by_level: Array[float] = []
	for enhancement_level: int in [1, 64]:
		var score_state: Dictionary = _rich_state(44003, "강화 점수")
		score_state["inventory"] = [{"id": "OUTFIT_PLAIN", "count": 1}] if enhancement_level == 1 else [{"id": "OUTFIT_PLAIN", "count": 1, "enhancementLevel": enhancement_level}]
		(score_state["equipment"] as Dictionary)["outfit"] = "OUTFIT_PLAIN"
		score_state["activeTask"] = _manual_task("CH_EXAM_ACADEMY", 1, 1)
		var score_engine: GameEngine = GameEngine.new()
		score_engine.initialize_from_state(score_state)
		var score_result: Dictionary = score_engine.advance_slots(1)
		var score_completed: Dictionary = ((score_result.get("completedActivities", []) as Array)[0] as Dictionary)
		score_by_level.append(float((score_completed.get("outcome", {}) as Dictionary).get("playerScore", 0.0)))
	var expected_delta: float = 3.0 * 0.08 * sqrt(63.0)
	_check(absf((score_by_level[1] - score_by_level[0]) - expected_delta) < 0.02, "장비 modifier가 1+0.08×sqrt(level-1)로 실제 도전 점수에 반영")


func _test_career_non_terminal() -> void:
	var state: Dictionary = _rich_state(55001, "칭호")
	for stat_key: Variant in (state.get("stats", {}) as Dictionary).keys():
		(state["stats"] as Dictionary)[stat_key] = 1.0e9
	(state["meters"] as Dictionary)["reputation"] = 1.0e9
	(state["meters"] as Dictionary)["integrityViolations"] = 100000
	for relation_key: Variant in (state.get("relations", {}) as Dictionary).keys():
		(state["relations"] as Dictionary)[relation_key] = 1.0e9
	(state["relations"] as Dictionary)["citizens"] = 2.0e9
	for lifetime_key: Variant in (state.get("lifetimeStats", {}) as Dictionary).keys():
		(state["lifetimeStats"] as Dictionary)[lifetime_key] = 100000
	state["worldTier"] = 100
	(state["bigValues"] as Dictionary)["renown"] = BigValue.from_log10(120.0)
	(state["bigValues"] as Dictionary)["lifetimeRenown"] = BigValue.from_log10(120.0)
	state["activityQueue"] = ["REST_HOME"]

	var engine: GameEngine = GameEngine.new()
	engine.initialize_from_state(state)
	var first_review: Dictionary = engine.advance_slots(28)
	var after_first: Dictionary = engine.get_state()
	var titles_first: Dictionary = after_first.get("careerTitles", {}) as Dictionary
	print("[TEST] career first review titles=%d worldTier=%d" % [titles_first.size(), int(after_first.get("worldTier", 0))])
	if titles_first.size() != 38:
		var missing_titles: Array[String] = []
		for career: Dictionary in engine.get_content_db().get_careers():
			if not titles_first.has(str(career.get("id", ""))):
				missing_titles.append(str(career.get("id", "")))
		print("[TEST] career missing=%s" % ",".join(missing_titles))
	_check(not (first_review.get("seasonReviews", []) as Array).is_empty(), "시즌 심사 실행")
	_check(titles_first.size() == 38, "AC-CONTENT-05 진로 칭호 38개 획득")
	var relation_title_variant: bool = false
	for raw_title: Variant in titles_first.values():
		if raw_title is Dictionary and str((raw_title as Dictionary).get("variant", "")) == "guardian" and str((raw_title as Dictionary).get("variantName", "")).begins_with("후견의"):
			relation_title_variant = true
			break
	_check(relation_title_variant, "높은 관계가 진로 칭호 표시 변형을 개방")

	engine.advance_slots(28)
	var after_second: Dictionary = engine.get_state()
	var titles_second: Dictionary = after_second.get("careerTitles", {}) as Dictionary
	print("[TEST] career second review titles=%d worldTier=%d" % [titles_second.size(), int(after_second.get("worldTier", 0))])
	var repeated_star: bool = titles_second.size() == 38
	for title_id: Variant in titles_second.keys():
		var title_value: Variant = titles_second[title_id]
		if title_value is not Dictionary or int((title_value as Dictionary).get("stars", 0)) < 2:
			repeated_star = false
			break
	_check(repeated_star, "AC-CONTENT-06 38개 칭호 반복 심사 별 증가")
	_check(engine.career_rank_text(6) == "명인 +1", "5성 이후 무한 명인 표기")
	_check(int((after_second.get("time", {}) as Dictionary).get("slot", -1)) >= 56, "칭호 획득 후 시간 진행 지속")
	_check(_state_is_non_terminal(after_second), "AC-CONTENT-05 칭호가 게임을 종료/초기화하지 않음")


func _engine_with_queued_activity(activity_id: String, seed_value: int) -> GameEngine:
	var state: Dictionary = _rich_state(seed_value, activity_id)
	state["activityQueue"] = []
	state["activeTask"] = _manual_task(activity_id, 1, 1)
	var engine: GameEngine = GameEngine.new()
	engine.initialize_from_state(state)
	return engine


func _manual_task(activity_id: String, remaining_slots: int, world_tier: int) -> Dictionary:
	return {
		"id": activity_id,
		"activityId": activity_id,
		"remainingSlots": maxi(1, remaining_slots),
		"durationSlots": maxi(1, remaining_slots),
		"worldTier": maxi(1, world_tier),
		"paidCost": BigValue.zero(),
	}


func _rich_state(seed_value: int, player_name: String) -> Dictionary:
	var state: Dictionary = StateFactory.create(seed_value, player_name)
	(state["bigValues"] as Dictionary)["gold"] = BigValue.from_number(1.0e12)
	(state["bigValues"] as Dictionary)["lifetimeGold"] = BigValue.from_number(1.0e12)
	for stat_key: Variant in (state.get("stats", {}) as Dictionary).keys():
		(state["stats"] as Dictionary)[stat_key] = 5000.0
	(state["meters"] as Dictionary)["energy"] = 100.0
	(state["meters"] as Dictionary)["stress"] = 0.0
	return state


func _inventory_count(state: Dictionary, item_id: String) -> int:
	for raw_entry: Variant in state.get("inventory", []) as Array:
		if raw_entry is Dictionary and str((raw_entry as Dictionary).get("id", "")) == item_id:
			return int((raw_entry as Dictionary).get("count", 0))
	return 0


func _state_is_non_terminal(state: Dictionary) -> bool:
	if int(state.get("schemaVersion", 0)) != 2 or state.is_empty():
		return false
	var flags: Dictionary = state.get("flags", {}) as Dictionary
	for key: String in ["gameOver", "ended", "terminal", "hardReset"]:
		if bool(state.get(key, false)) or bool(flags.get(key, false)):
			return false
	return state.has("stats") and state.has("time") and state.has("growthPolicy")


func _all_unique_ids(entries: Array[Dictionary]) -> bool:
	var ids: Dictionary = {}
	for entry: Dictionary in entries:
		var content_id: String = str(entry.get("id", ""))
		if content_id.is_empty() or ids.has(content_id):
			return false
		ids[content_id] = true
	return true


func _weights_match(actual: Dictionary, expected: Dictionary) -> bool:
	for key: String in GrowthPolicy.ALLOWED_WEIGHT_KEYS:
		if absf(float(actual.get(key, 0.0)) - float(expected.get(key, 0.0))) > 0.000000001:
			return false
	return true


func _contract_definition_compatible(contract: Dictionary, content_db: ContentDB) -> bool:
	var target_ids: Array = contract.get("targetActivityIds", []) as Array
	if target_ids.is_empty():
		return false
	var target: Dictionary = content_db.get_activity(str(target_ids[0]))
	if target.is_empty():
		return false
	if str(contract.get("kind", "")) == "balanced_cycle" and int(contract.get("target", 99)) > 5:
		return false
	if str(contract.get("kind", "")) == "win_challenge" and int(contract.get("target", 0)) != 1:
		return false
	if str(contract.get("kind", "")) == "relation_gain" and not (target.get("tags", []) as Array).has("service"):
		return false
	if int(contract.get("targetDurationSlots", 0)) != maxi(1, int(target.get("durationSlots", 1))):
		return false
	for raw_modifier: Variant in contract.get("modifiers", []) as Array:
		var modifier_id: String = str(raw_modifier)
		if modifier_id == "risk_bonus" and float(target.get("risk", 0.0)) < 0.2 and not ["adventure", "challenge"].has(str(target.get("kind", ""))):
			return false
		if modifier_id == "community_bonus" and not (target.get("tags", []) as Array).has("service") and str(contract.get("kind", "")) != "relation_gain":
			return false
	return true


func _contract_reachable_by_generator_plan(contract: Dictionary, state: Dictionary, content_db: ContentDB, generator: ProceduralGenerator) -> bool:
	var target_ids: Array = contract.get("targetActivityIds", []) as Array
	if target_ids.is_empty():
		return false
	var target := content_db.get_activity(str(target_ids[0]))
	if target.is_empty():
		return false
	var slots_per_season := maxi(1, int(content_db.config.get("slotsPerSeason", 28)))
	var next_slot := int((state.get("time", {}) as Dictionary).get("slot", 0)) % slots_per_season + 1
	var unlocked: Array[Dictionary] = generator.call("_unlocked_activities", state, content_db.activities)
	var template_kind := str(contract.get("kind", "complete_kind"))
	var target_count := maxi(1, int(ceil(float(contract.get("target", 1.0)))))
	var plan: Dictionary
	if template_kind == "balanced_cycle":
		plan = generator.call("_balanced_completion_plan", state, unlocked, content_db.config, next_slot)
		if int(plan.get("kindCount", 0)) < target_count:
			return false
	else:
		plan = generator.call("_target_completion_plan", state, target, unlocked, content_db.config, next_slot, template_kind)
		var required_actions := int(generator.call("_required_target_actions", template_kind, target_count, state, target, content_db.config))
		if required_actions <= 0 or int(plan.get("actions", 0)) < required_actions:
			return false
		if template_kind == "relation_gain" and float(contract.get("target", 0.0)) > float(generator.call("_contract_relation_total_headroom", state, target)) + 0.0001:
			return false
	var requirements_by_modifier: Dictionary = contract.get("modifierRequirements", {}) as Dictionary
	for raw_modifier: Variant in contract.get("modifiers", []) as Array:
		var modifier_id := str(raw_modifier)
		if not bool(generator.call(
			"_modifier_compatible",
			modifier_id,
			target,
			str(contract.get("targetKind", "")),
			template_kind,
			target_count,
			state,
			unlocked,
			content_db.config,
			next_slot,
			requirements_by_modifier.get(modifier_id, {}) as Dictionary,
			plan
		)):
			return false
	return true


func _canonical(value: Variant) -> String:
	return JSON.stringify(value, "", true, true)


func _contains_non_finite(value: Variant) -> bool:
	match typeof(value):
		TYPE_FLOAT:
			return not _finite_number(float(value))
		TYPE_ARRAY:
			for child: Variant in value as Array:
				if _contains_non_finite(child):
					return true
		TYPE_DICTIONARY:
			for child: Variant in (value as Dictionary).values():
				if _contains_non_finite(child):
					return true
	return false


func _finite_number(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


func _has_invalid_number_text(value: String) -> bool:
	var upper: String = value.to_upper()
	return upper.contains("NAN") or upper.contains("INF")


func _cleanup_save_path(path: String) -> void:
	var absolute_path: String = ProjectSettings.globalize_path(path)
	for suffix: String in ["", ".tmp", ".bak"]:
		var candidate: String = absolute_path + suffix
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	if _failures.is_empty():
		print("[TEST] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[TEST] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	for failure: String in _failures:
		print("[TEST]   - %s" % failure)
	quit(1)
