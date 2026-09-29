extends Control

const RoyalTheme = preload("res://src/ui/royal_theme.gd")

var profile := "balanced"
var environment := "academy"
var reduced_motion := false
var equipment: Dictionary = {}
var _phase := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func set_profile(value: String) -> void:
	profile = value
	queue_redraw()


func set_environment(value: String) -> void:
	environment = value
	queue_redraw()


func set_equipment(value: Dictionary) -> void:
	equipment = value.duplicate(true)
	queue_redraw()


func set_reduced_motion(value: bool) -> void:
	reduced_motion = value
	queue_redraw()


func _process(delta: float) -> void:
	if reduced_motion:
		return
	_phase = fmod(_phase + delta, TAU)
	queue_redraw()


func _draw() -> void:
	var width := size.x
	var height := size.y
	if width < 10.0 or height < 10.0:
		return
	_draw_scene(width, height)
	_draw_aura(width, height)
	_draw_character(width, height)
	_draw_equipment(width, height)
	_draw_activity_prop(width, height)


func _draw_scene(width: float, height: float) -> void:
	var sky_top := Color("#18274c")
	var sky_bottom := Color("#273d68")
	match environment:
		"city":
			sky_top = Color("#202a4a")
			sky_bottom = Color("#68475d")
		"forest":
			sky_top = Color("#143a3a")
			sky_bottom = Color("#2d6255")
		"arena":
			sky_top = Color("#372944")
			sky_bottom = Color("#6a4554")
		"library":
			sky_top = Color("#252440")
			sky_bottom = Color("#514363")
	for index in range(10):
		var ratio := float(index) / 9.0
		var color := sky_top.lerp(sky_bottom, ratio)
		draw_rect(Rect2(0, height * ratio, width, height / 9.0 + 2.0), color)
	if environment == "city":
		var street_y := height * 0.78
		for index in range(6):
			var building_width := width * (0.13 + 0.02 * float(index % 2))
			var building_height := height * (0.19 + 0.035 * float(index % 3))
			var building_x := float(index) * width / 5.0 - building_width * 0.45
			var building_color := Color("#18213b").lerp(Color("#302c4c"), float(index % 3) * 0.18)
			draw_rect(Rect2(building_x, street_y - building_height, building_width, building_height), building_color, true)
			for window_index in range(2):
				var window_x := building_x + 9.0 + window_index * maxf(15.0, building_width * 0.38)
				draw_rect(Rect2(window_x, street_y - building_height + 16.0, 7.0, 11.0), Color(0.96, 0.76, 0.36, 0.48), true)
		for lamp_index in range(3):
			var lamp_x := width * (0.18 + 0.32 * lamp_index)
			draw_line(Vector2(lamp_x, street_y - 50.0), Vector2(lamp_x, street_y), Color("#84715f"), 3.0, true)
			draw_circle(Vector2(lamp_x, street_y - 54.0), 7.0, Color(1.0, 0.78, 0.38, 0.70))

	var arch_color := Color(0.97, 0.86, 0.59, 0.18)
	if environment != "city":
		for index in range(3):
			var cx := width * (0.18 + 0.32 * index)
			draw_arc(Vector2(cx, height * 0.54), width * 0.16, PI, TAU, 28, arch_color, 5.0, true)
			draw_line(Vector2(cx - width * 0.16, height * 0.54), Vector2(cx - width * 0.16, height * 0.84), arch_color, 5.0, true)
			draw_line(Vector2(cx + width * 0.16, height * 0.54), Vector2(cx + width * 0.16, height * 0.84), arch_color, 5.0, true)

	var floor_y := height * 0.86
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, floor_y), Vector2(width, floor_y), Vector2(width, height), Vector2(0, height)
	]), Color("#121a31"))
	for index in range(6):
		var x := float(index) * width / 5.0
		draw_line(Vector2(width * 0.5, floor_y), Vector2(x, height), Color(0.95, 0.78, 0.42, 0.10), 1.5, true)
	draw_line(Vector2(0, floor_y), Vector2(width, floor_y), Color(0.95, 0.78, 0.42, 0.30), 2.0, true)


