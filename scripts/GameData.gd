extends Node
## Shared game data and rules. Loaded on both the server and every client,
## so the map and the monster stats are identical everywhere.

const TILE := 16
const MAP_W := 60
const MAP_H := 40
const PARTY_MAX := 6

enum T { GRASS, TALL, TREE, WATER, PATH, HEAL, SAND, FLOWER }

const TILE_COLORS := {
	T.GRASS: Color("#7cc456"),
	T.TALL: Color("#3f8f3a"),
	T.TREE: Color("#2b5d2a"),
	T.WATER: Color("#3d8fd6"),
	T.PATH: Color("#d8c08a"),
	T.HEAL: Color("#f07fa0"),
	T.SAND: Color("#ecd9a0"),
	T.FLOWER: Color("#7cc456"),
}

# attacking type -> {defending type: multiplier}. Anything missing = 1.0
const TYPE_CHART := {
	"Fire": {"Grass": 2.0, "Bug": 2.0, "Water": 0.5, "Rock": 0.5, "Fire": 0.5},
	"Water": {"Fire": 2.0, "Rock": 2.0, "Water": 0.5, "Grass": 0.5},
	"Grass": {"Water": 2.0, "Rock": 2.0, "Fire": 0.5, "Grass": 0.5, "Flying": 0.5, "Bug": 0.5},
	"Electric": {"Water": 2.0, "Flying": 2.0, "Grass": 0.5, "Electric": 0.5, "Rock": 0.5},
	"Rock": {"Fire": 2.0, "Flying": 2.0, "Bug": 2.0},
	"Flying": {"Grass": 2.0, "Bug": 2.0, "Rock": 0.5, "Electric": 0.5},
	"Bug": {"Grass": 2.0, "Fire": 0.5, "Flying": 0.5},
	"Normal": {"Rock": 0.5},
}

var monsters: Dictionary = {}
var moves: Dictionary = {}
var map: Array = [] # map[y][x] -> T
var town_center := Vector2i(30, 20)
var heal_tile := Vector2i(30, 17)


func _ready() -> void:
	monsters = _load_json("res://data/monsters.json")
	moves = _load_json("res://data/moves.json")
	_generate_map()


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Could not open " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


# ---------------------------------------------------------------- map

func _generate_map() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242 # fixed seed: same map for everyone
	map.clear()
	for y in MAP_H:
		var row := []
		for x in MAP_W:
			row.append(T.GRASS)
		map.append(row)

	# tall grass patches
	var patches := [Rect2i(4, 4, 14, 9), Rect2i(42, 3, 13, 8), Rect2i(5, 26, 12, 10),
		Rect2i(22, 30, 10, 6), Rect2i(44, 18, 8, 7)]
	for r in patches:
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if rng.randf() < 0.85:
					map[y][x] = T.TALL

	# lake in the bottom right
	var lake_c := Vector2(48, 32)
	for y in MAP_H:
		for x in MAP_W:
			var d := Vector2(x, y).distance_to(lake_c) + rng.randf() * 1.2
			if d < 6.0:
				map[y][x] = T.WATER
			elif d < 7.5:
				map[y][x] = T.SAND

	# scattered trees + flowers
	for i in 90:
		var x := rng.randi_range(1, MAP_W - 2)
		var y := rng.randi_range(1, MAP_H - 2)
		if map[y][x] == T.GRASS:
			map[y][x] = T.TREE if rng.randf() < 0.6 else T.FLOWER

	# town square
	for y in range(town_center.y - 4, town_center.y + 4):
		for x in range(town_center.x - 6, town_center.x + 6):
			map[y][x] = T.PATH
	# roads out of town
	for x in range(1, MAP_W - 1):
		if map[town_center.y][x] != T.WATER:
			map[town_center.y][x] = T.PATH
	for y in range(1, MAP_H - 1):
		if map[y][town_center.x] != T.WATER:
			map[y][town_center.x] = T.PATH
	map[heal_tile.y][heal_tile.x] = T.HEAL

	# tree border
	for x in MAP_W:
		map[0][x] = T.TREE
		map[MAP_H - 1][x] = T.TREE
	for y in MAP_H:
		map[y][0] = T.TREE
		map[y][MAP_W - 1] = T.TREE


