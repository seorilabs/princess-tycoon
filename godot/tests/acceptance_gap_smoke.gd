extends SceneTree

const MainScreen = preload("res://src/ui/main_screen.gd")
const RoyalTheme = preload("res://src/ui/royal_theme.gd")
const ProceduralTrainee = preload("res://src/ui/procedural_trainee.gd")

const SAVE_PATH: String = "user://princess_tycoon_acceptance_gap_smoke.json"
const FONT_PATH: String = "res://assets/fonts/NotoSansKR-VariableFont_wght.ttf"

var _failures: Array[String] = []
var _passes: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[ACCEPTANCE-GAP] 계약 직접 증거 보강 smoke")
	_cleanup_save_path(SAVE_PATH)
	var content_db := ContentDB.new()
	var report: Dictionary = content_db.load_all("res://data")
	_check(bool(report.get("ok", false)), "선행조건: 콘텐츠 DB 로드", str(report.get("errors", [])))
	if not bool(report.get("ok", false)):
		_finish()
		return

	_test_policy_boundary_and_ui_reasons(content_db)
	_test_activity_economy_formula_and_history(content_db)
	_test_event_queue_and_default_timeout(content_db)
	_test_recent_template_weight_and_rng_isolation(content_db)
	_test_ui_new_policy_activity_save_continue(content_db)
	await _test_ui_accessibility_and_first_surface(content_db)

	_finish()


func _test_policy_boundary_and_ui_reasons(content_db: ContentDB) -> void:
	var state := StateFactory.create(71001, "정책 경계", content_db.config)
	_prevent_generated_contract_side_effects(state)
	state["activeTask"] = {
		"id": "EDU_LITERATURE",
		"activityId": "EDU_LITERATURE",
		"name": "왕립 교양학",
		"reason": "기존 학문 방향",
		"startedAtSlot": 0,
		"durationSlots": 2,
		"remainingSlots": 2,
		"worldTier": 1,
		"paidCost": BigValue.zero(),
	}
	var engine := GameEngine.new()
	engine.initialize_from_state(state)
	var before_task: Dictionary = engine.get_state().get("activeTask", {}) as Dictionary
	engine.set_policy({
		"preset": "martial",
		"weights": {},
		"bannedTags": ["study"],
		"reserveGold": BigValue.zero(),
		"maxStress": 90.0,
		"riskTolerance": 1.0,
	})
	var after_policy: Dictionary = engine.get_state()
	var preserved_task: Dictionary = after_policy.get("activeTask", {}) as Dictionary
	_check(
		str(preserved_task.get("activityId", "")) == str(before_task.get("activityId", ""))
		and int(preserved_task.get("remainingSlots", -1)) == int(before_task.get("remainingSlots", -2)),
		"AC-PLAN-04 정책 변경 시 진행 중 활동 보존"
	)
	var advance: Dictionary = engine.advance_slots(2)
	var completed_old := false
	for raw_completed: Variant in advance.get("completedActivities", []) as Array:
		if raw_completed is Dictionary and str((raw_completed as Dictionary).get("activityId", "")) == "EDU_LITERATURE":
			completed_old = true
	var next_state: Dictionary = engine.get_state()
	var next_task: Dictionary = next_state.get("activeTask", {}) as Dictionary
	var next_activity: Dictionary = content_db.get_activity(str(next_task.get("activityId", "")))
	var next_avoids_new_ban := not next_activity.is_empty() and not (next_activity.get("tags", []) as Array).has("study")
	var rejected: Dictionary = (next_state.get("lastPlannerDecision", {}) as Dictionary).get("rejected", {}) as Dictionary
	_check(completed_old, "AC-PLAN-04 기존 활동이 변경 정책에도 정상 완료")
	_check(
		next_avoids_new_ban and rejected.has("EDU_LITERATURE"),
		"AC-PLAN-04 새 정책은 다음 선택부터 반영",
		"next=%s rejected=%s" % [str(next_task.get("activityId", "")), str(rejected.get("EDU_LITERATURE", ""))]
	)

	var ui: Control = MainScreen.new()
	var ui_state := StateFactory.create(71002, "이유 표시", content_db.config)
	_prevent_generated_contract_side_effects(ui_state)
	ui_state["activeTask"] = {
		"activityId": "REST_WALK",
		"id": "REST_WALK",
		"name": "왕도 산책",
		"reason": "첫째 이유",
		"remainingSlots": 1,
	}
	ui_state["lastPlannerDecision"] = {
		"activityId": "REST_WALK",
		"reasons": ["성장 방향 일치", "예산 안전", "최근 활동 다양성"],
	}
	ui.set("_state", ui_state)
	ui.set("_activities", content_db.get_activities())
	var reason_text: String = str(ui.call("_planner_reason"))
	var reason_parts: PackedStringArray = reason_text.split(" · ", false)
	var home: Control = ui.call("_build_home_page") as Control
	var labels: Array[String] = _collect_label_texts(home)
	_check(
		reason_parts.size() == 3
		and reason_parts[0] == "성장 방향 일치"
		and reason_parts[1] == "예산 안전"
		and reason_parts[2] == "최근 활동 다양성",
		"AC-PLAN-05 UI 선택 이유 상위 3개 실제 조합",
		reason_text
	)
	_check(labels.has(reason_text), "AC-PLAN-05 홈 활동 카드에 이유 3개 실제 표시")
	home.free()
	ui.free()


