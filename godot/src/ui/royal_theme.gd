extends RefCounted

const MIDNIGHT := Color("#10182f")
const MIDNIGHT_SOFT := Color("#182445")
const NAVY_CARD := Color("#202d4f")
const NAVY_RAISED := Color("#29385f")
const PARCHMENT := Color("#fff4d8")
const PARCHMENT_MUTED := Color("#d8d2c4")
const INK := Color("#17213d")
const CORAL := Color("#ff746c")
const CORAL_DARK := Color("#d95559")
const GOLD := Color("#f3c864")
const GOLD_SOFT := Color("#ffe29a")
const MINT := Color("#7ed9bd")
const SKY := Color("#82b8e8")
const DANGER := Color("#ff9a91")
const DISABLED := Color("#69728a")


static func build(font: Font = null) -> Theme:
	var result := Theme.new()
	if font != null:
		result.default_font = font
	result.default_font_size = 16

	result.set_color("font_color", "Label", PARCHMENT)
	result.set_color("font_shadow_color", "Label", Color(0.02, 0.04, 0.10, 0.7))
	result.set_constant("shadow_offset_x", "Label", 1)
	result.set_constant("shadow_offset_y", "Label", 1)
	result.set_color("font_color", "Button", PARCHMENT)
	result.set_color("font_hover_color", "Button", Color.WHITE)
	result.set_color("font_pressed_color", "Button", Color.WHITE)
	result.set_color("font_focus_color", "Button", Color.WHITE)
	result.set_color("font_disabled_color", "Button", Color("#a6adc0"))
	result.set_stylebox("normal", "Button", button_style("secondary", "normal"))
	result.set_stylebox("hover", "Button", button_style("secondary", "hover"))
	result.set_stylebox("pressed", "Button", button_style("secondary", "pressed"))
	result.set_stylebox("focus", "Button", focus_style())
	result.set_stylebox("disabled", "Button", button_style("disabled", "normal"))

	result.set_color("font_color", "LineEdit", INK)
	result.set_color("caret_color", "LineEdit", CORAL_DARK)
	result.set_color("selection_color", "LineEdit", Color(CORAL, 0.35))
	result.set_stylebox("normal", "LineEdit", input_style(false))
	result.set_stylebox("focus", "LineEdit", input_style(true))
	result.set_stylebox("read_only", "LineEdit", input_style(false))

	result.set_stylebox("slider", "HSlider", slider_track())
	result.set_stylebox("grabber_area", "HSlider", slider_fill())
	result.set_stylebox("grabber_area_highlight", "HSlider", slider_fill())
	result.set_icon("grabber", "HSlider", _circle_icon(20, GOLD))
	result.set_icon("grabber_highlight", "HSlider", _circle_icon(22, GOLD_SOFT))

	result.set_stylebox("background", "ProgressBar", progress_background())
	result.set_stylebox("fill", "ProgressBar", progress_fill(CORAL))
	result.set_color("font_color", "ProgressBar", PARCHMENT)
	result.set_color("font_outline_color", "ProgressBar", MIDNIGHT)
	result.set_constant("outline_size", "ProgressBar", 3)

	result.set_color("font_color", "CheckButton", PARCHMENT)
	result.set_color("font_hover_color", "CheckButton", Color.WHITE)
	return result


static func apply_button(button: Button, variant: String = "secondary", high_contrast: bool = false) -> void:
	button.add_theme_stylebox_override("normal", button_style(variant, "normal", high_contrast))
	button.add_theme_stylebox_override("hover", button_style(variant, "hover", high_contrast))
	button.add_theme_stylebox_override("pressed", button_style(variant, "pressed", high_contrast))
	button.add_theme_stylebox_override("focus", focus_style())
	button.add_theme_stylebox_override("disabled", button_style("disabled", "normal", high_contrast))
	if variant == "primary":
		button.add_theme_color_override("font_color", MIDNIGHT)
		button.add_theme_color_override("font_hover_color", MIDNIGHT)
		button.add_theme_color_override("font_pressed_color", MIDNIGHT)
	elif variant == "gold":
		button.add_theme_color_override("font_color", INK)
		button.add_theme_color_override("font_hover_color", INK)
		button.add_theme_color_override("font_pressed_color", INK)
	elif variant == "ghost":
		button.add_theme_color_override("font_color", PARCHMENT_MUTED)


