extends Control
## Start screen: name, first monster, server, then JOIN or HOST.

const MonsterView := preload("res://scripts/MonsterView.gd")
const WorldScript := preload("res://scripts/World.gd")
const CFG_PATH := "user://client.cfg"

var name_edit: LineEdit
var addr_edit: LineEdit
var status_label: Label
var starter_label: Label
var starter := ""
var starter_buttons := {}
var menu: Control
var bg: ColorRect


func _ready() -> void:
	if OS.has_feature("web"):
		# installed (PWA) copies cache the game: switch to a newer version as soon as one exists
		JavaScriptBridge.pwa_update_available.connect(_on_pwa_update)
		if JavaScriptBridge.pwa_needs_update():
			_on_pwa_update()
	theme = Gb.theme()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Net.server != null and Net.my_id == 0:
		_show_dedicated()
		return
	_build_menu()
	Net.welcomed.connect(_on_welcomed)
	Net.connection_failed.connect(_on_failed)


func _on_pwa_update() -> void:
	# only refresh while still on the menu, never in the middle of a game
	if menu == null or menu.visible:
		JavaScriptBridge.pwa_update()


func _show_dedicated() -> void:
	var back := ColorRect.new()
	back.color = Gb.C0
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var l := Gb.label("SERVER RUNNING\nON PORT %d" % Net.DEFAULT_PORT)
	l.set_anchors_preset(Control.PRESET_CENTER)
	add_child(l)


func _build_menu() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)

	bg = ColorRect.new()
	bg.color = Gb.C0
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
	box.add_theme_constant_override("separation", 3)
	box.custom_minimum_size = Vector2(240, 0)
	center.add_child(box)

	var title := Gb.label("MONSTER GAME", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var name_row := HBoxContainer.new()
	box.add_child(name_row)
	var nl := Gb.label("NAME ")
	nl.custom_minimum_size.x = 56
	name_row.add_child(nl)
	name_edit = LineEdit.new()
	name_edit.max_length = 10
	name_edit.placeholder_text = "TRAINER"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text = cfg.get_value("client", "name", "")
	name_row.add_child(name_edit)

	var pick_row := HBoxContainer.new()
	pick_row.add_theme_constant_override("separation", 2)
	box.add_child(pick_row)
	for id in GameData.starters():
		var b := GbButton.new("", _pick_starter.bind(id))
		b.custom_minimum_size = Vector2(40, 30)
		var mv := MonsterView.new(id, 26)
		mv.position = Vector2(10, 2)
		mv.size = Vector2(26, 26)
		b.add_child(mv)
		pick_row.add_child(b)
		starter_buttons[id] = b
	starter_label = Gb.label("")
	starter_label.add_theme_constant_override("line_spacing", 2)
	pick_row.add_child(starter_label)
	_pick_starter(cfg.get_value("client", "starter", GameData.starters()[0]))

	var addr_row := HBoxContainer.new()
	box.add_child(addr_row)
	var al := Gb.label("SERVER")
	al.custom_minimum_size.x = 56
	addr_row.add_child(al)
	addr_edit = LineEdit.new()
	addr_edit.placeholder_text = "ask the host"
	addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_edit.text = cfg.get_value("client", "address", "" if OS.has_feature("web") else "localhost")
	if OS.has_feature("web"):
		# a share link like  .../MyMonsterGame/?server=abc.trycloudflare.com  fills this in
		var from_link := str(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('server') || ''"))
		if from_link != "":
			addr_edit.text = from_link
	addr_row.add_child(addr_edit)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 4)
	box.add_child(buttons)
	var join_b := GbButton.new("JOIN", _on_join)
	buttons.add_child(join_b)
	if not OS.has_feature("web"): # browsers can't host servers
		buttons.add_child(GbButton.new("HOST", _on_host))
	var colours_b := GbButton.new("COLOURS", _on_colours)
	buttons.add_child(colours_b)

	status_label = Gb.label("")
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Gb.C2)
	box.add_child(status_label)
	_set_status("Colours: " + Palette.current)
	join_b.call_deferred("grab_focus")


func _pick_starter(id: String) -> void:
	if not starter_buttons.has(id):
		id = GameData.starters()[0]
	starter = id
	for k in starter_buttons:
		starter_buttons[k].selected_mark = (k == id)
		starter_buttons[k].queue_redraw()
	var d: Dictionary = GameData.monsters[id]
	starter_label.text = "%s\n%s" % [d.name.to_upper(), "/".join(d.types).to_upper()]


func _on_colours() -> void:
	_set_status("Colours: " + Palette.cycle())


func _set_status(s: String) -> void:
	status_label.text = s


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
	if addr_edit.text.strip_edges() == "":
		_set_status("Type the server address first.")
		return
	_save_cfg()
	_set_status("Connecting...")
	var err := Net.join(addr_edit.text, _player_name(), starter)
	if err != OK:
		_set_status("Couldn't connect (error %d)." % err)


func _on_host() -> void:
	_save_cfg()
	var err := Net.host_and_play(Net.DEFAULT_PORT, _player_name(), starter)
	if err != OK:
		_set_status("Couldn't host (error %d). Is the game already hosting?" % err)


func _on_failed(reason: String) -> void:
	if status_label:
		_set_status(reason)
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