func _test_activity_economy_formula_and_history(content_db: ContentDB) -> void:
	var planner := Planner.new()
	planner.configure(content_db.config)
	var literature: Dictionary = content_db.get_activity("EDU_LITERATURE")
	var cost_state := StateFactory.create(72001, "비용", content_db.config)
	_prevent_generated_contract_side_effects(cost_state)
	cost_state["worldTier"] = 3
	cost_state["growthPolicy"] = GrowthPolicy.create("scholar", {}, [], 0, 100.0, 1.0)
	(cost_state["bigValues"] as Dictionary)["gold"] = BigValue.from_number(10000)
	cost_state["activityQueue"] = ["EDU_LITERATURE"]
	cost_state["activeTask"] = null
	var expected_cost: Dictionary = BigValue.from_number(150.0 * pow(1.11, 2.0))
	var cost_engine := GameEngine.new()
	cost_engine.initialize_from_state(cost_state)
	var selected_state: Dictionary = cost_engine.get_state()
	var selected_task: Dictionary = selected_state.get("activeTask", {}) as Dictionary
	var expected_gold: Dictionary = BigValue.subtract(BigValue.from_number(10000), expected_cost)
	_check(
		str(selected_task.get("activityId", "")) == "EDU_LITERATURE"
		and BigValue.compare(selected_task.get("paidCost", {}) as Dictionary, expected_cost) == 0
		and BigValue.compare((selected_state.get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary, expected_gold) == 0,
		"AC-ACT-02 비용 공식과 활동 시작 시 1회 차감"
	)

	var poor_state := StateFactory.create(72002, "잔액 보호", content_db.config)
	_prevent_generated_contract_side_effects(poor_state)
	poor_state["growthPolicy"] = GrowthPolicy.create("scholar", {}, [], 0, 100.0, 1.0)
	(poor_state["bigValues"] as Dictionary)["gold"] = BigValue.from_number(149)
	poor_state["activeTask"] = {
		"id": "REST_HOME", "activityId": "REST_HOME", "name": "기숙사 휴식",
		"durationSlots": 2, "remainingSlots": 2, "worldTier": 1, "paidCost": BigValue.zero(),
	}
	var poor_engine := GameEngine.new()
	poor_engine.initialize_from_state(poor_state)
	var poor_before: Dictionary = (poor_engine.get_state().get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary
	var rejected_run: Dictionary = poor_engine.run_activity("EDU_LITERATURE")
	var poor_after: Dictionary = (poor_engine.get_state().get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary
	_check(
		not bool(rejected_run.get("ok", true))
		and BigValue.compare(poor_after, BigValue.zero()) >= 0
		and BigValue.compare(poor_after, poor_before) == 0,
		"AC-ACT-02 잔액 부족 활동 거부 및 음수 방지"
	)

	var job: Dictionary = content_db.get_activity("JOB_FARM")
	var formula_state := StateFactory.create(72003, "공식", content_db.config)
	_prevent_generated_contract_side_effects(formula_state)
	formula_state["worldTier"] = 4
	formula_state["rngCounter"] = 17
	formula_state["growthPolicy"] = GrowthPolicy.create(
		"custom", {"stamina": 0.5, "strength": 0.3, "cooking": 0.2}, [], 0, 100.0, 1.0
	)
	(formula_state["meters"] as Dictionary)["energy"] = 73.0
	(formula_state["meters"] as Dictionary)["stress"] = 22.0
	(formula_state["stats"] as Dictionary)["stamina"] = 140.0
	(formula_state["stats"] as Dictionary)["strength"] = 90.0
	(formula_state["stats"] as Dictionary)["cooking"] = 75.0
	formula_state["mastery"] = {"JOB_FARM": 9}
	var recent_before: Array = [
		"EDU_ETIQUETTE", "REST_WALK", "JOB_CARE", "EDU_LITERATURE",
		"REST_HOME", "JOB_THEATER", "EDU_PAINTING", "JOB_RESTAURANT",
	]
	formula_state["recentActivities"] = recent_before.duplicate()
	formula_state["eventInbox"] = _dummy_inbox(20, 500000, 900000)
	formula_state["activeTask"] = {
		"id": "JOB_FARM", "activityId": "JOB_FARM", "name": str(job.get("name", "JOB_FARM")),
		"durationSlots": 1, "remainingSlots": 1, "worldTier": 4, "paidCost": BigValue.zero(),
	}
	var expected_gains: Dictionary = _expected_activity_gains(formula_state, job, planner)
	var expected_energy: float = clampf(73.0 + float(job.get("energyDelta", 0.0)), 0.0, 100.0)
	var expected_stress: float = clampf(22.0 + float(job.get("stressDelta", 0.0)), 0.0, 100.0)
	var stamina_after_growth: float = 140.0 + float(expected_gains.get("stamina", 0.0))
	var effective_primary: float = 100.0 * log(1.0 + stamina_after_growth / 100.0)
	var performance_mod: float = clampf(0.75 + effective_primary / (220.0 + 40.0 * 4.0), 0.75, 1.75)
	var expected_reward: Dictionary = planner.tier_reward(job, 4, performance_mod)
	var gold_before: Dictionary = (formula_state.get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary

	var formula_engine := GameEngine.new()
	formula_engine.initialize_from_state(formula_state)
	var formula_result: Dictionary = formula_engine.advance_slots(1)
	var completed: Array = formula_result.get("completedActivities", []) as Array
	var completed_job: Dictionary = completed[0] as Dictionary if not completed.is_empty() else {}
	var actual_gains: Dictionary = completed_job.get("gains", {}) as Dictionary
	var formula_after: Dictionary = formula_engine.get_state()
	var actual_gold: Dictionary = (formula_after.get("bigValues", {}) as Dictionary).get("gold", {}) as Dictionary
	var actual_reward_delta: Dictionary = BigValue.subtract(actual_gold, gold_before)
	var gains_match := not expected_gains.is_empty() and expected_gains.keys().size() == actual_gains.keys().size()
	for raw_key: Variant in expected_gains.keys():
		var key := str(raw_key)
		gains_match = gains_match and is_equal_approx(float(actual_gains.get(key, NAN)), float(expected_gains[key]))
	var meters_after: Dictionary = formula_after.get("meters", {}) as Dictionary
	_check(
		gains_match
		and int(formula_after.get("rngCounter", -1)) >= 17 + expected_gains.size(),
		"AC-ACT-03 seeded U(0.95,1.05) 성장 공식",
		"expected=%s actual=%s" % [str(expected_gains), str(actual_gains)]
	)
	_check(
		BigValue.compare(actual_reward_delta, expected_reward) == 0,
		"AC-ACT-03 보수 공식 baseReward×1.13^(tier-1)×performanceMod",
		"expected=%s actual=%s" % [BigValue.format_short(expected_reward), BigValue.format_short(actual_reward_delta)]
	)
	_check(
		is_equal_approx(float(meters_after.get("energy", NAN)), expected_energy)
		and is_equal_approx(float(meters_after.get("stress", NAN)), expected_stress),
		"AC-ACT-03 에너지·스트레스 delta 및 clamp"
	)
	var expected_recent: Array = recent_before.slice(1)
	expected_recent.append("JOB_FARM")
	_check(
		int((formula_after.get("mastery", {}) as Dictionary).get("JOB_FARM", -1)) == 10
		and (formula_after.get("recentActivities", []) as Array) == expected_recent,
		"AC-ACT-04 활동 숙련 +1 및 최근 8개 FIFO"
	)


func _test_event_queue_and_default_timeout(content_db: ContentDB) -> void:
	var queue_state := StateFactory.create(73001, "이벤트 큐", content_db.config)
	_prevent_generated_contract_side_effects(queue_state)
	queue_state["activeTask"] = {
		"id": "REST_HOME", "activityId": "REST_HOME", "name": "기숙사 휴식",
		"durationSlots": 1, "remainingSlots": 1, "worldTier": 1, "paidCost": BigValue.zero(),
	}
	var queue_engine := GameEngine.new()
	queue_engine.initialize_from_state(queue_state)
	var queue_before: int = (queue_engine.get_state().get("eventInbox", []) as Array).size()
	queue_engine.advance_slots(1, 200000)
	var queued_events: Array = queue_engine.get_state().get("eventInbox", []) as Array
	_check(
		queued_events.size() - queue_before == 1,
		"AC-CONTENT-02 활동 1회 해결당 이벤트 큐 최대 1건(보장 트리거 실제 경로)",
		str(queued_events)
	)

	var cap_state := StateFactory.create(73002, "이벤트 상한", content_db.config)
	_prevent_generated_contract_side_effects(cap_state)
	cap_state["eventInbox"] = _dummy_inbox(20, 200000, 500000)
	cap_state["activeTask"] = {
		"id": "REST_HOME", "activityId": "REST_HOME", "name": "기숙사 휴식",
		"durationSlots": 1, "remainingSlots": 1, "worldTier": 1, "paidCost": BigValue.zero(),
	}
	var cap_engine := GameEngine.new()
	cap_engine.initialize_from_state(cap_state)
	cap_engine.advance_slots(1, 200001)
	_check(
		(cap_engine.get_state().get("eventInbox", []) as Array).size() == 20,
		"AC-CONTENT-02 eventInbox 20건 상한"
	)

	var event: Dictionary = content_db.get_event("EV_GUARDIAN_LETTER")
	var default_choice: String = str(event.get("defaultChoice", ""))
	var direct_state := StateFactory.create(73003, "기본 선택", content_db.config)
	_prevent_generated_contract_side_effects(direct_state)
	direct_state["eventInbox"] = [_event_instance(event, "DIRECT_DEFAULT", 1000, 87400)]
	var direct_engine := GameEngine.new()
	direct_engine.initialize_from_state(direct_state)
	var direct_resolution: Dictionary = direct_engine.resolve_default_event("DIRECT_DEFAULT")
	var direct_after: Dictionary = direct_engine.get_state()
	_check(
		bool(direct_resolution.get("ok", false))
		and str(direct_resolution.get("choiceId", "")) == default_choice
		and (direct_after.get("eventInbox", []) as Array).is_empty(),
		"AC-CONTENT-03 공개 API 기본 선택 해결"
	)

	var timeout_state := StateFactory.create(73004, "24시간 자동 선택", content_db.config)
	_prevent_generated_contract_side_effects(timeout_state)
	timeout_state["eventInbox"] = [_event_instance(event, "TIMEOUT_DEFAULT", 1000, 87400)]
	var timeout_engine := GameEngine.new()
	timeout_engine.initialize_from_state(timeout_state)
	timeout_engine.advance_slots(0, 87400)
	var timeout_after: Dictionary = timeout_engine.get_state()
	var history: Dictionary = timeout_after.get("eventHistory", {}) as Dictionary
	var history_entry: Dictionary = history.get("EV_GUARDIAN_LETTER", {}) as Dictionary
	_check(
		(timeout_after.get("eventInbox", []) as Array).is_empty()
		and str(history_entry.get("lastChoice", "")) == default_choice,
		"AC-CONTENT-03 24시간 경계에서 안전 기본 선택 자동 적용",
		str(history_entry)
	)


func _test_recent_template_weight_and_rng_isolation(content_db: ContentDB) -> void:
	var generator := ProceduralGenerator.new()
	var state := StateFactory.create(74001, "생성 RNG", content_db.config)
	state["worldTier"] = 9
	(state["time"] as Dictionary)["season"] = 3
	state["rngCounter"] = 321
	var generated: Dictionary = generator.generate(state, content_db)
	_check(
		int(state.get("rngCounter", -1)) == 321
		and (generated.get("contracts", []) as Array).size() == 3
		and (generated.get("rivals", []) as Array).size() == 5,
		"AC-WORLD-05 절차 생성은 main rngCounter 불변"
	)

	var procedural_data: Dictionary = {
		"contractTemplates": [
			{"id": "repeat", "kind": "complete_kind", "baseReward": 10, "baseTarget": 1, "weight": 1.0},
			{"id": "fresh", "kind": "complete_kind", "baseReward": 10, "baseTarget": 1, "weight": 1.0},
		],
	}
	var recent_templates: Array = ["repeat", "old_1", "old_2", "old_3", "old_4", "old_5", "old_6", "old_7"]
	var unlocked: Array[Dictionary] = [content_db.get_activity("REST_HOME")]
	var every_pick_matches_weight := true
	var repeat_picks := 0
	var sample_count := 240
	for sample: int in range(sample_count):
		var seed_value := 910000 + sample
		var local_rng: Dictionary = {
			"seed": DeterministicRNG.derive_seed(seed_value, 1, 1, "contracts"),
			"rngCounter": 0,
		}
		var expected_index: int = DeterministicRNG.weighted_index(local_rng, [0.20, 1.0], "contract_template_0")
		var expected_id := "repeat" if expected_index == 0 else "fresh"
		var sample_state: Dictionary = StateFactory.create(seed_value, "가중치 표본", content_db.config)
		var contracts: Array = generator.call(
			"_generate_contracts", seed_value, 1, 1, 1, unlocked, procedural_data, content_db.config, recent_templates, sample_state
		) as Array
		if contracts.is_empty():
			every_pick_matches_weight = false
			continue
		var actual_id: String = str((contracts[0] as Dictionary).get("templateId", ""))
		every_pick_matches_weight = every_pick_matches_weight and actual_id == expected_id
		if actual_id == "repeat":
			repeat_picks += 1
	var repeat_rate: float = float(repeat_picks) / float(sample_count)
	_check(
		every_pick_matches_weight and repeat_rate > 0.08 and repeat_rate < 0.28,
		"AC-WORLD-05 최근 8개 템플릿 가중치 0.20 실제 weightedPick 반영",
		"repeat=%d/%d rate=%.3f" % [repeat_picks, sample_count, repeat_rate]
	)


func _test_ui_new_policy_activity_save_continue(content_db: ContentDB) -> void:
	_cleanup_save_path(SAVE_PATH)
	var engine := GameEngine.new()
	engine.set_save_path(SAVE_PATH)
	var ui: Control = MainScreen.new()
	ui.set("_engine", engine)
	ui.set("_state", ui.call("_fallback_state"))
	ui.set("_activities", content_db.get_activities())
	ui.set("_items", content_db.get_items())
	ui.set("_seed", 75000)
	var name_edit := LineEdit.new()
	name_edit.text = "세라"
	ui.set("_trainee_name_edit", name_edit)
	ui.call("_create_trainee", "scholar")
	var created: Dictionary = ui.get("_state") as Dictionary
	_check(
		str(created.get("traineeName", "")) == "세라"
		and str((created.get("growthPolicy", {}) as Dictionary).get("preset", "")) == "scholar",
		"AC-UI-01 UI 새 수련생 생성→성장 정책 설정"
	)
	var activities_before: int = int((created.get("lifetimeStats", {}) as Dictionary).get("activities", 0))
	ui.call("_run_activity", "REST_HOME")
	var after_activity: Dictionary = ui.get("_state") as Dictionary
	var last_result: Dictionary = after_activity.get("lastResult", {}) as Dictionary
	_check(
		str(last_result.get("activityId", "")) == "REST_HOME"
		and int((after_activity.get("lifetimeStats", {}) as Dictionary).get("activities", 0)) > activities_before
		and int((after_activity.get("mastery", {}) as Dictionary).get("REST_HOME", 0)) > 0,
		"AC-UI-01 UI 자동 활동→결과 반영"
	)
	ui.call("_save_game")
	var absolute_path := ProjectSettings.globalize_path(SAVE_PATH)
	_check(FileAccess.file_exists(absolute_path), "AC-UI-01 UI 저장 경로 user:// 생성")
	var saved_slot: int = int((after_activity.get("time", {}) as Dictionary).get("slot", -1))
	var saved_mastery: int = int((after_activity.get("mastery", {}) as Dictionary).get("REST_HOME", 0))

	var reload_engine := GameEngine.new()
	reload_engine.set_save_path(SAVE_PATH)
	var continued_ui: Control = MainScreen.new()
	continued_ui.set("_engine", reload_engine)
	continued_ui.set("_state", continued_ui.call("_fallback_state"))
	continued_ui.set("_activities", content_db.get_activities())
	continued_ui.set("_items", content_db.get_items())
	continued_ui.call("_continue_game")
	var continued: Dictionary = continued_ui.get("_state") as Dictionary
	_check(
		str(continued.get("traineeName", "")) == "세라"
		and str((continued.get("growthPolicy", {}) as Dictionary).get("preset", "")) == "scholar"
		and int((continued.get("time", {}) as Dictionary).get("slot", -2)) == saved_slot
		and int((continued.get("mastery", {}) as Dictionary).get("REST_HOME", 0)) == saved_mastery,
		"AC-UI-01 UI 이어하기로 이름·정책·진행 복원"
	)
	continued_ui.free()
	ui.free()
	name_edit.free()
	_cleanup_save_path(SAVE_PATH)


func _test_ui_accessibility_and_first_surface(content_db: ContentDB) -> void:
	var font_exists := ResourceLoader.exists(FONT_PATH) and FileAccess.file_exists(FONT_PATH)
	var bundled_font: Font = load(FONT_PATH) as Font if font_exists else null
	var korean_glyphs := false
	var rendered_size := Vector2.ZERO
	if bundled_font != null:
		korean_glyphs = bundled_font.has_char("왕".unicode_at(0)) and bundled_font.has_char("립".unicode_at(0))
		rendered_size = bundled_font.get_string_size("왕립 아카데미 수련생")
	_check(
		font_exists and bundled_font != null and korean_glyphs and rendered_size.x > 0.0 and rendered_size.y > 0.0,
		"AC-UI-04 번들 Noto Sans KR 한글 글리프 측정",
		"size=%s" % str(rendered_size)
	)
	var royal_theme: Theme = RoyalTheme.build(bundled_font)
	var ui: Control = MainScreen.new()
	var state := StateFactory.create(76001, "첫 화면", content_db.config)
	_prevent_generated_contract_side_effects(state)
	state["activeTask"] = {
		"id": "REST_WALK", "activityId": "REST_WALK", "name": "왕도 산책",
		"reason": "현재 안전 규칙", "remainingSlots": 1, "durationSlots": 1,
	}
	state["lastPlannerDecision"] = {"reasons": ["방향 일치", "예산 안전", "다양성 보완"]}
	ui.set("_state", state)
	ui.set("_activities", content_db.get_activities())
	ui.theme = royal_theme
	var body_label: Label = ui.call("_label", "본문", 12, RoyalTheme.PARCHMENT) as Label
	var touch_button: Button = ui.call("_button", "확인", Callable(), "secondary", 1.0) as Button
	var touch_host := VBoxContainer.new()
	touch_host.theme = royal_theme
	touch_host.size = Vector2(100.0, 120.0)
	touch_host.add_child(body_label)
	touch_host.add_child(touch_button)
	get_root().add_child(touch_host)
	await process_frame
	await process_frame
	var touch_size: Vector2 = touch_button.size
	var body_contrast: float = _contrast_ratio(RoyalTheme.PARCHMENT, RoyalTheme.NAVY_CARD)
	var muted_contrast: float = _contrast_ratio(RoyalTheme.PARCHMENT_MUTED, RoyalTheme.NAVY_CARD)
	var chip_background: Color = RoyalTheme.NAVY_RAISED.blend(Color(RoyalTheme.CORAL, 0.13))
	var chip_contrast: float = _contrast_ratio(RoyalTheme.PARCHMENT, chip_background)
	var primary_button_contrast: float = _contrast_ratio(RoyalTheme.MIDNIGHT, RoyalTheme.CORAL)
	_check(
		royal_theme.default_font == bundled_font
		and royal_theme.default_font_size >= 16
		and body_label.get_theme_font_size("font_size") >= 16,
		"AC-UI-04 번들 폰트 적용 및 본문 16px 최소"
	)
	_check(
		touch_button.custom_minimum_size.y >= 44.0 and touch_size.x >= 44.0 and touch_size.y >= 44.0,
		"AC-UI-04 터치 영역 44×44 최소",
		"combined=%s custom=%s" % [str(touch_size), str(touch_button.custom_minimum_size)]
	)
	_check(
		body_contrast >= 4.5 and muted_contrast >= 4.5 and chip_contrast >= 4.5 and primary_button_contrast >= 4.5,
		"AC-UI-04 본문·chip·주요 CTA 텍스트 대비 4.5:1 이상",
		"body=%.2f muted=%.2f chip=%.2f primary=%.2f" % [body_contrast, muted_contrast, chip_contrast, primary_button_contrast]
	)
	touch_host.free()

	var home: Control = ui.call("_build_home_page") as Control
	var labels: Array[String] = _collect_label_texts(home)
	var has_character := false
	var has_dev_surface := false
	for node: Node in _all_nodes(home):
		if node.get_script() == ProceduralTrainee:
			has_character = true
		if node is Tree or node is CodeEdit or node is TextEdit:
			has_dev_surface = true
	var has_current_activity := false
	var has_debug_copy := false
	for text_value: String in labels:
		var lowered := text_value.to_lower()
		has_current_activity = has_current_activity or text_value.contains("지금, 왕도 산책")
		has_debug_copy = has_debug_copy or lowered.contains("dashboard") or lowered.contains("debug") or text_value.contains("개발용") or text_value.contains("데이터 표")
	_check(
		has_character and has_current_activity,
		"AC-UI-06 첫 홈에 캐릭터와 현재 활동 표시",
		"character=%s activity=%s" % [str(has_character), str(has_current_activity)]
	)
	_check(not has_dev_surface and not has_debug_copy, "AC-UI-06 첫 홈은 개발 대시보드/데이터 표가 아님")
	home.free()
	ui.free()


func _expected_activity_gains(state: Dictionary, activity: Dictionary, planner: Planner) -> Dictionary:
	var rng_state: Dictionary = {"seed": int(state.get("seed", 1)), "rngCounter": int(state.get("rngCounter", 0))}
	var stats: Dictionary = (state.get("stats", {}) as Dictionary).duplicate(true)
	var meters: Dictionary = state.get("meters", {}) as Dictionary
	var weights: Dictionary = (state.get("growthPolicy", {}) as Dictionary).get("weights", {}) as Dictionary
	var tier := maxi(1, int(state.get("worldTier", 1)))
	var mastery_value := maxf(0.0, float((state.get("mastery", {}) as Dictionary).get(str(activity.get("id", "")), 0)))
	var condition_mod := clampf(1.0 - float(meters.get("stress", 0.0)) / 160.0, 0.40, 1.00)
	condition_mod *= clampf(0.60 + float(meters.get("energy", 100.0)) / 100.0, 0.60, 1.60)
	var mastery_mod := planner.mastery_modifier(mastery_value)
	var relation_mod := planner.relation_modifier(state, activity)
	var tier_mod := 1.0 + 0.04 * sqrt(float(tier - 1))
	var gains: Dictionary = activity.get("gains", {}) as Dictionary
	var keys: Array = gains.keys()
	keys.sort()
	var result: Dictionary = {}
	for raw_key: Variant in keys:
		var stat_key := str(raw_key)
		var current := maxf(0.0, float(stats.get(stat_key, meters.get(stat_key, 0.0))))
		var focus_mod := 0.85 + 0.50 * float(weights.get(stat_key, 0.0))
		var diminish_mod := 0.35 + 0.65 / (1.0 + current / (600.0 + 80.0 * float(tier)))
		var jitter := DeterministicRNG.next_float(rng_state, 0.95, 1.05, "%s:%s" % [str(activity.get("id", "")), stat_key])
		result[stat_key] = snappedf(float(gains[raw_key]) * focus_mod * condition_mod * mastery_mod * relation_mod * diminish_mod * tier_mod * jitter, 0.01)
	return result


func _event_instance(event: Dictionary, instance_id: String, queued_at: int, expires_at: int) -> Dictionary:
	var instance := event.duplicate(true)
	instance["instanceId"] = instance_id
	instance["name"] = str(instance.get("title", instance.get("name", instance.get("id", "이벤트"))))
	instance["queuedAtSlot"] = 0
	instance["queuedAtUnix"] = queued_at
	instance["expiresAtUnix"] = expires_at
	return instance


func _dummy_inbox(count: int, queued_at: int, expires_at: int) -> Array:
	var result: Array = []
	for index: int in range(count):
		result.append({
			"id": "DUMMY_%02d" % index,
			"instanceId": "DUMMY_%02d" % index,
			"queuedAtUnix": queued_at,
			"expiresAtUnix": expires_at,
			"defaultChoice": "safe",
			"choices": [{"id": "safe", "text": "안전", "effects": {}}],
		})
	return result


func _prevent_generated_contract_side_effects(state: Dictionary) -> void:
	state["generatedContent"] = {
		"contracts": [{"id": "TEST_NOOP", "status": "inactive"}],
		"rivals": [],
		"region": {},
		"generatedFor": {"test": true},
		"pinnedContractId": "",
	}


func _all_nodes(root: Node) -> Array[Node]:
	var result: Array[Node] = [root]
	for child: Node in root.get_children():
		result.append_array(_all_nodes(child))
	return result


func _collect_label_texts(root: Node) -> Array[String]:
	var result: Array[String] = []
	for node: Node in _all_nodes(root):
		if node is Label:
			result.append((node as Label).text)
		elif node is Button:
			result.append((node as Button).text)
	return result


func _contrast_ratio(foreground: Color, background: Color) -> float:
	var foreground_luminance := _relative_luminance(foreground)
	var background_luminance := _relative_luminance(background)
	var lighter := maxf(foreground_luminance, background_luminance)
	var darker := minf(foreground_luminance, background_luminance)
	return (lighter + 0.05) / (darker + 0.05)


func _relative_luminance(color: Color) -> float:
	return 0.2126 * _linear_channel(color.r) + 0.7152 * _linear_channel(color.g) + 0.0722 * _linear_channel(color.b)


func _linear_channel(value: float) -> float:
	return value / 12.92 if value <= 0.04045 else pow((value + 0.055) / 1.055, 2.4)


func _cleanup_save_path(path: String) -> void:
	var absolute_path := ProjectSettings.globalize_path(path)
	for candidate: String in [absolute_path, absolute_path + ".bak", absolute_path + ".tmp"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)


func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
		return
	var message := label if detail.is_empty() else "%s | %s" % [label, detail]
	_failures.append(message)
	push_error("[FAIL] %s" % message)


func _finish() -> void:
	_cleanup_save_path(SAVE_PATH)
	if _failures.is_empty():
		print("[ACCEPTANCE-GAP] PASS (%d checks)" % _passes)
		quit(0)
		return
	print("[ACCEPTANCE-GAP] FAIL (%d pass, %d fail)" % [_passes, _failures.size()])
	for failure: String in _failures:
		print(" - %s" % failure)
	quit(1)
