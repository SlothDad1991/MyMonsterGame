extends Node2D
## The shared overworld on the client, in Game Boy style: 16 px tiles, the
## classic text boxes and menus, gen-1 style battles, trading and spectating.

const BattleView := preload("res://scripts/BattleView.gd")
const TILE := 16
enum T { GRASS, TALL, TREE, WATER, PATH, HEAL, SAND, FLOWER } # same order as GameData.T
const MOVE_TIME := 0.22
const DIRS := [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]
const PLAYER_COLORS := [Color("#d04040"), Color("#3b6fd0"), Color("#2f9e44"), Color("#e0a020"),
	Color("#9050c0"), Color("#e070a0"), Color("#20a8a8"), Color("#8a5a3c")]
# tile colours, picked so they also read well as 4 Game Boy shades
const COL := {
	"ground": Color("#e0f0c0"), "ground_dot": Color("#98c078"),
	"tall": Color("#88c868"), "tall_dark": Color("#3c7830"), "tall_light": Color("#c8e8a0"),
	"tree": Color("#3a8a42"), "tree_dark": Color("#1c4424"), "tree_light": Color("#78c070"),
	"trunk": Color("#6b4a2b"), "water": Color("#5898e0"), "water_light": Color("#d0e8ff"),
	"path": Color("#f0e4c0"), "path_dot": Color("#c8b488"), "sand": Color("#f4e8b0"),
	"heal": Color("#f08ab0"), "ink": Color("#181818"), "white": Color("#f8f8f8"),
}

var my_id := 0
var my_name := ""
var my_pos := Vector2i.ZERO
var my_draw := Vector2.ZERO
var my_dir := 0
var my_status := "free"
var my_color := 0
var move_from := Vector2.ZERO
var move_t := 0.0
var bump_t := 0.0
var step_parity := false
var anim_t := 0.0
var follower_draw := Vector2.ZERO

var players := {} # id -> {name, pos, draw, dir, status, color, lead, step_t}
var wilds := {}   # id -> {species, pos, draw, level, in_battle, flip}
var party: Array = []

var cam: Camera2D
var ui: Control
var stack: Array = [] # open menus, top last
var toast_box: PanelContainer
var toast_label: Label
var toast_queue: Array = []
var toast_t := 0.0
var menu_btn: PanelContainer
var touch_layer: CanvasLayer

var battle_panel: Control
var battle_view
var battle_text: GbTextBox
var cmd_box: PanelContainer
var move_box: PanelContainer
var move_info: Label
var info_box: PanelContainer
var flash: ColorRect
var battle_state := {}
var trade_panel: PanelContainer
var trade_state := {}


func setup(me: Dictionary) -> void:
	my_id = int(me.id)
	my_name = me.name
	my_pos = Vector2i(int(me.x), int(me.y))
	my_draw = _center(my_pos)
	follower_draw = my_draw
	party = me.party
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	cam = Camera2D.new()
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = GameData.MAP_W * TILE
	cam.limit_bottom = GameData.MAP_H * TILE
	add_child(cam)
	cam.make_current()

	_setup_keys()
	_build_ui()
	Net.world_updated.connect(_on_world)
	Net.battle_updated.connect(_on_battle)
	Net.request_received.connect(_on_request)
	Net.trade_updated.connect(_on_trade)
	Net.trade_closed.connect(_on_trade_closed)
	Net.party_updated.connect(_on_party)
	Net.teleported.connect(_on_teleport)
	Net.toast.connect(show_toast)
	if me.get("returning", false):
		show_toast("Welcome back, %s!" % my_name)
	else:
		show_toast("Welcome, %s! Wild monsters live in the tall grass." % my_name)


func _center(p: Vector2i) -> Vector2:
	return Vector2(p.x * TILE + TILE / 2.0, p.y * TILE + TILE / 2.0)


static func _setup_keys() -> void:
	# keyboard: arrows/WASD move, Z/Enter = A, X/Backspace = B, Tab/M = menu
	var extra := {
		"ui_up": [KEY_W], "ui_down": [KEY_S], "ui_left": [KEY_A], "ui_right": [KEY_D],
		"ui_accept": [KEY_Z], "ui_cancel": [KEY_X, KEY_BACKSPACE],
	}
	for act in extra:
		for k in extra[act]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			if not InputMap.action_has_event(act, ev):
				InputMap.action_add_event(act, ev)
	if not InputMap.has_action("game_menu"):
		InputMap.add_action("game_menu")
		for k in [KEY_TAB, KEY_M, KEY_ESCAPE]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event("game_menu", ev)


# ---------------------------------------------------------------- update loop

