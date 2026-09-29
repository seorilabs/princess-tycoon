extends Control

const RoyalTheme = preload("res://src/ui/royal_theme.gd")

const MAX_DETAIL_LINES := 4
const STATIC_VISIBLE_SECONDS := 4.0

var _active_panel: PanelContainer
var _active_tween: Tween
var _active_serial := 0
var _reduced_motion := false
var _static_hide_timer: Timer
var _static_hide_serial := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_static_hide_timer = Timer.new()
	_static_hide_timer.one_shot = true
	_static_hide_timer.ignore_time_scale = true
	_static_hide_timer.timeout.connect(_on_static_hide_timeout)
	add_child(_static_hide_timer)


func present(payload: Dictionary, reduced_motion: bool) -> void:
	if payload.is_empty():
		return
	_reduced_motion = reduced_motion
	_clear_active()
	_active_serial += 1
	var serial := _active_serial
	var panel := _build_panel(payload)
	_active_panel = panel
	add_child(panel)
	if _reduced_motion:
		_apply_static_state(panel)
		_schedule_static_hide(serial)
	else:
		panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
		panel.scale = Vector2(0.88, 0.88) if str(payload.get("kind", "activity")) in ["challenge", "review", "title"] else Vector2(0.95, 0.95)
		call_deferred("_animate_active", serial)


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	if not enabled or _active_panel == null or not is_instance_valid(_active_panel):
		return
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	_apply_static_state(_active_panel)
	_schedule_static_hide(_active_serial)


func has_active_feedback() -> bool:
	return _active_panel != null and is_instance_valid(_active_panel) and _active_panel.visible


func active_feedback_kind() -> String:
	if not has_active_feedback():
		return ""
	return str(_active_panel.get_meta("feedback_kind", ""))


func active_motion_mode() -> String:
	if not has_active_feedback():
		return ""
	return str(_active_panel.get_meta("motion_mode", ""))


func active_detail_count() -> int:
	if not has_active_feedback():
		return 0
	return int(_active_panel.get_meta("detail_count", 0))


func active_floating_stat_count() -> int:
	if not has_active_feedback():
		return 0
	return int(_active_panel.get_meta("floating_stat_count", 0))


