class_name TouchKey
extends TouchScreenButton
## On-screen key for phones (multi-touch). Only shows on touch screens.
## It presses a normal input action, so menus and movement treat it like a keyboard key.

var glyph := ""
var key_size := Vector2(16, 16)
var round_key := false


func _init(g: String, act: String, sz: Vector2, is_round := false) -> void:
	glyph = g
	action = act
	key_size = sz
	round_key = is_round
	visibility_mode = TouchScreenButton.VISIBILITY_TOUCHSCREEN_ONLY
	passby_press = not is_round # slide your thumb across the d-pad
	var sh := RectangleShape2D.new()
	sh.size = sz + Vector2(4, 4) # a little extra so it's easy to hit
	shape = sh
	shape_centered = false # the key is drawn centred on its position
	pressed.connect(queue_redraw)
	released.connect(queue_redraw)


func _draw() -> void:
	var down := is_pressed()
	var col := Gb.C3 if down else Gb.C2
	col.a = 0.75 if down else 0.45
	draw_set_transform(-key_size / 2.0)
	var r := Rect2(Vector2.ZERO, key_size)
	if round_key:
		draw_circle(key_size / 2.0, key_size.x / 2.0, col)
	else:
		draw_rect(r, col)
	var txt_col := Gb.C0
	txt_col.a = 0.9
	match glyph:
		"up": _tri(Vector2(key_size.x / 2, 5), Vector2(0, 1))
		"down": _tri(Vector2(key_size.x / 2, key_size.y - 5), Vector2(0, -1))
		"left": _tri(Vector2(5, key_size.y / 2), Vector2(1, 0))
		"right": _tri(Vector2(key_size.x - 5, key_size.y / 2), Vector2(-1, 0))
		_:
			var w := Gb.font().get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
			Gb.text(self, Vector2(round((key_size.x - w) / 2), round((key_size.y - 8) / 2)), glyph, txt_col)


func _tri(tip: Vector2, back: Vector2) -> void:
	var c := Gb.C0
	c.a = 0.9
	var side := Vector2(back.y, back.x)
	draw_colored_polygon(PackedVector2Array([tip, tip + back * 4 + side * 4, tip + back * 4 - side * 4]), c)
