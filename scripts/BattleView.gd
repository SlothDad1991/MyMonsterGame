extends Control
## Draws the battle scene: two monsters with name plates and HP bars.

var state := {}
var _t := 0.0
var _shown_hp := {} # uid -> displayed hp (animates down)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_state(s: Dictionary) -> void:
	state = s
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _side_order() -> Array:
	# returns [near_side_index, far_side_index]
	var you: int = state.get("you", -1)
	if you == 1:
		return [1, 0]
	return [0, 1]


func _draw() -> void:
	var w := size.x
	var h := size.y
	# sky + ground
	draw_rect(Rect2(0, 0, w, h * 0.55), Color("#bfe3f2"))
	draw_rect(Rect2(0, h * 0.55, w, h * 0.45), Color("#9fd27a"))
	if state.is_empty():
		return
	var order := _side_order()
	var near: Dictionary = state.sides[order[0]]
	var far: Dictionary = state.sides[order[1]]
	var s: float = min(w * 0.3, h * 0.55)

	var far_pos := Vector2(w * 0.72, h * 0.38)
	var near_pos := Vector2(w * 0.28, h * 0.72)
	draw_colored_polygon(GameData._ellipse(far_pos + Vector2(0, s * 0.4), Vector2(s * 0.55, s * 0.13)), Color("#7fb25e"))
	draw_colored_polygon(GameData._ellipse(near_pos + Vector2(0, s * 0.4), Vector2(s * 0.6, s * 0.14)), Color("#7fb25e"))

	_draw_side(far, far_pos, s * 0.85, true, Vector2(w * 0.04, h * 0.06))
	_draw_side(near, near_pos, s, false, Vector2(w * 0.56, h * 0.68))


func _draw_side(side: Dictionary, pos: Vector2, s: float, is_far: bool, plate_pos: Vector2) -> void:
	var mon: Dictionary = side.party[side.active]
	var font := ThemeDB.fallback_font
	var bob := sin(_t * 2.5 + (1.0 if is_far else 0.0)) * s * 0.015
	if mon.hp > 0:
		GameData.draw_monster(self, mon.species, pos, s, is_far, bob)
	else:
		GameData.draw_monster(self, mon.species, pos + Vector2(0, s * 0.25), s * 0.6, is_far, 0.0)

	# animate hp bar
	var uid: String = mon.uid
	var target := float(mon.hp)
	var cur: float = _shown_hp.get(uid, target)
	cur = move_toward(cur, target, max(1.0, mon.max_hp * 0.02))
	_shown_hp[uid] = cur

	var pw: float = min(size.x * 0.4, 380.0)
	var plate := Rect2(plate_pos, Vector2(pw, 78))
	draw_rect(plate, Color(1, 1, 1, 0.92))
	draw_rect(plate, Color("#333"), false, 2.0)
	var title := "%s  Lv%d" % [GameData.monsters[mon.species].name, mon.level]
	draw_string(font, plate_pos + Vector2(12, 28), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color("#222"))
	draw_string(font, plate_pos + Vector2(12, 28), side.name, HORIZONTAL_ALIGNMENT_RIGHT, pw - 24, 14, Color("#666"))
	# show the types
	var types: Array = GameData.monsters[mon.species].types
	draw_string(font, plate_pos + Vector2(12, 46), " / ".join(types), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#555"))
	var bar := Rect2(plate_pos + Vector2(12, 54), Vector2(pw - 24, 12))
	draw_rect(bar, Color("#444"))
	var ratio := clampf(cur / float(mon.max_hp), 0.0, 1.0)
	var col := Color("#4cd964") if ratio > 0.5 else (Color("#ffcc00") if ratio > 0.2 else Color("#ff3b30"))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), col)
	draw_string(font, plate_pos + Vector2(12, 46), "%d / %d" % [int(round(cur)), mon.max_hp], HORIZONTAL_ALIGNMENT_RIGHT, pw - 24, 14, Color("#333"))
	# party balls
	for i in side.party.size():
		var alive: bool = side.party[i].hp > 0
		draw_circle(plate_pos + Vector2(14 + i * 16, 90), 6, Color("#e04848") if alive else Color("#999"))
