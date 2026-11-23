extends Control
## Start menu: pick a name and starter, then host or join.

const MonsterView := preload("res://scripts/MonsterView.gd")
const WorldScript := preload("res://scripts/World.gd")
const CFG_PATH := "user://client.cfg"

var name_edit: LineEdit
var addr_edit: LineEdit
var status_label: Label
var starter := ""
var starter_buttons := {}
var menu: Control
var bg: ColorRect


func _ready() -> void:
	theme = make_theme()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Net.server != null and Net.my_id == 0:
		_show_dedicated()
		return
	_build_menu()
	Net.welcomed.connect(_on_welcomed)
	Net.connection_failed.connect(_on_failed)


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.1, 0.12, 0.18, 0.94)
	panel.set_corner_radius_all(14)
	panel.set_content_margin_all(16)
	t.set_stylebox("panel", "PanelContainer", panel)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		match state:
			"normal": sb.bg_color = Color("#3b4a6b")
			"hover": sb.bg_color = Color("#4a5d86")
			"pressed": sb.bg_color = Color("#f0b23a")
			"disabled": sb.bg_color = Color("#2a3042")
			"focus":
				sb.bg_color = Color(0, 0, 0, 0)
				sb.border_color = Color("#f0b23a")
				sb.set_border_width_all(2)
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(10)
		t.set_stylebox(state, "Button", sb)
	t.set_color("font_pressed_color", "Button", Color("#1b1b1b"))
	return t


func _show_dedicated() -> void:
	var back := ColorRect.new()
	back.color = Color("#1d2433")
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var l := Label.new()
	l.text = "Dedicated server running on port %d.\nPlayers can join from the game menu." % Net.DEFAULT_PORT
	l.set_anchors_preset(Control.PRESET_CENTER)
	add_child(l)


func _build_menu() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)

	bg = ColorRect.new()
	bg.color = Color("#1d2433")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	menu = scroll

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(520, 0)
	center.add_child(box)

	var title := Label.new()
	title.text = "MONSTER GAME"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = "prototype"
	sub.modulate = Color(1, 1, 1, 0.6)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Your name"
	name_edit.max_length = 14
	name_edit.text = cfg.get_value("client", "name", "")
	box.add_child(name_edit)

	var pick := Label.new()
	pick.text = "Choose your first monster (new players only):"
	box.add_child(pick)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	for id in GameData.starters():
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(150, 150)
		var v := VBoxContainer.new()
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		var mv := MonsterView.new(id, 96)
		mv.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(mv)
		var l := Label.new()
		l.text = "%s\n%s" % [GameData.monsters[id].name, "/".join(GameData.monsters[id].types)]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 16)
		v.add_child(l)
		b.add_child(v)
		b.pressed.connect(_pick_starter.bind(id))
		row.add_child(b)
		starter_buttons[id] = b
	_pick_starter(cfg.get_value("client", "starter", GameData.starters()[0]))

	addr_edit = LineEdit.new()
	addr_edit.placeholder_text = "Server address (e.g. 192.168.1.20)"
	addr_edit.text = cfg.get_value("client", "address", "localhost")
	box.add_child(addr_edit)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)
	var join_b := Button.new()
	join_b.text = "Join game"
	join_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_b.pressed.connect(_on_join)
	buttons.add_child(join_b)
	if not OS.has_feature("web"): # browsers can't host servers
		var host_b := Button.new()
		host_b.text = "Host on this computer"
		host_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host_b.pressed.connect(_on_host)
		buttons.add_child(host_b)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.modulate = Color("#ffd37a")
	box.add_child(status_label)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.55)
	help.add_theme_font_size_override("font_size", 15)
	help.text = "Host: runs the world on this computer and lets you play too. Others on your Wi-Fi join using this computer's IP address.\nMove with arrow keys / WASD or the on-screen pad. Walk into a wild monster to battle. Tap another player to battle, trade or watch."
	box.add_child(help)


func _pick_starter(id: String) -> void:
	if not starter_buttons.has(id):
		id = GameData.starters()[0]
	starter = id
	for k in starter_buttons:
		starter_buttons[k].button_pressed = (k == id)


func _save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("client", "name", name_edit.text.strip_edges())
	cfg.set_value("client", "starter", starter)
	cfg.set_value("client", "address", addr_edit.text.strip_edges())
	cfg.save(CFG_PATH)


func _player_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if n != "" else "Trainer"


func _on_join() -> void:
	_save_cfg()
	status_label.text = "Connecting..."
	var err := Net.join(addr_edit.text, _player_name(), starter)
	if err != OK:
		status_label.text = "Couldn't start connection (error %d)." % err


func _on_host() -> void:
	_save_cfg()
	var err := Net.host_and_play(Net.DEFAULT_PORT, _player_name(), starter)
	if err != OK:
		status_label.text = "Couldn't host (error %d). Is another copy already hosting?" % err


func _on_failed(reason: String) -> void:
	if status_label:
		status_label.text = reason
	var was_playing: bool = menu != null and not menu.visible
	Net.multiplayer.multiplayer_peer = null
	if was_playing:
		# we were in the world: go back to the menu
		get_tree().reload_current_scene()


func _on_welcomed(me: Dictionary) -> void:
	menu.visible = false
	bg.visible = false
	var world := WorldScript.new()
	world.name = "World"
	add_child(world)
	world.setup(me)
