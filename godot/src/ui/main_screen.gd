extends Control

const RoyalTheme = preload("res://src/ui/royal_theme.gd")
const ProceduralTrainee = preload("res://src/ui/procedural_trainee.gd")
const ResultFeedbackLayer = preload("res://src/ui/result_feedback_layer.gd")
const ActivityProgressRing = preload("res://src/ui/activity_progress_ring.gd")
const LocalAnalyticsPort = preload("res://src/ports/local_analytics_port.gd")
const NoOpAdPort = preload("res://src/ports/noop_ad_port.gd")
const NoOpIapPort = preload("res://src/ports/noop_iap_port.gd")
const SynthAudioPort = preload("res://src/ports/synth_audio_port.gd")
const FONT_PATH := "res://assets/fonts/NotoSansKR-VariableFont_wght.ttf"

const TABS := [
	{"id": "home", "label": "홈"},
	{"id": "plan", "label": "계획"},
	{"id": "activity", "label": "활동"},
	{"id": "growth", "label": "성장"},
	{"id": "record", "label": "기록"},
]

const PRESETS := [
	{"id": "balanced", "name": "균형", "hint": "고른 성장"},
	{"id": "martial", "name": "무예", "hint": "전투·체력"},
	{"id": "scholar", "name": "학문", "hint": "지력·마법"},
	{"id": "artist", "name": "예술", "hint": "예술·무용"},
	{"id": "leader", "name": "리더십", "hint": "기품·소통"},
	{"id": "care", "name": "돌봄", "hint": "간호·도덕"},
	{"id": "explorer", "name": "탐험", "hint": "모험·전투"},
	{"id": "prosperity", "name": "번영", "hint": "골드·교류"},
	{"id": "custom", "name": "직접 설계", "hint": "세부 가중치"},
]

const STAT_LABELS := {
	"stamina": "체력", "strength": "근력", "intelligence": "지력",
	"refinement": "기품", "sensitivity": "감수성", "style": "스타일",
	"discipline": "절제", "morals": "도덕", "faith": "신앙",
	"combat": "전투", "magic": "마법", "etiquette": "예절",
	"communication": "소통", "art": "예술", "cooking": "요리",
	"housework": "생활", "nursing": "간호", "dance": "무용",
}

const RELATION_LABELS := {
	"guardian": "후견인", "steward": "비서", "rival": "라이벌", "citizens": "왕국 시민",
}

const FALLBACK_ACTIVITIES := [
	{"id": "EDU_LITERATURE", "kind": "education", "name": "왕립 교양학", "description": "읽고 토론하며 사고와 소통을 기른다.", "baseCost": 150, "energyDelta": -8, "stressDelta": 6, "primaryStat": "intelligence"},
	{"id": "EDU_FENCING", "kind": "education", "name": "왕립 검술", "description": "정교한 검술과 절제를 익힌다.", "baseCost": 220, "energyDelta": -14, "stressDelta": 8, "primaryStat": "combat"},
	{"id": "EDU_PAINTING", "kind": "education", "name": "빛의 회화", "description": "관찰과 표현을 작품으로 남긴다.", "baseCost": 180, "energyDelta": -8, "stressDelta": 4, "primaryStat": "art"},
	{"id": "JOB_FARM", "kind": "job", "name": "학당 농장", "description": "계절 작물을 돌보며 보수를 얻는다.", "baseReward": 210, "energyDelta": -15, "stressDelta": 5, "primaryStat": "stamina"},
	{"id": "JOB_THEATER", "kind": "job", "name": "극장 운영", "description": "공연을 지원하며 소통과 감각을 익힌다.", "baseReward": 280, "energyDelta": -12, "stressDelta": 8, "primaryStat": "communication"},
	{"id": "REST_HOME", "kind": "rest", "name": "기숙사 휴식", "description": "안전하게 쉬며 에너지를 회복한다.", "baseCost": 0, "energyDelta": 38, "stressDelta": -24, "primaryStat": "stamina"},
	{"id": "REST_WALK", "kind": "rest", "name": "왕도 산책", "description": "도시를 걸으며 생각을 정돈한다.", "baseCost": 0, "energyDelta": 18, "stressDelta": -16, "primaryStat": "sensitivity"},
	{"id": "ADV_FOREST", "kind": "adventure", "name": "별빛 숲 원정", "description": "세 노드를 자동 탐사하고 전리품을 얻는다.", "baseCost": 60, "energyDelta": -20, "stressDelta": 9, "primaryStat": "combat"},
	{"id": "CH_EXAM_ACADEMY", "kind": "challenge", "name": "아카데미 종합시험", "description": "성장 방향과 기초 역량을 종합 평가한다.", "baseCost": 100, "energyDelta": -10, "stressDelta": 10, "primaryStat": "intelligence"},
	{"id": "CH_SPORT_DANCE", "kind": "challenge", "name": "왕도 무용 리그", "description": "무용과 표현력으로 라이벌과 겨룬다.", "baseCost": 120, "energyDelta": -14, "stressDelta": 8, "primaryStat": "dance"},
]

var _engine: Object = null
var _state: Dictionary = {}
var _seed := 1729
var _current_tab := "home"
var _activity_filter := "education"
var _gift_target := "citizens"
var _activity_elapsed := 0.0
var _auto_running := true
var _nav_buttons: Dictionary = {}
var _activities: Array = []
var _items: Array = []
var _events: Array = []
var _runtime_config: Dictionary = {}
var _analytics_port: RefCounted
var _ad_port: RefCounted
var _iap_port: RefCounted
var _audio_port: Node

var _content_host: Control
var _modal_layer: Control
var _header_time_label: Label
var _header_gold_label: Label
var _activity_label: Label
var _reason_label: Label
var _activity_progress: Control
var _pause_button: Button
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_serial := 0
var _result_feedback_layer: Control
var _trainee_name_edit: LineEdit
var _home_avatar: Control


func _ready() -> void:
	var bundled_font: Font = null
	if ResourceLoader.exists(FONT_PATH):
		bundled_font = load(FONT_PATH)
	theme = RoyalTheme.build(bundled_font)
	_runtime_config = _load_json_dictionary("res://data/config.json")
	_state = _fallback_state()
	_activities = _load_activities()
	_items = _load_json_array("res://data/items.json")
	_events = _load_json_array("res://data/events.json")
	_initialize_engine()
	_auto_running = bool(_read(["settings", "autoRun"], true))
	_initialize_runtime_ports()
	_build_shell()
	_show_tab("home")
	_refresh_chrome()
	set_process(true)
	if int(_state.get("pendingOfflineSlots", 0)) > 0:
		call_deferred("_open_sheet", "offline")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_track_event(&"app_background", {"slot": int(_read(["time", "slot"], 0))})
		_persist_silently()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_sync_engine_state()
		var resume_now := int(Time.get_unix_time_from_system())
		var last_boundary := int(_state.get("lastSimulatedAt", 0))
		# Paused growth still needs a zero-slot settlement for event expiry, and
		# clock rollback must preserve a future boundary before online ticks resume.
		var needs_boundary_settlement := not bool(_read(["settings", "autoRun"], true)) or last_boundary > resume_now
		if needs_boundary_settlement and _engine != null and _engine.has_method("settle_offline"):
			_adopt_engine_result(_engine.call("settle_offline", resume_now))
			_persist_silently()
		_auto_running = bool(_read(["settings", "autoRun"], true))
		_state["pendingOfflineSlots"] = _pending_offline_slots()
		_refresh_chrome()
		if int(_state.get("pendingOfflineSlots", 0)) > 0:
			call_deferred("_open_sheet", "offline")


func _process(delta: float) -> void:
	if not _auto_running or int(_state.get("pendingOfflineSlots", 0)) > 0:
		return
	var seconds_per_slot := _config_float("onlineSecondsPerSlot", 5.0)
	seconds_per_slot = maxf(0.01, seconds_per_slot)
	_activity_elapsed += delta
	if _activity_progress != null:
		_activity_progress.value = clampf(_activity_elapsed / seconds_per_slot * 100.0, 0.0, 100.0)
	if _activity_elapsed >= seconds_per_slot:
		_activity_elapsed = fmod(_activity_elapsed, seconds_per_slot)
		_advance_slots(1, false)


func _initialize_engine() -> void:
	var script_path := ""
	for global_class in ProjectSettings.get_global_class_list():
		if str(global_class.get("class", "")) == "GameEngine":
			script_path = str(global_class.get("path", ""))
			break
	if script_path.is_empty() and ResourceLoader.exists("res://src/core/game_engine.gd"):
		script_path = "res://src/core/game_engine.gd"
	if script_path.is_empty() or not ResourceLoader.exists(script_path):
		return
	var engine_script = load(script_path)
	if engine_script == null or not engine_script.can_instantiate():
		return
	_engine = engine_script.new()
	var test_save_path := str(ProjectSettings.get_setting("princess_tycoon/testing/save_path", ""))
	if not test_save_path.is_empty() and _engine.has_method("set_save_path"):
		_engine.call("set_save_path", test_save_path)
	var initialized = null
	var loaded_ok := false
	if _engine.has_method("load_save"):
		var loaded = _engine.call("load_save")
		loaded_ok = loaded is Dictionary and bool((loaded as Dictionary).get("ok", false))
	if not loaded_ok and _engine.has_method("initialize"):
		initialized = _engine.call("initialize", _seed)
	if _engine.has_method("get_state"):
		_sync_engine_state()
	elif typeof(initialized) == TYPE_DICTIONARY:
		_state = _deep_merge(_fallback_state(), initialized)
	var last_seen := int(_state.get("lastSimulatedAt", 0))
	var now := int(Time.get_unix_time_from_system())
	if last_seen <= 0 and _engine.has_method("advance_slots"):
		_stamp_engine_time_boundary(now)
		_persist_silently()
	elif loaded_ok and (last_seen > now or not bool(_read(["settings", "autoRun"], true))) and _engine.has_method("settle_offline"):
		_adopt_engine_result(_engine.call("settle_offline", now))
		_persist_silently()
	_state["pendingOfflineSlots"] = _pending_offline_slots()


func _sync_engine_state() -> void:
	if _engine == null or not _engine.has_method("get_state"):
		return
	var snapshot = _engine.call("get_state")
	if typeof(snapshot) == TYPE_DICTIONARY:
		_state = _deep_merge(_fallback_state(), snapshot)
	elif typeof(snapshot) == TYPE_OBJECT and snapshot != null and snapshot.has_method("to_dict"):
		var converted = snapshot.call("to_dict")
		if typeof(converted) == TYPE_DICTIONARY:
			_state = _deep_merge(_fallback_state(), converted)


func _fallback_state() -> Dictionary:
	return {
		"schemaVersion": 2,
		"seed": _seed,
		"traineeName": "아리아",
		"time": {"slot": 6, "season": 1, "year": 1},
		"stats": {
			"stamina": 86.0, "strength": 48.0, "intelligence": 112.0,
			"refinement": 74.0, "sensitivity": 67.0, "style": 58.0,
			"discipline": 91.0, "morals": 65.0, "faith": 42.0,
			"combat": 51.0, "magic": 88.0, "etiquette": 70.0,
			"communication": 96.0, "art": 62.0, "cooking": 44.0,
			"housework": 38.0, "nursing": 55.0, "dance": 61.0,
		},
		"meters": {"energy": 82.0, "stress": 24.0, "reputation": 50.0, "integrityViolations": 0},
		"bigValues": {
			"gold": {"mantissa": 3.0, "exponent": 3},
			"renown": {"mantissa": 8.4, "exponent": 1},
			"lifetimeRenown": {"mantissa": 8.4, "exponent": 1},
		},
		"growthPolicy": {
			"preset": "scholar", "weights": {}, "bannedTags": [],
			"reserveGold": {"mantissa": 3.0, "exponent": 2},
			"maxStress": 72.0, "riskTolerance": 0.35,
		},
		"activeTask": {
			"id": "EDU_LITERATURE", "activityId": "EDU_LITERATURE",
			"name": "왕립 교양학", "reason": "학문 방향과 계약 목표에 가장 잘 맞아요.",
		},
		"recentActivities": ["REST_WALK", "JOB_THEATER", "EDU_LITERATURE"],
		"lastResult": {"title": "토론 발표 완료", "summary": "지력 +8.4 · 소통 +4.1 · 숙련 +1"},
		"mastery": {"EDU_LITERATURE": 14, "EDU_MAGIC": 8, "JOB_THEATER": 6},
		"inventory": [{"id": "ITEM_TEA", "count": 3}],
		"equipment": {"outfit": "OUTFIT_PLAIN", "weapon": null, "armor": null, "accessory": "ACC_RIBBON"},
		"relations": {"guardian": 100, "steward": 100, "rival": 18, "citizens": 62},
		"worldTier": 1,
		"seasonHistory": [],
		"generatedContent": {
			"contracts": [
				{"name": "도서관의 새 기준", "progress": 3, "target": 8, "reward": "명성 35"},
				{"name": "균형 잡힌 일주일", "progress": 2, "target": 5, "reward": "골드 480"},
				{"name": "별빛 숲 기록", "progress": 0, "target": 3, "reward": "장비 상자"},
			],
			"rivals": [
				{"name": "붉은 매의 세린", "strength": "무예", "score": 184},
				{"name": "새벽 기록관 루나", "strength": "학문", "score": 177},
			],
		},
		"eventInbox": [{"id": "EV_GUARDIAN_LETTER", "name": "후견인의 편지", "description": "최근 성장 방향을 응원하는 편지가 도착했어요.", "choices": [{"id": "reply", "text": "답장을 쓴다"}, {"id": "keep", "text": "소중히 보관한다"}]}],
		"careerTitles": {"END_SCHOLAR": {"name": "왕립 연구자", "stars": 1}},
		"settings": {"autoRun": true, "reducedMotion": false, "sound": true, "highContrast": false},
	}