static func button_style(variant: String, state: String, high_contrast: bool = false) -> StyleBoxFlat:
	var fill := NAVY_RAISED
	var border := Color("#43557d")
	match variant:
		"primary":
			fill = CORAL if state == "normal" else Color("#ff8b83")
			border = Color("#ffaca5")
		"gold":
			fill = GOLD if state == "normal" else GOLD_SOFT
			border = Color("#fff0b7")
		"ghost":
			fill = Color(0.12, 0.18, 0.32, 0.28) if state == "normal" else Color(0.24, 0.31, 0.49, 0.7)
			border = Color(0.55, 0.62, 0.76, 0.38)
		"danger":
			fill = Color("#6e3443") if state == "normal" else Color("#884354")
			border = DANGER
		"disabled":
			fill = Color("#303a53")
			border = Color("#4d576f")
		_:
			if state == "hover":
				fill = Color("#35466e")
			elif state == "pressed":
				fill = Color("#1d2948")
	if high_contrast:
		border = GOLD_SOFT if variant != "danger" else Color.WHITE
	var box := _box(fill, 14, border, 3 if high_contrast else 1)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	return box


static func card_style(tone: String = "navy") -> StyleBoxFlat:
	var fill := NAVY_CARD
	var border := Color("#3b4b71")
	match tone:
		"raised":
			fill = NAVY_RAISED
			border = Color("#55668d")
		"parchment":
			fill = PARCHMENT
			border = GOLD
		"coral":
			fill = Color("#4a2d43")
			border = CORAL
		"gold":
			fill = Color("#403a3c")
			border = GOLD
		"transparent":
			fill = Color(0.08, 0.12, 0.23, 0.70)
			border = Color(0.45, 0.54, 0.72, 0.30)
	var box := _box(fill, 18, border, 1)
	box.content_margin_left = 16.0
	box.content_margin_right = 16.0
	box.content_margin_top = 14.0
	box.content_margin_bottom = 14.0
	box.shadow_color = Color(0.01, 0.02, 0.06, 0.28)
	box.shadow_size = 7
	box.shadow_offset = Vector2(0, 3)
	return box


static func sheet_style() -> StyleBoxFlat:
	var box := _box(MIDNIGHT_SOFT, 26, Color("#52648d"), 1)
	box.corner_radius_bottom_left = 0
	box.corner_radius_bottom_right = 0
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 18.0
	box.content_margin_bottom = 18.0
	box.shadow_color = Color(0, 0, 0, 0.55)
	box.shadow_size = 18
	box.shadow_offset = Vector2(0, -6)
	return box


static func chip_style(accent: Color = GOLD) -> StyleBoxFlat:
	var box := _box(Color(accent, 0.13), 999, Color(accent, 0.72), 1)
	box.content_margin_left = 10.0
	box.content_margin_right = 10.0
	box.content_margin_top = 5.0
	box.content_margin_bottom = 5.0
	return box


static func focus_style() -> StyleBoxFlat:
	var box := _box(Color.TRANSPARENT, 15, GOLD_SOFT, 3)
	box.expand_margin_left = 2.0
	box.expand_margin_right = 2.0
	box.expand_margin_top = 2.0
	box.expand_margin_bottom = 2.0
	return box


static func input_style(focused: bool) -> StyleBoxFlat:
	var box := _box(PARCHMENT, 12, CORAL if focused else GOLD, 2 if focused else 1)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	return box


static func progress_background() -> StyleBoxFlat:
	var box := _box(Color("#0b1225"), 999, Color("#3e4c6c"), 1)
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	return box


static func progress_fill(color: Color) -> StyleBoxFlat:
	return _box(color, 999, color, 0)


static func slider_track() -> StyleBoxFlat:
	var box := _box(Color("#0a1123"), 999, Color("#425272"), 1)
	box.content_margin_top = 5.0
	box.content_margin_bottom = 5.0
	return box


static func slider_fill() -> StyleBoxFlat:
	var box := _box(CORAL, 999, CORAL, 0)
	box.content_margin_top = 5.0
	box.content_margin_bottom = 5.0
	return box


static func _box(fill: Color, radius: int, border_color: Color, border_width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_left = radius
	box.corner_radius_bottom_right = radius
	box.border_color = border_color
	box.border_width_left = border_width
	box.border_width_top = border_width
	box.border_width_right = border_width
	box.border_width_bottom = border_width
	return box


static func _circle_icon(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var center := Vector2(size - 1, size - 1) * 0.5
	for y in range(size):
		for x in range(size):
			if Vector2(x, y).distance_to(center) <= float(size) * 0.43:
				image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)
