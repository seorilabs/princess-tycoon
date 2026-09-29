extends SceneTree

const SAVE_PATH := "user://qa_ui_motion_smoke_save.json"

var _failures: Array[String] = []
var _passes := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[UI-MOTION] Result feedback and reduced motion")
	_prepare_test_save()
	root.size = Vector2i(390, 844)
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "main scene 로드")
	if packed == null:
		_finish()
		return
	var main := packed.instantiate() as Control
	root.add_child(main)
	await process_frame
	await process_frame

	var layer: Variant = main.get("_result_feedback_layer")
	_check(layer != null and layer.has_method("present"), "결과 피드백 단일 레이어 연결")
	var activity_progress: Variant = main.get("_activity_progress")
	_check(activity_progress != null and activity_progress.get_script() != null and activity_progress.custom_minimum_size.x >= 44.0, "현재 활동 원형 진행 피드백 연결")
	var initialized_state: Dictionary = main.get("_state") as Dictionary
	_check(int(initialized_state.get("lastSimulatedAt", 0)) > 0, "새 세션 시간 경계를 저장해 오프라인 진행 기준점 확보")
	_check(str(main.call("_event_choice_display_name", "EV_NEW_YEAR", "plan")) == "구체적인 훈련 목표를 적는다", "이벤트 도감 마지막 선택 ID를 한국어 선택문으로 표시")
	var original_policy: Dictionary = (initialized_state.get("growthPolicy", {}) as Dictionary).duplicate(true)
	var policy_label := Label.new()
	var percent_formatter := func(raw_value: Variant) -> String: return "%d%%" % int(round(float(raw_value)))
	main.call("_on_policy_slider_changed", 50.0, "weight:stamina", policy_label, percent_formatter)
	var normalized_weights: Dictionary = (main.get("_state") as Dictionary).get("growthPolicy", {}).get("weights", {}) as Dictionary
	var normalized_total := 0.0
	for raw_weight: Variant in normalized_weights.values():
		normalized_total += float(raw_weight)
	_check(is_equal_approx(float(normalized_weights.get("stamina", 0.0)), 0.5) and absf(normalized_total - 1.0) < 0.0001 and policy_label.text == "50%", "직접 설계 slider 선택 비율·전체 정규화·label 정합")
	policy_label.free()
	main.call("_apply_policy", original_policy)
	initialized_state = main.get("_state") as Dictionary
	var original_task: Variant = initialized_state.get("activeTask")
	initialized_state["activeTask"] = {"activityId": "JOB_FARM"}
	var job_environment := str(main.call("_profile_environment"))
	initialized_state["activeTask"] = {"activityId": "ADV_FOREST"}
	var adventure_environment := str(main.call("_profile_environment"))
	initialized_state["activeTask"] = {"activityId": "CH_SPORT_DANCE"}
	var challenge_environment := str(main.call("_profile_environment"))
	initialized_state["activeTask"] = original_task
	_check(job_environment == "city" and adventure_environment == "forest" and challenge_environment == "arena", "활동 종류가 거리·숲·경기장 절차 배경에 연결")
	if layer == null:
		main.queue_free()
		_finish()
		return
	main.call("_open_sheet", "settings")
	await process_frame
	main.call("_close_sheet")
	await process_frame
	_check(is_instance_valid(layer) and layer.get_parent() != null, "시트 열기·닫기 뒤 결과 피드백 영구 레이어 보존")

	var activity_result := {
		"activityId": "EDU_LITERATURE",
		"kind": "education",
		"title": "왕립 교양학 완료",
		"gains": {"intelligence": 8.4, "communication": 4.1},
		"reward": {"mantissa": 2.5, "exponent": 2},
		"mastery": 7,
		"outcome": {"reputationGain": 2.0, "relationGain": 1.0},
	}
	var activity_payload: Dictionary = main.call("_build_result_feedback_payload", activity_result, {})
	_check(str(activity_payload.get("kind", "")) == "activity", "활동 결과 payload 분류")
	_check(_joined_details(activity_payload).contains("지력 +8.4") and _joined_details(activity_payload).contains("골드 +250"), "실제 스탯·보상 결과 표시")
	_check((activity_payload.get("floatingStats", []) as Array).size() == 2, "능력치별 플로팅 토큰 생성")
	layer.call("present", activity_payload, false)
	await process_frame
	_check(layer.call("active_feedback_kind") == "activity" and layer.call("active_motion_mode") == "animated", "기본 활동 카드 Tween 연출")
	_check(int(layer.call("active_floating_stat_count")) == 2, "능력치 플로팅 칩을 개별 시각 요소로 표시")
	var active_feedback_panel: Control = layer.get("_active_panel") as Control
	if active_feedback_panel != null and active_feedback_panel.size.y > 240.0:
		print("[UI-MOTION] feedback panel diagnostic size=%s min=%s pos=%s anchors=%s/%s offsets=%s/%s parent=%s" % [str(active_feedback_panel.size), str(active_feedback_panel.get_combined_minimum_size()), str(active_feedback_panel.position), str(active_feedback_panel.anchor_top), str(active_feedback_panel.anchor_bottom), str(active_feedback_panel.offset_top), str(active_feedback_panel.offset_bottom), str((active_feedback_panel.get_parent() as Control).size)])
		for raw_feedback_node: Node in active_feedback_panel.find_children("*", "Control", true, false):
			var feedback_control := raw_feedback_node as Control
			print("[UI-MOTION] feedback child %s/%s size=%s min=%s" % [feedback_control.get_class(), feedback_control.name, str(feedback_control.size), str(feedback_control.get_combined_minimum_size())])
	_check(active_feedback_panel != null and active_feedback_panel.size.y <= 240.0, "결과 카드가 모바일 상단 영역 높이 안에 유지 size=%s" % str(active_feedback_panel.size if active_feedback_panel != null else Vector2.ZERO))
	_check(int(layer.call("active_detail_count")) <= 4, "모바일 결과 카드 상세 4줄 상한")
	layer.call("present", activity_payload, true)
	await process_frame

	var challenge_result := {
		"activityId": "CH_EXAM_ACADEMY",
		"kind": "challenge",
		"title": "아카데미 종합시험 완료",
		"gains": {"intelligence": 3.2},
		"reward": {"mantissa": 0.0, "exponent": 0},
		"outcome": {
			"won": false,
			"playerScore": 91.2,
			"opponentScore": 104.7,
			"rank": "participation",
			"leagueTier": 2,
			"nextLeagueTier": 1,
			"rivalName": "새벽 기록관 루나",
			"hint": "지력 유효 점수를 약 12.0 보강하세요.",
			"rewardGold": {"mantissa": 1.2, "exponent": 2},
		},
	}
	var challenge_payload: Dictionary = main.call("_build_result_feedback_payload", challenge_result, {})
	_check(str(challenge_payload.get("kind", "")) == "challenge" and str(challenge_payload.get("headline", "")).contains("도전 경험"), "도전 실패 강조 분류")
	_check(_joined_details(challenge_payload).contains("91.2") and _joined_details(challenge_payload).contains("104.7") and _joined_details(challenge_payload).contains("지력 유효 점수"), "도전 점수·상대·개선 hint 표시")
	var challenge_persistent: Array = main.call("_result_specialized_summary_lines", challenge_result)
	_check("\n".join(challenge_persistent).contains("참가") and "\n".join(challenge_persistent).contains("다음 준비") and not "\n".join(challenge_persistent).contains("participation"), "홈 최근 결과 도전 등급 한국어 상세 유지")

	var job_result := {
		"activityId": "JOB_RANGER",
		"kind": "job",
		"title": "외곽 경비 완료",
		"gains": {"stamina": 4.1},
		"reward": {"mantissa": 2.1, "exponent": 2},
		"outcome": {
			"type": "job", "incident": true, "event": "작업 중 돌발 사고",
			"rewardMultiplier": 0.68, "effects": {"stress": 8.2, "citizens": -1.9},
		},
	}
	var job_payload: Dictionary = main.call("_build_result_feedback_payload", job_result, {})
	var job_details := _joined_details(job_payload)
	_check(job_details.contains("돌발 사고") and job_details.contains("스트레스 +8.2") and job_details.contains("보수 68%"), "아르바이트 위험 사건 결과 표시")

	var adventure_result := {
		"activityId": "ADV_FOREST",
		"kind": "adventure",
		"title": "별빛 숲 원정 완료",
		"gains": {"combat": 2.4},
		"reward": {"mantissa": 0.0, "exponent": 0},
		"outcome": {
			"won": false,
			"clearedNodes": 2,
			"nodes": [
				{"type": "exploration", "event": "지도 조각 발견"},
			{"type": "encounter", "event": "적 조우", "enemyName": "안개빛 수호체", "enemyTraitName": "민첩"},
			{"type": "boss", "event": "지역 보스", "enemyName": "봉인된 골렘", "enemyTraitName": "견고"},
			],
			"loot": [{"itemId": "ITEM_TEA", "count": 2}],
			"injured": true,
			"regionName": "안개 낀 별빛 숲",
			"regionReward": {"mantissa": 3.5, "exponent": 2},
			"rewardFragment": "희귀 연구 표본",
		},
	}
	var adventure_payload: Dictionary = main.call("_build_result_feedback_payload", adventure_result, {})
	var adventure_details := _joined_details(adventure_payload)
	_check(str(adventure_payload.get("badge", "")) == "원정" and adventure_details.contains("탐색") and adventure_details.contains("조우") and adventure_details.contains("보스"), "모험 3노드 결과 표시")
	_check(adventure_details.contains("안개빛 수호체") and adventure_details.contains("민첩") and adventure_details.contains("봉인된 골렘") and adventure_details.contains("견고"), "생성 적 이름·특성을 모험 결과에 표시")
	_check(adventure_details.contains("전리품") and adventure_details.contains("지역 보상") and adventure_details.contains("희귀 연구 표본") and adventure_details.contains("강제 휴식"), "모험 loot·regionReward·보상 조각·부상 후 휴식 표시")

	var title_review := {
		"year": 2,
		"season": 3,
		"renownGained": 78,
		"policyFit": 0.84,
		"worldTierBefore": 3,
		"worldTierAfter": 4,
		"titles": [{"id": "END_SCHOLAR", "name": "왕립 연구자", "stars": 2, "rank": "2성"}],
	}
	var title_payload: Dictionary = main.call("_build_result_feedback_payload", {}, title_review)
	_check(str(title_payload.get("kind", "")) == "title" and str(title_payload.get("headline", "")).contains("별 상승"), "진로 칭호 별 상승 연출 훅")
	_check(_joined_details(title_payload).contains("왕립 연구자") and _joined_details(title_payload).contains("3 → 4"), "칭호·세계 티어 실제 심사 데이터 표시")
	_check(
		str(main.call("_career_display_name", "END_SCHOLAR", {"name": "왕립 연구자", "variantName": "시민의 왕립 연구자"})) == "시민의 왕립 연구자",
		"관계 기반 진로 칭호 변형을 기록 화면에 지속 표시"
	)

	layer.call("present", title_payload, false)
	await process_frame
	main.call("_toggle_setting", true, "reducedMotion")
	await process_frame
	_check(layer.call("active_motion_mode") == "static", "실행 중 Tween을 reducedMotion으로 즉시 정지")
	var home_avatar: Variant = main.get("_home_avatar")
	_check(home_avatar != null and bool(home_avatar.get("reduced_motion")), "현재 홈 캐릭터도 reducedMotion을 즉시 반영")
	layer.call("present", challenge_payload, true)
	await process_frame
	_check(layer.call("active_motion_mode") == "static", "reducedMotion 신규 결과는 정적 카드 대체")

	var trainee_script := load("res://src/ui/procedural_trainee.gd")
	var trainee: Control = trainee_script.new()
	trainee.size = Vector2(390, 302)
	trainee.call("set_reduced_motion", true)
	trainee.call("set_equipment", {
		"outfit": "OUTFIT_NOBLE",
		"weapon": "WPN_WAND",
		"armor": "ARM_ROBE",
		"accessory": "ACC_JEWEL",
		"enhancementLevels": {"outfit": 25, "weapon": 18, "armor": 12, "accessory": 8},
		"visualSeed": 1729,
	})
	root.add_child(trainee)
	await process_frame
	_check(int(trainee.call("_max_enhancement_level")) == 25, "장비 강화 레벨이 절차 외형 입력으로 연결")
	var base_outfit := Color("#7a5aa6")
	var enhanced_outfit: Color = trainee.call("_enhanced_color", base_outfit, "outfit", 31)
	_check(not enhanced_outfit.is_equal_approx(base_outfit), "강화·시드가 장비 색 변형에 반영")
	_check(trainee.call("_seed_accent", 79) is Color, "고정 seed 기반 문양·장식 팔레트 생성")
	trainee.queue_free()

	var engine: Variant = main.get("_engine")
	var live_config: Dictionary = engine.call("get_content_db").get("config") as Dictionary
	var original_offline_seconds := int(live_config.get("offlineSecondsPerSlot", 60))
	var original_offline_cap := int(live_config.get("offlineCapSeconds", 28800))
	live_config["offlineSecondsPerSlot"] = 30
	live_config["offlineCapSeconds"] = 90
	var config_state: Dictionary = main.get("_state") as Dictionary
	(config_state.get("settings", {}) as Dictionary)["autoRun"] = true
	config_state["lastSimulatedAt"] = int(Time.get_unix_time_from_system()) - 120
	_check(int(main.call("_offline_cap_slots")) == 3 and int(main.call("_pending_offline_slots")) == 3, "UI 오프라인 환산이 config 변경을 실제 behavior에 반영")
	live_config["offlineSecondsPerSlot"] = original_offline_seconds
	live_config["offlineCapSeconds"] = original_offline_cap
	var pending_state: Dictionary = engine.call("get_state") as Dictionary
	var pending_boundary := int(Time.get_unix_time_from_system()) - 3600
	pending_state["lastSimulatedAt"] = pending_boundary
	engine.call("initialize_from_state", pending_state)
	main.call("_sync_engine_state")
	var ui_state: Dictionary = main.get("_state") as Dictionary
	ui_state["pendingOfflineSlots"] = 60
	main.call("_persist_silently")
	var persisted_state: Dictionary = engine.call("get_state") as Dictionary
	_check(int(persisted_state.get("lastSimulatedAt", 0)) == pending_boundary, "오프라인 미정산 중 자동저장이 정산 기준시각을 보존")
	(ui_state.get("settings", {}) as Dictionary)["autoRun"] = false
	_check(int(main.call("_pending_offline_slots")) == 0, "자동 진행 일시정지는 오프라인 자동 성장도 중지")

	var paused_now := int(Time.get_unix_time_from_system())
	var paused_state := StateFactory.create(990001, "일시정지 만료")
	(paused_state.get("settings", {}) as Dictionary)["autoRun"] = false
	paused_state["lastSimulatedAt"] = paused_now - 120
	paused_state["eventInbox"] = [_expired_test_event("UI_PAUSED_EXPIRED", paused_now - 1)]
	engine.call("initialize_from_state", paused_state)
	main.call("_sync_engine_state")
	main.call("_notification", NOTIFICATION_APPLICATION_RESUMED)
	var paused_resumed: Dictionary = main.get("_state") as Dictionary
	_check((paused_resumed.get("eventInbox", []) as Array).is_empty() and (paused_resumed.get("eventHistory", {}) as Dictionary).has("UI_PAUSED_EXPIRED") and int((paused_resumed.get("time", {}) as Dictionary).get("slot", -1)) == 0, "일시정지 resume도 0-slot 이벤트 만료 정산")

	var wall_now := int(Time.get_unix_time_from_system())
	var future_boundary := wall_now + 3600
	var rollback_state: Dictionary = engine.call("get_state") as Dictionary
	rollback_state["lastSimulatedAt"] = future_boundary
	(rollback_state.get("settings", {}) as Dictionary)["autoRun"] = true
	engine.call("initialize_from_state", rollback_state)
	main.call("_adopt_engine_result", engine.call("settle_offline", wall_now))
	var rollback_ui_state: Dictionary = main.get("_state") as Dictionary
	rollback_ui_state["pendingOfflineSlots"] = 0
	var rollback_saved: bool = bool(main.call("_persist_silently"))
	var rollback_persisted: Dictionary = engine.call("get_state") as Dictionary
	var has_rollback_warning := false
	for raw_warning: Variant in rollback_persisted.get("warnings", []) as Array:
		if raw_warning is Dictionary and str((raw_warning as Dictionary).get("code", "")) == "CLOCK_ROLLBACK":
			has_rollback_warning = true
	_check(rollback_saved and int(rollback_persisted.get("lastSimulatedAt", 0)) == future_boundary and has_rollback_warning, "시계 역행 경고 저장이 미래 기준시각과 상태를 보존")

	var cold_now := int(Time.get_unix_time_from_system())
	var cold_state := StateFactory.create(990002, "냉시작 만료")
	(cold_state.get("settings", {}) as Dictionary)["autoRun"] = false
	cold_state["lastSimulatedAt"] = cold_now - 120
	cold_state["eventInbox"] = [_expired_test_event("UI_COLD_EXPIRED", cold_now - 1)]
	SaveCodec.save_atomic(SAVE_PATH, cold_state)
	main.queue_free()
	await process_frame
	var cold_main := packed.instantiate() as Control
	root.add_child(cold_main)
	await process_frame
	await process_frame
	var cold_loaded: Dictionary = cold_main.get("_state") as Dictionary
	_check((cold_loaded.get("eventInbox", []) as Array).is_empty() and (cold_loaded.get("eventHistory", {}) as Dictionary).has("UI_COLD_EXPIRED") and int((cold_loaded.get("time", {}) as Dictionary).get("slot", -1)) == 0, "일시정지 cold startup도 0-slot 이벤트 만료 정산")
	cold_main.queue_free()
	await process_frame
	_finish()


func _joined_details(payload: Dictionary) -> String:
	var lines: Array[String] = []
	for raw_line: Variant in payload.get("details", []) as Array:
		lines.append(str(raw_line))
	return "\n".join(lines)


func _expired_test_event(event_id: String, expires_at: int) -> Dictionary:
	return {
		"id": event_id,
		"instanceId": "%s_INSTANCE" % event_id,
		"name": "만료 테스트",
		"queuedAtUnix": expires_at - 60,
		"expiresAtUnix": expires_at,
		"defaultChoice": "safe",
		"choices": [{"id": "safe", "text": "안전한 선택", "effects": {"stats": {"intelligence": 1.0}}}],
	}


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		print("[FAIL] %s" % label)


func _finish() -> void:
	_cleanup_test_save()
	if _failures.is_empty():
		print("[UI-MOTION] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[UI-MOTION] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	quit(1)


func _prepare_test_save() -> void:
	_cleanup_test_save()
	ProjectSettings.set_setting("princess_tycoon/testing/save_path", SAVE_PATH)


func _cleanup_test_save() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_PATH)
	for suffix in ["", ".bak", ".tmp", ".corrupt"]:
		if FileAccess.file_exists(absolute + suffix):
			DirAccess.remove_absolute(absolute + suffix)
