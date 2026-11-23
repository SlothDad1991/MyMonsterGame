extends Node2D
## The shared overworld on the client: draws the map, players and wild monsters,
## handles movement and all in-game menus (party, battle, trade, requests).

const MonsterView := preload("res://scripts/MonsterView.gd")
const BattleView := preload("res://scripts/BattleView.gd")
const TILE := 32
enum T { GRASS, TALL, TREE, WATER, PATH, HEAL, SAND, FLOWER } # same order as GameData.T
const MOVE_TIME := 0.16
const PLAYER_COLORS := [Color("#e04848"), Color("#3b7de0"), Color("#3fbf5f"), Color("#f0b23a"),
	Color("#9b59d0"), Color("#ff7fb0"), Color("#2bc4c4"), Color("#8a5a3c")]
const TYPE_COLORS := {"Normal": Color("#b8b08d"), "Fire": Color("#f08030"), "Water": Color("#6890f0"),
	"Grass": Color("#78c850"), "Electric": Color("#f8d030"), "Rock": Color("#b8a038"),
	"Flying": Color("#a890f0"), "Bug": Color("#a8b820")}
const DIRS := [Vector2i.DOWN, Vector2i.UP, Vector2i.LEFT, Vector2i.RIGHT]

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
var pad_dir := Vector2i.ZERO
var anim_t := 0.0
var follower_draw := Vector2.ZERO

var players := {} # id -> {name, pos, draw, dir, status, color, lead}
var wilds := {}   # id -> {species, pos, draw, level, in_battle, flip}
var party: Array = []

var cam: Camera2D
var ui: Control
var toast_box: VBoxContainer
var info_label: Label
var popup: Control
var party_panel: PanelContainer
var party_wrap: Control
var trade_wrap: Control
var battle_panel: Control
var battle_view # BattleView
var battle_log: RichTextLabel
var battle_actions: VBoxContainer
var battle_state := {}
var battle_submenu := ""
var trade_panel: PanelContainer
var trade_state := {}
var dpad: Control


func setup(me: Dictionary) -> void:
	my_id = int(me.id)
	my_name = me.name
	my_pos = Vector2i(int(me.x), int(me.y))
	my_draw = _center(my_pos)
	follower_draw = my_draw
	party = me.party

	cam = Camera2D.new()
	cam.zoom = Vector2(2, 2)
	cam.position_smoothing_enabled = false
	add_child(cam)
	cam.make_current()

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
		show_toast("Welcome, %s! Walk into wild monsters in the tall grass to battle." % my_name)


func _center(p: Vector2i) -> Vector2:
	return Vector2(p.x * TILE + TILE / 2.0, p.y * TILE + TILE / 2.0)


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
		if want != Vector2i.ZERO and _can_move() and bump_t <= 0.0:
			_try_move(want)

	var speed := TILE / MOVE_TIME * 1.15
	for p in players.values():
		var target := _center(p.pos)
		if p.draw.distance_to(target) > TILE * 3:
			p.draw = target
		else:
			p.draw = p.draw.move_toward(target, speed * delta)
	for w in wilds.values():
		var target := _center(w.pos)
		if w.draw.distance_to(target) > TILE * 3:
			w.draw = target
		else:
			w.draw = w.draw.move_toward(target, speed * 0.6 * delta)

	# lead monster follows one step behind
	var behind := my_draw - Vector2(DIRS[my_dir]) * TILE * 0.9
	follower_draw = follower_draw.lerp(behind, clampf(delta * 8.0, 0.0, 1.0))

	cam.position = my_draw
	queue_redraw()


func _input_dir() -> Vector2i:
	if pad_dir != Vector2i.ZERO:
		return pad_dir
	if Input.is_action_pressed("ui_up") or Input.is_physical_key_pressed(KEY_W):
		return Vector2i.UP
	if Input.is_action_pressed("ui_down") or Input.is_physical_key_pressed(KEY_S):
		return Vector2i.DOWN
	if Input.is_action_pressed("ui_left") or Input.is_physical_key_pressed(KEY_A):
		return Vector2i.LEFT
	if Input.is_action_pressed("ui_right") or Input.is_physical_key_pressed(KEY_D):
		return Vector2i.RIGHT
	return Vector2i.ZERO