func _draw_aura(width: float, height: float) -> void:
	var center := Vector2(width * 0.5, height * 0.50)
	var pulse := 0.0 if reduced_motion else sin(_phase * 1.8) * 3.0
	var aura_color := _profile_color()
	var enhancement_level := _max_enhancement_level()
	var aura_layers := 3 + mini(2, enhancement_level / 12)
	for index in range(aura_layers):
		draw_arc(center, 62.0 + index * 14.0 + pulse, -2.7, -0.45, 36, Color(aura_color, 0.20 - index * 0.04), 3.0, true)
		draw_arc(center, 62.0 + index * 14.0 + pulse, 0.45, 2.7, 36, Color(aura_color, 0.20 - index * 0.04), 3.0, true)
	var mote_count := 5 + mini(5, enhancement_level / 5)
	var seed_offset := _seed_fraction(17) * TAU
	for index in range(mote_count):
		var angle := _phase * 0.25 + seed_offset + float(index) * TAU / float(mote_count)
		var radius := 72.0 + float(index % 2) * 12.0
		var point := center + Vector2(cos(angle), sin(angle)) * radius
		var mote_color := RoyalTheme.GOLD_SOFT.lerp(_seed_accent(23 + index), 0.25)
		draw_circle(point, 2.5 + mini(1.5, float(enhancement_level) * 0.04), Color(mote_color, 0.75))


func _draw_character(width: float, height: float) -> void:
	var bob := 0.0 if reduced_motion else sin(_phase * 1.5) * 2.0
	var cx := width * 0.5
	var head_center := Vector2(cx, height * 0.34 + bob)
	var shoulder_y := height * 0.53 + bob
	var foot_y := height * 0.86 + bob
	var skin := Color("#f5c9ad")
	var hair := Color("#30284a")
	var outfit := _profile_color()
	match str(equipment.get("outfit", "")):
		"OUTFIT_FORMAL": outfit = Color("#496aa3")
		"OUTFIT_NOBLE": outfit = Color("#7a5aa6")
		"OUTFIT_ACTIVE": outfit = Color("#3b987f")
		"OUTFIT_STAGE": outfit = Color("#bc5d8f")
	outfit = _enhanced_color(outfit, "outfit", 31)
	var outfit_dark := outfit.darkened(0.28)

	# 뒤쪽 머리카락
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 35, head_center.y - 16), Vector2(cx + 35, head_center.y - 16),
		Vector2(cx + 30, shoulder_y + 31), Vector2(cx + 13, shoulder_y + 18),
		Vector2(cx - 13, shoulder_y + 18), Vector2(cx - 30, shoulder_y + 31)
	]), hair)

	# 다리와 부츠
	draw_rect(Rect2(cx - 25, foot_y - 60, 18, 55), Color("#e8d5c5"), true)
	draw_rect(Rect2(cx + 7, foot_y - 60, 18, 55), Color("#e8d5c5"), true)
	draw_rect(Rect2(cx - 29, foot_y - 18, 24, 18), Color("#252b42"), true)
	draw_rect(Rect2(cx + 5, foot_y - 18, 24, 18), Color("#252b42"), true)

	# 외투와 금색 가장자리
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 37, shoulder_y), Vector2(cx + 37, shoulder_y),
		Vector2(cx + 48, foot_y - 48), Vector2(cx + 18, foot_y - 37),
		Vector2(cx, foot_y - 47), Vector2(cx - 18, foot_y - 37), Vector2(cx - 48, foot_y - 48)
	]), outfit_dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 27, shoulder_y + 1), Vector2(cx + 27, shoulder_y + 1),
		Vector2(cx + 35, foot_y - 44), Vector2(cx, foot_y - 33), Vector2(cx - 35, foot_y - 44)
	]), outfit)
	draw_line(Vector2(cx, shoulder_y + 4), Vector2(cx, foot_y - 37), RoyalTheme.GOLD, 3.0, true)
	draw_line(Vector2(cx - 32, foot_y - 45), Vector2(cx, foot_y - 34), RoyalTheme.GOLD, 2.0, true)
	draw_line(Vector2(cx, foot_y - 34), Vector2(cx + 32, foot_y - 45), RoyalTheme.GOLD, 2.0, true)
	_draw_outfit_pattern(cx, shoulder_y, foot_y, outfit)

	# 팔
	draw_line(Vector2(cx - 29, shoulder_y + 7), Vector2(cx - 46, shoulder_y + 65), outfit_dark, 14.0, true)
	draw_line(Vector2(cx + 29, shoulder_y + 7), Vector2(cx + 46, shoulder_y + 65), outfit_dark, 14.0, true)
	draw_circle(Vector2(cx - 47, shoulder_y + 67), 7.0, skin)
	draw_circle(Vector2(cx + 47, shoulder_y + 67), 7.0, skin)

	# 목과 얼굴
	draw_rect(Rect2(cx - 8, shoulder_y - 11, 16, 21), skin, true)
	draw_circle(head_center, 31.0, skin)
	draw_arc(head_center + Vector2(0, -3), 29.0, PI + 0.05, TAU - 0.05, 24, hair, 13.0, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 30, head_center.y - 13), Vector2(cx - 24, head_center.y - 29),
		Vector2(cx + 25, head_center.y - 28), Vector2(cx + 31, head_center.y - 10),
		Vector2(cx + 8, head_center.y - 18), Vector2(cx - 8, head_center.y - 18)
	]), hair)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 20, head_center.y - 22), Vector2(cx - 4, head_center.y - 24), Vector2(cx - 2, head_center.y - 7)
	]), hair)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 2, head_center.y - 24), Vector2(cx + 16, head_center.y - 22), Vector2(cx + 5, head_center.y - 8)
	]), hair)

	# 표정
	draw_arc(head_center + Vector2(-11, 2), 4.0, PI + 0.15, TAU - 0.15, 8, Color("#23243a"), 2.0, true)
	draw_arc(head_center + Vector2(11, 2), 4.0, PI + 0.15, TAU - 0.15, 8, Color("#23243a"), 2.0, true)
	draw_arc(head_center + Vector2(0, 14), 7.0, 0.25, PI - 0.25, 10, Color("#a45d68"), 1.8, true)
	draw_circle(head_center + Vector2(-22, 12), 4.0, Color(1.0, 0.47, 0.52, 0.18))
	draw_circle(head_center + Vector2(22, 12), 4.0, Color(1.0, 0.47, 0.52, 0.18))

	# 현대적으로 재해석한 왕립 아카데미 배지
	draw_circle(Vector2(cx + 18, shoulder_y + 20), 8.0, RoyalTheme.GOLD)
	draw_circle(Vector2(cx + 18, shoulder_y + 20), 4.0, RoyalTheme.MIDNIGHT)


