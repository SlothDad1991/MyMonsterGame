extends Control
## Gen-1 style battle scene (top part of the screen): foe top-right with its
## info top-left, your monster bottom-left with its info on the right.

var state := {}
var intro := 0.0 # 0..1 slide-in when a battle starts
var _t := 0.0
var _shown_hp := {} # uid -> displayed hp (drains smoothly)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_state(s: Dictionary, fresh := false) -> void:
	state = s
	if fresh:
		intro = 0.0
		_shown_hp.clear()


func _process(delta: float) -> void:
	_t += delta
	intro = minf(1.0, intro + delta * 2.0)
	queue_redraw()


func _order() -> Array:
	return [1, 0] if int(state.get("you", -1)) == 1 else [0, 1]


func _hp_of(mon: Dictionary) -> float:
	var uid: String = mon.uid
	var target := float(mon.hp)
	var cur: float = _shown_hp.get(uid, target)
	cur = move_toward(cur, target, maxf(0.25, mon.max_hp * 0.012))
	_shown_hp[uid] = cur
	return cur


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Gb.C0)
	if state.is_empty():
		return
	var o := _order()
	var near: Dictionary = state.sides[o[0]]
	var far: Dictionary = state.sides[o[1]]
	var w := size.x
	var slide := (1.0 - intro) * w * 0.6

	# --- foe (top right sprite, info top left)
	var fm: Dictionary = far.party[far.active]
	var fpos := Vector2(round(w - 52 + slide), 26)
	if fm.hp > 0:
		GameData.draw_monster(self, fm.species, fpos, 44, true, 0.0)
	var fname: String = GameData.monsters[fm.species].name.to_upper()
	Gb.text(self, Vector2(8, 4), fname)
	Gb.text(self, Vector2(24, 13), ":L%d" % int(fm.level))
	Gb.hp_bar(self, Vector2(16, 22), 64, _hp_of(fm) / float(fm.max_hp))
	# bracket under the foe's info
	draw_rect(Rect2(8, 22, 1, 10), Gb.C3)
	draw_rect(Rect2(8, 31, 100, 1), Gb.C3)
	_party_dots(far, Vector2(16, 34))

	# --- you (bottom left sprite, info right)
	var nm: Dictionary = near.party[near.active]
	var npos := Vector2(round(52 - slide), 68)
	if nm.hp > 0:
		GameData.draw_monster(self, nm.species, npos, 56, false, 0.0)
	var info_x := w - 120
	var nname: String = GameData.monsters[nm.species].name.to_upper()
	Gb.text(self, Vector2(info_x, 52), nname)
	Gb.text(self, Vector2(info_x + 48, 60), ":L%d" % int(nm.level))
	var hp := _hp_of(nm)
	Gb.hp_bar(self, Vector2(info_x + 8, 68), 64, hp / float(nm.max_hp))
	Gb.text_right(self, w - 16, 77, "%3d/%3d" % [int(round(hp)), int(nm.max_hp)])
	# bracket to the right of your info
	draw_rect(Rect2(w - 9, 66, 1, 20), Gb.C3)
	draw_rect(Rect2(info_x, 86, w - 8 - info_x, 1), Gb.C3)
	_party_dots(near, Vector2(info_x + 8, 89))


func _party_dots(side: Dictionary, pos: Vector2) -> void:
	## one ball per party member: filled = can still fight
	for i in side.party.size():
		var alive: bool = side.party[i].hp > 0
		var p := pos + Vector2(i * 8, 0)
		draw_rect(Rect2(p + Vector2(1, 0), Vector2(4, 6)), Gb.C3)
		draw_rect(Rect2(p + Vector2(0, 1), Vector2(6, 4)), Gb.C3)
		if alive:
			draw_rect(Rect2(p + Vector2(1, 1), Vector2(4, 2)), Color("#d1372a"))
			draw_rect(Rect2(p + Vector2(1, 3), Vector2(4, 2)), Gb.C0)
		else:
			draw_rect(Rect2(p + Vector2(1, 1), Vector2(4, 4)), Gb.C1)