func _process(delta: float) -> void:
	anim_t += delta
	bump_t = max(0.0, bump_t - delta)

	var want := _input_dir()
	if move_t > 0.0:
		move_t = max(0.0, move_t - delta)
		my_draw = move_from.lerp(_center(my_pos), 1.0 - move_t / MOVE_TIME)
	else:
		my_draw = _center(my_pos)
		if want != Vector2i.ZERO and _can_move():
			if bump_t <= 0.0:
				_try_move(want)
			else:
				my_dir = DIRS.find(want)

	var speed := TILE / MOVE_TIME
	for p in players.values():
		var target := _center(p.pos)
		if p.draw.distance_to(target) > TILE * 3:
			p.draw = target
		elif p.draw != target:
			p.draw = p.draw.move_toward(target, speed * delta)
			p.step_t += delta
	for w in wilds.values():
		var target := _center(w.pos)
		if w.draw.distance_to(target) > TILE * 3:
			w.draw = target
		else:
			w.draw = w.draw.move_toward(target, speed * 0.6 * delta)

	var behind := my_draw - Vector2(DIRS[my_dir]) * TILE
	follower_draw = follower_draw.lerp(behind, clampf(delta * 6.0, 0.0, 1.0))

	cam.position = my_draw.round()
	_update_toast(delta)
	touch_layer.visible = not _menu_open()
	menu_btn.visible = not (battle_panel.visible or trade_panel.visible)
	queue_redraw()


func _input_dir() -> Vector2i:
	if Input.is_action_pressed("ui_up"):
		return Vector2i.UP
	if Input.is_action_pressed("ui_down"):
		return Vector2i.DOWN
	if Input.is_action_pressed("ui_left"):
		return Vector2i.LEFT
	if Input.is_action_pressed("ui_right"):
		return Vector2i.RIGHT
	return Vector2i.ZERO


func _menu_open() -> bool:
	return not stack.is_empty() or battle_panel.visible or trade_panel.visible


func _can_move() -> bool:
	return my_status == "free" and not _menu_open()


func _wild_at(p: Vector2i) -> Dictionary:
	for w in wilds.values():
		if w.pos == p:
			return w
	return {}


func _player_at(p: Vector2i) -> int:
	for id in players:
		if players[id].pos == p:
			return id
	return -1


func _try_move(d: Vector2i) -> void:
	my_dir = DIRS.find(d)
	var target := my_pos + d
	var w := _wild_at(target)
	if not w.is_empty():
		Net.to_server("c_move", [target.x, target.y, my_dir]) # the server starts the battle
		bump_t = 0.5
		return
	if not GameData.walkable(target):
		bump_t = 0.15
		return
	move_from = my_draw
	my_pos = target
	move_t = MOVE_TIME
	step_parity = not step_parity
	Net.to_server("c_move", [target.x, target.y, my_dir])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_back()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("game_menu"):
		if stack.is_empty() and not battle_panel.visible and not trade_panel.visible:
			open_start_menu()
		else:
			_back()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		if battle_panel.visible and battle_text.is_busy():
			battle_text.advance()
		elif not _menu_open():
			_interact()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _menu_open():
			return
		var wp := get_global_mouse_position()
		if wp.distance_to(my_draw) < TILE * 0.8:
			open_party("world")
			return
		var best := -1
		var best_d := TILE * 1.0
		for id in players:
			var dist: float = wp.distance_to(players[id].draw)
			if dist < best_d:
				best_d = dist
				best = id
		if best != -1:
			_open_player_menu(best)