func _can_move() -> bool:
	if my_status != "free":
		return false
	return not (battle_panel.visible or trade_wrap.visible or party_wrap.visible or popup != null)


func _wild_at(p: Vector2i) -> Dictionary:
	for w in wilds.values():
		if w.pos == p:
			return w
	return {}


func _try_move(d: Vector2i) -> void:
	my_dir = DIRS.find(d)
	var target := my_pos + d
	var w := _wild_at(target)
	if not w.is_empty():
		# bumping a wild monster: the server starts the battle
		Net.to_server("c_move", [target.x, target.y, my_dir])
		bump_t = 0.5
		return
	if not GameData.walkable(target):
		bump_t = 0.12
		return
	move_from = my_draw
	my_pos = target
	move_t = MOVE_TIME
	Net.to_server("c_move", [target.x, target.y, my_dir])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if battle_panel.visible or trade_wrap.visible or party_wrap.visible or popup != null:
			return
		var wp := get_global_mouse_position()
		if wp.distance_to(my_draw) < TILE * 0.7:
			open_party()
			return
		var best := -1
		var best_d := TILE * 0.9
		for id in players:
			var dist: float = wp.distance_to(players[id].draw)
			if dist < best_d:
				best_d = dist
				best = id
		if best != -1:
			_open_player_menu(best)


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	var vp := get_viewport_rect().size / cam.zoom
	var tl := cam.position - vp / 2.0
	var x0 := clampi(int(floor(tl.x / TILE)) - 1, 0, GameData.MAP_W - 1)
	var y0 := clampi(int(floor(tl.y / TILE)) - 1, 0, GameData.MAP_H - 1)
	var x1 := clampi(int(ceil((tl.x + vp.x) / TILE)) + 1, 0, GameData.MAP_W - 1)
	var y1 := clampi(int(ceil((tl.y + vp.y) / TILE)) + 1, 0, GameData.MAP_H - 1)
	# outside the map
	draw_rect(Rect2(tl - Vector2(TILE, TILE), vp + Vector2(TILE, TILE) * 2), Color("#1f4a1f"))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_draw_tile(x, y, GameData.map[y][x])

	# entities sorted by y so nearer things overlap farther ones
	var ents := []
	for w in wilds.values():
		ents.append({"y": w.draw.y, "kind": "wild", "d": w})
	for id in players:
		ents.append({"y": players[id].draw.y, "kind": "player", "d": players[id]})
	ents.append({"y": my_draw.y, "kind": "me"})
	if party.size() > 0:
		ents.append({"y": follower_draw.y, "kind": "follower"})
	ents.sort_custom(func(a, b): return a.y < b.y)
	for e in ents:
		match e.kind:
			"wild": _draw_wild(e.d)
			"player": _draw_player(e.d.draw, e.d.dir, e.d.color, e.d.name, e.d.status)
			"me": _draw_player(my_draw, my_dir, my_color, my_name, my_status, true)
			"follower": GameData.draw_monster(self, party[0].species, follower_draw, TILE * 0.7, my_dir == 2, sin(anim_t * 6.0) * 1.0)


