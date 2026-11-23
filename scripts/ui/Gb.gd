class_name Gb
extends RefCounted
## Game Boy style kit: screen size, the 4 UI shades, colour palettes,
## the pixel font, boxes, theme and saved settings.

const W := 256 # base screen: 16 x 9 tiles of 16 px (wider phones show a bit more)
const H := 144

# UI shades, lightest to darkest. They map cleanly onto any 4-colour palette.
const C0 := Color(0.97, 0.97, 0.97)
const C1 := Color(0.66, 0.66, 0.66)
const C2 := Color(0.36, 0.36, 0.36)
const C3 := Color(0.06, 0.06, 0.06)

const PALETTE_ORDER := ["Full colour", "Pocket grey", "Classic green", "Sunset tint"]
# darkest -> lightest
const PALETTES := {
	"Full colour": [],
	"Pocket grey": [Color("#141414"), Color("#5c5c5c"), Color("#a8a8a8"), Color("#f4f4f0")],
	"Classic green": [Color("#0f380f"), Color("#306230"), Color("#8bac0f"), Color("#9bbc0f")],
	"Sunset tint": [Color("#2d1b2e"), Color("#7b4258"), Color("#d79b7d"), Color("#fbf0d9")],
}

const SETTINGS_PATH := "user://settings.cfg"

static var _font: FontFile
static var _theme: Theme
static var _box_tex: ImageTexture


static func font() -> Font:
	if _font == null:
		_font = load("res://fonts/PressStart2P.woff")
		_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_font.hinting = TextServer.HINTING_NONE
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return _font


## The classic double-line box border as a 9-patch texture.
static func box_texture() -> ImageTexture:
	if _box_tex != null:
		return _box_tex
	var n := 9
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(C0)
	for i in n:
		for j in n:
			var edge: int = min(min(i, j), min(n - 1 - i, n - 1 - j))
			if edge == 0 or edge == 2:
				img.set_pixel(i, j, C3)
	# round the outer corners
	for c in [Vector2i(0, 0), Vector2i(n - 1, 0), Vector2i(0, n - 1), Vector2i(n - 1, n - 1)]:
		img.set_pixelv(c, Color(0, 0, 0, 0))
	_box_tex = ImageTexture.create_from_image(img)
	return _box_tex


static func box_style(pad_x := 6, pad_y := 5) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = box_texture()
	sb.set_texture_margin_all(4)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 8
	t.set_stylebox("panel", "PanelContainer", box_style())
	t.set_color("font_color", "Label", C3)
	t.set_constant("line_spacing", "Label", 3)
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		var e := StyleBoxEmpty.new()
		e.content_margin_left = 9
		e.content_margin_right = 2
		e.content_margin_top = 2
		e.content_margin_bottom = 2
		t.set_stylebox(st, "Button", e)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(c, "Button", C3)
	t.set_color("font_disabled_color", "Button", C1)
	var le := StyleBoxFlat.new()
	le.bg_color = C0
	le.border_color = C3
	le.set_border_width_all(1)
	le.content_margin_left = 3
	le.content_margin_right = 3
	le.content_margin_top = 2
	le.content_margin_bottom = 2
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate()
	lef.set_border_width_all(2)
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_color("font_color", "LineEdit", C3)
	t.set_color("caret_color", "LineEdit", C3)
	t.set_color("font_placeholder_color", "LineEdit", C1)
	t.set_color("selection_color", "LineEdit", C1)
	_theme = t
	return t


static func box() -> PanelContainer:
	return PanelContainer.new()


static func label(s: String, size := 8) -> Label:
	var l := Label.new()
	l.text = s
	if size != 8:
		l.add_theme_font_size_override("font_size", size)
	return l


# ---------------------------------------------------------------- settings

static func load_setting(key: String, default):
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	return cfg.get_value("settings", key, default)


static func save_setting(key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("settings", key, value)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- drawing helpers

static func text(ci: CanvasItem, pos: Vector2, s: String, col := C3, size := 8) -> void:
	## pos is the top-left of the text
	ci.draw_string(font(), pos + Vector2(0, size), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func text_right(ci: CanvasItem, right_x: float, y: float, s: String, col := C3) -> void:
	var w := font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
	text(ci, Vector2(right_x - w, y), s, col)


static func hp_bar(ci: CanvasItem, pos: Vector2, width: float, ratio: float) -> void:
	## Classic "HP:" bar. pos is top-left of the "HP:" label.
	text(ci, pos + Vector2(0, 0), "HP:", C3)
	var bx := pos.x + 25
	var r := Rect2(bx, pos.y + 2, width, 5)
	ci.draw_rect(r, C3)
	ci.draw_rect(r.grow(-1), C0)
	var col := Color("#2f9e44") if ratio > 0.5 else (Color("#d9a400") if ratio > 0.2 else Color("#d1372a"))
	ci.draw_rect(Rect2(r.position + Vector2(1, 1), Vector2(round((width - 2) * clampf(ratio, 0, 1)), 3)), col)


static func cursor(ci: CanvasItem, pos: Vector2, col := C3) -> void:
	## the ▶ menu cursor, 4x7 px, pos = top-left
	for i in 4:
		ci.draw_rect(Rect2(pos.x + i, pos.y + i, 1, 7 - i * 2), col)


static func down_arrow(ci: CanvasItem, pos: Vector2, col := C3) -> void:
	for i in 4:
		ci.draw_rect(Rect2(pos.x + i, pos.y + i, 7 - i * 2, 1), col)