func _interact() -> void:
	## A button in the world: talk to whoever you're facing
	var front: Vector2i = my_pos + DIRS[my_dir]
	var pid := _player_at(front)
	if pid != -1:
		_open_player_menu(pid)
	elif GameData.tile_at(front) == GameData.T.HEAL:
		show_toast("Step on the pad to heal your monsters.")


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	var vp := get_viewport_rect().size
	var tl := cam.get_screen_center_position() - vp / 2.0
	var x0 := clampi(int(floor(tl.x / TILE)) - 1, 0, GameData.MAP_W - 1)
	var y0 := clampi(int(floor(tl.y / TILE)) - 1, 0, GameData.MAP_H - 1)
	var x1 := clampi(int(ceil((tl.x + vp.x) / TILE)) + 1, 0, GameData.MAP_W - 1)
	var y1 := clampi(int(ceil((tl.y + vp.y) / TILE)) + 1, 0, GameData.MAP_H - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_draw_tile(x, y, GameData.map[y][x])

	var ents := []
	for w in wilds.values():
		ents.append({"y": w.draw.y, "kind": "wild", "d": w})
	for id in players:
		ents.append({"y": players[id].draw.y, "kind": "player", "d": players[id]})
	ents.append({"y": my_draw.y + 0.1, "kind": "me"})
	if party.size() > 0:
		ents.append({"y": follower_draw.y, "kind": "follower"})
	ents.sort_custom(func(a, b): return a.y < b.y)
	for e in ents:
		match e.kind:
			"wild": _draw_wild(e.d)
			"player":
				var moving: bool = e.d.draw != _center(e.d.pos)
				var frame := 0
				if moving:
					frame = 1 if fmod(e.d.step_t, MOVE_TIME * 2) < MOVE_TIME else 2
				_draw_trainer(e.d.draw, e.d.dir, e.d.color, frame)
			"me":
				var frame := 0
				if move_t > MOVE_TIME * 0.3:
					frame = 1 if step_parity else 2
				_draw_trainer(my_draw, my_dir, my_color, frame)
			"follower":
				GameData.draw_monster(self, party[0].species, follower_draw.round() + Vector2(0, 1), 13, my_dir == 2, 0.0)
	# tall grass hides feet, like the originals
	for e in ents:
		var pos: Vector2 = my_draw if e.kind == "me" else (follower_draw if e.kind == "follower" else e.d.draw)
		var tp := Vector2i(floor(pos.x / TILE), floor(pos.y / TILE))
		if GameData.tile_at(tp) == GameData.T.TALL:
			_draw_tall_front(tp)
	# name tags and status on top
	for id in players:
		var p: Dictionary = players[id]
		var tag: String = p.name
		match p.status:
			"battle": tag += " !"
			"trade": tag += " $"
			"watching": tag += " ?"
		_name_tag(p.draw + Vector2(0, -15), tag)


func _draw_tile(x: int, y: int, t: int) -> void:
	var o := Vector2(x * TILE, y * TILE)
	var h := (x * 73856093) ^ (y * 19349663)
	var n := absi(h) % 7
	match t:
		T.GRASS:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.ground)
			if n < 3:
				draw_rect(Rect2(o + Vector2(3 + n * 3, 4), Vector2(1, 2)), COL.ground_dot)
				draw_rect(Rect2(o + Vector2(5 + n * 3, 3), Vector2(1, 2)), COL.ground_dot)
			if n == 4:
				draw_rect(Rect2(o + Vector2(10, 10), Vector2(1, 2)), COL.ground_dot)
				draw_rect(Rect2(o + Vector2(12, 9), Vector2(1, 2)), COL.ground_dot)
		T.TALL:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.tall)
			for q in [Vector2(0, 0), Vector2(8, 0), Vector2(0, 8), Vector2(8, 8)]:
				_tuft(o + q)
		T.TREE:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.ground)
			draw_rect(Rect2(o + Vector2(6, 11), Vector2(4, 5)), COL.ink)
			draw_rect(Rect2(o + Vector2(7, 11), Vector2(2, 4)), COL.trunk)
			draw_rect(Rect2(o + Vector2(2, 0), Vector2(12, 12)), COL.ink)
			draw_rect(Rect2(o + Vector2(1, 2), Vector2(14, 8)), COL.ink)
			draw_rect(Rect2(o + Vector2(3, 1), Vector2(10, 10)), COL.tree)
			draw_rect(Rect2(o + Vector2(2, 3), Vector2(12, 6)), COL.tree)
			draw_rect(Rect2(o + Vector2(4, 2), Vector2(4, 2)), COL.tree_light)
			draw_rect(Rect2(o + Vector2(3, 4), Vector2(2, 2)), COL.tree_light)
			draw_rect(Rect2(o + Vector2(9, 7), Vector2(3, 2)), COL.tree_dark)
			draw_rect(Rect2(o + Vector2(5, 9), Vector2(3, 1)), COL.tree_dark)
		T.WATER:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.water)
			var shift := int(anim_t * 2.0) % 2 * 2
			draw_rect(Rect2(o + Vector2(2 + shift, 4), Vector2(5, 1)), COL.water_light)
			draw_rect(Rect2(o + Vector2(9 - shift, 11), Vector2(5, 1)), COL.water_light)
		T.PATH:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.path)
			if n < 2:
				draw_rect(Rect2(o + Vector2(4 + n * 6, 6 + n * 4), Vector2(1, 1)), COL.path_dot)
				draw_rect(Rect2(o + Vector2(11 - n * 5, 12 - n * 6), Vector2(1, 1)), COL.path_dot)
		T.SAND:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.sand)
			draw_rect(Rect2(o + Vector2(3 + n, 5), Vector2(1, 1)), COL.path_dot)
		T.FLOWER:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.ground)
			var open := int(anim_t * 1.6 + x) % 2 == 0 # flowers sway, like the originals
			for c: Vector2 in [Vector2(4, 4), Vector2(11, 10)]:
				var p := o + c
				if open:
					draw_rect(Rect2(p + Vector2(-1, 0), Vector2(3, 1)), COL.heal)
					draw_rect(Rect2(p + Vector2(0, -1), Vector2(1, 3)), COL.heal)
				else:
					draw_rect(Rect2(p + Vector2(-1, -1), Vector2(3, 3)), COL.heal)
				draw_rect(Rect2(p, Vector2(1, 1)), Color("#f8e040"))
		T.HEAL:
			draw_rect(Rect2(o, Vector2(16, 16)), COL.path)
			draw_rect(Rect2(o + Vector2(1, 1), Vector2(14, 14)), COL.ink)
			var pulse := int(anim_t * 2.0) % 2 == 0
			draw_rect(Rect2(o + Vector2(2, 2), Vector2(12, 12)), COL.heal if pulse else COL.heal.lightened(0.25))
			draw_rect(Rect2(o + Vector2(7, 4), Vector2(2, 8)), COL.white)
			draw_rect(Rect2(o + Vector2(4, 7), Vector2(8, 2)), COL.white)