func _draw_tile(x: int, y: int, t: int) -> void:
	var r := Rect2(x * TILE, y * TILE, TILE, TILE)
	var base: Color = GameData.TILE_COLORS[t]
	if t == T.TREE:
		base = GameData.TILE_COLORS[T.GRASS]
	draw_rect(r, base)
	var h := float((x * 73856093) ^ (y * 19349663)) # stable per-tile noise
	var n := absf(fmod(h, 97.0)) / 97.0
	match t:
		T.GRASS:
			if n > 0.7:
				draw_rect(Rect2(r.position + Vector2(6 + n * 14, 8 + n * 10), Vector2(2, 3)), base.darkened(0.15))
		T.TALL:
			var sway := sin(anim_t * 2.0 + x * 0.7 + y * 0.3) * 1.5
			for i in 3:
				var bx := r.position.x + 5 + i * 10
				var by := r.position.y + TILE - 4
				draw_colored_polygon(PackedVector2Array([Vector2(bx, by), Vector2(bx + 8, by),
					Vector2(bx + 4 + sway, by - 16 - n * 6)]), base.lightened(0.18 if i == 1 else 0.05))
		T.TREE:
			draw_rect(Rect2(r.position + Vector2(13, 18), Vector2(6, 12)), Color("#6b4a2b"))
			draw_circle(r.position + Vector2(16, 13), 13, GameData.TILE_COLORS[T.TREE])
			draw_circle(r.position + Vector2(12, 10), 6, GameData.TILE_COLORS[T.TREE].lightened(0.15))
		T.WATER:
			var off := sin(anim_t * 1.5 + x + y * 0.5) * 3
			draw_line(r.position + Vector2(5 + off, 12), r.position + Vector2(15 + off, 12), base.lightened(0.3), 2)
			draw_line(r.position + Vector2(16 - off, 24), r.position + Vector2(26 - off, 24), base.lightened(0.3), 2)
		T.FLOWER:
			var fc: Color = [Color("#ffffff"), Color("#ffd23f"), Color("#ff6f91")][int(n * 3) % 3]
			draw_circle(r.position + Vector2(10, 12), 3, fc)
			draw_circle(r.position + Vector2(21, 20), 3, fc)
		T.PATH:
			if n > 0.6:
				draw_circle(r.position + Vector2(8 + n * 16, 10 + n * 12), 1.5, base.darkened(0.15))
		T.HEAL:
			draw_rect(r, Color("#d8c08a"))
			var pulse := 0.85 + sin(anim_t * 3.0) * 0.15
			draw_rect(r.grow(-3), base * Color(pulse, pulse, pulse))
			draw_rect(Rect2(r.position + Vector2(13, 7), Vector2(6, 18)), Color.WHITE)
			draw_rect(Rect2(r.position + Vector2(7, 13), Vector2(18, 6)), Color.WHITE)


func _draw_wild(w: Dictionary) -> void:
	var bob := sin(anim_t * 5.0 + w.draw.x * 0.1) * 1.5
	GameData.draw_monster(self, w.species, w.draw + Vector2(0, -4), TILE * 0.95, w.flip, bob)
	if w.in_battle:
		_badge(w.draw + Vector2(0, -26), "!", Color("#e04848"))


func _draw_player(pos: Vector2, dir: int, color_idx: int, pname: String, status: String, is_me := false) -> void:
	var col: Color = PLAYER_COLORS[color_idx % PLAYER_COLORS.size()]
	var font := ThemeDB.fallback_font
	var step := 0.0
	if is_me and move_t > 0.0:
		step = sin(move_t / MOVE_TIME * PI) * 2.0
	draw_colored_polygon(GameData._ellipse(pos + Vector2(0, 12), Vector2(9, 3)), Color(0, 0, 0, 0.25))
	# body, head, hat
	draw_rect(Rect2(pos + Vector2(-7, -2 - step), Vector2(14, 13)), col)
	draw_rect(Rect2(pos + Vector2(-6, 10 - step), Vector2(5, 3)), Color("#333"))
	draw_rect(Rect2(pos + Vector2(1, 10 - step), Vector2(5, 3)), Color("#333"))
	draw_circle(pos + Vector2(0, -8 - step), 7, Color("#f6d2b0"))
	draw_rect(Rect2(pos + Vector2(-8, -16 - step), Vector2(16, 6)), col.darkened(0.2))
	# eyes show facing
	if dir != 1:
		var ex := 0.0
		if dir == 2: ex = -3.0
		elif dir == 3: ex = 3.0
		draw_rect(Rect2(pos + Vector2(-3 + ex, -9 - step), Vector2(2, 2)), Color("#222"))
		draw_rect(Rect2(pos + Vector2(2 + ex, -9 - step), Vector2(2, 2)), Color("#222"))
	# name
	var label_pos := pos + Vector2(0, -22)
	draw_string_outline(font, label_pos - Vector2(60, 0), pname, HORIZONTAL_ALIGNMENT_CENTER, 120, 9, 3, Color(0, 0, 0, 0.8))
	draw_string(font, label_pos - Vector2(60, 0), pname, HORIZONTAL_ALIGNMENT_CENTER, 120, 9, Color("#fff27a") if is_me else Color.WHITE)
	match status:
		"battle": _badge(pos + Vector2(0, -34), "VS", Color("#e04848"))
		"trade": _badge(pos + Vector2(0, -34), "TRADE", Color("#3b7de0"))
		"watching": _badge(pos + Vector2(0, -34), "WATCHING", Color("#777"))


