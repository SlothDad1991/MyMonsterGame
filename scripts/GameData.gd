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


# attacking type -> {defending type: multiplier}; anything missing = 1.0 (data/types.json)
var type_chart: Dictionary = {}
var monsters: Dictionary = {}
var _tex_cache := {}
var moves: Dictionary = {}
var map: Array = [] # map[y][x] -> T
# Tall-grass areas: which monsters live there and at what levels (weights = how common).
const ZONES := [
	{"name": "North Meadow", "rect": Rect2i(4, 4, 14, 9), "levels": [2, 5],
		"species": {"cairfrey": 30, "vamporm": 30, "propellercat": 20, "pigabyte": 20}},
	{"name": "East Hills", "rect": Rect2i(42, 3, 13, 8), "levels": [4, 7],
		"species": {"propellercat": 25, "lambert": 25, "noctula": 20, "cardiling": 15, "merlicun": 15}},
	{"name": "Old Woods", "rect": Rect2i(5, 26, 12, 10), "levels": [5, 8],
		"species": {"selket": 30, "sludgehog": 25, "vamporm": 25, "eyenemy": 20}},
	{"name": "South Field", "rect": Rect2i(22, 30, 10, 6), "levels": [6, 9],
		"species": {"axolightl": 35, "tweesher": 25, "chillimp": 20, "cairfrey": 20}},
	{"name": "Far East", "rect": Rect2i(44, 18, 8, 7), "levels": [8, 12],
		"species": {"wrougon": 20, "eyenemy": 20, "noctula": 20, "merlicun": 20, "chillimp": 20}},
]

var town_center := Vector2i(30, 20)
var heal_tile := Vector2i(30, 17)


func _ready() -> void:
	monsters = _load_json("res://data/monsters.json")
	moves = _load_json("res://data/moves.json")
	type_chart = _load_json("res://data/types.json")
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
	for z in ZONES:
		var r: Rect2i = z.rect
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
	for evo in monsters[m.species].get("evolutions", []):
		if m.level >= int(evo[0]) and monsters.has(evo[1]):
			var old_name := mon_name(m)
			var ratio := float(m.hp) / float(max(1, m.max_hp))
			m.species = evo[1]
			calc_stats(m)
			m.hp = max(1, int(round(m.max_hp * ratio)))
			lines.append("What? %s is evolving!" % old_name)
			lines.append("%s evolved into %s!" % [old_name, mon_name(m)])
			break
	return lines


## Keeps saves from older versions working (renamed monsters, removed moves).
func migrate_monster(m: Dictionary) -> void:
	var old_names := {"embertail": "agnite", "splashkit": "dollfin", "sproutling": "anoleaf"}
	if not monsters.has(m.species):
		m.species = old_names.get(m.species, "cairfrey")
	var keep := []
	for mid in m.get("moves", []):
		if moves.has(mid):
			keep.append(mid)
	if keep.is_empty():
		for entry in monsters[m.species].moves:
			if int(entry[0]) <= int(m.level):
				keep.append(entry[1])
		keep = keep.slice(max(0, keep.size() - 4))
	m.moves = keep
	calc_stats(m)
	m.hp = clampi(int(m.get("hp", m.max_hp)), 0, m.max_hp)


func mon_name(m: Dictionary) -> String:
	return monsters[m.species].name


func type_multiplier(move_type: String, def_types: Array) -> float:
	var mult := 1.0
	var row: Dictionary = type_chart.get(move_type, {})
	for t in def_types:
		mult *= row.get(t, 1.0)
	return mult


func zone_at(p: Vector2i) -> Dictionary:
	for z in ZONES:
		if z.rect.has_point(p):
			return z
	return {}


func pick_zone_species(zone: Dictionary, rng: RandomNumberGenerator) -> String:
	var table: Dictionary = zone.species
	var total := 0
	for id in table:
		if monsters.has(id):
			total += int(table[id])
	var roll := rng.randi_range(1, max(1, total))
	for id in table:
		if not monsters.has(id):
			continue
		roll -= int(table[id])
		if roll <= 0:
			return id
	return table.keys()[0]


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


# ---------------------------------------------------------------- monster sprites
## Each sheet (from Tuxemon, see CREDITS.md) is 128x88: front 64x64, back 64x64,
## then two 24x24 icon frames underneath.

func _ellipse(c: Vector2, r: Vector2, n := 20) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return pts


func sheet(species: String) -> Texture2D:
	if not _tex_cache.has(species):
		var path: String = monsters.get(species, {}).get("sprite", "")
		_tex_cache[species] = load(path) if path != "" and ResourceLoader.exists(path) else null
	return _tex_cache[species]


func _blit(ci: CanvasItem, tex: Texture2D, src: Rect2, center: Vector2, scale: float, flip: bool) -> void:
	var size := src.size * scale
	var dst := Rect2((center - size / 2.0).round(), size)
	if flip:
		dst.position.x += dst.size.x
		dst.size.x = -dst.size.x
	ci.draw_texture_rect_region(tex, dst, src)


## Front view (what you see of the other side in battle).
func draw_front(ci: CanvasItem, species: String, center: Vector2, scale := 1.0, flip := false) -> void:
	var tex := sheet(species)
	if tex:
		_blit(ci, tex, Rect2(0, 0, 64, 64), center, scale, flip)


## Back view (your own monster in battle).
func draw_back(ci: CanvasItem, species: String, center: Vector2, scale := 1.0) -> void:
	var tex := sheet(species)
	if tex:
		_blit(ci, tex, Rect2(64, 0, 64, 64), center, scale, false)


## Small animated icon (overworld, party list, menus). frame 0 or 1.
func draw_icon(ci: CanvasItem, species: String, center: Vector2, frame := 0, flip := false) -> void:
	var tex := sheet(species)
	if tex:
		_blit(ci, tex, Rect2(24 * (frame % 2), 64, 24, 24), center, 1.0, flip)


## Old entry point, kept so every caller still works: small sizes get the
## icon, bigger sizes the front sprite.
func draw_monster(ci: CanvasItem, species: String, c: Vector2, s: float, flip := false, bob := 0.0) -> void:
	if s <= 28.0:
		draw_icon(ci, species, c + Vector2(0, bob), int(Time.get_ticks_msec() / 400.0) % 2, flip)
	else:
		draw_front(ci, species, c + Vector2(0, bob), maxf(1.0, round(s / 64.0)), flip)