func _tuft(o: Vector2) -> void:
	draw_rect(Rect2(o + Vector2(1, 2), Vector2(1, 3)), COL.tall_dark)
	draw_rect(Rect2(o + Vector2(2, 4), Vector2(1, 2)), COL.tall_dark)
	draw_rect(Rect2(o + Vector2(3, 5), Vector2(2, 1)), COL.tall_dark)
	draw_rect(Rect2(o + Vector2(5, 4), Vector2(1, 2)), COL.tall_dark)
	draw_rect(Rect2(o + Vector2(6, 2), Vector2(1, 3)), COL.tall_dark)
	draw_rect(Rect2(o + Vector2(3, 2), Vector2(2, 2)), COL.tall_light)


func _draw_tall_front(tp: Vector2i) -> void:
	var o := Vector2(tp.x * TILE, tp.y * TILE + 10)
	draw_rect(Rect2(o, Vector2(16, 6)), COL.tall)
	_tuft(o + Vector2(0, -2))
	_tuft(o + Vector2(8, -2))


func _draw_trainer(pos: Vector2, dir: int, color_idx: int, frame: int) -> void:
	var col: Color = PLAYER_COLORS[color_idx % PLAYER_COLORS.size()]
	var res: Array = Sprites.trainer(col, dir, frame)
	var tl := (pos - Vector2(8, 12)).round()
	if res[1]:
		draw_set_transform(tl + Vector2(16, 0), 0.0, Vector2(-1, 1))
		draw_texture(res[0], Vector2.ZERO)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_texture(res[0], tl)


func _draw_wild(w: Dictionary) -> void:
	var hop := 0.0
	if w.draw != _center(w.pos):
		hop = -1.0
	GameData.draw_monster(self, w.species, w.draw.round() + Vector2(0, -1 + hop), 15, w.flip, 0.0)
	if w.in_battle:
		_name_tag(w.draw + Vector2(0, -13), "!")


func _name_tag(pos: Vector2, s: String) -> void:
	var w := Gb.font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
	var r := Rect2((pos - Vector2(w / 2.0 + 2, 5)).round(), Vector2(w + 4, 10))
	draw_rect(r, Gb.C3)
	draw_rect(r.grow(-1), Gb.C0)
	Gb.text(self, r.position + Vector2(2, 1), s)


# ---------------------------------------------------------------- network events

func _on_world(plist: Array, wlist: Array) -> void:
	var seen := {}
	for e in plist:
		var id := int(e[0])
		if id == my_id:
			my_status = e[5]
			my_color = int(e[6])
			continue
		seen[id] = true
		var pos := Vector2i(int(e[2]), int(e[3]))
		if not players.has(id):
			players[id] = {"draw": _center(pos), "step_t": 0.0}
		var p: Dictionary = players[id]
		p.name = e[1]
		p.pos = pos
		p.dir = int(e[4])
		p.status = e[5]
		p.color = int(e[6])
		p.lead = e[7]
	for id in players.keys():
		if not seen.has(id):
			players.erase(id)

	var wseen := {}
	for e in wlist:
		var id: String = e[0]
		wseen[id] = true
		var pos := Vector2i(int(e[2]), int(e[3]))
		if not wilds.has(id):
			wilds[id] = {"draw": _center(pos), "flip": false}
		var w: Dictionary = wilds[id]
		if w.has("pos") and pos.x != w.pos.x:
			w.flip = pos.x < w.pos.x
		w.species = e[1]
		w.pos = pos
		w.level = int(e[4])
		w.in_battle = e[5]
	for id in wilds.keys():
		if not wseen.has(id):
			wilds.erase(id)


func _on_teleport(pos: Vector2i) -> void:
	my_pos = pos
	my_draw = _center(pos)
	move_t = 0.0


func _on_party(new_party: Array) -> void:
	party = new_party
	var top = stack.back() if not stack.is_empty() else null
	if top != null and top.get_meta("kind", "") == "party" and top.get_meta("mode", "") == "world":
		_pop()
		open_party("world")