func tile_at(p: Vector2i) -> int:
	if p.x < 0 or p.y < 0 or p.x >= MAP_W or p.y >= MAP_H:
		return T.TREE
	return map[p.y][p.x]


func walkable(p: Vector2i) -> bool:
	var t := tile_at(p)
	return t != T.TREE and t != T.WATER


func spawn_point(rng: RandomNumberGenerator) -> Vector2i:
	for i in 50:
		var p := town_center + Vector2i(rng.randi_range(-4, 4), rng.randi_range(-2, 2))
		if walkable(p) and p != heal_tile:
			return p
	return town_center


# ---------------------------------------------------------------- monsters

func calc_stats(m: Dictionary) -> void:
	var base: Dictionary = monsters[m.species].base
	var lv: int = m.level
	m.max_hp = int(base.hp * 2 * lv / 100.0) + lv + 10
	m.atk = int(base.atk * 2 * lv / 100.0) + 5
	m.def = int(base.def * 2 * lv / 100.0) + 5
	m.spd = int(base.spd * 2 * lv / 100.0) + 5


func make_monster(species: String, level: int, uid: String) -> Dictionary:
	var m := {"uid": uid, "species": species, "level": level, "xp": 0}
	calc_stats(m)
	m.hp = m.max_hp
	var learned := []
	for entry in monsters[species].moves:
		if int(entry[0]) <= level:
			learned.append(entry[1])
	m.moves = learned.slice(max(0, learned.size() - 4))
	return m


func xp_to_next(level: int) -> int:
	return level * level * 4 + 10


## Adds xp, handles level-ups and new moves. Returns log lines.
func give_xp(m: Dictionary, amount: int) -> Array:
	var lines := []
	m.xp += amount
	lines.append("%s gained %d XP." % [mon_name(m), amount])
	while m.xp >= xp_to_next(m.level) and m.level < 100:
		m.xp -= xp_to_next(m.level)
		var old_max: int = m.max_hp
		m.level += 1
		calc_stats(m)
		m.hp += m.max_hp - old_max
		lines.append("%s grew to level %d!" % [mon_name(m), m.level])
		for entry in monsters[m.species].moves:
			if int(entry[0]) == m.level and not m.moves.has(entry[1]):
				m.moves.append(entry[1])
				if m.moves.size() > 4:
					m.moves.pop_front()
				lines.append("%s learned %s!" % [mon_name(m), moves[entry[1]].name])
	return lines


func mon_name(m: Dictionary) -> String:
	return monsters[m.species].name


func type_multiplier(move_type: String, def_types: Array) -> float:
	var mult := 1.0
	var row: Dictionary = TYPE_CHART.get(move_type, {})
	for t in def_types:
		mult *= row.get(t, 1.0)
	return mult


func starters() -> Array:
	var out := []
	for id in monsters:
		if monsters[id].get("starter", false):
			out.append(id)
	return out


func pick_wild_species(rng: RandomNumberGenerator) -> String:
	var total := 0
	for id in monsters:
		total += int(monsters[id].wild_weight)
	var roll := rng.randi_range(1, total)
	for id in monsters:
		roll -= int(monsters[id].wild_weight)
		if roll <= 0:
			return id
	return monsters.keys()[0]


# ---------------------------------------------------------------- placeholder art
## Draws a simple original placeholder creature. Swap for real sprites later.

func _ellipse(c: Vector2, r: Vector2, n := 20) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return pts


