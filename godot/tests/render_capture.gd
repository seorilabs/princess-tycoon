extends SceneTree

const LOGICAL_SIZE := Vector2i(390, 844)

var _capture_size := LOGICAL_SIZE
var _output_path := "/tmp/princess-tycoon-render.png"
var _save_path := "user://qa_render_capture.json"
var _capture_result_feedback := false


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			var pieces := argument.trim_prefix("--size=").split("x")
			if pieces.size() == 2:
				_capture_size = Vector2i(maxi(1, int(pieces[0])), maxi(1, int(pieces[1])))
		if argument.begins_with("--output="):
			_output_path = argument.trim_prefix("--output=")
		if argument == "--result-feedback":
			_capture_result_feedback = true
	_save_path = "user://qa_render_%dx%d.json" % [_capture_size.x, _capture_size.y]
	_cleanup_save()
	ProjectSettings.set_setting("princess_tycoon/testing/save_path", _save_path)
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		push_error("[RENDER] main scene load failed")
		quit(1)
		return
	var logical_viewport := SubViewport.new()
	logical_viewport.name = "Logical390x844"
	logical_viewport.size = LOGICAL_SIZE
	logical_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	logical_viewport.disable_3d = true
	root.add_child(logical_viewport)
	var main := packed.instantiate() as Control
	logical_viewport.add_child(main)

	var capture_viewport := SubViewport.new()
	capture_viewport.name = "Capture%dx%d" % [_capture_size.x, _capture_size.y]
	capture_viewport.size = _capture_size
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	capture_viewport.disable_3d = true
	root.add_child(capture_viewport)
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	capture_viewport.add_child(background)
	var presentation := TextureRect.new()
	presentation.texture = logical_viewport.get_texture()
	presentation.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	presentation.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	presentation.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	capture_viewport.add_child(presentation)

	for _frame: int in range(4):
		await process_frame
	if _capture_result_feedback:
		main.call("_complete_current_activity")
	for _frame: int in range(4):
		await process_frame
	var texture := capture_viewport.get_texture()
	if texture == null:
		push_error("[RENDER] viewport texture unavailable")
		_cleanup_save()
		quit(1)
		return
	var image := texture.get_image()
	if image == null or image.get_size() != _capture_size:
		push_error("[RENDER] size mismatch expected=%s actual=%s" % [str(_capture_size), str(image.get_size() if image != null else Vector2i.ZERO)])
		_cleanup_save()
		quit(1)
		return
	var error := image.save_png(_output_path)
	_cleanup_save()
	if error != OK:
		push_error("[RENDER] png save failed error=%d" % error)
		quit(1)
		return
	logical_viewport.queue_free()
	capture_viewport.queue_free()
	await process_frame
	print("[RENDER] PASS size=%dx%d output=%s" % [_capture_size.x, _capture_size.y, _output_path])
	quit(0)


func _cleanup_save() -> void:
	var absolute := ProjectSettings.globalize_path(_save_path)
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:
		if FileAccess.file_exists(absolute + suffix):
			DirAccess.remove_absolute(absolute + suffix)
