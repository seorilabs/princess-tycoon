extends Control

const RoyalTheme = preload("res://src/ui/royal_theme.gd")

var value := 0.0:
	set(next_value):
		value = clampf(next_value, 0.0, 100.0)
		queue_redraw()


func _ready() -> void:
	custom_minimum_size = Vector2(44.0, 44.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := maxf(8.0, minf(size.x, size.y) * 0.5 - 5.0)
	draw_arc(center, radius, 0.0, TAU, 40, Color(RoyalTheme.NAVY_RAISED, 0.95), 5.0, true)
	var ratio := clampf(value / 100.0, 0.0, 1.0)
	if ratio > 0.0:
		var end_angle := -PI * 0.5 + TAU * ratio
		draw_arc(center, radius, -PI * 0.5, end_angle, maxi(3, int(40.0 * ratio)), RoyalTheme.CORAL, 5.0, true)
		var endpoint := center + Vector2(cos(end_angle), sin(end_angle)) * radius
		draw_circle(endpoint, 3.0, RoyalTheme.GOLD_SOFT)
	draw_circle(center, 3.0, RoyalTheme.GOLD)
