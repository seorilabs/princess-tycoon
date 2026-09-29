extends SceneTree

const EXPECTED_SCREENS: Array[String] = [
	"home", "plan", "activity", "growth", "record",
	"world", "shop", "settings", "offline", "event", "profile", "continue",
]
const SAVE_PATH := "user://qa_headless_smoke_save.json"

var _failures: Array[String] = []
var _passes: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[SMOKE] Main scene headless interaction")
	_prepare_test_save()
	root.size = Vector2i(390, 844)
	var packed: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "main.tscn 로드")
	if packed == null:
		_finish()
		return

	var main: Node = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	_check(is_instance_valid(main) and main.is_inside_tree(), "main scene 인스턴스 진입")
	_check(main is Control and (main as Control).size.x > 0.0 and (main as Control).size.y > 0.0, "main root 유효 bounds")
	_check(str(main.get_meta("screen_id", "")) == "home", "초기 홈 화면")

	var raw_screens: Variant = main.get_meta("available_screen_ids", PackedStringArray())
	var available: PackedStringArray = PackedStringArray(raw_screens) if raw_screens is PackedStringArray or raw_screens is Array else PackedStringArray()
	_check(available.size() == 12, "AC-UI-02 기능 경로 12개")
	for screen_id: String in EXPECTED_SCREENS:
		_check(available.has(screen_id), "기능 경로 노출: %s" % screen_id)

	var ctas: Array[Node] = _descendant_group_nodes(main, "critical_cta")
	_check(ctas.size() >= 6, "critical_cta 그룹 노출")
	var touch_targets_ok: bool = true
	for cta: Node in ctas:
		if cta is Control:
			var control: Control = cta as Control
			if control.size.x < 44.0 or control.size.y < 44.0:
				touch_targets_ok = false
	_check(touch_targets_ok, "AC-UI-04 critical CTA 44x44 이상")

	var engine_value: Variant = main.get("_engine")
	var engine: Object = engine_value as Object
	_check(engine != null and engine.has_method("get_state"), "MainScreen GameEngine 연결")
	if engine != null and engine.has_method("get_state"):
		var before: Dictionary = engine.call("get_state") as Dictionary
		var before_slot: int = int((before.get("time", {}) as Dictionary).get("slot", -1))
		var decision: Dictionary = engine.call("preview_next_activity") as Dictionary
		_check(not str(decision.get("activityId", "")).is_empty(), "GameEngine 다음 활동 상호작용")
		var step: Dictionary = engine.call("advance_slots", 1) as Dictionary
		var after: Dictionary = engine.call("get_state") as Dictionary
		_check(int(step.get("slotsAdvanced", 0)) == 1, "GameEngine 1 slot 실행")
		_check(int((after.get("time", {}) as Dictionary).get("slot", -1)) == before_slot + 1, "GameEngine 상태 진행")
		_check(bool((engine.call("validate_state") as Dictionary).get("ok", false)), "GameEngine 상호작용 후 상태 유효")

	for tab_id: String in ["home", "plan", "activity", "growth", "record"]:
		main.call("_show_tab", tab_id)
		await process_frame
		await process_frame
		_check(str(main.get_meta("screen_id", "")) == tab_id, "탭 도달: %s" % tab_id)

	for sheet_id: String in ["world", "shop", "settings", "offline", "event", "profile", "continue"]:
		main.call("_open_sheet", sheet_id)
		await process_frame
		await process_frame
		_check(_find_screen_node(main, sheet_id) != null, "보조 화면 도달: %s" % sheet_id)
		main.call("_close_sheet")
		await process_frame

	main.queue_free()
	await process_frame
	_finish()


func _descendant_group_nodes(ancestor: Node, group_name: StringName) -> Array[Node]:
	var result: Array[Node] = []
	for candidate: Node in get_nodes_in_group(group_name):
		if candidate == ancestor or ancestor.is_ancestor_of(candidate):
			result.append(candidate)
	return result


func _find_screen_node(ancestor: Node, screen_id: String) -> Node:
	if str(ancestor.get_meta("screen_id", "")) == screen_id:
		return ancestor
	for child: Node in ancestor.get_children():
		var found: Node = _find_screen_node(child, screen_id)
		if found != null:
			return found
	return null


func _check(condition: bool, label: String) -> void:
	if condition:
		_passes += 1
		print("[PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	_cleanup_test_save()
	if _failures.is_empty():
		print("[SMOKE] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[SMOKE] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	for failure: String in _failures:
		print("[SMOKE]   - %s" % failure)
	quit(1)


func _prepare_test_save() -> void:
	_cleanup_test_save()
	ProjectSettings.set_setting("princess_tycoon/testing/save_path", SAVE_PATH)


func _cleanup_test_save() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_PATH)
	for suffix in ["", ".bak", ".tmp", ".corrupt"]:
		if FileAccess.file_exists(absolute + suffix):
			DirAccess.remove_absolute(absolute + suffix)
