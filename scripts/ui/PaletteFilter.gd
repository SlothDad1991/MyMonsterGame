extends CanvasLayer
## Autoload "Palette": recolours the whole screen into 4 Game Boy shades.
## "Full colour" turns the filter off.

const SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform vec4 c0 : source_color;
uniform vec4 c1 : source_color;
uniform vec4 c2 : source_color;
uniform vec4 c3 : source_color;
void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	vec4 o = l < 0.24 ? c0 : (l < 0.5 ? c1 : (l < 0.78 ? c2 : c3));
	COLOR = vec4(o.rgb, 1.0);
}
"""

var current := "Full colour"
var _rect: ColorRect
var _mat: ShaderMaterial


func _ready() -> void:
	layer = 128
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_rect.material = _mat
	add_child(_rect)
	apply(Gb.load_setting("palette", "Pocket grey"))


func apply(palette_name: String) -> void:
	if not Gb.PALETTES.has(palette_name):
		palette_name = "Full colour"
	current = palette_name
	var cols: Array = Gb.PALETTES[palette_name]
	_rect.visible = not cols.is_empty()
	if not cols.is_empty():
		for i in 4:
			_mat.set_shader_parameter("c%d" % i, cols[i])
	Gb.save_setting("palette", palette_name)


func cycle() -> String:
	var i := Gb.PALETTE_ORDER.find(current)
	apply(Gb.PALETTE_ORDER[(i + 1) % Gb.PALETTE_ORDER.size()])
	return current