func _on_request(kind: String, from_id: int, from_name: String) -> void:
	var text := "%s wants to battle!" % from_name if kind == "battle" else "%s wants to trade." % from_name
	_prompt(text, [
		["YES", func(): Net.to_server("c_respond", [kind, from_id, true])],
		["NO", func(): Net.to_server("c_respond", [kind, from_id, false])],
	])


# ---------------------------------------------------------------- UI basics

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = Gb.theme()
	layer.add_child(ui)

	menu_btn = Gb.box()
	menu_btn.add_theme_stylebox_override("panel", Gb.box_style(3, 2))
	menu_btn.add_child(GbButton.new("MENU", open_start_menu))
	menu_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	menu_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	menu_btn.offset_right = -2
	menu_btn.offset_top = 2
	ui.add_child(menu_btn)

	toast_box = Gb.box()
	toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_box.offset_top = 2
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.visible = false
	toast_label = Label.new()
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.custom_minimum_size = Vector2(150, 0)
	toast_box.add_child(toast_label)
	ui.add_child(toast_box)

	_build_battle_panel()

	trade_panel = Gb.box()
	trade_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	trade_panel.visible = false
	ui.add_child(trade_panel)

	touch_layer = CanvasLayer.new()
	touch_layer.layer = 11
	add_child(touch_layer)
	var keys := {
		"up": [Vector2(0, -18), "ui_up"], "down": [Vector2(0, 18), "ui_down"],
		"left": [Vector2(-18, 0), "ui_left"], "right": [Vector2(18, 0), "ui_right"],
	}
	for g in keys:
		var k := TouchKey.new(g, keys[g][1], Vector2(17, 17))
		k.set_meta("pad_offset", keys[g][0])
		k.set_meta("corner", "left")
		touch_layer.add_child(k)
	var a := TouchKey.new("A", "ui_accept", Vector2(22, 22), true)
	a.set_meta("pad_offset", Vector2(-18, -30))
	a.set_meta("corner", "right")
	touch_layer.add_child(a)
	var b := TouchKey.new("B", "ui_cancel", Vector2(22, 22), true)
	b.set_meta("pad_offset", Vector2(-44, -18))
	b.set_meta("corner", "right")
	touch_layer.add_child(b)
	get_viewport().size_changed.connect(_place_touch_keys)
	_place_touch_keys()


func _place_touch_keys() -> void:
	var vs := get_viewport().get_visible_rect().size
	for k in touch_layer.get_children():
		var off: Vector2 = k.get_meta("pad_offset")
		if k.get_meta("corner") == "left":
			k.position = Vector2(30, vs.y - 30) + off
		else:
			k.position = Vector2(vs.x, vs.y) + off


func show_toast(msg: String) -> void:
	toast_queue.append(msg)


func _update_toast(delta: float) -> void:
	if toast_t > 0.0:
		toast_t -= delta
		if toast_t <= 0.0:
			toast_box.visible = false
	elif not toast_queue.is_empty():
		toast_label.text = toast_queue.pop_front()
		toast_box.visible = true
		toast_box.reset_size()
		toast_t = 2.6


## Adds a menu on top of the stack and focuses its first item.
func _push(c: Control, closable := true) -> void:
	c.set_meta("closable", closable)
	ui.add_child(c)
	stack.append(c)
	_focus_first(c)


func _pop() -> void:
	if stack.is_empty():
		return
	var c: Control = stack.pop_back()
	c.queue_free()
	if not stack.is_empty():
		_focus_first(stack.back())
	elif battle_panel.visible:
		_focus_first(cmd_box if cmd_box.visible else move_box)


func _close_menus() -> void:
	while not stack.is_empty():
		var c: Control = stack.pop_back()
		c.queue_free()


func _back() -> void:
	## B button
	if not stack.is_empty():
		if stack.back().get_meta("closable", true):
			_pop()
	elif battle_panel.visible:
		if move_box.visible:
			move_box.visible = false
			info_box.visible = false
			_refresh_commands()
		elif battle_text.is_busy():
			battle_text.advance()


func _focus_first(c: Control) -> void:
	if c == null or not is_instance_valid(c):
		return
	var b := _find_button(c)
	if b:
		_grab.call_deferred(b)


func _grab(b: Control) -> void:
	if is_instance_valid(b) and b.is_inside_tree() and b.is_visible_in_tree():
		b.grab_focus()


func _find_button(n: Node) -> Button:
	for ch in n.get_children():
		if ch is Button and ch.visible and not ch.disabled:
			return ch
		var found := _find_button(ch)
		if found:
			return found
	return null