func _badge(pos: Vector2, text: String, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x + 8
	var r := Rect2(pos - Vector2(w / 2.0, 7), Vector2(w, 11))
	draw_rect(r, col)
	draw_string(font, r.position + Vector2(4, 8.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color.WHITE)


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
			players[id] = {"draw": _center(pos)}
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
	info_label.text = "%s   •   Online: %d" % [my_name, plist.size()]

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
	if party_wrap.visible:
		open_party()


func _on_request(kind: String, from_id: int, from_name: String) -> void:
	var text := "%s wants to battle you!" % from_name if kind == "battle" else "%s wants to trade with you." % from_name
	_show_popup(text, [
		["Accept", func(): Net.to_server("c_respond", [kind, from_id, true])],
		["No thanks", func(): Net.to_server("c_respond", [kind, from_id, false])],
	])


# ---------------------------------------------------------------- UI building

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = (get_parent() as Control).theme
	layer.add_child(ui)

	var top := HBoxContainer.new()
	top.position = Vector2(12, 12)
	top.add_theme_constant_override("separation", 12)
	ui.add_child(top)
	var party_b := Button.new()
	party_b.text = "Party"
	party_b.custom_minimum_size = Vector2(110, 52)
	party_b.pressed.connect(open_party)
	top.add_child(party_b)
	info_label = Label.new()
	info_label.add_theme_color_override("font_outline_color", Color.BLACK)
	info_label.add_theme_constant_override("outline_size", 6)
	top.add_child(info_label)

	toast_box = VBoxContainer.new()
	toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_box.position.y = 80
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ui.add_child(toast_box)

	_build_dpad()

	var pm := _make_modal()
	party_wrap = pm[0]
	party_panel = pm[1]
	ui.add_child(party_wrap)

	_build_battle_panel()

	var tm := _make_modal()
	trade_wrap = tm[0]
	trade_panel = tm[1]
	ui.add_child(trade_wrap)


func _build_dpad() -> void:
	dpad = Control.new()
	dpad.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	dpad.offset_left = 30
	dpad.offset_top = -250
	dpad.offset_right = 250
	dpad.offset_bottom = -30
	dpad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(dpad)
	var sz := 72.0
	var layout := {Vector2i.UP: Vector2(1, 0), Vector2i.DOWN: Vector2(1, 2),
		Vector2i.LEFT: Vector2(0, 1), Vector2i.RIGHT: Vector2(2, 1)}
	var arrows := {Vector2i.UP: "▲", Vector2i.DOWN: "▼", Vector2i.LEFT: "◀", Vector2i.RIGHT: "▶"}
	for d in layout:
		var b := Button.new()
		b.text = arrows[d]
		b.position = layout[d] * sz
		b.size = Vector2(sz - 6, sz - 6)
		b.modulate = Color(1, 1, 1, 0.75)
		b.focus_mode = Control.FOCUS_NONE
		b.button_down.connect(_pad_down.bind(d))
		b.button_up.connect(_pad_up.bind(d))
		dpad.add_child(b)
	dpad.visible = DisplayServer.is_touchscreen_available() or OS.has_feature("web") or OS.has_feature("mobile")


func _pad_down(d: Vector2i) -> void:
	pad_dir = d


func _pad_up(d: Vector2i) -> void:
	if pad_dir == d:
		pad_dir = Vector2i.ZERO


## A dimmed full-screen backdrop with a centred panel. Returns [backdrop, panel].
func _make_modal() -> Array:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.35)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.visible = false
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(cc)
	var panel := PanelContainer.new()
	cc.add_child(panel)
	return [backdrop, panel]


func _center_panel(p: Control, min_size: Vector2) -> void:
	p.custom_minimum_size = min_size


func _clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


func _button(text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 52)
	b.pressed.connect(cb)
	return b


func show_toast(msg: String) -> void:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = msg
	l.add_theme_font_size_override("font_size", 18)
	p.add_child(l)
	toast_box.add_child(p)
	ui.move_child(toast_box, -1) # keep toasts above any open menu
	var tw := p.create_tween()
	tw.tween_interval(3.5)
	tw.tween_property(p, "modulate:a", 0.0, 0.6)
	tw.tween_callback(p.queue_free)
	while toast_box.get_child_count() > 4:
		var old := toast_box.get_child(0)
		toast_box.remove_child(old)
		old.queue_free()


func _show_popup(text: String, buttons: Array) -> void:
	_close_popup()
	var m := _make_modal()
	var p: PanelContainer = m[1]
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	p.add_child(v)
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	for entry in buttons:
		var cb: Callable = entry[1]
		v.add_child(_button(entry[0], _popup_pressed.bind(cb)))
	ui.add_child(m[0])
	m[0].visible = true
	popup = m[0]
	_center_panel(p, Vector2(420, 0))


func _popup_pressed(cb: Callable) -> void:
	_close_popup()
	cb.call()


func _close_popup() -> void:
	if popup != null:
		popup.queue_free()
		popup = null


func _open_player_menu(id: int) -> void:
	var p: Dictionary = players[id]
	var buttons := []
	if p.status == "free" and my_status == "free":
		buttons.append(["Battle", func(): Net.to_server("c_request", ["battle", id])])
		buttons.append(["Trade", func(): Net.to_server("c_request", ["trade", id])])
	if (p.status == "battle" or p.status == "trade") and my_status == "free":
		buttons.append(["Watch", func(): Net.to_server("c_watch", [id])])
	buttons.append(["Close", func(): pass])
	var lead := ""
	if p.get("lead", "") != "" and GameData.monsters.has(p.lead):
		lead = "\nLead: " + GameData.monsters[p.lead].name
	_show_popup("%s%s" % [p.name, lead], buttons)


# ---------------------------------------------------------------- party

func _mon_line(m: Dictionary) -> String:
	return "%s  Lv%d\nHP %d/%d" % [GameData.monsters[m.species].name, int(m.level), int(m.hp), int(m.max_hp)]


func open_party() -> void:
	_clear(party_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	party_panel.add_child(v)
	var title := Label.new()
	title.text = "Your party"
	title.add_theme_font_size_override("font_size", 28)
	v.add_child(title)
	for i in party.size():
		var m: Dictionary = party[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(MonsterView.new(m.species, 64))
		var l := Label.new()
		var move_names := []
		for mid in m.moves:
			move_names.append(GameData.moves[mid].name)
		l.text = _mon_line(m) + "   " + "/".join(GameData.monsters[m.species].types) + "\n" + ", ".join(move_names)
		l.add_theme_font_size_override("font_size", 17)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if int(m.hp) <= 0:
			l.modulate = Color(1, 0.6, 0.6)
		row.add_child(l)
		if i > 0 and my_status == "free":
			row.add_child(_button("Make lead", func(): Net.to_server("c_set_lead", [i])))
		v.add_child(row)
	var hint := Label.new()
	hint.text = "Heal on the pink pad in town."
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.add_theme_font_size_override("font_size", 16)
	v.add_child(hint)
	v.add_child(_button("Close", func(): party_wrap.visible = false))
	party_wrap.visible = true
	_center_panel(party_panel, Vector2(620, 0))


# ---------------------------------------------------------------- battle

func _build_battle_panel() -> void:
	battle_panel = ColorRect.new()
	(battle_panel as ColorRect).color = Color("#101521")
	battle_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle_panel.visible = false
	ui.add_child(battle_panel)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)
	battle_panel.add_child(v)

	battle_view = BattleView.new()
	battle_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_view.size_flags_stretch_ratio = 1.6
	v.add_child(battle_view)

	var bottom := HBoxContainer.new()
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom.add_theme_constant_override("separation", 10)
	v.add_child(bottom)

	battle_log = RichTextLabel.new()
	battle_log.scroll_following = true
	battle_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	battle_log.add_theme_font_size_override("normal_font_size", 18)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	margin.add_child(battle_log)
	bottom.add_child(margin)

	var right := MarginContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		right.add_theme_constant_override("margin_" + side, 10)
	bottom.add_child(right)
	battle_actions = VBoxContainer.new()
	battle_actions.add_theme_constant_override("separation", 8)
	right.add_child(battle_actions)


func _on_battle(state: Dictionary) -> void:
	var fresh: bool = battle_state.get("id", "") != state.id or not battle_panel.visible
	battle_state = state
	_close_popup()
	party_wrap.visible = false
	battle_panel.visible = true
	battle_view.set_state(state)
	if fresh:
		battle_submenu = ""
		battle_log.clear()
		for line in state.log:
			battle_log.append_text(line + "\n")
	else:
		for line in state.new:
			battle_log.append_text(line + "\n")
	_rebuild_battle_actions()


func _rebuild_battle_actions() -> void:
	_clear(battle_actions)
	var s := battle_state
	var you: int = s.you
	if s.over:
		_battle_label(s.result)
		battle_actions.add_child(_button("Continue", _close_battle))
		return
	if you == -1:
		_battle_label("Watching %s vs %s" % [s.sides[0].name, s.sides[1].name])
		battle_actions.add_child(_button("Stop watching", _stop_watching_battle))
		return
	var me: Dictionary = s.sides[you]
	var foe: Dictionary = s.sides[1 - you]
	if me.must_switch:
		_battle_label("Choose your next monster:")
		_party_buttons(me, false)
		return
	if foe.must_switch:
		_battle_label("Waiting for %s to choose..." % foe.name)
		return
	if me.ready:
		_battle_label("Waiting for %s..." % foe.name)
		return
	if battle_submenu == "switch":
		_battle_label("Switch to:")
		_party_buttons(me, true)
		battle_actions.add_child(_button("Back", _back_to_moves))
		return

	var active: Dictionary = me.party[me.active]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	battle_actions.add_child(grid)
	for i in active.moves.size():
		var mv: Dictionary = GameData.moves[active.moves[i]]
		var b := _button("%s\n%s · %d" % [mv.name, mv.type, int(mv.power)],
			func(): _act("move", i))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 18)
		var tc: Color = TYPE_COLORS.get(mv.type, Color("#3b4a6b"))
		for st in ["normal", "hover", "pressed"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = tc.darkened(0.25) if st == "normal" else (tc if st == "hover" else tc.lightened(0.2))
			sb.set_corner_radius_all(10)
			sb.set_content_margin_all(10)
			b.add_theme_stylebox_override(st, sb)
		grid.add_child(b)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	battle_actions.add_child(row)
	var extra := [["Switch", _open_switch_menu]]
	if s.kind == "wild":
		extra.append(["Catch", _act.bind("catch", 0)])
		extra.append(["Run", _act.bind("run", 0)])
	else:
		extra.append(["Forfeit", _act.bind("forfeit", 0)])
	for e in extra:
		var b := _button(e[0], e[1])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)


func _open_switch_menu() -> void:
	battle_submenu = "switch"
	_rebuild_battle_actions()


func _back_to_moves() -> void:
	battle_submenu = ""
	_rebuild_battle_actions()


func _stop_watching_battle() -> void:
	Net.to_server("c_stop_watching")
	_close_battle()


func _stop_watching_trade() -> void:
	Net.to_server("c_stop_watching")
	trade_wrap.visible = false


func _battle_label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	battle_actions.add_child(l)


func _party_buttons(side: Dictionary, skip_active: bool) -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	battle_actions.add_child(grid)
	for i in side.party.size():
		var m: Dictionary = side.party[i]
		if int(m.hp) <= 0 or (skip_active and i == side.active):
			continue
		var b := _button(_mon_line(m), func(): _act("switch", i))
		b.add_theme_font_size_override("font_size", 16)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(b)


func _act(kind: String, index: int) -> void:
	battle_submenu = ""
	Net.to_server("c_battle_action", [kind, index])
	_clear(battle_actions)
	_battle_label("...")


func _close_battle() -> void:
	battle_panel.visible = false
	battle_state = {}


# ---------------------------------------------------------------- trade

func _on_trade(state: Dictionary) -> void:
	trade_state = state
	_close_popup()
	party_wrap.visible = false
	_clear(trade_panel)
	var you: int = state.you
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	trade_panel.add_child(v)

	var title := Label.new()
	if you == -1:
		title.text = "Watching: %s ⇄ %s" % [state.sides[0].name, state.sides[1].name]
	else:
		title.text = "Trading with %s" % state.sides[1 - you].name
	title.add_theme_font_size_override("font_size", 26)
	v.add_child(title)

	var offers := HBoxContainer.new()
	offers.add_theme_constant_override("separation", 30)
	offers.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(offers)
	for side in state.sides:
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(200, 0)
		var n := Label.new()
		n.text = side.name + ("  ✓ ready" if side.confirmed else "")
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(n)
		if side.offer.is_empty():
			var l := Label.new()
			l.text = "(choosing...)"
			l.modulate = Color(1, 1, 1, 0.5)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.custom_minimum_size = Vector2(0, 110)
			col.add_child(l)
		else:
			var mv := MonsterView.new(side.offer.species, 96)
			mv.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			col.add_child(mv)
			var l := Label.new()
			l.text = _mon_line(side.offer)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.add_theme_font_size_override("font_size", 16)
			col.add_child(l)
		offers.add_child(col)

	if you == -1:
		v.add_child(_button("Stop watching", _stop_watching_trade))
	else:
		var pick := Label.new()
		pick.text = "Tap one of yours to offer it:"
		v.add_child(pick)
		var grid := GridContainer.new()
		grid.columns = 3
		v.add_child(grid)
		var mine: Dictionary = state.sides[you]
		for m in mine.party:
			var uid: String = m.uid
			var b := _button("", func(): Net.to_server("c_trade_offer", [uid]), 170)
			b.custom_minimum_size.y = 90
			b.toggle_mode = true
			b.button_pressed = not mine.offer.is_empty() and mine.offer.uid == uid
			var h := HBoxContainer.new()
			h.mouse_filter = Control.MOUSE_FILTER_IGNORE
			h.set_anchors_preset(Control.PRESET_FULL_RECT)
			h.add_child(MonsterView.new(m.species, 56))
			var l := Label.new()
			l.text = "%s\nLv%d" % [GameData.monsters[m.species].name, int(m.level)]
			l.add_theme_font_size_override("font_size", 15)
			h.add_child(l)
			b.add_child(h)
			grid.add_child(b)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		v.add_child(row)
		var both: bool = not state.sides[0].offer.is_empty() and not state.sides[1].offer.is_empty()
		var confirm := _button("Confirm trade", func(): Net.to_server("c_trade_confirm"))
		confirm.disabled = not both or mine.confirmed
		confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(confirm)
		var cancel := _button("Cancel", func(): Net.to_server("c_trade_cancel"))
		cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(cancel)
	trade_wrap.visible = true
	_center_panel(trade_panel, Vector2(640, 0))


func _on_trade_closed() -> void:
	trade_wrap.visible = false
	trade_state = {}