func _build_shell() -> void:
	name = "PrincessTycoonMobileUI"
	set_meta("screen_id", "home")
	set_meta("available_screen_ids", PackedStringArray(["home", "plan", "activity", "growth", "record", "world", "shop", "settings", "offline", "event", "profile", "continue"]))
	var background := ColorRect.new()
	background.color = RoyalTheme.MIDNIGHT
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var safe_area := MarginContainer.new()
	safe_area.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_area.add_theme_constant_override("margin_left", 10)
	safe_area.add_theme_constant_override("margin_right", 10)
	safe_area.add_theme_constant_override("margin_top", 8)
	safe_area.add_theme_constant_override("margin_bottom", 8)
	add_child(safe_area)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	safe_area.add_child(column)
	column.add_child(_build_header())
	column.add_child(_build_activity_status())

	_content_host = Control.new()
	_content_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_content_host)
	column.add_child(_build_navigation())

	_modal_layer = Control.new()
	_modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal_layer.z_index = 50
	add_child(_modal_layer)
	_result_feedback_layer = ResultFeedbackLayer.new()
	_result_feedback_layer.name = "ResultFeedbackLayer"
	_modal_layer.add_child(_result_feedback_layer)
	_build_toast()


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 54.0
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_theme_constant_override("separation", 8)

	var menu := _button("메뉴", _open_sheet.bind("menu"), "ghost", 48.0)
	menu.custom_minimum_size.x = 64.0
	menu.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	menu.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(menu)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", -2)
	var title := _label("왕립 아카데미", 20, RoyalTheme.PARCHMENT)
	var name_label := _label(str(_state.get("traineeName", "수련생")), 16, RoyalTheme.PARCHMENT_MUTED)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	title_box.add_child(title)
	title_box.add_child(name_label)
	row.add_child(title_box)

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.custom_minimum_size.x = 84.0
	right.size_flags_horizontal = Control.SIZE_SHRINK_END
	_header_gold_label = _label("", 18, RoyalTheme.GOLD_SOFT, HORIZONTAL_ALIGNMENT_RIGHT)
	_header_time_label = _label("", 16, RoyalTheme.PARCHMENT_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	_header_gold_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_header_time_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	right.add_child(_header_gold_label)
	right.add_child(_header_time_label)
	row.add_child(right)
	return row


func _build_activity_status() -> Control:
	var panel := _card("coral")
	panel.custom_minimum_size.y = 110.0
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var status_style := RoyalTheme.card_style("coral")
	status_style.content_margin_top = 8.0
	status_style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", status_style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	panel.add_child(content)

	var top := HBoxContainer.new()
	_activity_label = _label("현재 활동", 18, RoyalTheme.PARCHMENT)
	_activity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_activity_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_activity_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(_activity_label)
	var offline := _button("방치 %s" % _duration_label(_config_int("offlineCapSeconds", 28800)), _open_sheet.bind("offline"), "ghost", 44.0)
	offline.custom_minimum_size.x = 104.0
	offline.size_flags_horizontal = Control.SIZE_SHRINK_END
	top.add_child(offline)
	_pause_button = _button("일시정지", _toggle_auto, "gold", 44.0)
	_pause_button.custom_minimum_size.x = 84.0
	_pause_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	top.add_child(_pause_button)
	content.add_child(top)

	var status_bottom := HBoxContainer.new()
	status_bottom.add_theme_constant_override("separation", 8)
	_reason_label = _label("", 16, RoyalTheme.PARCHMENT_MUTED)
	_reason_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reason_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_bottom.add_child(_reason_label)
	_activity_progress = ActivityProgressRing.new()
	_activity_progress.tooltip_text = "현재 활동 진행률"
	status_bottom.add_child(_activity_progress)
	content.add_child(status_bottom)
	return panel


func _build_navigation() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 70.0
	panel.add_theme_stylebox_override("panel", RoyalTheme.card_style("transparent"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	panel.add_child(row)
	for definition in TABS:
		var tab_id := str(definition["id"])
		var tab_button := _button(str(definition["label"]), _show_tab.bind(tab_id), "ghost", 54.0)
		tab_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_button.toggle_mode = true
		row.add_child(tab_button)
		tab_button.add_to_group("critical_cta")
		_nav_buttons[tab_id] = tab_button
	return panel


func _show_tab(tab_id: String) -> void:
	_current_tab = tab_id
	for key in _nav_buttons:
		var tab_button: Button = _nav_buttons[key]
		tab_button.button_pressed = key == tab_id
		var variant := "primary" if key == tab_id else "ghost"
		tab_button.set_meta("royal_variant", variant)
		RoyalTheme.apply_button(tab_button, variant, bool(_read(["settings", "highContrast"], false)))
	_render_current_page()
	_track_event(&"screen_view", {"screen": tab_id})


func _render_current_page() -> void:
	if _content_host == null:
		return
	_home_avatar = null
	for child in _content_host.get_children():
		child.queue_free()
	var page: Control
	match _current_tab:
		"plan": page = _build_plan_page()
		"activity": page = _build_activity_page()
		"growth": page = _build_growth_page()
		"record": page = _build_record_page()
		_: page = _build_home_page()
	page.name = "Screen_%s" % _current_tab.capitalize()
	page.set_meta("screen_id", _current_tab)
	set_meta("screen_id", _current_tab)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content_host.add_child(page)


func _page_scroll() -> Dictionary:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_top", 2)
	margin.add_theme_constant_override("margin_bottom", 12)
	scroll.add_child(margin)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	margin.add_child(body)
	return {"scroll": scroll, "body": body}


func _build_home_page() -> Control:
	var page := _page_scroll()
	var body: VBoxContainer = page["body"]

	var hero := PanelContainer.new()
	hero.custom_minimum_size.y = 302.0
	hero.add_theme_stylebox_override("panel", RoyalTheme.card_style("gold"))
	var stage := Control.new()
	hero.add_child(stage)
	var avatar := ProceduralTrainee.new()
	_home_avatar = avatar
	avatar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	avatar.set_profile(_policy_preset())
	avatar.set_environment(_profile_environment())
	avatar.set_equipment(_equipment_visual_state())
	avatar.set_reduced_motion(bool(_read(["settings", "reducedMotion"], false)))
	stage.add_child(avatar)

	var profile_chip := PanelContainer.new()
	profile_chip.position = Vector2(12, 12)
	profile_chip.size = Vector2(126, 38)
	profile_chip.add_theme_stylebox_override("panel", RoyalTheme.chip_style(RoyalTheme.GOLD))
	profile_chip.add_child(_label("%s 성장" % _preset_name(_policy_preset()), 16, RoyalTheme.GOLD_SOFT, HORIZONTAL_ALIGNMENT_CENTER))
	stage.add_child(profile_chip)

	var activity_card := PanelContainer.new()
	activity_card.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	activity_card.offset_left = 12
	activity_card.offset_right = -12
	activity_card.offset_top = -76
	activity_card.offset_bottom = -12
	activity_card.add_theme_stylebox_override("panel", RoyalTheme.card_style("transparent"))
	var activity_text := VBoxContainer.new()
	activity_text.add_theme_constant_override("separation", 1)
	activity_text.add_child(_label("지금, %s" % _current_activity_name(), 19, RoyalTheme.PARCHMENT))
	activity_text.add_child(_label(_planner_reason(), 16, RoyalTheme.PARCHMENT_MUTED))
	activity_card.add_child(activity_text)
	stage.add_child(activity_card)
	body.add_child(hero)

	var resource_row := HBoxContainer.new()
	resource_row.add_theme_constant_override("separation", 8)
	resource_row.add_child(_resource_card("에너지", "%d" % int(_read(["meters", "energy"], 0)), RoyalTheme.MINT))
	resource_row.add_child(_resource_card("스트레스", "%d" % int(_read(["meters", "stress"], 0)), RoyalTheme.CORAL))
	resource_row.add_child(_resource_card("평판", "%d" % int(_read(["meters", "reputation"], 0)), RoyalTheme.GOLD))
	body.add_child(resource_row)

	var quick_title := _section_heading("오늘의 선택", "방향만 정하면 수련생이 스스로 다음 활동을 골라요.")
	body.add_child(quick_title)
	var quick_grid := GridContainer.new()
	quick_grid.columns = 2
	quick_grid.add_theme_constant_override("h_separation", 8)
	quick_grid.add_theme_constant_override("v_separation", 8)
	quick_grid.add_child(_button("자동 1회 실행", _complete_current_activity, "primary"))
	quick_grid.add_child(_button("월드 출정", _open_sheet.bind("world"), "gold"))
	quick_grid.add_child(_button("성장 방향", _show_tab.bind("plan"), "secondary"))
	quick_grid.add_child(_button("이벤트 확인", _open_sheet.bind("event"), "secondary"))
	body.add_child(quick_grid)

	var result = _read(["lastResult"], {})
	var recent := _card("raised")
	var recent_box := VBoxContainer.new()
	recent_box.add_theme_constant_override("separation", 3)
	recent_box.add_child(_label("최근 결과 · %s" % str(result.get("title", "수련 완료")), 17, RoyalTheme.GOLD_SOFT))
	recent_box.add_child(_label(str(result.get("summary", "성장 결과를 확인하세요.")), 16, RoyalTheme.PARCHMENT_MUTED))
	if result is Dictionary:
		for specialized_line: String in _result_specialized_summary_lines(result as Dictionary):
			recent_box.add_child(_label(specialized_line, 16, RoyalTheme.PARCHMENT_MUTED))
	recent.add_child(recent_box)
	body.add_child(recent)
	return page["scroll"]


func _build_plan_page() -> Control:
	var page := _page_scroll()
	var body: VBoxContainer = page["body"]
	body.add_child(_section_heading("성장 방향", "다음 자동 선택부터 정책이 반영됩니다."))

	var preset_grid := GridContainer.new()
	preset_grid.columns = 2
	preset_grid.add_theme_constant_override("h_separation", 8)
	preset_grid.add_theme_constant_override("v_separation", 8)
	for preset in PRESETS:
		var selected := str(preset["id"]) == _policy_preset()
		var text := "%s%s · %s" % ["선택됨  " if selected else "", preset["name"], preset["hint"]]
		var preset_button := _button(text, _apply_preset.bind(str(preset["id"])), "primary" if selected else "secondary", 54.0)
		preset_grid.add_child(preset_button)
	body.add_child(preset_grid)

	if _policy_preset() == "custom":
		body.add_child(_section_heading("직접 설계 가중치", "각 항목을 조절하면 음수를 제거하고 전체 합을 100%로 자동 정규화합니다."))
		var custom_weights: Dictionary = _read(["growthPolicy", "weights"], {})
		for stat_id in STAT_LABELS:
			body.add_child(_policy_slider(
				str(STAT_LABELS[stat_id]),
				"자동 플래너가 이 성장 결과를 얼마나 중요하게 볼지 정합니다.",
				"weight:%s" % stat_id,
				float(custom_weights.get(stat_id, 0.0)) * 100.0,
				0.0, 100.0, 1.0,
				func(value): return "%d%%" % int(value)
			))
		for extra in [{"id": "reputation", "name": "평판"}, {"id": "gold", "name": "골드"}]:
			var extra_id := str(extra["id"])
			body.add_child(_policy_slider(
				str(extra["name"]),
				"도전 평판 또는 경제 활동의 우선순위를 정합니다.",
				"weight:%s" % extra_id,
				float(custom_weights.get(extra_id, 0.0)) * 100.0,
				0.0, 100.0, 1.0,
				func(value): return "%d%%" % int(value)
			))

	body.add_child(_section_heading("안전 규칙", "예산·스트레스·위험 상한은 활동 점수보다 먼저 적용돼요."))
	var policy: Dictionary = _read(["growthPolicy"], {})
	body.add_child(_policy_slider("위험 허용도", "낮을수록 안전한 활동을 우선해요.", "riskTolerance", float(policy.get("riskTolerance", 0.35)), 0.0, 1.0, 0.05, func(value): return "%d%%" % int(value * 100.0)))
	body.add_child(_policy_slider("최대 스트레스", "한계에 도달하면 회복 활동으로 전환해요.", "maxStress", float(policy.get("maxStress", 72.0)), 35.0, 95.0, 1.0, func(value): return "%d" % int(value)))
	body.add_child(_policy_slider("최소 보유금", "이 금액 아래로 내려가는 소비 활동은 피합니다.", "reserveGoldValue", _reserve_gold_number(), 0.0, 3000.0, 100.0, func(value): return "%s G" % _format_number(value)))

	body.add_child(_section_heading("금지 태그", "원하지 않는 활동 유형을 자동 후보에서 제외합니다."))
	var tags := [
		{"id": "risk", "name": "고위험"}, {"id": "combat", "name": "전투"},
		{"id": "social", "name": "사교"}, {"id": "costly", "name": "고비용"},
		{"id": "outdoor", "name": "야외"}, {"id": "performance", "name": "공연"},
	]
	var banned: Array = policy.get("bannedTags", [])
	var tag_grid := GridContainer.new()
	tag_grid.columns = 2
	tag_grid.add_theme_constant_override("h_separation", 8)
	tag_grid.add_theme_constant_override("v_separation", 8)
	for tag in tags:
		var active := banned.has(tag["id"])
		var tag_button := _button("제외됨  %s" % tag["name"] if active else str(tag["name"]), _toggle_banned_tag.bind(str(tag["id"])), "danger" if active else "ghost")
		tag_grid.add_child(tag_button)
	body.add_child(tag_grid)

	var note := _card("transparent")
	note.add_child(_label("현재 선택 이유 상위 3개는 활동 상태 카드에 표시되며, 정책 변경으로 진행 중 활동이 취소되지는 않습니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	body.add_child(note)
	return page["scroll"]


func _build_activity_page() -> Control:
	var page := _page_scroll()
	var body: VBoxContainer = page["body"]
	body.add_child(_section_heading("활동 선택", "자동 플래너와 같은 해결 경로로 원하는 활동을 1회 실행할 수 있어요."))

	var categories := [
		{"id": "education", "name": "학습 15"},
		{"id": "job", "name": "알바 11"},
		{"id": "rest", "name": "휴식 4"},
		{"id": "adventure", "name": "모험 5"},
		{"id": "challenge", "name": "시험·대회 8"},
	]
	var category_grid := GridContainer.new()
	category_grid.columns = 2
	category_grid.add_theme_constant_override("h_separation", 8)
	category_grid.add_theme_constant_override("v_separation", 8)
	for category in categories:
		var category_id := str(category["id"])
		category_grid.add_child(_button(str(category["name"]), _select_activity_filter.bind(category_id), "primary" if category_id == _activity_filter else "ghost"))
	body.add_child(category_grid)

	var automatic := _card("coral")
	var automatic_box := VBoxContainer.new()
	automatic_box.add_theme_constant_override("separation", 8)
	automatic_box.add_child(_label("추천 · %s" % _current_activity_name(), 19, RoyalTheme.PARCHMENT))
	automatic_box.add_child(_label(_planner_reason(), 16, RoyalTheme.PARCHMENT_MUTED))
	automatic_box.add_child(_button("추천 활동 즉시 실행", _complete_current_activity, "primary"))
	automatic.add_child(automatic_box)
	body.add_child(automatic)

	var queued: Array = _read(["activityQueue"], [])
	var queue_card := _card("transparent")
	var queue_box := VBoxContainer.new()
	queue_box.add_theme_constant_override("separation", 5)
	queue_box.add_child(_label("자동 큐 · %d건" % queued.size(), 17, RoyalTheme.PARCHMENT))
	if queued.is_empty():
		queue_box.add_child(_label("비어 있으면 성장 정책이 다음 활동을 자동 선택합니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	else:
		for queue_index in range(mini(5, queued.size())):
			var queue_row := HBoxContainer.new()
			queue_row.add_theme_constant_override("separation", 5)
			queue_row.add_child(_label("%d. %s" % [queue_index + 1, _activity_name_by_id(str(queued[queue_index]))], 16, RoyalTheme.PARCHMENT))
			var up := _button("↑", _move_queued_activity.bind(queue_index, -1), "ghost", 44.0)
			up.custom_minimum_size.x = 44.0
			up.size_flags_horizontal = Control.SIZE_SHRINK_END
			up.disabled = queue_index == 0
			queue_row.add_child(up)
			var down := _button("↓", _move_queued_activity.bind(queue_index, 1), "ghost", 44.0)
			down.custom_minimum_size.x = 44.0
			down.size_flags_horizontal = Control.SIZE_SHRINK_END
			down.disabled = queue_index == queued.size() - 1
			queue_row.add_child(down)
			var remove := _button("삭제", _remove_queued_activity.bind(queue_index), "danger", 44.0)
			remove.custom_minimum_size.x = 58.0
			remove.size_flags_horizontal = Control.SIZE_SHRINK_END
			queue_row.add_child(remove)
			queue_box.add_child(queue_row)
		if queued.size() > 5:
			queue_box.add_child(_label("외 %d건" % (queued.size() - 5), 16, RoyalTheme.PARCHMENT_MUTED))
		queue_box.add_child(_button("자동 큐 모두 비우기", _clear_activity_queue, "ghost"))
	queue_card.add_child(queue_box)
	body.add_child(queue_card)

	var visible_count := 0
	for activity in _activities:
		if _activity_kind(activity) != _activity_filter:
			continue
		body.add_child(_activity_card(activity))
		visible_count += 1
		if visible_count >= 15:
			break
	if visible_count == 0:
		var empty := _card("transparent")
		empty.add_child(_label("이 분류의 활동은 세계 티어 또는 시즌 조건을 달성하면 열립니다.", 16, RoyalTheme.PARCHMENT_MUTED))
		body.add_child(empty)
	return page["scroll"]


func _activity_card(activity: Dictionary) -> Control:
	var card := _card("raised")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var title_row := HBoxContainer.new()
	var title := _label(str(activity.get("name", activity.get("id", "활동"))), 18, RoyalTheme.PARCHMENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var mastery_level := int(_read(["mastery", str(activity.get("id", ""))], 0))
	title_row.add_child(_chip("숙련 %d" % mastery_level, RoyalTheme.GOLD))
	box.add_child(title_row)
	box.add_child(_label(str(activity.get("description", "새로운 경험으로 성장합니다.")), 16, RoyalTheme.PARCHMENT_MUTED))
	var facts := HBoxContainer.new()
	facts.add_theme_constant_override("separation", 8)
	var cost := float(activity.get("baseCost", 0.0))
	var reward := float(activity.get("baseReward", 0.0))
	var economy := "비용 %s G" % _format_number(cost) if cost > 0.0 else ("보수 %s G" % _format_number(reward) if reward > 0.0 else "무료")
	facts.add_child(_chip(economy, RoyalTheme.GOLD))
	facts.add_child(_chip("에너지 %+d" % int(activity.get("energyDelta", 0)), RoyalTheme.MINT))
	facts.add_child(_chip("스트레스 %+d" % int(activity.get("stressDelta", 0)), RoyalTheme.CORAL))
	box.add_child(facts)
	var activity_id := str(activity.get("id", ""))
	var lock_reason := _activity_lock_reason(activity_id)
	if not lock_reason.is_empty():
		box.add_child(_label("잠금 · %s" % lock_reason, 16, RoyalTheme.DANGER))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	var action := _button("이 활동 1회", _run_activity.bind(activity_id), "secondary")
	action.add_to_group("critical_cta")
	action.disabled = not lock_reason.is_empty()
	actions.add_child(action)
	var queue_action := _button("자동 큐 +", _queue_activity.bind(activity_id), "ghost")
	queue_action.disabled = not lock_reason.is_empty()
	actions.add_child(queue_action)
	box.add_child(actions)
	card.add_child(box)
	return card


func _build_growth_page() -> Control:
	var page := _page_scroll()
	var body: VBoxContainer = page["body"]
	body.add_child(_section_heading("성장 현황", "능력치는 무한히 성장하고, 높은 수치일수록 새로운 콘텐츠가 열려요."))

	var summary := _card("gold")
	var summary_box := HBoxContainer.new()
	summary_box.add_theme_constant_override("separation", 8)
	summary_box.add_child(_resource_card("세계 티어", "%d" % int(_state.get("worldTier", 1)), RoyalTheme.GOLD))
	summary_box.add_child(_resource_card("명성", _format_big(_read(["bigValues", "renown"], {"mantissa": 0, "exponent": 0})), RoyalTheme.CORAL))
	summary_box.add_child(_resource_card("칭호", "%d" % _career_title_count(), RoyalTheme.MINT))
	summary.add_child(summary_box)
	body.add_child(summary)

	body.add_child(_section_heading("핵심 능력", "막대는 다음 100 단위 마일스톤까지의 진행도입니다."))
	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 8)
	stats_grid.add_theme_constant_override("v_separation", 8)
	for stat_id in STAT_LABELS:
		var value := float(_read(["stats", stat_id], 0.0))
		stats_grid.add_child(_stat_card(str(STAT_LABELS[stat_id]), value))
	body.add_child(stats_grid)

	body.add_child(_section_heading("장비", "의상·무기·방어구·장신구가 성장 분야와 절차 외형에 반영됩니다."))
	var equipment_grid := GridContainer.new()
	equipment_grid.columns = 2
	equipment_grid.add_theme_constant_override("h_separation", 8)
	equipment_grid.add_theme_constant_override("v_separation", 8)
	var slots := {"outfit": "의상", "weapon": "무기", "armor": "방어구", "accessory": "장신구"}
	for slot_id in slots:
		var equipped = _read(["equipment", slot_id], null)
		var display := "비어 있음" if equipped == null else _item_display_name(str(equipped))
		equipment_grid.add_child(_button("%s\n%s" % [slots[slot_id], display], _open_sheet.bind("shop"), "secondary", 64.0))
	body.add_child(equipment_grid)

	body.add_child(_section_heading("관계", "대화·선물·계약·도전 결과가 보너스, 계약 태그와 진로 조건을 엽니다."))
	var relation_grid := GridContainer.new()
	relation_grid.columns = 2
	relation_grid.add_theme_constant_override("h_separation", 8)
	relation_grid.add_theme_constant_override("v_separation", 8)
	for relation_id in RELATION_LABELS:
		var relation_value := float(_read(["relations", relation_id], 0.0))
		relation_grid.add_child(_button(
			"%s · %d / 1000\n선물 고르기" % [str(RELATION_LABELS[relation_id]), int(relation_value)],
			_open_shop_for_gift.bind(str(relation_id)), "secondary", 64.0
		))
	body.add_child(relation_grid)

	body.add_child(_section_heading("활동 숙련", "10·25·50·100 이후 매 100레벨마다 효율 마일스톤을 획득해요."))
	var mastery: Dictionary = _read(["mastery"], {})
	if mastery.is_empty():
		var mastery_empty := _card("transparent")
		mastery_empty.add_child(_label("활동을 완료하면 숙련 기록이 쌓입니다.", 16, RoyalTheme.PARCHMENT_MUTED))
		body.add_child(mastery_empty)
	else:
		for activity_id in mastery:
			var mastery_row := _card("raised")
			var mastery_content := HBoxContainer.new()
			var mastery_name := _label(_activity_name_by_id(str(activity_id)), 16, RoyalTheme.PARCHMENT)
			mastery_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			mastery_content.add_child(mastery_name)
			mastery_content.add_child(_chip("Lv. %d" % int(mastery[activity_id]), RoyalTheme.GOLD))
			mastery_row.add_child(mastery_content)
			body.add_child(mastery_row)
	return page["scroll"]


func _build_record_page() -> Control:
	var page := _page_scroll()
	var body: VBoxContainer = page["body"]
	body.add_child(_section_heading("시즌 기록", "게임은 끝나지 않습니다. 매 시즌 성과가 칭호와 새 세계를 엽니다."))

	var season_card := _card("gold")
	var season_box := VBoxContainer.new()
	season_box.add_theme_constant_override("separation", 7)
	season_box.add_child(_label("%d연차 · %d시즌" % [int(_read(["time", "year"], 1)), int(_read(["time", "season"], 1))], 22, RoyalTheme.GOLD_SOFT))
	var season_progress := ProgressBar.new()
	season_progress.custom_minimum_size.y = 22.0
	var slots_per_season := maxi(1, _config_int("slotsPerSeason", 28))
	season_progress.max_value = float(slots_per_season)
	season_progress.value = float(_season_slot())
	season_progress.show_percentage = false
	season_box.add_child(season_progress)
	season_box.add_child(_label("다음 심사까지 %d회 · 강제 종료나 초기화 없음" % (slots_per_season - _season_slot()), 16, RoyalTheme.PARCHMENT_MUTED))
	season_card.add_child(season_box)
	body.add_child(season_card)
	var season_history: Array = _read(["seasonHistory"], [])
	if not season_history.is_empty() and typeof(season_history.back()) == TYPE_DICTIONARY:
		var latest_review: Dictionary = season_history.back() as Dictionary
		var review_card := _card("raised")
		var review_box := VBoxContainer.new()
		review_box.add_theme_constant_override("separation", 4)
		review_box.add_child(_label("최근 심사 · %d연차 %d시즌" % [int(latest_review.get("year", 1)), int(latest_review.get("season", 1))], 18, RoyalTheme.PARCHMENT))
		review_box.add_child(_label("명성 +%d · 정책 일치 %d%% · 도전 승리 %d · 계약 %d" % [
			int(latest_review.get("renownGained", 0)), int(float(latest_review.get("policyFit", 0.0)) * 100.0),
			int(latest_review.get("challengeWins", 0)), int(latest_review.get("completedContracts", 0))
		], 16, RoyalTheme.PARCHMENT_MUTED))
		review_card.add_child(review_box)
		body.add_child(review_card)

	var event_count := _event_inbox().size()
	var record_actions := GridContainer.new()
	record_actions.columns = 2
	record_actions.add_theme_constant_override("h_separation", 8)
	record_actions.add_theme_constant_override("v_separation", 8)
	record_actions.add_child(_button("월드·라이벌", _open_sheet.bind("world"), "primary"))
	record_actions.add_child(_button("이벤트 %d건" % event_count, _open_sheet.bind("event"), "gold" if event_count > 0 else "secondary"))
	record_actions.add_child(_button("상점·인벤토리", _open_sheet.bind("shop"), "secondary"))
	record_actions.add_child(_button("설정·접근성", _open_sheet.bind("settings"), "secondary"))
	body.add_child(record_actions)

	body.add_child(_section_heading("주간 계약", "현재 해금 상태로 달성 가능한 목표만 생성됩니다."))
	var contracts: Array = _read(["generatedContent", "contracts"], [])
	var pinned_contract_id := str(_read(["generatedContent", "pinnedContractId"], ""))
	for contract in contracts:
		if typeof(contract) != TYPE_DICTIONARY:
			continue
		var contract_card := _card("raised")
		var contract_box := VBoxContainer.new()
		contract_box.add_theme_constant_override("separation", 5)
		var contract_top := HBoxContainer.new()
		var contract_name := _label(str(contract.get("name", "주간 계약")), 17, RoyalTheme.PARCHMENT)
		contract_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		contract_top.add_child(contract_name)
		contract_top.add_child(_chip("%s G" % _format_big(contract.get("reward", {"mantissa": 0, "exponent": 0})), RoyalTheme.GOLD))
		contract_box.add_child(contract_top)
		contract_box.add_child(_label(str(contract.get("description", "현재 성장 경로로 달성 가능한 계약입니다.")), 16, RoyalTheme.PARCHMENT_MUTED))
		var contract_meta: Array[String] = []
		var contract_region = contract.get("region", {})
		if typeof(contract_region) == TYPE_DICTIONARY and not str(contract_region.get("name", "")).is_empty():
			contract_meta.append(str(contract_region.get("name", "")))
		for modifier in contract.get("modifiers", []):
			contract_meta.append(_contract_modifier_name(str(modifier)))
		var bonus = contract.get("bonusObjective", {})
		if typeof(bonus) == TYPE_DICTIONARY and not str(bonus.get("name", "")).is_empty():
			contract_meta.append("보너스: %s" % str(bonus.get("name", "")))
		if not contract_meta.is_empty():
			contract_box.add_child(_label(" · ".join(contract_meta), 16, RoyalTheme.MINT))
		var contract_progress := ProgressBar.new()
		contract_progress.custom_minimum_size.y = 18.0
		contract_progress.max_value = maxf(1.0, float(contract.get("target", 1)))
		contract_progress.value = float(contract.get("progress", 0))
		contract_progress.show_percentage = false
		contract_box.add_child(contract_progress)
		var contract_id := str(contract.get("id", ""))
		var contract_status := str(contract.get("status", "active"))
		contract_box.add_child(_label("%d / %d · %s" % [
			int(contract.get("progress", 0)), int(contract.get("target", 1)),
			"보상 자동 수령 완료" if contract_status == "completed" else ("고정 중" if pinned_contract_id == contract_id else "진행 중")
		], 16, RoyalTheme.PARCHMENT_MUTED))
		if contract_status == "active":
			contract_box.add_child(_button("고정 해제" if pinned_contract_id == contract_id else "이 계약 고정", _pin_contract.bind("" if pinned_contract_id == contract_id else contract_id), "gold" if pinned_contract_id == contract_id else "secondary"))
		contract_card.add_child(contract_box)
		body.add_child(contract_card)

	body.add_child(_section_heading("진로 칭호", "38개 진로는 엔딩이 아니라 반복 성장하는 전문 분야입니다."))
	var titles: Dictionary = _read(["careerTitles"], {})
	if titles.is_empty():
		var title_empty := _card("transparent")
		title_empty.add_child(_label("첫 시즌 심사에서 가까운 진로 세 개가 제안됩니다.", 16, RoyalTheme.PARCHMENT_MUTED))
		body.add_child(title_empty)
	else:
		for title_id in titles:
			var title_data = titles[title_id]
			var title_name := _career_display_name(str(title_id), title_data)
			var stars := int(title_data.get("stars", 1)) if typeof(title_data) == TYPE_DICTIONARY else int(title_data)
			var title_card := _card("coral")
			var title_row := HBoxContainer.new()
			var title_label := _label(title_name, 18, RoyalTheme.PARCHMENT)
			title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			title_row.add_child(title_label)
			title_row.add_child(_chip(_career_rank(stars), RoyalTheme.GOLD))
			title_card.add_child(title_row)
			body.add_child(title_card)

	if not season_history.is_empty() and typeof(season_history.back()) == TYPE_DICTIONARY:
		var near_titles: Array = (season_history.back() as Dictionary).get("nearTitles", []) as Array
		if not near_titles.is_empty():
			body.add_child(_section_heading("가까운 진로", "다음 심사에서 노릴 수 있는 상위 세 분야입니다."))
			for near in near_titles:
				if typeof(near) != TYPE_DICTIONARY:
					continue
				var near_card := _card("transparent")
				near_card.add_child(_label("%s · %d%%\n%s" % [
					str(near.get("name", near.get("id", "진로"))), int(float(near.get("progress", 0.0)) * 100.0),
					", ".join(near.get("missing", []))
				], 16, RoyalTheme.PARCHMENT_MUTED))
				body.add_child(near_card)

	var event_history: Dictionary = _read(["eventHistory"], {})
	body.add_child(_section_heading("이벤트 도감 · %d / 26" % event_history.size(), "해결한 사건과 마지막 선택이 로컬 기록에 남습니다."))
	if event_history.is_empty():
		var event_empty := _card("transparent")
		event_empty.add_child(_label("아직 해결한 이벤트가 없습니다.", 16, RoyalTheme.PARCHMENT_MUTED))
		body.add_child(event_empty)
	else:
		for event_id in event_history:
			var history_entry: Dictionary = event_history[event_id] as Dictionary
			var history_card := _card("transparent")
			history_card.add_child(_label("%s · %d회 · 마지막 선택 %s" % [
				_event_display_name(str(event_id)), int(history_entry.get("count", 0)), _event_choice_display_name(str(event_id), str(history_entry.get("lastChoice", "-")))
			], 16, RoyalTheme.PARCHMENT_MUTED))
			body.add_child(history_card)
	return page["scroll"]


func _open_sheet(kind: String) -> void:
	_close_sheet()
	_track_event(&"screen_view", {"screen": kind})
	var overlay := ColorRect.new()
	overlay.name = "Screen_%s" % kind.capitalize()
	overlay.set_meta("screen_id", kind)
	overlay.color = Color(0.02, 0.035, 0.08, 0.78)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_layer.add_child(overlay)

	var sheet := PanelContainer.new()
	sheet.name = "Sheet"
	sheet.anchor_left = 0.0
	sheet.anchor_right = 1.0
	sheet.anchor_top = 0.17
	sheet.anchor_bottom = 1.0
	sheet.offset_left = 6.0
	sheet.offset_right = -6.0
	sheet.offset_bottom = 0.0
	sheet.add_theme_stylebox_override("panel", RoyalTheme.sheet_style())
	overlay.add_child(sheet)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	sheet.add_child(column)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	var heading_text := VBoxContainer.new()
	heading_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_text.add_theme_constant_override("separation", 0)
	var sheet_info := _sheet_title(kind)
	heading_text.add_child(_label(str(sheet_info[0]), 24, RoyalTheme.PARCHMENT))
	heading_text.add_child(_label(str(sheet_info[1]), 16, RoyalTheme.PARCHMENT_MUTED))
	heading.add_child(heading_text)
	var close_button := _button("닫기", _close_sheet, "ghost", 48.0)
	close_button.custom_minimum_size.x = 64.0
	heading.add_child(close_button)
	column.add_child(heading)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	match kind:
		"menu": _build_menu_sheet(body)
		"world": _build_world_sheet(body)
		"shop": _build_shop_sheet(body)
		"settings": _build_settings_sheet(body)
		"offline": _build_offline_sheet(body)
		"event": _build_event_sheet(body)
		"profile": _build_profile_sheet(body)
		"continue": _build_continue_sheet(body)
		"reset": _build_reset_sheet(body)
		_: _build_menu_sheet(body)


func _close_sheet() -> void:
	if _modal_layer == null:
		return
	for child in _modal_layer.get_children():
		if child != _toast_panel and child != _result_feedback_layer:
			child.queue_free()


func _sheet_title(kind: String) -> Array:
	match kind:
		"world": return ["월드", "모험·시험·스포츠·대회·라이벌 리그"]
		"shop": return ["상점과 인벤토리", "장비와 소비품을 성장 방향에 맞춰 준비하세요."]
		"settings": return ["설정", "접근성·사운드·자동 진행·데이터"]
		"offline": return ["오프라인 정산", "실제 %d초당 1회, 최대 %s까지 동일 규칙으로 처리합니다." % [
			maxi(1, _config_int("offlineSecondsPerSlot", 60)),
			_duration_label(_config_int("offlineCapSeconds", 28800)),
		]]
		"event": return ["이벤트", "자동 성장은 멈추지 않으며 선택은 나중에 결정해도 됩니다."]
		"profile": return ["새 수련생", "이름과 첫 성장 방향을 정합니다."]
		"continue": return ["이어하기", "기기에 저장된 최신 수련 기록을 불러옵니다."]
		"reset": return ["데이터 초기화", "현재 수련 기록을 지우고 처음부터 시작합니다."]
		_: return ["아카데미 메뉴", "모든 기능 경로로 이동할 수 있습니다."]


func _build_menu_sheet(body: VBoxContainer) -> void:
	var summary := _card("gold")
	var summary_box := VBoxContainer.new()
	summary_box.add_theme_constant_override("separation", 5)
	summary_box.add_child(_label("%s · %s 성장" % [str(_state.get("traineeName", "수련생")), _preset_name(_policy_preset())], 20, RoyalTheme.GOLD_SOFT))
	summary_box.add_child(_label("%d연차 %d시즌 · 세계 티어 %d" % [int(_read(["time", "year"], 1)), int(_read(["time", "season"], 1)), int(_state.get("worldTier", 1))], 16, RoyalTheme.PARCHMENT_MUTED))
	summary.add_child(summary_box)
	body.add_child(summary)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.add_child(_button("이어하기", _replace_sheet.bind("continue"), "primary"))
	grid.add_child(_button("새 수련생", _replace_sheet.bind("profile"), "secondary"))
	grid.add_child(_button("월드", _replace_sheet.bind("world"), "gold"))
	grid.add_child(_button("상점", _replace_sheet.bind("shop"), "secondary"))
	grid.add_child(_button("오프라인", _replace_sheet.bind("offline"), "secondary"))
	grid.add_child(_button("이벤트", _replace_sheet.bind("event"), "secondary"))
	grid.add_child(_button("설정", _replace_sheet.bind("settings"), "secondary"))
	grid.add_child(_button("지금 저장", _save_game, "ghost"))
	body.add_child(grid)

	var guide := _card("transparent")
	guide.add_child(_label("하단 5탭에서는 일상 성장 흐름을, 월드와 상점 같은 확장 기능은 이 보조 시트에서 관리합니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	body.add_child(guide)


func _build_world_sheet(body: VBoxContainer) -> void:
	var world_card := _card("gold")
	var world_box := VBoxContainer.new()
	world_box.add_theme_constant_override("separation", 6)
	world_box.add_child(_label("세계 티어 %d · 새벽빛 왕국" % int(_state.get("worldTier", 1)), 21, RoyalTheme.GOLD_SOFT))
	var league: Dictionary = _read(["challengeLeague"], {})
	world_box.add_child(_label("리그 %d단계 · 이번 시즌 %d승 %d패 · 최고 %.1f" % [
		int(league.get("leagueTier", 1)), int(league.get("seasonWins", 0)), int(league.get("seasonLosses", 0)), float(league.get("bestScore", 0.0))
	], 16, RoyalTheme.PARCHMENT_MUTED))
	world_box.add_child(_label("실패해도 참가 경험과 다음 시도 힌트를 얻습니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	world_card.add_child(world_box)
	body.add_child(world_card)
	var region: Dictionary = _read(["generatedContent", "region"], {})
	if not region.is_empty():
		var region_card := _card("coral")
		var region_box := VBoxContainer.new()
		region_box.add_theme_constant_override("separation", 5)
		region_box.add_child(_label(str(region.get("name", "이번 시즌 변형 지역")), 19, RoyalTheme.GOLD_SOFT))
		var region_key := str(region.get("baseRegionId", region.get("templateId", "REG_DEFAULT")))
		var region_progress: Dictionary = _read(["regionProgress", region_key], {})
		var region_clears := int(region_progress.get("clearCount", 0))
		var clears_per_tier := maxi(1, _config_int("regionClearsPerTier", 3))
		region_box.add_child(_label("특성 · %s · 지역 티어 %d · 클리어 %d · 시즌 %d까지" % [
			", ".join(region.get("modifiers", [])), 1 + int(region_clears / clears_per_tier), region_clears, int(region.get("expirySeason", 1))
		], 16, RoyalTheme.PARCHMENT_MUTED))
		region_card.add_child(region_box)
		body.add_child(region_card)

	body.add_child(_section_heading("자동 모험", "탐색 → 조우/사건 → 보스의 세 노드를 해결합니다."))
	for activity in _activities:
		if typeof(activity) != TYPE_DICTIONARY or _activity_kind(activity) != "adventure":
			continue
		var adventure_id := str(activity.get("id", ""))
		body.add_child(_world_action_card(
			str(activity.get("name", adventure_id)),
			str(activity.get("description", "세 노드 자동 원정")),
			adventure_id, "원정 시작", _activity_lock_reason(adventure_id)
		))

	body.add_child(_section_heading("시험·스포츠·대회", "여덟 종목은 서로 다른 능력 가중치로 평가됩니다."))
	for activity in _activities:
		if typeof(activity) != TYPE_DICTIONARY or _activity_kind(activity) != "challenge":
			continue
		var challenge_id := str(activity.get("id", ""))
		body.add_child(_world_action_card(
			str(activity.get("name", challenge_id)),
			_challenge_weight_summary(activity),
			challenge_id, "참가하기", _activity_lock_reason(challenge_id)
		))

	body.add_child(_section_heading("라이벌 리그", "현재 유효 점수 주변의 다섯 라이벌이 같은 시드로 생성됩니다."))
	var rivals: Array = _read(["generatedContent", "rivals"], [])
	for rival in rivals:
		if typeof(rival) != TYPE_DICTIONARY:
			continue
		var rival_card := _card("coral")
		var rival_row := HBoxContainer.new()
		var rival_text := VBoxContainer.new()
		rival_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rival_text.add_child(_label(str(rival.get("name", "라이벌")), 17, RoyalTheme.PARCHMENT))
		rival_text.add_child(_label("%d위 · %s · 강점 %s / 약점 %s" % [
			int(rival.get("leagueRank", 1)), str(rival.get("personality", "신중함")),
			str(rival.get("strength", "균형")), str(rival.get("weakness", "균형"))
		], 16, RoyalTheme.PARCHMENT_MUTED))
		rival_row.add_child(rival_text)
		rival_row.add_child(_chip("점수 %d" % int(rival.get("score", 0)), RoyalTheme.GOLD))
		rival_card.add_child(rival_row)
		body.add_child(rival_card)


func _build_shop_sheet(body: VBoxContainer) -> void:
	var wallet := _card("gold")
	var wallet_row := HBoxContainer.new()
	var wallet_label := _label("보유 골드", 17, RoyalTheme.PARCHMENT)
	wallet_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wallet_row.add_child(wallet_label)
	wallet_row.add_child(_label("%s G" % _format_big(_read(["bigValues", "gold"], {"mantissa": 0, "exponent": 0})), 22, RoyalTheme.GOLD_SOFT))
	wallet.add_child(wallet_row)
	body.add_child(wallet)

	body.add_child(_section_heading("선물 대상", "보유 소비품을 건네 관계를 높일 대상을 선택합니다."))
	var gift_targets := GridContainer.new()
	gift_targets.columns = 2
	gift_targets.add_theme_constant_override("h_separation", 8)
	gift_targets.add_theme_constant_override("v_separation", 8)
	for relation_id in RELATION_LABELS:
		gift_targets.add_child(_button(
			"선택됨 · %s" % RELATION_LABELS[relation_id] if _gift_target == relation_id else str(RELATION_LABELS[relation_id]),
			_select_gift_target.bind(str(relation_id)), "primary" if _gift_target == relation_id else "ghost"
		))
	body.add_child(gift_targets)

	body.add_child(_section_heading("전체 상점 · %d종" % _items.size(), "장비는 구매 당시 세계 티어의 강화 레벨을 얻고, 소비품은 99개까지 중첩됩니다."))
	for raw_item in _items:
		if typeof(raw_item) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = raw_item as Dictionary
		var item_id := str(item.get("id", ""))
		var owned := _inventory_count_ui(item_id)
		var equipped_slot := _equipped_slot_for(item_id)
		var item_card := _card("raised")
		var item_box := VBoxContainer.new()
		item_box.add_theme_constant_override("separation", 6)
		var item_top := HBoxContainer.new()
		var item_name := _label("%s · %s" % [_item_category_name(str(item.get("category", ""))), str(item.get("name", item_id))], 17, RoyalTheme.PARCHMENT)
		item_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item_top.add_child(item_name)
		item_top.add_child(_chip("%s G" % _tier_item_price_text(item), RoyalTheme.GOLD))
		item_box.add_child(item_top)
		item_box.add_child(_label(str(item.get("description", "성장에 도움이 되는 물품입니다.")), 16, RoyalTheme.PARCHMENT_MUTED))
		var status_parts: Array[String] = []
		if owned > 0:
			status_parts.append("보유 %d" % owned)
		var enhancement := _inventory_enhancement_level(item_id)
		if enhancement > 0:
			status_parts.append("강화 Lv.%d" % enhancement)
		if not equipped_slot.is_empty():
			status_parts.append("장착 중")
		if not status_parts.is_empty():
			item_box.add_child(_label(" · ".join(status_parts), 16, RoyalTheme.MINT))
		var actions := HBoxContainer.new()
		actions.add_theme_constant_override("separation", 7)
		if owned <= 0 or bool(item.get("stackable", false)):
			actions.add_child(_button("구매", _shop_action.bind(item_id), "primary" if owned <= 0 else "secondary"))
		if owned > 0 and bool(item.get("stackable", false)):
			actions.add_child(_button("사용", _inventory_action.bind("use", item_id), "gold"))
			actions.add_child(_button("선물", _gift_item.bind(item_id, _gift_target), "secondary"))
		elif owned > 0:
			actions.add_child(_button("해제" if not equipped_slot.is_empty() else "장착", _inventory_action.bind("unequip" if not equipped_slot.is_empty() else "equip", item_id), "gold"))
		if owned > 0:
			actions.add_child(_button("판매", _inventory_action.bind("sell", item_id), "ghost"))
		item_box.add_child(actions)
		item_card.add_child(item_box)
		body.add_child(item_card)

	var inventory_stack_max := maxi(1, _config_int("inventoryStackMax", 99))
	body.add_child(_section_heading("인벤토리", "소비품은 최대 %d개까지 중첩됩니다." % inventory_stack_max))
	var inventory: Array = _read(["inventory"], [])
	if inventory.is_empty():
		var inventory_empty := _card("transparent")
		inventory_empty.add_child(_label("보관 중인 물품이 없습니다.", 16, RoyalTheme.PARCHMENT_MUTED))
		body.add_child(inventory_empty)
	else:
		for stack in inventory:
			if typeof(stack) != TYPE_DICTIONARY:
				continue
			var stack_card := _card("transparent")
			var stack_row := HBoxContainer.new()
			var stack_name := _label(_item_display_name(str(stack.get("id", "ITEM"))), 17, RoyalTheme.PARCHMENT)
			stack_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			stack_row.add_child(stack_name)
			stack_row.add_child(_chip("%d%s" % [int(stack.get("count", 1)), " / %d" % inventory_stack_max if bool(_item_by_id(str(stack.get("id", ""))).get("stackable", false)) else ""], RoyalTheme.MINT))
			stack_card.add_child(stack_row)
			body.add_child(stack_card)


func _build_settings_sheet(body: VBoxContainer) -> void:
	body.add_child(_section_heading("진행", "자동 진행 상태와 접근성 설정은 즉시 반영됩니다."))
	body.add_child(_setting_toggle("자동 진행", "%s마다 다음 활동을 해결합니다." % _duration_label(int(ceil(_config_float("onlineSecondsPerSlot", 5.0)))), "autoRun", _auto_running))
	body.add_child(_setting_toggle("모션 줄이기", "캐릭터 부유·오라 애니메이션을 멈춥니다.", "reducedMotion", bool(_read(["settings", "reducedMotion"], false))))
	body.add_child(_setting_toggle("효과음", "합성 톤 기반 효과음 훅을 사용합니다.", "sound", bool(_read(["settings", "sound"], true))))
	body.add_child(_setting_toggle("고대비", "중요 CTA와 진행 정보를 더 선명하게 표시합니다.", "highContrast", bool(_read(["settings", "highContrast"], false))))

	body.add_child(_section_heading("저장과 데이터", "활동 해결·정책 변경·백그라운드 진입 시 자동 저장됩니다."))
	body.add_child(_button("지금 저장", _save_game, "primary"))
	body.add_child(_button("저장 기록 이어하기", _replace_sheet.bind("continue"), "secondary"))
	body.add_child(_button("데이터 초기화", _replace_sheet.bind("reset"), "danger"))

	var policy_note := _card("transparent")
	policy_note.add_child(_label("광고·결제·클라우드 저장은 현재 빌드에 포함되지 않습니다. 모든 핵심 진행은 로컬에서 동작합니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	body.add_child(policy_note)


func _build_offline_sheet(body: VBoxContainer) -> void:
	var summary := _card("gold")
	var summary_box := VBoxContainer.new()
	summary_box.add_theme_constant_override("separation", 8)
	var pending_slots := int(_state.get("pendingOfflineSlots", 0))
	var last_summary: Dictionary = _state.get("lastOfflineSummary", {}) as Dictionary
	var settled_slots := int(last_summary.get("slotsAdvanced", 0))
	if settled_slots > 0:
		summary_box.add_child(_label("오프라인 성장 %d회 완료" % settled_slots, 26, RoyalTheme.GOLD_SOFT))
		summary_box.add_child(_label("활동 %d건 · 시즌 심사 %d건%s" % [
			(last_summary.get("completedActivities", []) as Array).size(),
			(last_summary.get("seasonReviews", []) as Array).size(),
			" · 8시간 상한 적용" if bool(last_summary.get("capped", false)) else "",
		], 16, RoyalTheme.PARCHMENT_MUTED))
	else:
		summary_box.add_child(_label("정산 가능 %d회" % pending_slots, 26, RoyalTheme.GOLD_SOFT))
	summary_box.add_child(_label("최대 %d회 · %s · 시계 역행 시 0회" % [_offline_cap_slots(), _duration_label(_config_int("offlineCapSeconds", 28800))], 16, RoyalTheme.PARCHMENT_MUTED))
	summary.add_child(summary_box)
	body.add_child(summary)

	var rules := _card("raised")
	var rules_box := VBoxContainer.new()
	rules_box.add_theme_constant_override("separation", 7)
	rules_box.add_child(_label("정산 규칙", 18, RoyalTheme.PARCHMENT))
	rules_box.add_child(_label("· 저장된 seed와 rngCounter를 그대로 사용", 16, RoyalTheme.PARCHMENT_MUTED))
	rules_box.add_child(_label("· 온라인과 같은 활동 리듀서를 순서대로 실행", 16, RoyalTheme.PARCHMENT_MUTED))
	rules_box.add_child(_label("· 이벤트는 최대 20건까지 받은 편지함에 보관", 16, RoyalTheme.PARCHMENT_MUTED))
	rules.add_child(rules_box)
	body.add_child(rules)

	var collect := _button("오프라인 결과 받기", _collect_offline, "primary")
	collect.disabled = pending_slots <= 0
	collect.add_to_group("critical_cta")
	body.add_child(collect)


func _build_event_sheet(body: VBoxContainer) -> void:
	var events := _event_inbox()
	if events.is_empty():
		var empty := _card("transparent")
		var empty_box := VBoxContainer.new()
		empty_box.add_theme_constant_override("separation", 8)
		empty_box.add_child(_label("대기 중인 이벤트가 없습니다.", 20, RoyalTheme.PARCHMENT))
		empty_box.add_child(_label("활동 해결당 최대 한 건이 도착하며 자동 진행은 멈추지 않아요.", 16, RoyalTheme.PARCHMENT_MUTED))
		empty.add_child(empty_box)
		body.add_child(empty)
		return
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		var event_card := _card("coral")
		var event_box := VBoxContainer.new()
		event_box.add_theme_constant_override("separation", 9)
		event_box.add_child(_label(str(event.get("name", "아카데미 소식")), 21, RoyalTheme.GOLD_SOFT))
		event_box.add_child(_label(str(event.get("description", "새로운 선택지가 도착했습니다.")), 16, RoyalTheme.PARCHMENT))
		var choices: Array = event.get("choices", [])
		if choices.is_empty():
			choices = [{"id": "default", "text": "확인"}]
		for choice in choices:
			if typeof(choice) != TYPE_DICTIONARY:
				continue
			var choice_button := _button(str(choice.get("text", "선택")), _resolve_event.bind(str(event.get("id", "")), str(choice.get("id", "default"))), "primary" if choice == choices[0] else "secondary")
			choice_button.add_to_group("critical_cta")
			event_box.add_child(choice_button)
		event_box.add_child(_label("%s 미응답 시 안전한 기본 선택이 적용됩니다." % _duration_label(_config_int("eventChoiceTimeoutSeconds", 86400)), 16, RoyalTheme.PARCHMENT_MUTED))
		event_card.add_child(event_box)
		body.add_child(event_card)


func _build_profile_sheet(body: VBoxContainer) -> void:
	var intro := _card("gold")
	var intro_box := VBoxContainer.new()
	intro_box.add_theme_constant_override("separation", 7)
	intro_box.add_child(_label("성인 왕립 아카데미 수련생", 20, RoyalTheme.GOLD_SOFT))
	intro_box.add_child(_label("나이로 종료되지 않으며 선택한 전문 분야를 끝없이 개척합니다.", 16, RoyalTheme.PARCHMENT_MUTED))
	intro.add_child(intro_box)
	body.add_child(intro)

	body.add_child(_label("수련생 이름", 17, RoyalTheme.PARCHMENT))
	_trainee_name_edit = LineEdit.new()
	_trainee_name_edit.custom_minimum_size.y = 48.0
	_trainee_name_edit.placeholder_text = "이름을 입력하세요"
	_trainee_name_edit.text = str(_state.get("traineeName", "아리아"))
	_trainee_name_edit.max_length = 16
	body.add_child(_trainee_name_edit)
	body.add_child(_label("첫 방향은 생성 후 계획 탭에서 언제든 바꿀 수 있습니다.", 16, RoyalTheme.PARCHMENT_MUTED))

	var preset_grid := GridContainer.new()
	preset_grid.columns = 2
	preset_grid.add_theme_constant_override("h_separation", 8)
	preset_grid.add_theme_constant_override("v_separation", 8)
	for preset in PRESETS:
		preset_grid.add_child(_button(str(preset["name"]), _create_trainee.bind(str(preset["id"])), "primary" if str(preset["id"]) == _policy_preset() else "secondary"))
	body.add_child(preset_grid)


func _build_continue_sheet(body: VBoxContainer) -> void:
	var save_card := _card("gold")
	var save_box := VBoxContainer.new()
	save_box.add_theme_constant_override("separation", 7)
	save_box.add_child(_label(str(_state.get("traineeName", "수련생")), 24, RoyalTheme.GOLD_SOFT))
	save_box.add_child(_label("%d연차 %d시즌 · 세계 티어 %d" % [int(_read(["time", "year"], 1)), int(_read(["time", "season"], 1)), int(_state.get("worldTier", 1))], 16, RoyalTheme.PARCHMENT))
	save_box.add_child(_label("현재 활동 · %s" % _current_activity_name(), 16, RoyalTheme.PARCHMENT_MUTED))
	save_card.add_child(save_box)
	body.add_child(save_card)
	var continue_button := _button("이 기록으로 이어하기", _continue_game, "primary")
	continue_button.add_to_group("critical_cta")
	body.add_child(continue_button)
	body.add_child(_button("새 수련생 만들기", _replace_sheet.bind("profile"), "secondary"))


func _build_reset_sheet(body: VBoxContainer) -> void:
	var warning := _card("coral")
	var warning_box := VBoxContainer.new()
	warning_box.add_theme_constant_override("separation", 8)
	warning_box.add_child(_label("되돌릴 수 없는 작업입니다.", 21, RoyalTheme.DANGER))
	warning_box.add_child(_label("현재 능력치·장비·계약·칭호·이벤트 기록이 모두 초기화됩니다.", 16, RoyalTheme.PARCHMENT))
	warning.add_child(warning_box)
	body.add_child(warning)
	body.add_child(_button("초기화하지 않고 돌아가기", _replace_sheet.bind("settings"), "primary"))
	body.add_child(_button("모든 데이터 초기화", _reset_game, "danger"))


func _replace_sheet(kind: String) -> void:
	_open_sheet(kind)


func _toggle_auto() -> void:
	_auto_running = not _auto_running
	_state["settings"]["autoRun"] = _auto_running
	_activity_elapsed = 0.0
	if _engine != null:
		if _auto_running and _engine.has_method("resume"):
			_engine.call("resume")
		elif not _auto_running and _engine.has_method("pause"):
			_engine.call("pause")
		elif _engine.has_method("set_auto_run"):
			_engine.call("set_auto_run", _auto_running)
	_refresh_chrome()
	_persist_silently()
	_show_toast("자동 진행을 %s했습니다." % ("시작" if _auto_running else "일시정지"))


func _complete_current_activity() -> void:
	var task = _read(["activeTask"], {})
	var remaining := 1
	if typeof(task) == TYPE_DICTIONARY:
		remaining = maxi(1, int(task.get("remainingSlots", task.get("durationSlots", 1))))
	_advance_slots(remaining, true)


func _advance_slots(count: int, show_feedback: bool = true) -> void:
	var feedback_checkpoint := _result_feedback_checkpoint()
	var result = null
	if _engine != null and _engine.has_method("advance_slots"):
		result = _engine.call("advance_slots", count, int(Time.get_unix_time_from_system()))
		_adopt_engine_result(result)
		_persist_silently()
	else:
		for index in range(max(0, count)):
			_simulate_fallback_slot()
	_activity_elapsed = 0.0
	_refresh_chrome()
	_render_current_page()
	_present_result_feedback(result, feedback_checkpoint)
	_track_event(&"slots_advanced", {"count": maxi(0, count), "manual": show_feedback})
	if show_feedback:
		_play_sfx(SynthAudioPort.CUE_REWARD)
		_show_toast("%s · 성장 결과를 반영했습니다." % str(_read(["lastResult", "title"], "%s 완료" % _current_activity_name())))


func _simulate_fallback_slot() -> void:
	var stats: Dictionary = _state["stats"]
	var meters: Dictionary = _state["meters"]
	var policy_preset := _policy_preset()
	var target := "intelligence"
	match policy_preset:
		"martial": target = "combat"
		"artist": target = "art"
		"leader": target = "communication"
		"care": target = "nursing"
		"explorer": target = "stamina"
		"prosperity": target = "refinement"
		"balanced": target = "discipline"
	stats[target] = float(stats.get(target, 0.0)) + 4.0
	meters["energy"] = clampf(float(meters.get("energy", 100.0)) - 7.0, 0.0, 100.0)
	meters["stress"] = clampf(float(meters.get("stress", 0.0)) + 3.0, 0.0, 100.0)
	if float(meters["energy"]) < 20.0 or float(meters["stress"]) >= float(_read(["growthPolicy", "maxStress"], 72.0)):
		_state["activeTask"] = {"id": "REST_HOME", "name": "기숙사 휴식", "reason": "회복 안전 규칙이 우선 적용되었어요."}
		meters["energy"] = minf(100.0, float(meters["energy"]) + 32.0)
		meters["stress"] = maxf(0.0, float(meters["stress"]) - 22.0)
	else:
		_state["activeTask"] = _fallback_activity_for_preset(policy_preset)
	var time_state: Dictionary = _state["time"]
	time_state["slot"] = int(time_state.get("slot", 0)) + 1
	var slots_per_season := maxi(1, _config_int("slotsPerSeason", 28))
	var seasons_per_year := maxi(1, _config_int("seasonsPerYear", 4))
	if int(time_state["slot"]) >= slots_per_season:
		time_state["slot"] = 0
		time_state["season"] = int(time_state.get("season", 1)) + 1
		if int(time_state["season"]) > seasons_per_year:
			time_state["season"] = 1
			time_state["year"] = int(time_state.get("year", 1)) + 1
	_state["lastResult"] = {"title": "%s 완료" % _current_activity_name(), "summary": "%s +4.0 · 숙련 +1" % str(STAT_LABELS.get(target, target))}


func _fallback_activity_for_preset(preset: String) -> Dictionary:
	match preset:
		"martial": return {"id": "EDU_FENCING", "name": "왕립 검술", "reason": "무예 방향의 전투·절제 성장을 우선했어요."}
		"artist": return {"id": "EDU_PAINTING", "name": "빛의 회화", "reason": "예술 방향과 최근 활동 다양성을 함께 고려했어요."}
		"leader": return {"id": "JOB_DIPLOMACY", "name": "외교 행사", "reason": "리더십과 주간 계약을 함께 진전시켜요."}
		"care": return {"id": "EDU_NURSING", "name": "왕립 간호학", "reason": "돌봄 방향의 핵심 숙련을 강화해요."}
		"explorer": return {"id": "ADV_FOREST", "name": "별빛 숲 원정", "reason": "탐험 방향과 현재 위험 허용도에 맞아요."}
		"prosperity": return {"id": "JOB_BANQUET", "name": "연회 운영", "reason": "최소 보유금을 지키며 골드 효율을 높여요."}
		"balanced": return {"id": "REST_WALK", "name": "왕도 산책", "reason": "최근 성장 벡터의 균형을 보완해요."}
		_: return {"id": "EDU_LITERATURE", "name": "왕립 교양학", "reason": "학문 방향과 계약 목표에 가장 잘 맞아요."}


func _run_activity(activity_id: String) -> void:
	var feedback_checkpoint := _result_feedback_checkpoint()
	var result = null
	if _engine != null and _engine.has_method("run_activity"):
		result = _engine.call("run_activity", activity_id, int(Time.get_unix_time_from_system()))
	elif _engine != null and _engine.has_method("execute_activity"):
		result = _engine.call("execute_activity", activity_id, int(Time.get_unix_time_from_system()))
	else:
		var definition := _activity_by_id(activity_id)
		if not definition.is_empty():
			_state["activeTask"] = {
				"id": activity_id,
				"name": str(definition.get("name", activity_id)),
				"reason": "플레이어가 즉시 활동으로 선택했어요.",
			}
		_advance_slots(1, true)
		return
	var succeeded := _result_ok(result)
	_adopt_engine_result(result)
	_persist_silently()
	_refresh_chrome()
	_render_current_page()
	_track_event(&"activity_run", {"activityId": activity_id, "ok": succeeded})
	_play_sfx(SynthAudioPort.CUE_REWARD if succeeded else SynthAudioPort.CUE_FAILURE)
	if succeeded:
		_present_result_feedback(result, feedback_checkpoint)
		_show_toast("%s 1회를 해결했습니다." % _activity_name_by_id(activity_id))
	else:
		_show_toast(str((result as Dictionary).get("error", "활동을 실행하지 못했습니다.")) if result is Dictionary else "활동을 실행하지 못했습니다.")


func _queue_activity(activity_id: String) -> void:
	var queued := false
	if _engine != null and _engine.has_method("queue_activity"):
		var result = _engine.call("queue_activity", activity_id)
		queued = result is Dictionary and bool((result as Dictionary).get("ok", false))
		_sync_engine_state()
	else:
		var queue: Array = _state.get("activityQueue", []) as Array
		queue.append(activity_id)
		queued = true
	if queued:
		_persist_silently()
		_render_current_page()
		_show_toast("%s을(를) 자동 큐에 추가했습니다." % _activity_name_by_id(activity_id))
	else:
		_show_toast("현재 조건에서는 자동 큐에 추가할 수 없습니다.")


func _remove_queued_activity(queue_index: int) -> void:
	var updated := false
	if _engine != null and _engine.has_method("remove_queued_activity"):
		updated = _result_ok(_engine.call("remove_queued_activity", queue_index))
		_sync_engine_state()
	else:
		var queue: Array = _state.get("activityQueue", []) as Array
		if queue_index >= 0 and queue_index < queue.size():
			queue.remove_at(queue_index)
			updated = true
	_finish_queue_edit(updated, "자동 큐에서 활동을 제거했습니다.")


func _move_queued_activity(queue_index: int, offset: int) -> void:
	var updated := false
	if _engine != null and _engine.has_method("move_queued_activity"):
		updated = _result_ok(_engine.call("move_queued_activity", queue_index, offset))
		_sync_engine_state()
	else:
		var queue: Array = _state.get("activityQueue", []) as Array
		if queue_index >= 0 and queue_index < queue.size():
			var destination := clampi(queue_index + offset, 0, queue.size() - 1)
			if destination == queue_index:
				_finish_queue_edit(false, "")
				return
			var value = queue.pop_at(queue_index)
			queue.insert(destination, value)
			updated = true
	_finish_queue_edit(updated, "자동 큐 순서를 바꿨습니다.")


func _clear_activity_queue() -> void:
	var updated := false
	if _engine != null and _engine.has_method("clear_activity_queue"):
		updated = _result_ok(_engine.call("clear_activity_queue"))
		_sync_engine_state()
	else:
		(_state.get("activityQueue", []) as Array).clear()
		updated = true
	_finish_queue_edit(updated, "자동 큐를 비웠습니다.")


func _finish_queue_edit(updated: bool, success_message: String) -> void:
	if updated:
		_persist_silently()
		_render_current_page()
		_show_toast(success_message)
	else:
		_show_toast("자동 큐를 변경하지 못했습니다.")


func _pin_contract(contract_id: String) -> void:
	var updated := false
	if _engine != null and _engine.has_method("pin_contract"):
		updated = bool(_engine.call("pin_contract", contract_id))
		_sync_engine_state()
	else:
		var generated: Dictionary = _state.get("generatedContent", {}) as Dictionary
		generated["pinnedContractId"] = contract_id
		updated = true
	if updated:
		_persist_silently()
		_render_current_page()
		_show_toast("계약 고정을 해제했습니다." if contract_id.is_empty() else "계약을 자동 플래너 우선 목표로 고정했습니다.")
	else:
		_show_toast("계약 고정을 변경하지 못했습니다.")


func _run_world_activity(activity_id: String) -> void:
	_run_activity(activity_id)
	if _modal_layer != null and _modal_layer.get_child_count() > 1:
		_open_sheet("world")


func _apply_preset(preset: String) -> void:
	var policy: Dictionary = _read(["growthPolicy"], {}).duplicate(true)
	policy["preset"] = preset
	if preset != "custom":
		policy["weights"] = {}
	_apply_policy(policy)
	_render_current_page()
	_show_toast("성장 방향을 %s으로 변경했습니다." % _preset_name(preset))


func _toggle_banned_tag(tag_id: String) -> void:
	var policy: Dictionary = _read(["growthPolicy"], {}).duplicate(true)
	var banned: Array = policy.get("bannedTags", []).duplicate()
	if banned.has(tag_id):
		banned.erase(tag_id)
	else:
		banned.append(tag_id)
	policy["bannedTags"] = banned
	_apply_policy(policy)
	_render_current_page()


func _on_policy_slider_changed(value: float, key: String, value_label: Label, formatter: Callable) -> void:
	var policy: Dictionary = _read(["growthPolicy"], {}).duplicate(true)
	if key.begins_with("weight:"):
		var weights: Dictionary = policy.get("weights", {}).duplicate(true)
		var weight_key := key.trim_prefix("weight:")
		weights = _rebalance_custom_weights(weights, weight_key, value / 100.0)
		policy["preset"] = "custom"
		policy["weights"] = weights
	elif key == "reserveGoldValue":
		policy["reserveGold"] = _number_to_big(value)
	else:
		policy[key] = value
	_apply_policy(policy)
	if key.begins_with("weight:"):
		var normalized_value := float(_read(["growthPolicy", "weights", key.trim_prefix("weight:")], 0.0)) * 100.0
		value_label.text = str(formatter.call(normalized_value))
		_sync_custom_weight_sliders()
	else:
		value_label.text = str(formatter.call(value))


func _rebalance_custom_weights(current_weights: Dictionary, selected_key: String, selected_ratio: float) -> Dictionary:
	var result: Dictionary = {}
	var keys := _custom_weight_keys()
	var selected := clampf(selected_ratio, 0.0, 1.0)
	var other_total := 0.0
	for weight_key: String in keys:
		if weight_key != selected_key:
			other_total += maxf(0.0, float(current_weights.get(weight_key, 0.0)))
	var remaining := 1.0 - selected
	var fallback_share := remaining / float(maxi(1, keys.size() - 1))
	for weight_key: String in keys:
		if weight_key == selected_key:
			result[weight_key] = selected
		elif other_total > 0.0:
			result[weight_key] = maxf(0.0, float(current_weights.get(weight_key, 0.0))) / other_total * remaining
		else:
			result[weight_key] = fallback_share
	return result


func _custom_weight_keys() -> Array[String]:
	var result: Array[String] = []
	for raw_key: Variant in STAT_LABELS.keys():
		result.append(str(raw_key))
	result.append("reputation")
	result.append("gold")
	return result


func _sync_custom_weight_sliders() -> void:
	if _content_host == null:
		return
	var weights: Dictionary = _read(["growthPolicy", "weights"], {})
	for raw_node: Node in _content_host.find_children("*", "HSlider", true, false):
		var slider := raw_node as HSlider
		var policy_key := str(slider.get_meta("policy_key", ""))
		if not policy_key.begins_with("weight:"):
			continue
		var displayed_value := float(weights.get(policy_key.trim_prefix("weight:"), 0.0)) * 100.0
		slider.set_block_signals(true)
		slider.value = displayed_value
		slider.set_block_signals(false)
		var label_value: Variant = slider.get_meta("policy_value_label", null)
		if label_value is Label and is_instance_valid(label_value):
			(label_value as Label).text = "%d%%" % int(round(displayed_value))


func _apply_policy(policy: Dictionary) -> void:
	_state["growthPolicy"] = policy
	if _engine != null and _engine.has_method("set_policy"):
		var result = _engine.call("set_policy", policy)
		_adopt_engine_result(result)
		_persist_silently()
	_refresh_chrome()


func _select_activity_filter(kind: String) -> void:
	_activity_filter = kind
	_render_current_page()


func _toggle_setting(pressed: bool, key: String) -> void:
	if not _state.has("settings") or typeof(_state["settings"]) != TYPE_DICTIONARY:
		_state["settings"] = {}
	_state["settings"][key] = pressed
	if key == "autoRun":
		_auto_running = pressed
		_activity_elapsed = 0.0
	elif key == "sound" and _audio_port != null and _audio_port.has_method("set_enabled"):
		_audio_port.call("set_enabled", pressed)
	elif key == "reducedMotion":
		if _result_feedback_layer != null and _result_feedback_layer.has_method("set_reduced_motion"):
			_result_feedback_layer.call("set_reduced_motion", pressed)
		if _home_avatar != null and is_instance_valid(_home_avatar) and _home_avatar.has_method("set_reduced_motion"):
			_home_avatar.call("set_reduced_motion", pressed)
	if _engine != null:
		if _engine.has_method("set_setting"):
			_engine.call("set_setting", key, pressed)
		elif _engine.has_method("set_settings"):
			_engine.call("set_settings", _state["settings"])
	_refresh_chrome()
	if key == "highContrast":
		_refresh_high_contrast()
	_persist_silently()
	_track_event(&"setting_changed", {"setting": key, "enabled": pressed})
	_show_toast("설정을 반영했습니다.")


func _collect_offline() -> void:
	var pending := clampi(int(_state.get("pendingOfflineSlots", 0)), 0, _offline_cap_slots())
	var offline_summary: Dictionary = {}
	if _engine != null and _engine.has_method("settle_offline"):
		var result = _engine.call("settle_offline", int(Time.get_unix_time_from_system()))
		if result is Dictionary:
			offline_summary = (result as Dictionary).duplicate(true)
		_adopt_engine_result(result)
	elif pending > 0:
		_advance_slots(pending, false)
	_state["pendingOfflineSlots"] = 0
	_state["lastOfflineSummary"] = offline_summary
	_persist_silently()
	_refresh_chrome()
	_open_sheet("offline")
	_track_event(&"offline_settled", {"requestedSlots": pending, "settledSlots": int(offline_summary.get("slotsAdvanced", pending))})
	_play_sfx(SynthAudioPort.CUE_REWARD if pending > 0 else SynthAudioPort.CUE_FAILURE)
	_show_toast("오프라인 결과를 반영했습니다.")


func _resolve_event(event_id: String, choice_id: String) -> void:
	var succeeded := false
	if _engine != null and _engine.has_method("resolve_event"):
		var result = _engine.call("resolve_event", event_id, choice_id)
		succeeded = _result_ok(result)
		_adopt_engine_result(result)
	else:
		var events := _event_inbox()
		for index in range(events.size() - 1, -1, -1):
			if typeof(events[index]) == TYPE_DICTIONARY and str(events[index].get("id", "")) == event_id:
				events.remove_at(index)
				succeeded = true
				break
		_state["eventInbox"] = events
	_persist_silently()
	_open_sheet("event")
	_track_event(&"event_resolved", {"eventId": event_id, "choiceId": choice_id, "ok": succeeded})
	_play_sfx(SynthAudioPort.CUE_REWARD if succeeded else SynthAudioPort.CUE_FAILURE)
	_show_toast("선택을 기록했습니다. 자동 성장은 계속됩니다." if succeeded else "이벤트 선택을 반영하지 못했습니다.")


func _shop_action(item_id: String) -> void:
	var completed := false
	var error_message := "구매 조건을 확인해 주세요."
	if _engine != null and _engine.has_method("buy_item"):
		var result = _engine.call("buy_item", item_id)
		completed = _result_ok(result)
		if result is Dictionary:
			error_message = str((result as Dictionary).get("error", error_message))
		_sync_engine_state()
	elif _engine != null and _engine.has_method("purchase_item"):
		var result = _engine.call("purchase_item", item_id)
		completed = _result_ok(result)
		if result is Dictionary:
			error_message = str((result as Dictionary).get("error", error_message))
		_sync_engine_state()
	_track_event(&"shop_action", {"itemId": item_id, "ok": completed})
	_play_sfx(SynthAudioPort.CUE_REWARD if completed else SynthAudioPort.CUE_FAILURE)
	if completed:
		_show_toast("%s을(를) 인벤토리에 넣었습니다." % _item_display_name(item_id))
	else:
		_show_toast(error_message)
	_persist_silently()
	_render_current_page()
	_open_sheet("shop")


func _open_shop_for_gift(relation_id: String) -> void:
	_gift_target = relation_id if RELATION_LABELS.has(relation_id) else "citizens"
	_open_sheet("shop")


func _select_gift_target(relation_id: String) -> void:
	if RELATION_LABELS.has(relation_id):
		_gift_target = relation_id
		_open_sheet("shop")


func _gift_item(item_id: String, relation_id: String) -> void:
	var result: Variant = {"ok": false, "error": "선물 기능을 사용할 수 없습니다."}
	if _engine != null and _engine.has_method("gift_item"):
		result = _engine.call("gift_item", item_id, relation_id)
		_sync_engine_state()
	var succeeded := _result_ok(result)
	if succeeded:
		_persist_silently()
		_render_current_page()
	_track_event(&"gift_item", {"itemId": item_id, "relation": relation_id, "ok": succeeded})
	_play_sfx(SynthAudioPort.CUE_REWARD if succeeded else SynthAudioPort.CUE_FAILURE)
	_show_toast(
		"%s에게 %s을(를) 선물했습니다." % [str(RELATION_LABELS.get(relation_id, relation_id)), _item_display_name(item_id)]
		if succeeded else str((result as Dictionary).get("error", "선물을 건네지 못했습니다."))
	)
	_open_sheet("shop")


func _inventory_action(action: String, item_id: String) -> void:
	var result: Variant = {"ok": false, "error": "지원하지 않는 인벤토리 작업"}
	if _engine != null:
		match action:
			"equip":
				if _engine.has_method("equip_item"):
					result = _engine.call("equip_item", item_id)
			"unequip":
				var slot := _equipped_slot_for(item_id)
				if _engine.has_method("unequip") and not slot.is_empty():
					result = {"ok": bool(_engine.call("unequip", slot))}
			"use":
				if _engine.has_method("use_item"):
					result = _engine.call("use_item", item_id)
			"sell":
				if _engine.has_method("sell_item"):
					result = _engine.call("sell_item", item_id, 1)
	_sync_engine_state()
	var succeeded := _result_ok(result)
	_persist_silently()
	_track_event(&"inventory_action", {"action": action, "itemId": item_id, "ok": succeeded})
	_play_sfx(SynthAudioPort.CUE_REWARD if succeeded else SynthAudioPort.CUE_FAILURE)
	_show_toast(
		"%s · %s" % [_item_display_name(item_id), {"equip": "장착", "unequip": "해제", "use": "사용", "sell": "판매"}.get(action, action)]
		if succeeded else str((result as Dictionary).get("error", "인벤토리 작업을 반영하지 못했습니다."))
	)
	_render_current_page()
	_open_sheet("shop")


func _save_game() -> void:
	var called := _persist_silently()
	_show_toast("현재 수련 기록을 저장했습니다." if called else "현재 세션 상태를 유지했습니다.")


func _continue_game() -> void:
	if _engine != null:
		for method in ["load_game", "load_save", "load"]:
			if _engine.has_method(method):
				_engine.call(method)
				break
		_sync_engine_state()
	_state["pendingOfflineSlots"] = _pending_offline_slots()
	_auto_running = bool(_read(["settings", "autoRun"], true))
	_close_sheet()
	_show_tab("home")
	_refresh_chrome()
	if int(_state.get("pendingOfflineSlots", 0)) > 0:
		_open_sheet("offline")
	_show_toast("최신 수련 기록으로 이어갑니다.")


func _create_trainee(preset: String) -> void:
	var trainee_name := "새 수련생"
	if _trainee_name_edit != null and not _trainee_name_edit.text.strip_edges().is_empty():
		trainee_name = _trainee_name_edit.text.strip_edges()
	_seed += 1
	if _engine != null and _engine.has_method("initialize"):
		_engine.call("initialize", _seed)
		if _engine.has_method("set_trainee_name"):
			_engine.call("set_trainee_name", trainee_name)
		elif _engine.has_method("set_player_name"):
			_engine.call("set_player_name", trainee_name)
		_sync_engine_state()
		_stamp_engine_time_boundary()
	else:
		_state = _fallback_state()
	_state["traineeName"] = trainee_name
	_auto_running = true
	var policy: Dictionary = _read(["growthPolicy"], {}).duplicate(true)
	policy["preset"] = preset
	if preset != "custom":
		policy["weights"] = {}
	_apply_policy(policy)
	_close_sheet()
	_show_tab("home")
	_refresh_chrome()
	_show_toast("%s의 수련을 시작합니다." % trainee_name)


func _reset_game() -> void:
	if _engine != null:
		if _engine.has_method("reset_save"):
			_engine.call("reset_save")
		elif _engine.has_method("delete_save"):
			_engine.call("delete_save")
		if _engine.has_method("initialize"):
			_engine.call("initialize", _seed)
		_sync_engine_state()
		_stamp_engine_time_boundary()
	else:
		_state = _fallback_state()
	_auto_running = true
	_persist_silently()
	_close_sheet()
	_show_tab("home")
	_refresh_chrome()
	_show_toast("새 수련 기록을 시작했습니다.")


func _refresh_chrome() -> void:
	if _header_gold_label != null:
		_header_gold_label.text = "%s G" % _format_big(_read(["bigValues", "gold"], {"mantissa": 0, "exponent": 0}))
	if _header_time_label != null:
		_header_time_label.text = "%d연차 · %d시즌" % [int(_read(["time", "year"], 1)), int(_read(["time", "season"], 1))]
	if _activity_label != null:
		_activity_label.text = _current_activity_name()
	if _reason_label != null:
		_reason_label.text = _planner_reason()
	if _pause_button != null:
		_pause_button.text = "일시정지" if _auto_running else "계속하기"
		RoyalTheme.apply_button(_pause_button, "gold" if _auto_running else "primary", bool(_read(["settings", "highContrast"], false)))


func _refresh_high_contrast() -> void:
	var enabled := bool(_read(["settings", "highContrast"], false))
	for node in get_tree().get_nodes_in_group("royal_button"):
		if node is Button and (node == self or is_ancestor_of(node)):
			var button := node as Button
			RoyalTheme.apply_button(button, str(button.get_meta("royal_variant", "secondary")), enabled)


func _build_toast() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.name = "Toast"
	_toast_panel.anchor_left = 0.04
	_toast_panel.anchor_right = 0.96
	_toast_panel.anchor_top = 1.0
	_toast_panel.anchor_bottom = 1.0
	_toast_panel.offset_top = -150.0
	_toast_panel.offset_bottom = -94.0
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.z_index = 100
	_toast_panel.add_theme_stylebox_override("panel", RoyalTheme.card_style("gold"))
	_toast_label = _label("", 16, RoyalTheme.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	_toast_panel.add_child(_toast_label)
	_toast_panel.visible = false
	_modal_layer.add_child(_toast_panel)


func _show_toast(message: String) -> void:
	if _toast_panel == null:
		return
	_toast_serial += 1
	var serial := _toast_serial
	_toast_label.text = message
	_toast_panel.visible = true
	_toast_panel.modulate = Color.WHITE
	get_tree().create_timer(2.2).timeout.connect(func():
		if serial == _toast_serial and is_instance_valid(_toast_panel):
			_toast_panel.visible = false
	)


func _result_feedback_checkpoint() -> Dictionary:
	var history: Array = _state.get("seasonHistory", []) as Array
	return {
		"lastResult": (_state.get("lastResult", {}) as Dictionary).duplicate(true),
		"seasonHistorySize": history.size(),
	}


func _present_result_feedback(engine_result: Variant, checkpoint: Dictionary) -> void:
	if _result_feedback_layer == null or not _result_feedback_layer.has_method("present"):
		return
	var completed: Array[Dictionary] = []
	var reviews: Array[Dictionary] = []
	if engine_result is Dictionary:
		var result_dict := engine_result as Dictionary
		for raw_completed: Variant in result_dict.get("completedActivities", []) as Array:
			if raw_completed is Dictionary:
				completed.append((raw_completed as Dictionary).duplicate(true))
		if result_dict.get("result") is Dictionary:
			completed.append((result_dict.get("result") as Dictionary).duplicate(true))
		for raw_review: Variant in result_dict.get("seasonReviews", []) as Array:
			if raw_review is Dictionary:
				reviews.append((raw_review as Dictionary).duplicate(true))

	var history: Array = _state.get("seasonHistory", []) as Array
	var previous_history_size := clampi(int(checkpoint.get("seasonHistorySize", history.size())), 0, history.size())
	if reviews.is_empty() and history.size() > previous_history_size:
		for index: int in range(previous_history_size, history.size()):
			if history[index] is Dictionary:
				reviews.append((history[index] as Dictionary).duplicate(true))

	if completed.is_empty():
		var current_last: Dictionary = _state.get("lastResult", {}) as Dictionary
		var previous_last: Dictionary = checkpoint.get("lastResult", {}) as Dictionary
		if not current_last.is_empty() and JSON.stringify(current_last, "", true, true) != JSON.stringify(previous_last, "", true, true):
			completed.append(current_last.duplicate(true))

	var activity_result: Dictionary = completed.back() if not completed.is_empty() else {}
	var season_review: Dictionary = reviews.back() if not reviews.is_empty() else {}
	var payload := _build_result_feedback_payload(activity_result, season_review)
	if payload.is_empty():
		return
	_result_feedback_layer.call("present", payload, bool(_read(["settings", "reducedMotion"], false)))


func _build_result_feedback_payload(activity_result: Dictionary, season_review: Dictionary = {}) -> Dictionary:
	if not season_review.is_empty():
		return _build_review_feedback_payload(season_review, activity_result)
	if activity_result.is_empty():
		return {}
	if str(activity_result.get("kind", "")) == "challenge":
		return _build_challenge_feedback_payload(activity_result)
	if str(activity_result.get("kind", "")) == "adventure":
		return _build_adventure_feedback_payload(activity_result)
	return _build_activity_feedback_payload(activity_result)


func _build_activity_feedback_payload(activity_result: Dictionary) -> Dictionary:
	var details: Array[String] = []
	details.append_array(_result_specialized_summary_lines(activity_result))
	var growth_line := _feedback_growth_line(activity_result.get("gains", {}) as Dictionary)
	if not growth_line.is_empty():
		details.append(growth_line)
	details.append_array(_feedback_reward_lines(activity_result))
	var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
	var relation_gain := float(outcome.get("relationGain", 0.0))
	var reputation_gain := float(outcome.get("reputationGain", 0.0))
	if relation_gain > 0.0 or reputation_gain > 0.0:
		var social_parts: Array[String] = []
		if reputation_gain > 0.0:
			social_parts.append("평판 +%s" % _feedback_number(reputation_gain))
		if relation_gain > 0.0:
			social_parts.append("관계 +%s" % _feedback_number(relation_gain))
		details.append("교류 · %s" % " · ".join(social_parts))
	if int(activity_result.get("mastery", 0)) > 0:
		details.append("숙련 · %d" % int(activity_result.get("mastery", 0)))
	if details.is_empty() and not str(activity_result.get("summary", "")).is_empty():
		details.append(str(activity_result.get("summary", "")))
	return {
		"kind": "activity",
		"badge": "성장",
		"tone": "raised",
		"headline": str(activity_result.get("title", "활동 완료")),
		"floatingStats": _feedback_stat_tokens(activity_result.get("gains", {}) as Dictionary),
		"details": details,
	}


func _build_challenge_feedback_payload(activity_result: Dictionary) -> Dictionary:
	var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
	if outcome.is_empty():
		return _build_activity_feedback_payload(activity_result)
	var won := bool(outcome.get("won", false))
	var details: Array[String] = []
	if outcome.has("playerScore") and outcome.has("opponentScore"):
		details.append("점수 · 나 %.1f / %s %.1f" % [
			float(outcome.get("playerScore", 0.0)),
			str(outcome.get("rivalName", "상대")),
			float(outcome.get("opponentScore", 0.0)),
		])
	var rank := str(outcome.get("rank", "")).strip_edges()
	var league_before := int(outcome.get("leagueTier", 0))
	var league_after := int(outcome.get("nextLeagueTier", league_before))
	var rank_parts: Array[String] = []
	if not rank.is_empty():
		rank_parts.append("등급 %s" % _challenge_rank_name(rank))
	if league_before > 0:
		rank_parts.append("리그 %d→%d" % [league_before, league_after])
	if not rank_parts.is_empty():
		details.append("판정 · %s" % " · ".join(rank_parts))
	var hint := str(outcome.get("hint", "")).strip_edges()
	if not hint.is_empty():
		details.append("다음 준비 · %s" % hint)
	var growth_line := _feedback_growth_line(activity_result.get("gains", {}) as Dictionary)
	if not growth_line.is_empty():
		details.append(growth_line)
	details.append_array(_feedback_reward_lines(activity_result))
	return {
		"kind": "challenge",
		"badge": "도전",
		"tone": "gold" if won else "coral",
		"headline": "%s · %s" % ["승리" if won else "도전 경험", _feedback_activity_name(activity_result)],
		"floatingStats": _feedback_stat_tokens(activity_result.get("gains", {}) as Dictionary),
		"details": details,
	}


func _build_adventure_feedback_payload(activity_result: Dictionary) -> Dictionary:
	var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
	if outcome.is_empty():
		return _build_activity_feedback_payload(activity_result)
	var won := bool(outcome.get("won", false))
	var details := _result_specialized_summary_lines(activity_result)
	var growth_line := _feedback_growth_line(activity_result.get("gains", {}) as Dictionary)
	if not growth_line.is_empty():
		details.append(growth_line)
	details.append_array(_feedback_reward_lines(activity_result))
	var region_name := str(outcome.get("regionName", _feedback_activity_name(activity_result)))
	return {
		"kind": "challenge",
		"badge": "원정",
		"tone": "gold" if won else "coral",
		"headline": "%s · %s" % ["원정 성공" if won else "원정 후퇴", region_name],
		"floatingStats": _feedback_stat_tokens(activity_result.get("gains", {}) as Dictionary),
		"details": details,
	}


func _result_specialized_summary_lines(activity_result: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
	if outcome.is_empty():
		return lines
	var kind := str(activity_result.get("kind", outcome.get("type", "")))
	if kind == "challenge":
		if outcome.has("playerScore") and outcome.has("opponentScore"):
			var rank := str(outcome.get("rank", "")).strip_edges()
			lines.append("도전 점수 · 나 %.1f / 상대 %.1f%s" % [
				float(outcome.get("playerScore", 0.0)),
				float(outcome.get("opponentScore", 0.0)),
					" · %s" % _challenge_rank_name(rank) if not rank.is_empty() else "",
			])
		var hint := str(outcome.get("hint", "")).strip_edges()
		if not hint.is_empty():
			lines.append("다음 준비 · %s" % hint)
		return lines
	if kind == "job":
		var incident_name := str(outcome.get("event", "근무 완료")).strip_edges()
		if bool(outcome.get("incident", false)):
			var incident_parts: Array[String] = []
			var effects: Dictionary = outcome.get("effects", {}) as Dictionary
			var stress_gain := float(effects.get("stress", 0.0))
			var citizen_delta := float(effects.get("citizens", 0.0))
			if stress_gain > 0.0:
				incident_parts.append("스트레스 +%s" % _feedback_number(stress_gain))
			if citizen_delta < 0.0:
				incident_parts.append("시민 관계 %s" % _feedback_number(citizen_delta))
			var reward_multiplier := float(outcome.get("rewardMultiplier", 1.0))
			if reward_multiplier < 1.0:
				incident_parts.append("보수 %d%%" % int(round(reward_multiplier * 100.0)))
			lines.append("돌발 사건 · %s%s" % [
				incident_name,
				" · %s" % " · ".join(incident_parts) if not incident_parts.is_empty() else "",
			])
		elif not incident_name.is_empty():
			lines.append("근무 결과 · %s" % incident_name)
		return lines
	if kind != "adventure":
		return lines

	var node_parts: Array[String] = []
	var node_labels := {"exploration": "탐색", "event": "사건", "encounter": "조우", "boss": "보스"}
	for raw_node: Variant in outcome.get("nodes", []) as Array:
		if raw_node is not Dictionary:
			continue
		var node := raw_node as Dictionary
		var node_type := str(node.get("type", "node"))
		var event_name := str(node.get("event", "")).strip_edges()
		var node_text := str(node_labels.get(node_type, node_type))
		var enemy_name := str(node.get("enemyName", "")).strip_edges()
		var enemy_trait := str(node.get("enemyTraitName", "")).strip_edges()
		if ["encounter", "boss"].has(node_type) and not enemy_name.is_empty():
			node_text += " %s%s" % [enemy_name, " (%s)" % enemy_trait if not enemy_trait.is_empty() else ""]
		elif not event_name.is_empty():
			node_text += " %s" % event_name
		node_parts.append(node_text)
	if not node_parts.is_empty():
		lines.append("3노드 · %s" % " → ".join(node_parts))

	var result_parts: Array[String] = []
	if bool(outcome.get("injured", false)):
		result_parts.append("부상")
		result_parts.append("다음 일정 강제 휴식")
	else:
		result_parts.append("%d노드 클리어" % int(outcome.get("clearedNodes", node_parts.size())))
	var loot_parts: Array[String] = []
	for raw_loot: Variant in outcome.get("loot", []) as Array:
		if raw_loot is not Dictionary:
			continue
		var loot := raw_loot as Dictionary
		loot_parts.append("%s ×%d" % [_item_display_name(str(loot.get("itemId", ""))), int(loot.get("count", 1))])
		if loot_parts.size() >= 2:
			break
	if not loot_parts.is_empty():
		result_parts.append("전리품 %s" % ", ".join(loot_parts))
	var region_reward: Dictionary = outcome.get("regionReward", {}) as Dictionary
	if _feedback_big_is_positive(region_reward):
		result_parts.append("지역 보상 골드 +%s" % _format_big(region_reward))
	var reward_fragment := str(outcome.get("rewardFragment", "")).strip_edges()
	if not reward_fragment.is_empty():
		result_parts.append("발견품 %s" % reward_fragment)
	if not result_parts.is_empty():
		lines.append("원정 결과 · %s" % " · ".join(result_parts))
	return lines


func _build_review_feedback_payload(review: Dictionary, activity_result: Dictionary) -> Dictionary:
	var awarded: Array = review.get("titles", []) as Array
	var details: Array[String] = []
	var kind := "review"
	var badge := "심사"
	var headline := "%d연차 %d시즌 심사 완료" % [int(review.get("year", 1)), int(review.get("season", 1))]
	var tone := "raised"
	if not awarded.is_empty():
		kind = "title"
		badge = "칭호"
		tone = "gold"
		var has_new_title := false
		var has_star_up := false
		for raw_title: Variant in awarded:
			if raw_title is not Dictionary:
				continue
			var title_data := raw_title as Dictionary
			var stars := int(title_data.get("stars", 1))
			has_new_title = has_new_title or stars <= 1
			has_star_up = has_star_up or stars > 1
			if details.size() < 2:
				details.append("★ %s · %s" % [str(title_data.get("name", title_data.get("id", "진로 칭호"))), str(title_data.get("rank", _career_rank(stars)))])
		if awarded.size() > 2:
			details.append("외 %d개 칭호가 함께 성장했습니다." % (awarded.size() - 2))
		if has_new_title and has_star_up:
			headline = "새 칭호와 별 상승"
		elif has_star_up:
			headline = "진로 칭호 별 상승"
		else:
			headline = "새 진로 칭호 획득"

	details.append("심사 보상 · 명성 +%d · 정책 일치 %d%%" % [
		int(review.get("renownGained", 0)),
		int(round(float(review.get("policyFit", 0.0)) * 100.0)),
	])
	var tier_before := int(review.get("worldTierBefore", _state.get("worldTier", 1)))
	var tier_after := int(review.get("worldTierAfter", tier_before))
	if tier_after > tier_before:
		details.append("세계 티어 상승 · %d → %d" % [tier_before, tier_after])
	else:
		details.append("성과 · 도전 승리 %d · 계약 %d" % [int(review.get("challengeWins", 0)), int(review.get("completedContracts", 0))])
	if str(activity_result.get("kind", "")) == "challenge":
		var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
		if outcome.has("playerScore") and outcome.has("opponentScore"):
			details.append("직전 도전 · %.1f / %.1f%s" % [
				float(outcome.get("playerScore", 0.0)),
				float(outcome.get("opponentScore", 0.0)),
				" 승리" if bool(outcome.get("won", false)) else " 경험 축적",
			])
		var hint := str(outcome.get("hint", "")).strip_edges()
		if not bool(outcome.get("won", false)) and not hint.is_empty():
			details.append("다음 준비 · %s" % hint)
	return {
		"kind": kind,
		"badge": badge,
		"tone": tone,
		"headline": headline,
		"floatingStats": _feedback_stat_tokens(activity_result.get("gains", {}) as Dictionary),
		"details": details,
	}


func _feedback_growth_line(gains: Dictionary) -> String:
	var parts := _feedback_stat_tokens(gains)
	return "성장 · %s" % " · ".join(parts) if not parts.is_empty() else ""


func _feedback_stat_tokens(gains: Dictionary) -> Array[String]:
	var keys: Array = gains.keys()
	keys.sort_custom(func(left: Variant, right: Variant) -> bool:
		return absf(float(gains[left])) > absf(float(gains[right]))
	)
	var parts: Array[String] = []
	for raw_key: Variant in keys:
		var value := float(gains[raw_key])
		if is_zero_approx(value):
			continue
		parts.append("%s %s%s" % [
			str(STAT_LABELS.get(str(raw_key), str(raw_key))),
			"+" if value > 0.0 else "",
			_feedback_number(value),
		])
		if parts.size() >= 3:
			break
	return parts


func _feedback_reward_lines(activity_result: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var reward: Dictionary = activity_result.get("reward", {}) as Dictionary
	if _feedback_big_is_positive(reward):
		lines.append("활동 보상 · 골드 +%s" % _format_big(reward))
	var outcome: Dictionary = activity_result.get("outcome", {}) as Dictionary
	var challenge_reward: Dictionary = outcome.get("rewardGold", {}) as Dictionary
	if _feedback_big_is_positive(challenge_reward):
		lines.append("도전 보상 · 골드 +%s" % _format_big(challenge_reward))
	return lines


func _feedback_big_is_positive(value: Dictionary) -> bool:
	return float(value.get("mantissa", 0.0)) > 0.0


func _feedback_number(value: float) -> String:
	return "%.1f" % value if absf(value) < 100.0 else "%.0f" % value


func _feedback_activity_name(activity_result: Dictionary) -> String:
	var activity_id := str(activity_result.get("activityId", ""))
	if not activity_id.is_empty():
		return _activity_name_by_id(activity_id)
	var title := str(activity_result.get("title", "도전"))
	return title.trim_suffix(" 완료")


func _world_action_card(title: String, detail: String, activity_id: String, action_label: String, lock_reason: String = "") -> Control:
	var card := _card("raised")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	box.add_child(_label(title, 18, RoyalTheme.PARCHMENT))
	box.add_child(_label(detail, 16, RoyalTheme.PARCHMENT_MUTED))
	if not lock_reason.is_empty():
		box.add_child(_label("잠금 · %s" % lock_reason, 16, RoyalTheme.DANGER))
	var action := _button(action_label, _run_world_activity.bind(activity_id), "secondary")
	action.disabled = not lock_reason.is_empty()
	action.add_to_group("critical_cta")
	box.add_child(action)
	card.add_child(box)
	return card


func _challenge_weight_summary(activity: Dictionary) -> String:
	var parts: Array[String] = []
	var weights: Dictionary = activity.get("challengeWeights", {}) as Dictionary
	var keys := weights.keys()
	keys.sort_custom(func(left, right): return float(weights[left]) > float(weights[right]))
	for key in keys.slice(0, 3):
		parts.append("%s %d%%" % [str(STAT_LABELS.get(str(key), key)), int(float(weights[key]) * 100.0)])
	return " · ".join(parts)


func _challenge_rank_name(rank: String) -> String:
	return str({
		"participation": "참가", "pass": "통과", "honors": "우수",
	}.get(rank, rank))


func _contract_modifier_name(modifier_id: String) -> String:
	return str({
		"low_energy": "에너지 25 이상", "high_quality": "고품질 수행", "no_repeat": "연속 반복 금지",
		"risk_bonus": "위험 임무 무부상", "budget_guard": "최소 보유금 준수", "mastery_focus": "숙련 집중",
		"limited_slots": "기한 내 완료", "balanced_tags": "분야 다양성", "stress_guard": "스트레스 상한 준수",
		"community_bonus": "관계 성장",
	}.get(modifier_id, modifier_id.replace("_", " ")))


func _setting_toggle(title: String, description: String, key: String, value: bool) -> Control:
	var card := _card("raised")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_child(_label(title, 18, RoyalTheme.PARCHMENT))
	text_box.add_child(_label(description, 16, RoyalTheme.PARCHMENT_MUTED))
	row.add_child(text_box)
	var toggle := CheckButton.new()
	toggle.custom_minimum_size = Vector2(64, 48)
	toggle.button_pressed = value
	toggle.toggled.connect(_toggle_setting.bind(key))
	row.add_child(toggle)
	card.add_child(row)
	return card


func _policy_slider(title: String, description: String, key: String, value: float, minimum: float, maximum: float, step: float, formatter: Callable) -> Control:
	var card := _card("raised")
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	var top := HBoxContainer.new()
	var title_label := _label(title, 17, RoyalTheme.PARCHMENT)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title_label)
	var value_label := _label(str(formatter.call(value)), 17, RoyalTheme.GOLD_SOFT, HORIZONTAL_ALIGNMENT_RIGHT)
	top.add_child(value_label)
	box.add_child(top)
	box.add_child(_label(description, 16, RoyalTheme.PARCHMENT_MUTED))
	var slider := HSlider.new()
	slider.set_meta("policy_key", key)
	slider.set_meta("policy_value_label", value_label)
	slider.custom_minimum_size.y = 44.0
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.value_changed.connect(_on_policy_slider_changed.bind(key, value_label, formatter))
	box.add_child(slider)
	card.add_child(box)
	return card


func _stat_card(title: String, value: float) -> Control:
	var card := _card("transparent")
	card.custom_minimum_size.y = 80.0
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	var title_label := _label(title, 16, RoyalTheme.PARCHMENT)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title_label)
	row.add_child(_label(_format_number(value), 17, RoyalTheme.GOLD_SOFT, HORIZONTAL_ALIGNMENT_RIGHT))
	box.add_child(row)
	var progress := ProgressBar.new()
	progress.custom_minimum_size.y = 12.0
	progress.value = fmod(value, 100.0)
	progress.show_percentage = false
	box.add_child(progress)
	card.add_child(box)
	return card


func _resource_card(title: String, value: String, accent: Color) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size.y = 72.0
	card.add_theme_stylebox_override("panel", RoyalTheme.card_style("transparent"))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	box.add_child(_label(title, 16, RoyalTheme.PARCHMENT_MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	box.add_child(_label(value, 19, accent, HORIZONTAL_ALIGNMENT_CENTER))
	card.add_child(box)
	return card


func _section_heading(title: String, subtitle: String = "") -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.add_child(_label(title, 20, RoyalTheme.PARCHMENT))
	if not subtitle.is_empty():
		box.add_child(_label(subtitle, 16, RoyalTheme.PARCHMENT_MUTED))
	return box


func _chip(text_value: String, accent: Color) -> Control:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", RoyalTheme.chip_style(accent))
	chip.add_child(_label(text_value, 16, RoyalTheme.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER))
	return chip


func _card(tone: String = "navy") -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", RoyalTheme.card_style(tone))
	return card


func _button(label_text: String, callback: Callable = Callable(), variant: String = "secondary", min_height: float = 48.0) -> Button:
	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size.y = maxf(44.0, min_height)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.tooltip_text = label_text.replace("\n", " · ")
	button.set_meta("royal_variant", variant)
	button.add_to_group("royal_button")
	RoyalTheme.apply_button(button, variant, bool(_read(["settings", "highContrast"], false)))
	button.pressed.connect(_on_button_pressed.bind(label_text))
	if callback.is_valid():
		button.pressed.connect(callback)
	for marker in ["자동 1회", "즉시 실행", "이 활동 1회", "원정 시작", "참가하기", "오프라인 결과", "이어하기", "구매", "장착", "사용", "판매", "계약 고정"]:
		if label_text.contains(marker):
			button.add_to_group("critical_cta")
			break
	return button


func _label(text_value: String, font_size: int = 16, color: Color = RoyalTheme.PARCHMENT, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", max(16, font_size))
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = alignment
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _load_activities() -> Array:
	var loaded := _load_json_array("res://data/activities.json")
	if not loaded.is_empty():
		return loaded
	return FALLBACK_ACTIVITIES.duplicate(true)


func _load_json_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) == TYPE_ARRAY:
		return parsed
	if typeof(parsed) == TYPE_DICTIONARY:
		for key in ["activities", "items", "data"]:
			if typeof(parsed.get(key, null)) == TYPE_ARRAY:
				return parsed[key]
	return []


func _load_json_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _activity_kind(activity: Dictionary) -> String:
	var kind := str(activity.get("kind", "education"))
	if kind in ["exam", "sport", "contest", "league"]:
		return "challenge"
	return kind


func _activity_by_id(activity_id: String) -> Dictionary:
	for activity in _activities:
		if typeof(activity) == TYPE_DICTIONARY and str(activity.get("id", "")) == activity_id:
			return activity
	return {}


func _activity_lock_reason(activity_id: String) -> String:
	var decision = _read(["lastPlannerDecision"], {})
	if typeof(decision) == TYPE_DICTIONARY:
		var rejected = decision.get("rejected", {})
		if typeof(rejected) == TYPE_DICTIONARY and rejected.has(activity_id):
			return str(rejected[activity_id])
	var activity := _activity_by_id(activity_id)
	var requires: Dictionary = activity.get("requires", {}) as Dictionary
	for key in (requires.get("gte", {}) as Dictionary):
		var actual := float(_read(["stats", str(key)], _read(["meters", str(key)], 0.0)))
		if actual < float((requires.get("gte", {}) as Dictionary)[key]):
			return "%s %.0f 필요" % [str(STAT_LABELS.get(str(key), key)), float((requires.get("gte", {}) as Dictionary)[key])]
	var tier_requirement = requires.get("worldTier", 0)
	var required_tier := int((tier_requirement as Dictionary).get("gte", 0)) if tier_requirement is Dictionary else int(tier_requirement)
	if int(_state.get("worldTier", 1)) < required_tier:
		return "세계 티어 %d 필요" % required_tier
	return ""


func _activity_name_by_id(activity_id: String) -> String:
	var activity := _activity_by_id(activity_id)
	if not activity.is_empty():
		return str(activity.get("name", activity_id))
	return activity_id.replace("_", " ")


func _current_activity_name() -> String:
	var task = _read(["activeTask"], {})
	if typeof(task) == TYPE_DICTIONARY:
		if not str(task.get("name", "")).is_empty():
			return str(task["name"])
		var activity_id := str(task.get("activityId", task.get("id", "REST_HOME")))
		return _activity_name_by_id(activity_id)
	return "다음 활동 준비"


func _planner_reason() -> String:
	var result: Array[String] = []
	var decision = _read(["lastPlannerDecision"], {})
	if typeof(decision) == TYPE_DICTIONARY:
		var decision_reasons = decision.get("reasons", [])
		if typeof(decision_reasons) == TYPE_ARRAY:
			for reason in decision_reasons:
				var text := str(reason.get("text", reason)) if typeof(reason) == TYPE_DICTIONARY else str(reason)
				if not text.is_empty() and not result.has(text):
					result.append(text)
				if result.size() == 3:
					break
	var task = _read(["activeTask"], {})
	if result.is_empty() and typeof(task) == TYPE_DICTIONARY and not str(task.get("reason", "")).is_empty():
		result.append(str(task["reason"]))
	var legacy_reasons = _state.get("selectionReasons", [])
	if result.size() < 3 and typeof(legacy_reasons) == TYPE_ARRAY:
		for reason in legacy_reasons:
			var text := str(reason.get("text", reason)) if typeof(reason) == TYPE_DICTIONARY else str(reason)
			if not text.is_empty() and not result.has(text):
				result.append(text)
			if result.size() == 3:
				break
	if not result.is_empty():
		return " · ".join(result)
	return "%s 방향 · 예산 안전 · 최근 다양성" % _preset_name(_policy_preset())


func _policy_preset() -> String:
	return str(_read(["growthPolicy", "preset"], "balanced"))


func _preset_name(preset_id: String) -> String:
	for preset in PRESETS:
		if str(preset["id"]) == preset_id:
			return str(preset["name"])
	return "균형"


func _season_slot() -> int:
	return posmod(int(_read(["time", "slot"], 0)), maxi(1, _config_int("slotsPerSeason", 28)))


func _profile_environment() -> String:
	var current_id := str(_read(["activeTask", "activityId"], _read(["activeTask", "id"], "")))
	var activity := _activity_by_id(current_id)
	var kind := str(activity.get("kind", ""))
	if kind == "job":
		return "city"
	if kind == "adventure":
		return "forest"
	if kind == "challenge":
		var tags: Array = activity.get("tags", []) as Array
		return "arena" if tags.has("sport") or tags.has("contest") or tags.has("league") else "library"
	if kind == "education":
		return "library"
	if kind == "rest":
		return "city" if current_id == "REST_WALK" else ("forest" if current_id in ["REST_TRIP", "REST_RESORT"] else "academy")
	match _policy_preset():
		"martial": return "arena"
		"artist", "leader": return "library"
		"explorer", "care": return "forest"
		_: return "academy"


func _reserve_gold_number() -> float:
	return _big_to_number(_read(["growthPolicy", "reserveGold"], {"mantissa": 3.0, "exponent": 2}))


func _career_title_count() -> int:
	var titles = _read(["careerTitles"], {})
	return titles.size() if typeof(titles) == TYPE_DICTIONARY else 0


func _career_display_name(title_id: String, title_data: Variant) -> String:
	if title_data is not Dictionary:
		return title_id
	var variant_name := str((title_data as Dictionary).get("variantName", "")).strip_edges()
	if not variant_name.is_empty():
		return variant_name
	return str((title_data as Dictionary).get("name", title_id))


func _career_rank(stars: int) -> String:
	return "명인 +%d" % (stars - 5) if stars > 5 else "%d성" % max(1, stars)


func _event_inbox() -> Array:
	var events = _read(["eventInbox"], [])
	return events.duplicate(true) if typeof(events) == TYPE_ARRAY else []


func _event_display_name(event_id: String) -> String:
	for raw_event in _events:
		if typeof(raw_event) == TYPE_DICTIONARY and str(raw_event.get("id", "")) == event_id:
			return str(raw_event.get("title", raw_event.get("name", event_id)))
	return event_id


func _event_choice_display_name(event_id: String, choice_id: String) -> String:
	for raw_event in _events:
		if typeof(raw_event) != TYPE_DICTIONARY or str(raw_event.get("id", "")) != event_id:
			continue
		for raw_choice in raw_event.get("choices", []):
			if typeof(raw_choice) == TYPE_DICTIONARY and str(raw_choice.get("id", "")) == choice_id:
				return str(raw_choice.get("text", choice_id))
	return "선택 기록 없음" if choice_id.is_empty() or choice_id == "-" else choice_id


func _item_display_name(item_id: String) -> String:
	var item := _item_by_id(item_id)
	return str(item.get("name", item_id.replace("_", " ")))


func _item_by_id(item_id: String) -> Dictionary:
	for raw_item in _items:
		if typeof(raw_item) == TYPE_DICTIONARY and str(raw_item.get("id", "")) == item_id:
			return raw_item as Dictionary
	return {}


func _item_category_name(category: String) -> String:
	return {"outfit": "의상", "accessory": "장신구", "weapon": "무기", "armor": "방어구", "consumable": "소비품"}.get(category, category)


func _inventory_stack(item_id: String) -> Dictionary:
	for raw_stack in _read(["inventory"], []):
		if typeof(raw_stack) == TYPE_DICTIONARY and str(raw_stack.get("id", "")) == item_id:
			return raw_stack as Dictionary
	return {}


func _inventory_count_ui(item_id: String) -> int:
	return int(_inventory_stack(item_id).get("count", 0))


func _inventory_enhancement_level(item_id: String) -> int:
	return int(_inventory_stack(item_id).get("enhancementLevel", 0))


func _equipped_slot_for(item_id: String) -> String:
	var equipment: Dictionary = _read(["equipment"], {})
	for slot in equipment:
		if str(equipment[slot]) == item_id:
			return str(slot)
	return ""


func _equipment_visual_state() -> Dictionary:
	var result: Dictionary = (_read(["equipment"], {}) as Dictionary).duplicate(true)
	var levels: Dictionary = {}
	for slot_id in ["outfit", "weapon", "armor", "accessory"]:
		var item_id := str(result.get(slot_id, ""))
		if not item_id.is_empty():
			levels[slot_id] = maxi(1, _inventory_enhancement_level(item_id))
	result["enhancementLevels"] = levels
	result["visualSeed"] = int(_state.get("seed", 1))
	return result


func _tier_item_price_text(item: Dictionary) -> String:
	var base_price := maxf(0.0, float(item.get("basePrice", 0.0)))
	if base_price <= 0.0:
		return "0"
	var tier_growth := maxf(1.0, _config_float("activityCostTierGrowth", 1.11))
	var log_value := log(base_price) / log(10.0) + float(maxi(0, int(_state.get("worldTier", 1)) - 1)) * log(tier_growth) / log(10.0)
	var exponent := int(floor(log_value))
	var mantissa := pow(10.0, log_value - float(exponent))
	return _format_big({"mantissa": mantissa, "exponent": exponent})


func _game_config() -> Dictionary:
	if _engine != null and _engine.has_method("get_content_db"):
		var content_db: Object = _engine.call("get_content_db") as Object
		if content_db != null:
			var live_config: Variant = content_db.get("config")
			if live_config is Dictionary:
				return live_config as Dictionary
	return _runtime_config


func _config_int(key: String, fallback: int) -> int:
	return int(_game_config().get(key, fallback))


func _config_float(key: String, fallback: float) -> float:
	return float(_game_config().get(key, fallback))


func _offline_cap_slots() -> int:
	var seconds_per_slot := maxi(1, _config_int("offlineSecondsPerSlot", 60))
	return maxi(0, _config_int("offlineCapSeconds", 28800) / seconds_per_slot)


func _duration_label(total_seconds: int) -> String:
	var seconds := maxi(0, total_seconds)
	if seconds > 0 and seconds % 3600 == 0:
		return "%d시간" % (seconds / 3600)
	if seconds > 0 and seconds % 60 == 0:
		return "%d분" % (seconds / 60)
	return "%d초" % seconds


func _read(path: Array, fallback = null):
	var cursor = _state
	for key in path:
		if typeof(cursor) != TYPE_DICTIONARY or not cursor.has(key):
			return fallback
		cursor = cursor[key]
	return cursor


func _deep_merge(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in overlay:
		if result.has(key) and typeof(result[key]) == TYPE_DICTIONARY and typeof(overlay[key]) == TYPE_DICTIONARY:
			result[key] = _deep_merge(result[key], overlay[key])
		else:
			result[key] = overlay[key]
	return result


func _format_big(value) -> String:
	if typeof(value) == TYPE_DICTIONARY and int(value.get("exponent", 0)) > 15:
		return "%.2fe%d" % [float(value.get("mantissa", 0.0)), int(value.get("exponent", 0))]
	return _format_number(_big_to_number(value))


func _big_to_number(value) -> float:
	if typeof(value) == TYPE_DICTIONARY:
		var mantissa := float(value.get("mantissa", 0.0))
		var exponent := int(value.get("exponent", 0))
		if exponent > 15:
			return mantissa * pow(10.0, 15.0)
		return mantissa * pow(10.0, float(exponent))
	return float(value)


func _number_to_big(value: float) -> Dictionary:
	if value <= 0.0:
		return {"mantissa": 0.0, "exponent": 0}
	var exponent := int(floor(log(value) / log(10.0)))
	return {"mantissa": value / pow(10.0, float(exponent)), "exponent": exponent}


func _format_number(value: float) -> String:
	var absolute := absf(value)
	if absolute < 1000.0:
		return "%d" % int(round(value))
	if absolute < 1000000.0:
		return "%.1f천" % (value / 1000.0)
	if absolute < 100000000.0:
		return "%.1f만" % (value / 10000.0)
	if absolute < 1000000000000.0:
		return "%.1f억" % (value / 100000000.0)
	return "%.2e" % value


func _has_engine_method(method: String) -> bool:
	return _engine != null and _engine.has_method(method)


func _adopt_engine_result(result: Variant) -> void:
	if result is Dictionary:
		var result_dict: Dictionary = result as Dictionary
		if result_dict.get("state") is Dictionary:
			_state = _deep_merge(_fallback_state(), result_dict["state"] as Dictionary)
			return
		if result_dict.has("schemaVersion") and result_dict.get("stats") is Dictionary:
			_state = _deep_merge(_fallback_state(), result_dict)
			return
	_sync_engine_state()


func _persist_silently() -> bool:
	if _engine == null:
		return false
	var wall_now := int(Time.get_unix_time_from_system())
	var save_boundary := wall_now
	var preserve_last_simulated_at := false
	if int(_state.get("pendingOfflineSlots", 0)) > 0:
		save_boundary = int(_state.get("lastSimulatedAt", save_boundary))
		preserve_last_simulated_at = true
	elif int(_state.get("lastSimulatedAt", 0)) > wall_now:
		preserve_last_simulated_at = true
	if _engine.has_method("save_game"):
		return _result_ok(_engine.call("save_game", "", save_boundary, preserve_last_simulated_at))
	if _engine.has_method("save"):
		return _result_ok(_engine.call("save", "", save_boundary, preserve_last_simulated_at))
	if _engine.has_method("persist"):
		var result: Variant = _engine.call("persist")
		return _result_ok(result) if result != null else true
	return false


func _stamp_engine_time_boundary(now_unix: int = -1) -> void:
	if _engine == null or not _engine.has_method("advance_slots"):
		return
	var boundary := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	_adopt_engine_result(_engine.call("advance_slots", 0, boundary))


func _pending_offline_slots() -> int:
	if not bool(_read(["settings", "autoRun"], true)):
		return 0
	var last_seen := int(_state.get("lastSimulatedAt", 0))
	if last_seen <= 0:
		return 0
	var now := int(Time.get_unix_time_from_system())
	if now <= last_seen:
		return 0
	var seconds_per_slot := maxi(1, _config_int("offlineSecondsPerSlot", 60))
	return clampi((now - last_seen) / seconds_per_slot, 0, _offline_cap_slots())


func _initialize_runtime_ports() -> void:
	_analytics_port = LocalAnalyticsPort.new()
	_ad_port = NoOpAdPort.new()
	_iap_port = NoOpIapPort.new()
	_audio_port = SynthAudioPort.new()
	_audio_port.name = "RuntimeAudioPort"
	add_child(_audio_port)
	_audio_port.call("set_enabled", bool(_read(["settings", "sound"], true)))
	_audio_port.call("play_bgm", SynthAudioPort.SILENT_BGM)
	_track_event(&"session_started", {
		"worldTier": int(_state.get("worldTier", 1)),
		"preset": _policy_preset(),
	})


func _track_event(event_name: StringName, parameters: Dictionary = {}) -> void:
	if _analytics_port != null and _analytics_port.has_method("track"):
		_analytics_port.call("track", event_name, parameters)


func _play_sfx(cue: StringName) -> void:
	if _audio_port != null and _audio_port.has_method("play_cue"):
		_audio_port.call("play_cue", cue)


func _on_button_pressed(label_text: String) -> void:
	_play_sfx(SynthAudioPort.CUE_BUTTON)
	_track_event(&"button_pressed", {"screen": _current_tab, "label": label_text})


func _result_ok(result: Variant) -> bool:
	if result is Dictionary:
		return bool((result as Dictionary).get("ok", true))
	return result != null and result != false