## Bottom text box with a choice box above its right end, like YES/NO in the originals.
func _prompt(text: String, options: Array, closable := true) -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var tb := GbTextBox.new()
	tb.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	tb.offset_top = -46
	tb.show_text(text)
	root.add_child(tb)
	var choice := Gb.box()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	choice.add_child(v)
	for o in options:
		v.add_child(GbButton.new(o[0], _prompt_pick.bind(root, o[1])))
	choice.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	choice.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	choice.grow_vertical = Control.GROW_DIRECTION_BEGIN
	choice.offset_bottom = -44
	choice.offset_right = 0
	root.add_child(choice)
	_push(root, closable)


func _prompt_pick(root: Control, cb: Callable) -> void:
	if not stack.is_empty() and stack.back() == root:
		_pop()
	cb.call()


func _list_menu(title: String, options: Array, kind := "list") -> void:
	## a box on the right side, like the START menu
	var box := Gb.box()
	box.set_meta("kind", kind)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	box.add_child(v)
	if title != "":
		var l := Gb.label(title)
		v.add_child(l)
	for o in options:
		var b := GbButton.new(o[0], o[1])
		if o.size() > 2 and o[2]:
			b.selected_mark = true
		v.add_child(b)
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.offset_top = 2
	box.offset_right = -2
	_push(box)


# ---------------------------------------------------------------- start menu

func open_start_menu() -> void:
	if not stack.is_empty() or battle_panel.visible or trade_panel.visible:
		return
	_list_menu("", [
		["MONSTERS", func(): open_party("world")],
		["PLAYERS", _open_players],
		["COLOURS", _open_colours],
		["EXIT", _pop],
	], "start")


func _open_players() -> void:
	var opts := []
	for id in players:
		var p: Dictionary = players[id]
		var tag := ""
		match p.status:
			"battle": tag = " !"
			"trade": tag = " $"
		opts.append([p.name.to_upper() + tag, _open_player_menu.bind(id)])
	if opts.is_empty():
		show_toast("Nobody else is online yet.")
		return
	opts.append(["CANCEL", _pop])
	_list_menu("ONLINE: %d" % (players.size() + 1), opts)


func _open_colours() -> void:
	var opts := []
	for pn in Gb.PALETTE_ORDER:
		opts.append([pn.to_upper(), _pick_colour.bind(pn), pn == Palette.current])
	opts.append(["CANCEL", _pop])
	_list_menu("COLOURS", opts, "colours")


func _pick_colour(pn: String) -> void:
	Palette.apply(pn)
	_pop()
	_open_colours()


func _open_player_menu(id: int) -> void:
	if not players.has(id):
		return
	var p: Dictionary = players[id]
	var opts := []
	if p.status == "free" and my_status == "free":
		opts.append(["BATTLE", func(): Net.to_server("c_request", ["battle", id])])
		opts.append(["TRADE", func(): Net.to_server("c_request", ["trade", id])])
	if (p.status == "battle" or p.status == "trade") and my_status == "free":
		opts.append(["WATCH", func(): Net.to_server("c_watch", [id])])
	opts.append(["CANCEL", func(): pass])
	var what := ""
	match p.status:
		"battle": what = " is battling."
		"trade": what = " is trading."
		_:
			what = "."
	_close_menus()
	_prompt("It's %s%s" % [p.name, what], opts)


# ---------------------------------------------------------------- party screen

class PartyRow extends GbButton:
	var mon := {}

	func _init(m: Dictionary, cb: Callable) -> void:
		super("", cb)
		mon = m
		custom_minimum_size = Vector2(0, 18)

	func _draw() -> void:
		super()
		var w := size.x
		GameData.draw_monster(self, mon.species, Vector2(16, 9), 14, false, 0.0)
		Gb.text(self, Vector2(28, 1), GameData.monsters[mon.species].name.to_upper())
		Gb.text(self, Vector2(w - 40, 1), ":L%d" % int(mon.level))
		var ratio := float(mon.hp) / float(mon.max_hp)
		Gb.hp_bar(self, Vector2(28, 10), 48, ratio)
		Gb.text_right(self, w - 2, 10, "%d/%d" % [int(mon.hp), int(mon.max_hp)])
		if int(mon.hp) <= 0:
			Gb.text(self, Vector2(w - 92, 1), "FNT", Gb.C2)


## mode: "world" (set lead), "switch" (battle), "forced" (must pick after a faint)
func open_party(mode: String) -> void:
	var src: Array = party
	if mode != "world" and not battle_state.is_empty() and battle_state.you >= 0:
		src = battle_state.sides[battle_state.you].party
	var box := Gb.box()
	box.set_meta("kind", "party")
	box.set_meta("mode", mode)
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	box.add_child(v)
	var title := "Bring out which MONSTER?" if mode != "world" else "MONSTERS"
	v.add_child(Gb.label(title))
	for i in src.size():
		v.add_child(PartyRow.new(src[i], _party_pick.bind(mode, i)))
	if mode != "forced":
		v.add_child(GbButton.new("CANCEL", _pop))
	_push(box, mode != "forced")