func draw_monster(ci: CanvasItem, species: String, c: Vector2, s: float, flip := false, bob := 0.0) -> void:
	if not monsters.has(species):
		return
	var d: Dictionary = monsters[species]
	var col := Color(d.color)
	var acc := Color(d.accent)
	var dark := col.darkened(0.45)
	var f := -1.0 if flip else 1.0
	c.y += bob
	# shadow
	ci.draw_colored_polygon(_ellipse(c + Vector2(0, s * 0.42), Vector2(s * 0.38, s * 0.1)), Color(0, 0, 0, 0.25))
	match d.shape:
		"fox":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.22 * s * f, 0.2 * s), c + Vector2(-0.5 * s * f, -0.05 * s), c + Vector2(-0.6 * s * f, -0.3 * s), c + Vector2(-0.38 * s * f, 0.28 * s)]), acc)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.25 * s, -0.15 * s), c + Vector2(-0.18 * s, -0.48 * s), c + Vector2(-0.02 * s, -0.22 * s)]), col)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0.25 * s, -0.15 * s), c + Vector2(0.18 * s, -0.48 * s), c + Vector2(0.02 * s, -0.22 * s)]), col)
		"bunny":
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.12 * s, -0.42 * s), Vector2(0.07 * s, 0.22 * s)), col)
			ci.draw_colored_polygon(_ellipse(c + Vector2(0.12 * s, -0.42 * s), Vector2(0.07 * s, 0.22 * s)), col)
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.12 * s, -0.42 * s), Vector2(0.035 * s, 0.15 * s)), acc)
			ci.draw_colored_polygon(_ellipse(c + Vector2(0.12 * s, -0.42 * s), Vector2(0.035 * s, 0.15 * s)), acc)
		"bulb":
			ci.draw_colored_polygon(_ellipse(c + Vector2(0.08 * s, -0.36 * s), Vector2(0.16 * s, 0.07 * s)), acc)
			ci.draw_line(c + Vector2(0, -0.2 * s), c + Vector2(0, -0.38 * s), dark, max(1.0, s * 0.03))
		"crab":
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.38 * s, -0.05 * s), Vector2(0.12 * s, 0.1 * s)), acc)
			ci.draw_colored_polygon(_ellipse(c + Vector2(0.38 * s, -0.05 * s), Vector2(0.12 * s, 0.1 * s)), acc)
		"bug":
			ci.draw_line(c + Vector2(-0.08 * s, -0.22 * s), c + Vector2(-0.18 * s, -0.42 * s), dark, max(1.0, s * 0.03))
			ci.draw_line(c + Vector2(0.08 * s, -0.22 * s), c + Vector2(0.18 * s, -0.42 * s), dark, max(1.0, s * 0.03))
		"wisp":
			for i in 5:
				var a := -PI / 2 + (i - 2) * 0.5
				var p1 := c + Vector2(cos(a), sin(a)) * s * 0.25
				var p2 := c + Vector2(cos(a), sin(a)) * s * 0.45
				ci.draw_line(p1, p2, acc, max(1.0, s * 0.04))
	# body
	var body_r := Vector2(0.3 * s, 0.26 * s)
	if d.shape == "seal" or d.shape == "blob":
		body_r = Vector2(0.34 * s, 0.24 * s)
	ci.draw_colored_polygon(_ellipse(c + Vector2(0, 0.08 * s), body_r), col)
	# belly
	ci.draw_colored_polygon(_ellipse(c + Vector2(0, 0.16 * s), body_r * Vector2(0.55, 0.5)), col.lightened(0.3))
	match d.shape:
		"bird":
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.22 * s * f, 0.06 * s), Vector2(0.12 * s, 0.07 * s)), acc)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0.18 * s * f, -0.02 * s), c + Vector2(0.34 * s * f, 0.03 * s), c + Vector2(0.18 * s * f, 0.08 * s)]), Color("#f2a33a"))
		"seal":
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.3 * s * f, 0.2 * s), Vector2(0.1 * s, 0.05 * s)), acc)
		"blob":
			ci.draw_colored_polygon(_ellipse(c + Vector2(-0.12 * s, 0.0), Vector2(0.05 * s, 0.04 * s)), acc)
			ci.draw_colored_polygon(_ellipse(c + Vector2(0.16 * s, 0.12 * s), Vector2(0.04 * s, 0.03 * s)), acc)
		"bug":
			ci.draw_line(c + Vector2(-0.2 * s, 0.1 * s), c + Vector2(0.2 * s, 0.1 * s), acc, max(1.0, s * 0.04))
	# eyes
	var ex := 0.1 * s
	var ey := 0.0
	var off := 0.04 * s * f
	for sx in [-1, 1]:
		var e := c + Vector2(sx * ex + off, ey)
		ci.draw_colored_polygon(_ellipse(e, Vector2(0.055 * s, 0.065 * s), 12), Color.WHITE)
		ci.draw_colored_polygon(_ellipse(e + Vector2(0.015 * s * f, 0.01 * s), Vector2(0.03 * s, 0.04 * s), 10), Color("#1d1d24"))
