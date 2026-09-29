extends SceneTree

const VIEWPORTS: Array[Vector2i] = [
	Vector2i(390, 844),
	Vector2i(430, 932),
	Vector2i(720, 1280),
]
const MAIN_TABS: Array[String] = ["home", "plan", "activity", "growth", "record"]
const SHEETS: Array[String] = ["world", "shop", "settings", "offline", "event", "profile", "continue"]
const EDGE_TOLERANCE: float = 1.5
const SAVE_PATH := "user://qa_layout_probe_save.json"

var _failures: Array[String] = []
var _passes: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[LAYOUT] Critical CTA viewport probe")
	_prepare_test_save()
	var packed: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "main.tscn 로드")
	if packed == null:
		_finish()
		return

	for viewport_size: Vector2i in VIEWPORTS:
		await _probe_viewport(packed, viewport_size)

	_finish()


func _probe_viewport(packed: PackedScene, viewport_size: Vector2i) -> void:
	root.size = viewport_size
	var main: Control = packed.instantiate() as Control
	root.add_child(main)
	await process_frame
	await process_frame
	var main_rect: Rect2 = main.get_global_rect()
	_check(main_rect.size.x > 0.0 and main_rect.size.y > 0.0, "%s root bounds" % _size_label(viewport_size))

	var total_checked: int = 0
	for tab_id: String in MAIN_TABS:
		main.call("_show_tab", tab_id)
		await process_frame
		await process_frame
		total_checked += _check_current_ctas(main, main_rect, "%s/%s" % [_size_label(viewport_size), tab_id])

	for sheet_id: String in SHEETS:
		main.call("_open_sheet", sheet_id)
		await process_frame
		await process_frame
		total_checked += _check_current_ctas(main, main_rect, "%s/%s" % [_size_label(viewport_size), sheet_id])
		main.call("_close_sheet")
		await process_frame
		await process_frame

	_check(total_checked >= (MAIN_TABS.size() + SHEETS.size()) * 5, "%s critical_cta coverage=%d" % [_size_label(viewport_size), total_checked])
	print("[LAYOUT] %s root=%s checked=%d" % [_size_label(viewport_size), str(main_rect), total_checked])
	main.queue_free()
	await process_frame
	await process_frame


func _check_current_ctas(main: Control, viewport_rect: Rect2, context: String) -> int:
	var checked: int = 0
	var all_valid: bool = true
	for candidate: Node in get_nodes_in_group("critical_cta"):
		if not is_instance_valid(candidate) or not (candidate == main or main.is_ancestor_of(candidate)):
			continue
		if candidate is not Control:
			continue
		var cta: Control = candidate as Control
		if not cta.is_visible_in_tree():
			continue
		var rect: Rect2 = cta.get_global_rect()
		if not rect.intersects(viewport_rect, true):
			# Scroll content below the fold is intentionally reachable by scrolling;
			# only controls presented in the current viewport are bounds-critical.
			continue
		checked += 1
		var within: bool = rect.position.x >= viewport_rect.position.x - EDGE_TOLERANCE
		within = within and rect.position.y >= viewport_rect.position.y - EDGE_TOLERANCE
		within = within and rect.end.x <= viewport_rect.end.x + EDGE_TOLERANCE
		within = within and rect.end.y <= viewport_rect.end.y + EDGE_TOLERANCE
		var touch_size: bool = rect.size.x >= 44.0 and rect.size.y >= 44.0
		var finite: bool = _finite(rect.position.x) and _finite(rect.position.y) and _finite(rect.size.x) and _finite(rect.size.y)
		if not within or not touch_size or not finite:
			all_valid = false
			print("[LAYOUT] invalid context=%s node=%s rect=%s viewport=%s" % [context, str(cta.get_path()), str(rect), str(viewport_rect)])
	_check(checked >= 5, "%s visible critical_cta >= 5" % context)
	_check(all_valid, "AC-UI-03 %s critical_cta bounds" % context)
	return checked


func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


func _size_label(value: Vector2i) -> String:
	return "%dx%d" % [value.x, value.y]


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
		print("[LAYOUT] PASS checks=%d" % _passes)
		quit(0)
		return
	print("[LAYOUT] FAIL passed=%d failed=%d" % [_passes, _failures.size()])
	for failure: String in _failures:
		print("[LAYOUT]   - %s" % failure)
	quit(1)


func _prepare_test_save() -> void:
	_cleanup_test_save()
	ProjectSettings.set_setting("princess_tycoon/testing/save_path", SAVE_PATH)


func _cleanup_test_save() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_PATH)
	for suffix in ["", ".bak", ".tmp", ".corrupt"]:
		if FileAccess.file_exists(absolute + suffix):
			DirAccess.remove_absolute(absolute + suffix)
