class_name GbTextBox
extends PanelContainer
## The classic bottom text box: types messages out one at a time.
## Tap (or press A) to speed up / skip ahead; pages also advance by themselves.

signal finished

const CPS := 70.0 # characters per second

var label: Label
var queue: Array = []
var auto_advance := 1.1
var _chars := 0.0
var _hold := 0.0
var _typing := false
var _done := true
var _t := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(0, 46)
	mouse_filter = Control.MOUSE_FILTER_STOP
	label = Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.add_theme_constant_override("line_spacing", 8)
	add_child(label)


func say(lines: Array) -> void:
	for l in lines:
		queue.append(str(l))
	if not _typing and _hold <= 0.0:
		_next()


func show_text(s: String) -> void:
	## show instantly, no typing, no queue
	queue.clear()
	label.text = s
	label.visible_characters = -1
	_typing = false
	_hold = 0.0
	_done = true


func clear() -> void:
	show_text("")


func is_busy() -> bool:
	return _typing or _hold > 0.0 or not queue.is_empty()


func advance() -> void:
	if _typing:
		_chars = label.text.length()
	elif _hold > 0.0:
		_hold = 0.0
		_next()


func _next() -> void:
	if queue.is_empty():
		_typing = false
		_hold = 0.0
		if not _done:
			_done = true
			finished.emit()
		return
	_done = false
	label.text = queue.pop_front()
	label.visible_characters = 0
	_chars = 0.0
	_typing = true


func _process(delta: float) -> void:
	_t += delta
	if _typing:
		_chars += delta * CPS
		label.visible_characters = int(_chars)
		if _chars >= label.text.length():
			label.visible_characters = -1
			_typing = false
			_hold = auto_advance
	elif _hold > 0.0:
		_hold -= delta
		if _hold <= 0.0:
			_next()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance()
		accept_event()


func _draw() -> void:
	if _hold > 0.0 and not queue.is_empty() and fmod(_t, 0.6) < 0.4:
		Gb.down_arrow(self, Vector2(size.x - 14, size.y - 9))