func _build_panel(payload: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "ResultFeedback"
	panel.anchor_left = 0.05
	panel.anchor_right = 0.95
	panel.anchor_top = 0.14
	panel.anchor_bottom = 0.14
	panel.offset_bottom = 218.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.z_index = 80
	panel.add_theme_stylebox_override("panel", RoyalTheme.card_style(str(payload.get("tone", "raised"))))
	panel.set_meta("feedback_kind", str(payload.get("kind", "activity")))
	panel.set_meta("payload", payload.duplicate(true))

	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.custom_minimum_size.x = 300.0
	content.add_theme_constant_override("separation", 5)
	panel.add_child(content)

	var heading := HBoxContainer.new()
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_theme_constant_override("separation", 8)
	content.add_child(heading)
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", RoyalTheme.chip_style(_accent_for_kind(str(payload.get("kind", "activity")))))
	var badge_label := _label(str(payload.get("badge", "성장")), 16, RoyalTheme.PARCHMENT, HORIZONTAL_ALIGNMENT_CENTER)
	badge_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	badge_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	badge.add_child(badge_label)
	heading.add_child(badge)
	var headline := _label(str(payload.get("headline", "활동 완료")), 21, RoyalTheme.GOLD_SOFT)
	headline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	headline.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	headline.autowrap_mode = TextServer.AUTOWRAP_OFF
	heading.add_child(headline)

	var floating_stat_count := 0
	var stat_row := HBoxContainer.new()
	stat_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stat_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stat_row.add_theme_constant_override("separation", 6)
	for raw_stat: Variant in payload.get("floatingStats", []) as Array:
		if floating_stat_count >= 3:
			break
		var stat_text := str(raw_stat).strip_edges()
		if stat_text.is_empty():
			continue
		var chip := PanelContainer.new()
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		chip.add_theme_stylebox_override("panel", RoyalTheme.chip_style(RoyalTheme.MINT))
		chip.add_to_group("result_stat_chip")
		chip.set_meta("stat_index", floating_stat_count)
		var stat_label := _label(stat_text, 16, RoyalTheme.GOLD_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
		stat_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		stat_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		chip.add_child(stat_label)
		stat_row.add_child(chip)
		floating_stat_count += 1
	if floating_stat_count > 0:
		content.add_child(stat_row)
	else:
		stat_row.free()
	panel.set_meta("floating_stat_count", floating_stat_count)

	var detail_count := 0
	for raw_line: Variant in payload.get("details", []) as Array:
		if detail_count >= MAX_DETAIL_LINES:
			break
		var line := str(raw_line).strip_edges()
		if line.is_empty():
			continue
		content.add_child(_label(line, 16, RoyalTheme.PARCHMENT_MUTED))
		detail_count += 1
	panel.set_meta("detail_count", detail_count)
	return panel


func _animate_active(serial: int) -> void:
	if serial != _active_serial or _active_panel == null or not is_instance_valid(_active_panel):
		return
	if _reduced_motion:
		_apply_static_state(_active_panel)
		_schedule_static_hide(serial)
		return
	var panel := _active_panel
	panel.pivot_offset = panel.size * 0.5
	panel.set_meta("motion_mode", "animated")
	var floating_chips := _floating_stat_chips(panel)
	var chip_positions: Array[Vector2] = []
	for chip: Control in floating_chips:
		chip.pivot_offset = chip.size * 0.5
		chip_positions.append(chip.position)
		chip.position += Vector2(0.0, 10.0)
		chip.scale = Vector2(0.86, 0.86)
		chip.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	_active_tween.parallel().tween_property(panel, "scale", Vector2.ONE, 0.24)
	for index: int in range(floating_chips.size()):
		var chip := floating_chips[index]
		var delay := 0.04 * float(index)
		_active_tween.parallel().tween_property(chip, "modulate:a", 1.0, 0.18).set_delay(delay)
		_active_tween.parallel().tween_property(chip, "scale", Vector2.ONE, 0.22).set_delay(delay)
		_active_tween.parallel().tween_property(chip, "position", chip_positions[index], 0.22).set_delay(delay)
	_active_tween.tween_interval(2.2)
	_active_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_active_tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	_active_tween.finished.connect(_finish_if_current.bind(serial))


func _apply_static_state(panel: PanelContainer) -> void:
	panel.modulate = Color.WHITE
	panel.scale = Vector2.ONE
	panel.rotation = 0.0
	for chip: Control in _floating_stat_chips(panel):
		chip.modulate = Color.WHITE
		chip.scale = Vector2.ONE
	panel.set_meta("motion_mode", "static")


func _floating_stat_chips(panel: PanelContainer) -> Array[Control]:
	var result: Array[Control] = []
	for node: Node in panel.find_children("*", "PanelContainer", true, false):
		if node.is_in_group("result_stat_chip"):
			result.append(node as Control)
	return result


func _schedule_static_hide(serial: int) -> void:
	_static_hide_serial = serial
	_static_hide_timer.start(STATIC_VISIBLE_SECONDS)


func _on_static_hide_timeout() -> void:
	_finish_if_current(_static_hide_serial)


func _finish_if_current(serial: int) -> void:
	if serial != _active_serial:
		return
	_clear_active()


func _clear_active() -> void:
	if _static_hide_timer != null:
		_static_hide_timer.stop()
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	if _active_panel != null and is_instance_valid(_active_panel):
		_active_panel.visible = false
		_active_panel.queue_free()
	_active_panel = null


func _accent_for_kind(kind: String) -> Color:
	match kind:
		"challenge": return RoyalTheme.CORAL
		"review": return RoyalTheme.SKY
		"title": return RoyalTheme.GOLD
		_: return RoyalTheme.MINT


func _label(text_value: String, font_size: int, color: Color, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text_value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", maxi(16, font_size))
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = alignment
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