func _draw_activity_prop(width: float, height: float) -> void:
	var cx := width * 0.5
	var base := Vector2(cx + 52, height * 0.69)
	match profile:
		"martial", "explorer":
			draw_line(base + Vector2(-3, 20), base + Vector2(21, -30), RoyalTheme.GOLD_SOFT, 6.0, true)
			draw_line(base + Vector2(4, 11), base + Vector2(14, 16), RoyalTheme.GOLD, 4.0, true)
			if profile == "explorer":
				draw_arc(base + Vector2(-7, -4), 13.0, -1.8, 1.8, 18, RoyalTheme.MINT, 3.0, true)
		"artist":
			draw_line(base + Vector2(-12, 24), base + Vector2(12, -26), Color("#d8a67d"), 5.0, true)
			draw_colored_polygon(PackedVector2Array([
				base + Vector2(8, -21), base + Vector2(15, -34), base + Vector2(18, -18)
			]), RoyalTheme.CORAL)
		"care":
			draw_circle(base, 22.0, Color(RoyalTheme.MINT, 0.78))
			draw_rect(Rect2(base.x - 4, base.y - 14, 8, 28), RoyalTheme.PARCHMENT, true)
			draw_rect(Rect2(base.x - 14, base.y - 4, 28, 8), RoyalTheme.PARCHMENT, true)
		_:
			draw_colored_polygon(PackedVector2Array([
				base + Vector2(-27, -12), base, base + Vector2(0, 18), base + Vector2(-28, 9)
			]), RoyalTheme.PARCHMENT)
			draw_colored_polygon(PackedVector2Array([
				base, base + Vector2(27, -12), base + Vector2(28, 9), base + Vector2(0, 18)
			]), Color("#f0dfb9"))
			draw_line(base + Vector2(0, -9), base + Vector2(0, 17), RoyalTheme.GOLD, 2.0, true)


