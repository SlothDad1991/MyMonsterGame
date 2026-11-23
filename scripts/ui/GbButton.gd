class_name GbButton
extends Button
## Text menu item with the classic ▶ cursor when selected.

var selected_mark := false # draws a hollow cursor even when not focused (e.g. chosen option)


func _init(t := "", cb := Callable()) -> void:
	text = t
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	focus_mode = Control.FOCUS_ALL
	if cb.is_valid():
		pressed.connect(cb)
	mouse_entered.connect(_on_hover)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _on_hover() -> void:
	if not disabled:
		grab_focus()


func _draw() -> void:
	var y := floor((size.y - 7) / 2.0)
	if has_focus():
		Gb.cursor(self, Vector2(1, y))
	elif selected_mark:
		Gb.cursor(self, Vector2(1, y), Gb.C1)
