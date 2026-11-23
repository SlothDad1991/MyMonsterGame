extends Control
## Small control that draws a placeholder monster. Used in menus, party and trade screens.

var species := ""
var flip := false
var _t := 0.0


func _init(sp := "", sz := 64.0) -> void:
	species = sp
	custom_minimum_size = Vector2(sz, sz)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func set_species(sp: String) -> void:
	species = sp
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	if species == "":
		return
	var s: float = min(size.x, size.y)
	GameData.draw_monster(self, species, size / 2.0 + Vector2(0, s * 0.02), s * 0.95, flip, sin(_t * 3.0) * s * 0.02)