func _draw_equipment(width: float, height: float) -> void:
	var cx := width * 0.5
	var bob := 0.0 if reduced_motion else sin(_phase * 1.5) * 2.0
	var head_y := height * 0.34 + bob
	var shoulder_y := height * 0.53 + bob
	var accessory_id := str(equipment.get("accessory", ""))
	if accessory_id == "ACC_RIBBON":
		var ribbon_color := _enhanced_color(RoyalTheme.CORAL, "accessory", 41)
		draw_colored_polygon(PackedVector2Array([
			Vector2(cx + 20, head_y - 27), Vector2(cx + 38, head_y - 38), Vector2(cx + 35, head_y - 18)
		]), ribbon_color)
		draw_colored_polygon(PackedVector2Array([
			Vector2(cx + 20, head_y - 27), Vector2(cx + 43, head_y - 14), Vector2(cx + 30, head_y - 8)
		]), ribbon_color.darkened(0.25))
	elif accessory_id == "ACC_JEWEL":
		draw_circle(Vector2(cx, shoulder_y + 18), 9.0, RoyalTheme.GOLD)
		draw_circle(Vector2(cx, shoulder_y + 18), 5.0, _enhanced_color(RoyalTheme.SKY, "accessory", 43))
	var accessory_level := _enhancement_level("accessory")
	for index in range(mini(3, accessory_level / 8)):
		var sparkle_angle := _seed_fraction(47 + index) * TAU
		var sparkle_center := Vector2(cx, head_y - 22) + Vector2(cos(sparkle_angle), sin(sparkle_angle)) * (30.0 + 5.0 * index)
		draw_circle(sparkle_center, 2.0 + 0.4 * index, Color(_seed_accent(53 + index), 0.9))

	var weapon_id := str(equipment.get("weapon", ""))
	if not weapon_id.is_empty():
		var weapon_color := RoyalTheme.SKY if weapon_id == "WPN_WAND" else RoyalTheme.GOLD_SOFT
		weapon_color = _enhanced_color(weapon_color, "weapon", 59)
		var weapon_width := 5.0 + mini(2.0, float(_enhancement_level("weapon")) * 0.08)
		draw_line(Vector2(cx - 50, shoulder_y + 72), Vector2(cx - 73, shoulder_y + 15), weapon_color, weapon_width, true)
		draw_line(Vector2(cx - 59, shoulder_y + 49), Vector2(cx - 75, shoulder_y + 55), RoyalTheme.GOLD, 3.0, true)
		for index in range(mini(3, _enhancement_level("weapon") / 10)):
			draw_circle(Vector2(cx - 73 + index * 4, shoulder_y + 14 - index * 4), 2.5, Color(_seed_accent(61 + index), 0.85))

	var armor_id := str(equipment.get("armor", ""))
	if not armor_id.is_empty():
		var armor_color := RoyalTheme.SKY if armor_id == "ARM_ROBE" else RoyalTheme.GOLD
		armor_color = _enhanced_color(armor_color, "armor", 67)
		var armor_level := _enhancement_level("armor")
		draw_arc(Vector2(cx, shoulder_y + 20), 31.0, PI + 0.25, TAU - 0.25, 24, Color(armor_color, 0.75), 4.0 + mini(2.0, float(armor_level) * 0.06), true)
		for index in range(mini(4, armor_level / 7)):
			var y := shoulder_y + 5.0 + index * 10.0
			draw_line(Vector2(cx - 20 + index * 2, y), Vector2(cx + 20 - index * 2, y), Color(_seed_accent(71 + index), 0.65), 1.5, true)


func _draw_outfit_pattern(cx: float, shoulder_y: float, foot_y: float, outfit_color: Color) -> void:
	var level := _enhancement_level("outfit")
	if level <= 1:
		return
	var layer_count := mini(4, 1 + level / 8)
	var pattern_color := outfit_color.lerp(_seed_accent(79), 0.65).lightened(0.18)
	var offset := (_seed_fraction(83) - 0.5) * 8.0
	for index in range(layer_count):
		var y := shoulder_y + 34.0 + index * 16.0 + offset
		var half_width := 10.0 + index * 4.0
		draw_line(Vector2(cx - half_width, y), Vector2(cx, y + 5.0), Color(pattern_color, 0.68), 1.6, true)
		draw_line(Vector2(cx, y + 5.0), Vector2(cx + half_width, y), Color(pattern_color, 0.68), 1.6, true)
	if level >= 20:
		draw_circle(Vector2(cx, foot_y - 56.0), 4.0, Color(_seed_accent(89), 0.9))


func _enhancement_level(slot_id: String) -> int:
	var levels: Dictionary = equipment.get("enhancementLevels", {}) as Dictionary
	return maxi(0, int(levels.get(slot_id, 0)))


func _max_enhancement_level() -> int:
	var result := 0
	for slot_id in ["outfit", "weapon", "armor", "accessory"]:
		result = maxi(result, _enhancement_level(slot_id))
	return result


func _seed_fraction(salt: int) -> float:
	var seed_value := int(equipment.get("visualSeed", 1))
	var wave := sin(float(seed_value * 97 + salt * 131) * 0.01745329252) * 43758.5453
	return wave - floor(wave)


func _seed_accent(salt: int) -> Color:
	var palette: Array[Color] = [RoyalTheme.GOLD_SOFT, RoyalTheme.SKY, RoyalTheme.MINT, RoyalTheme.CORAL]
	var index := mini(palette.size() - 1, int(floor(_seed_fraction(salt) * float(palette.size()))))
	return palette[index]


func _enhanced_color(base: Color, slot_id: String, salt: int) -> Color:
	var level := _enhancement_level(slot_id)
	if level <= 1:
		return base
	var blend_amount := minf(0.28, 0.06 + sqrt(float(level - 1)) * 0.025)
	return base.lerp(_seed_accent(salt), blend_amount)


func _profile_color() -> Color:
	match profile:
		"martial": return Color("#dd695f")
		"scholar": return Color("#6d8fd1")
		"artist": return Color("#c977ad")
		"leader": return Color("#a986d7")
		"care": return Color("#64bca3")
		"explorer": return Color("#4ea08e")
		"prosperity": return Color("#d7a941")
		_: return Color("#788fd0")