func _party_pick(mode: String, i: int) -> void:
	var src: Array = party
	if mode != "world":
		src = battle_state.sides[battle_state.you].party
	var m: Dictionary = src[i]
	var nm: String = GameData.monsters[m.species].name.to_upper()
	if mode == "world":
		var moves := []
		for mid in m.moves:
			moves.append(GameData.moves[mid].name.to_upper())
		var info := "%s :L%d %s\n%s" % [nm, int(m.level), "/".join(GameData.monsters[m.species].types).to_upper(), ", ".join(moves)]
		var opts := []
		if i > 0 and my_status == "free":
			opts.append(["LEAD", func(): Net.to_server("c_set_lead", [i])])
		opts.append(["CANCEL", func(): pass])
		_prompt(info, opts)
		return
	var side: Dictionary = battle_state.sides[battle_state.you]
	if int(m.hp) <= 0:
		show_toast("%s has fainted!" % nm)
		return
	if i == side.active and mode == "switch":
		show_toast("%s is already out!" % nm)
		return
	_close_menus()
	_act("switch", i)


# ---------------------------------------------------------------- battle

func _build_battle_panel() -> void:
	battle_panel = Control.new()
	battle_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle_panel.visible = false
	ui.add_child(battle_panel)

	battle_view = BattleView.new()
	battle_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle_view.offset_bottom = -46
	battle_panel.add_child(battle_view)

	battle_text = GbTextBox.new()
	battle_text.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	battle_text.offset_top = -46
	battle_text.finished.connect(_refresh_commands)
	battle_panel.add_child(battle_text)

	cmd_box = Gb.box()
	cmd_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	cmd_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	cmd_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	cmd_box.custom_minimum_size = Vector2(116, 46)
	cmd_box.visible = false
	battle_panel.add_child(cmd_box)

	move_box = Gb.box()
	move_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	move_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	move_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	move_box.custom_minimum_size = Vector2(150, 46)
	move_box.visible = false
	battle_panel.add_child(move_box)

	info_box = Gb.box()
	info_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	info_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	info_box.offset_bottom = -44
	info_box.custom_minimum_size = Vector2(92, 0)
	info_box.visible = false
	move_info = Label.new()
	info_box.add_child(move_info)
	battle_panel.add_child(info_box)

	flash = ColorRect.new()
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.color = Gb.C3
	flash.visible = false
	battle_panel.add_child(flash)


func _on_battle(state: Dictionary) -> void:
	var fresh: bool = battle_state.get("id", "") != state.id or not battle_panel.visible
	battle_state = state
	_close_menus()
	trade_panel.visible = false
	if fresh:
		battle_panel.visible = true
		battle_view.set_state(state, true)
		battle_text.clear()
		_hide_commands()
		_play_flash()
		var lines: Array = state.log
		if int(state.you) == -1:
			lines = lines.slice(max(0, lines.size() - 2)) # joined as a spectator
		battle_text.say(lines)
	else:
		battle_view.set_state(state)
		battle_text.say(state.new)
	if not battle_text.is_busy():
		_refresh_commands()


func _play_flash() -> void:
	## the classic encounter flash
	flash.visible = true
	var tw := flash.create_tween()
	for i in 3:
		tw.tween_callback(func(): flash.color = Gb.C3)
		tw.tween_interval(0.07)
		tw.tween_callback(func(): flash.color = Gb.C0)
		tw.tween_interval(0.07)
	tw.tween_callback(func(): flash.visible = false)


func _hide_commands() -> void:
	cmd_box.visible = false
	move_box.visible = false
	info_box.visible = false


func _refresh_commands() -> void:
	_hide_commands()
	if not battle_panel.visible or battle_state.is_empty() or battle_text.is_busy():
		return
	var s := battle_state
	var you: int = s.you
	if s.over:
		battle_text.show_text(s.result)
		_fill(cmd_box, [["OK", _close_battle]], 1)
		return
	if you == -1:
		battle_text.show_text("Watching %s\nvs %s." % [s.sides[0].name, s.sides[1].name])
		_fill(cmd_box, [["STOP", _stop_watching_battle]], 1)
		return
	var me: Dictionary = s.sides[you]
	var foe: Dictionary = s.sides[1 - you]
	if me.must_switch:
		if stack.is_empty():
			open_party("forced")
		return
	if foe.must_switch or me.ready:
		battle_text.show_text("Waiting for\n%s..." % foe.name)
		return
	var active: Dictionary = me.party[me.active]
	battle_text.show_text("What will\n%s do?" % GameData.monsters[active.species].name.to_upper())
	var opts := [["FIGHT", _open_moves], ["MON", func(): open_party("switch")]]
	if s.kind == "wild":
		opts.append(["CATCH", _act.bind("catch", 0)])
		opts.append(["RUN", _act.bind("run", 0)])
	else:
		opts.append(["GIVE UP", _act.bind("forfeit", 0)])
	_fill(cmd_box, opts, 2)


