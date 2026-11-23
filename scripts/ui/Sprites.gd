class_name Sprites
extends RefCounted
## Placeholder 16x16 trainer sprites, drawn from text templates.
## k = outline, h = cap (player colour), w = white, s = skin, c = shirt, p = trousers

const DOWN := [
	"................",
	".....kkkkkk.....",
	"....khhhhhhk....",
	"...khhhhhhhhk...",
	"...kwwwwwwwwk...",
	"...kkkkkkkkkk...",
	"...kssssssssk...",
	"...kskssssksk...",
	"....kssssssk....",
	"...kkkccccckkk..",
	"..ksskccccksssk.",
	"..kssccccccsssk.",
	"...kkccccccckk..",
	"....kppppppk....",
	"....kppkkppk....",
	"....kkk..kkk....",
]
const UP := [
	"................",
	".....kkkkkk.....",
	"....khhhhhhk....",
	"...khhhhhhhhk...",
	"...khhhhhhhhk...",
	"...khhhhhhhhk...",
	"...kkhhhhhhkk...",
	"...kssssssssk...",
	"....kssssssk....",
	"...kkkccccckkk..",
	"..ksskccccksssk.",
	"..kssccccccsssk.",
	"...kkccccccckk..",
	"....kppppppk....",
	"....kppkkppk....",
	"....kkk..kkk....",
]
const SIDE := [
	"................",
	".....kkkkkk.....",
	"....khhhhhhk....",
	"...khhhhhhhhkk..",
	"...khhhhhwwwwwk.",
	"...khhhhkkkkkk..",
	"...khhkssssssk..",
	"...khkssssskssk.",
	"....kssssssssk..",
	"....kkcccckkk...",
	"...kscccccssk...",
	"...kscccccssk...",
	"....kccccccck...",
	"....kppppppk....",
	"....kppkkppk....",
	"....kkk..kkk....",
]
const STEP_FRONT := ["....kppppppk....", "....kppkkkk.....", "....kkk........."]
const STEP_SIDE := ["....kppppppk....", "...kppk..kpk....", "...kkk...kkk...."]

static var _cache := {}


static func _build(rows: Array, cap: Color) -> ImageTexture:
	var cols := {
		"k": Color("#181818"), "h": cap, "w": Color("#f8f8f8"), "s": Color("#f8d0a8"),
		"c": cap.darkened(0.35), "p": Color("#383860"),
	}
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		var r: String = rows[y]
		for x in 16:
			var ch := r[x]
			if ch != ".":
				img.set_pixel(x, y, cols[ch])
	return ImageTexture.create_from_image(img)


## dir: 0 down, 1 up, 2 left, 3 right. frame: 0 standing, 1 / 2 steps.
## Returns [texture, flip_h].
static func trainer(cap: Color, dir: int, frame: int) -> Array:
	var key := "%s:%d:%d" % [cap.to_html(), dir, frame]
	var flip := false
	if not _cache.has(key):
		var rows: Array
		match dir:
			0: rows = DOWN.duplicate()
			1: rows = UP.duplicate()
			_: rows = SIDE.duplicate()
		if frame != 0:
			var step: Array = STEP_SIDE if dir >= 2 else STEP_FRONT
			for i in 3:
				rows[13 + i] = step[i]
		_cache[key] = _build(rows, cap)
	if dir == 2:
		flip = true # side frames face right; mirror for left
	elif dir < 2 and frame == 2:
		flip = true # alternate the stepping leg
	return [_cache[key], flip]