func _fill(box: PanelContainer, opts: Array, columns: int) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", 2)
	g.add_theme_constant_override("v_separation", 1)
	box.add_child(g)
	var first: Button = null
	for o in opts:
		var b := GbButton.new(o[0], o[1])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(b)
		if first == null:
			first = b
	box.visible = true
	if first and stack.is_empty():
		_grab.call_deferred(first)


func _open_moves() -> void:
	var me: Dictionary = battle_state.sides[battle_state.you]
	var active: Dictionary = me.party[me.active]
	cmd_box.visible = false
	battle_text.show_text("")
	var opts := []
	for i in active.moves.size():
		opts.append([GameData.moves[active.moves[i]].name.to_upper(), _act.bind("move", i)])
	_fill(move_box, opts, 1)
	var grid: GridContainer = move_box.get_child(0)
	for i in grid.get_child_count():
		grid.get_child(i).focus_entered.connect(_show_move_info.bind(active.moves[i]))
	info_box.visible = true
	_show_move_info(active.moves[0])


func _show_move_info(move_id: String) -> void:
	var mv: Dictionary = GameData.moves[move_id]
	move_info.text = "TYPE/\n %s\nPOWER %d" % [mv.type.to_upper(), int(mv.power)]


func _act(kind: String, index: int) -> void:
	# hide the menus first: when we are the host, the server answers instantly
	# (inside to_server) and that answer must not be hidden afterwards
	_hide_commands()
	battle_text.show_text("")
	Net.to_server("c_battle_action", [kind, index])


func battle_ui_ready() -> bool:
	## for the self-test: is the player able to act (or close) right now?
	return cmd_box.visible or move_box.visible or (not stack.is_empty() and stack.back().get_meta("kind", "") == "party")


func _stop_watching_battle() -> void:
	Net.to_server("c_stop_watching")
	_close_battle()


func _close_battle() -> void:
	_close_menus()
	battle_panel.visible = false
	battle_state = {}


# ---------------------------------------------------------------- trade

func _on_trade(state: Dictionary) -> void:
	trade_state = state
	_close_menus()
	for c in trade_panel.get_children():
		trade_panel.remove_child(c)
		c.queue_free()
	var you: int = state.you
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	trade_panel.add_child(v)
	if you == -1:
		v.add_child(Gb.label("%s <> %s" % [state.sides[0].name.to_upper(), state.sides[1].name.to_upper()]))
	else:
		v.add_child(Gb.label("TRADE WITH %s" % state.sides[1 - you].name.to_upper()))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 8)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(cols)
	var order := [0, 1] if you != 1 else [1, 0]
	for idx in order:
		var side: Dictionary = state.sides[idx]
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 1)
		var head: String = "YOURS" if idx == you else str(side.name).to_upper()
		if side.confirmed:
			head += " OK!"
		col.add_child(Gb.label(head))
		var offered_uid: String = side.offer.get("uid", "")
		for m in side.party:
			var line := "%s:L%d" % [GameData.monsters[m.species].name.to_upper(), int(m.level)]
			if idx == you:
				var b := GbButton.new(line, func(): Net.to_server("c_trade_offer", [m.uid]))
				b.selected_mark = m.uid == offered_uid
				col.add_child(b)
			else:
				var l := Gb.label(("> " if m.uid == offered_uid else "  ") + line, 8)
				l.custom_minimum_size.y = 12
				l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				if m.uid != offered_uid:
					l.add_theme_color_override("font_color", Gb.C2)
				col.add_child(l)
		cols.add_child(col)

	var a: Dictionary = state.sides[order[0]].offer
	var b2: Dictionary = state.sides[order[1]].offer
	var a_name: String = GameData.monsters[a.species].name.to_upper() if not a.is_empty() else "?"
	var b_name: String = GameData.monsters[b2.species].name.to_upper() if not b2.is_empty() else "?"
	v.add_child(Gb.label("%s <> %s" % [a_name, b_name]))
	var row := HBoxContainer.new()
	v.add_child(row)
	if you == -1:
		row.add_child(GbButton.new("STOP WATCHING", _stop_watching_trade))
	else:
		var both: bool = not a.is_empty() and not b2.is_empty()
		var ok := GbButton.new("CONFIRM", func(): Net.to_server("c_trade_confirm"))
		ok.disabled = not both or state.sides[you].confirmed
		row.add_child(ok)
		row.add_child(GbButton.new("CANCEL", func(): Net.to_server("c_trade_cancel")))
	trade_panel.visible = true
	_focus_first(trade_panel)


func _stop_watching_trade() -> void:
	Net.to_server("c_stop_watching")
	trade_panel.visible = false


func _on_trade_closed() -> void:
	trade_panel.visible = false
	trade_state = {}
