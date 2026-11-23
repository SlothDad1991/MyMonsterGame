extends Node
## Authoritative game server: world, wild monsters, battles, trades, saves.
## Only exists on the machine that hosts.

const WILD_COUNT := 24
const SYNC_INTERVAL := 0.1
const WANDER_INTERVAL := 0.9
const STARTER_LEVEL := 5

var net # the Net autoload
var rng := RandomNumberGenerator.new()

var players := {} # pid -> player dict
var wilds := {}   # wid -> wild dict
var battles := {} # bid -> battle dict
var trades := {}  # tid -> trade dict
var requests := {} # "kind:from:to" -> unix time
var saves := {}   # lowercase name -> {party, box}

var _next_id := 1
var _sync_t := 0.0
var _wander_t := 0.0
var _save_t := 0.0
var _dirty := false


var save_path := "user://server_save.json"


func _ready() -> void:
	rng.randomize()
	save_path = net.save_path
	_load_saves()
	for i in WILD_COUNT:
		_spawn_wild()


func _new_id(prefix: String) -> String:
	_next_id += 1
	return "%s%d_%x" % [prefix, _next_id, rng.randi() & 0xffff]


func _process(delta: float) -> void:
	_sync_t += delta
	_wander_t += delta
	_save_t += delta
	if _sync_t >= SYNC_INTERVAL:
		_sync_t = 0.0
		_broadcast_world()
	if _wander_t >= WANDER_INTERVAL:
		_wander_t = 0.0
		_wander_wilds()
		while wilds.size() < WILD_COUNT:
			_spawn_wild()
	if _save_t >= 10.0:
		_save_t = 0.0
		if _dirty:
			_write_saves()


# ---------------------------------------------------------------- saves

func _load_saves() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		saves = data
		for key in saves:
			for list_name in ["party", "box"]:
				for m in saves[key].get(list_name, []):
					_normalize(m)


func _normalize(m: Dictionary) -> void:
	for k in ["level", "xp", "hp", "max_hp", "atk", "def", "spd"]:
		m[k] = int(m.get(k, 0))


func _write_saves() -> void:
	for pid in players:
		_store_player(players[pid])
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(saves))
	_dirty = false


func _store_player(p: Dictionary) -> void:
	saves[p.name.to_lower()] = {"party": p.party, "box": p.box}


# ---------------------------------------------------------------- joining

func on_hello(pid: int, player_name: String, starter: String) -> void:
	if players.has(pid):
		return
	player_name = player_name.strip_edges().substr(0, 14)
	if player_name == "":
		player_name = "Trainer"
	# avoid two online players with the same name
	var taken := []
	for p in players.values():
		taken.append(p.name.to_lower())
	var base_name := player_name
	var n := 2
	while player_name.to_lower() in taken:
		player_name = "%s%d" % [base_name, n]
		n += 1

	var p := {
		"id": pid, "name": player_name,
		"pos": GameData.spawn_point(rng), "dir": 0,
		"status": "free", "battle": "", "trade": "", "watching": "",
		"color": rng.randi_range(0, 7),
		"party": [], "box": [],
	}
	var key := player_name.to_lower()
	if saves.has(key):
		p.party = saves[key].get("party", [])
		p.box = saves[key].get("box", [])
	if p.party.is_empty():
		if not GameData.monsters.has(starter) or not GameData.monsters[starter].get("starter", false):
			starter = GameData.starters()[0]
		p.party.append(GameData.make_monster(starter, STARTER_LEVEL, _new_id("m")))
	players[pid] = p
	_dirty = true
	net.to_client(pid, "s_welcome", [{
		"id": pid, "name": p.name, "x": p.pos.x, "y": p.pos.y, "party": p.party,
		"returning": saves.has(key),
	}])
	_toast_all("%s joined the world." % p.name, [pid])


func on_peer_disconnected(pid: int) -> void:
	if not players.has(pid):
		return
	var p: Dictionary = players[pid]
	if p.battle != "":
		var b: Dictionary = battles.get(p.battle, {})
		if not b.is_empty():
			var my_side := _side_index(b, pid)
			_log(b, "%s left the game." % p.name)
			_end_battle(b, 1 - my_side if my_side >= 0 else -1)
	if p.trade != "":
		_close_trade(p.trade, "%s left." % p.name)
	_stop_watching(p)
	_store_player(p)
	players.erase(pid)
	_write_saves()
	_toast_all("%s left the world." % p.name)


# ---------------------------------------------------------------- world sync

func _broadcast_world() -> void:
	if players.is_empty():
		return
	var plist := []
	for p in players.values():
		var lead: String = p.party[0].species if p.party.size() > 0 else ""
		plist.append([p.id, p.name, p.pos.x, p.pos.y, p.dir, p.status, p.color, lead])
	var wlist := []
	for w in wilds.values():
		wlist.append([w.id, w.species, w.pos.x, w.pos.y, w.level, w.in_battle])
	for pid in players:
		if pid == multiplayer.get_unique_id():
			net.s_world(plist, wlist)
		elif pid in multiplayer.get_peers():
			net.rpc_id(pid, "s_world", plist, wlist)


func _occupied_by_wild(pos: Vector2i) -> String:
	for w in wilds.values():
		if w.pos == pos:
			return w.id
	return ""


func _occupied_by_player(pos: Vector2i) -> bool:
	for p in players.values():
		if p.pos == pos:
			return true
	return false


func _spawn_wild() -> void:
	for attempt in 60:
		var pos := Vector2i(rng.randi_range(1, GameData.MAP_W - 2), rng.randi_range(1, GameData.MAP_H - 2))
		if GameData.tile_at(pos) != GameData.T.TALL:
			continue
		if _occupied_by_wild(pos) != "" or _occupied_by_player(pos):
			continue
		var species := GameData.pick_wild_species(rng)
		var dist := Vector2(pos).distance_to(Vector2(GameData.town_center))
		var level := clampi(2 + int(dist / 5.0) + rng.randi_range(-1, 1), 2, 30)
		var id := _new_id("w")
		wilds[id] = {"id": id, "species": species, "level": level, "pos": pos, "in_battle": false}
		return


func _wander_wilds() -> void:
	var dirs := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for w in wilds.values():
		if w.in_battle or rng.randf() > 0.4:
			continue
		var np: Vector2i = w.pos + dirs[rng.randi() % 4]
		var t := GameData.tile_at(np)
		if t != GameData.T.TALL and t != GameData.T.GRASS:
			continue
		# stay close to tall grass: only step onto short grass next to tall grass
		if t == GameData.T.GRASS and not _near_tall(np):
			continue
		if _occupied_by_wild(np) != "" or _occupied_by_player(np):
			continue
		w.pos = np


func _near_tall(p: Vector2i) -> bool:
	for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if GameData.tile_at(p + d) == GameData.T.TALL:
			return true
	return false


# ---------------------------------------------------------------- movement

func on_move(pid: int, target: Vector2i, dir: int) -> void:
	if not players.has(pid):
		return
	var p: Dictionary = players[pid]
	p.dir = dir
	if p.status != "free":
		net.to_client(pid, "s_teleport", [p.pos.x, p.pos.y])
		return
	var step: Vector2i = target - p.pos
	if absi(step.x) + absi(step.y) != 1 or not GameData.walkable(target):
		net.to_client(pid, "s_teleport", [p.pos.x, p.pos.y])
		return
	var wid := _occupied_by_wild(target)
	if wid != "":
		if not wilds[wid].in_battle:
			_start_wild_battle(p, wilds[wid])
		net.to_client(pid, "s_teleport", [p.pos.x, p.pos.y])
		return
	p.pos = target
	if target == GameData.heal_tile:
		_heal_party(p)
		net.to_client(pid, "s_party", [p.party])
		net.to_client(pid, "s_toast", ["Your monsters are fully healed!"])


func _heal_party(p: Dictionary) -> void:
	for m in p.party:
		m.hp = m.max_hp


func on_set_lead(pid: int, index: int) -> void:
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or p.status != "free" or index <= 0 or index >= p.party.size():
		return
	var m = p.party[index]
	p.party.remove_at(index)
	p.party.insert(0, m)
	net.to_client(pid, "s_party", [p.party])


# ---------------------------------------------------------------- requests (battle / trade)

func on_request(pid: int, kind: String, target: int) -> void:
	if not players.has(pid) or not players.has(target) or pid == target:
		return
	if kind != "battle" and kind != "trade":
		return
	var a: Dictionary = players[pid]
	var b: Dictionary = players[target]
	if a.status != "free":
		net.to_client(pid, "s_toast", ["Finish what you're doing first."])
		return
	if b.status != "free":
		net.to_client(pid, "s_toast", ["%s is busy right now." % b.name])
		return
	if kind == "battle" and not _has_healthy(a):
		net.to_client(pid, "s_toast", ["Your monsters need healing first (pink pad in town)."])
		return
	requests["%s:%d:%d" % [kind, pid, target]] = Time.get_unix_time_from_system()
	net.to_client(target, "s_request", [kind, pid, a.name])
	net.to_client(pid, "s_toast", ["Asked %s to %s..." % [b.name, kind]])


func on_respond(pid: int, kind: String, from_id: int, accept: bool) -> void:
	var key := "%s:%d:%d" % [kind, from_id, pid]
	if not requests.has(key):
		return
	var age := Time.get_unix_time_from_system() - float(requests[key])
	requests.erase(key)
	if not players.has(from_id) or not players.has(pid):
		return
	var asker: Dictionary = players[from_id]
	var me: Dictionary = players[pid]
	if not accept:
		net.to_client(from_id, "s_toast", ["%s said no." % me.name])
		return
	if age > 60.0 or asker.status != "free" or me.status != "free":
		net.to_client(pid, "s_toast", ["That request has expired."])
		return
	if kind == "battle":
		if not _has_healthy(me):
			net.to_client(pid, "s_toast", ["Your monsters need healing first."])
			net.to_client(from_id, "s_toast", ["%s's monsters need healing first." % me.name])
			return
		_start_pvp_battle(asker, me)
	else:
		_start_trade(asker, me)


func _has_healthy(p: Dictionary) -> bool:
	for m in p.party:
		if m.hp > 0:
			return true
	return false


# ---------------------------------------------------------------- spectating

func on_watch(pid: int, target: int) -> void:
	if not players.has(pid) or not players.has(target):
		return
	var me: Dictionary = players[pid]
	var t: Dictionary = players[target]
	if me.status != "free":
		return
	_stop_watching(me)
	if t.battle != "" and battles.has(t.battle):
		var b: Dictionary = battles[t.battle]
		b.spectators.append(pid)
		me.watching = b.id
		me.status = "watching"
		_send_battle_to(b, pid)
	elif t.trade != "" and trades.has(t.trade):
		var trd: Dictionary = trades[t.trade]
		trd.watchers.append(pid)
		me.watching = trd.id
		me.status = "watching"
		net.to_client(pid, "s_trade", [_trade_state(trd, pid)])
	else:
		net.to_client(pid, "s_toast", ["%s isn't battling or trading." % t.name])


func on_stop_watching(pid: int) -> void:
	if players.has(pid):
		_stop_watching(players[pid])


func _stop_watching(p: Dictionary) -> void:
	if p.watching == "":
		return
	if battles.has(p.watching):
		battles[p.watching].spectators.erase(p.id)
	if trades.has(p.watching):
		trades[p.watching].watchers.erase(p.id)
	p.watching = ""
	if p.status == "watching":
		p.status = "free"


# ---------------------------------------------------------------- battles

func _make_side(p: Dictionary) -> Dictionary:
	var active := 0
	for i in p.party.size():
		if p.party[i].hp > 0:
			active = i
			break
	return {"pid": p.id, "name": p.name, "party": p.party, "active": active,
		"action": {}, "must_switch": false, "wild_id": ""}


func _start_wild_battle(p: Dictionary, w: Dictionary) -> void:
	if not _has_healthy(p):
		net.to_client(p.id, "s_toast", ["Your monsters need healing first (pink pad in town)."])
		return
	w.in_battle = true
	var mon := GameData.make_monster(w.species, w.level, _new_id("m"))
	var wild_side := {"pid": -1, "name": "Wild " + GameData.mon_name(mon), "party": [mon],
		"active": 0, "action": {}, "must_switch": false, "wild_id": w.id}
	var b := _new_battle("wild", _make_side(p), wild_side)
	_log(b, "A wild %s (Lv %d) appeared!" % [GameData.mon_name(mon), mon.level])
	_log(b, "Go, %s!" % GameData.mon_name(_active(b.sides[0])))
	_broadcast_battle(b)


func _start_pvp_battle(a: Dictionary, c: Dictionary) -> void:
	var b := _new_battle("pvp", _make_side(a), _make_side(c))
	_log(b, "%s challenged %s!" % [a.name, c.name])
	_log(b, "%s sent out %s. %s sent out %s." % [a.name, GameData.mon_name(_active(b.sides[0])),
		c.name, GameData.mon_name(_active(b.sides[1]))])
	_broadcast_battle(b)


func _new_battle(kind: String, s0: Dictionary, s1: Dictionary) -> Dictionary:
	var id := _new_id("b")
	var b := {"id": id, "kind": kind, "sides": [s0, s1], "turn": 1, "log": [],
		"new": [], "spectators": [], "over": false, "result": ""}
	battles[id] = b
	for s in b.sides:
		if s.pid >= 0 and players.has(s.pid):
			var p: Dictionary = players[s.pid]
			_stop_watching(p)
			p.status = "battle"
			p.battle = id
	return b


func _active(side: Dictionary) -> Dictionary:
	return side.party[side.active]


func _side_index(b: Dictionary, pid: int) -> int:
	for i in 2:
		if b.sides[i].pid == pid:
			return i
	return -1


func _log(b: Dictionary, line: String) -> void:
	b.log.append(line)
	b.new.append(line)
	if b.log.size() > 40:
		b.log.pop_front()


func on_battle_action(pid: int, kind: String, index: int) -> void:
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or p.battle == "" or not battles.has(p.battle):
		return
	var b: Dictionary = battles[p.battle]
	if b.over:
		return
	var si := _side_index(b, pid)
	var side: Dictionary = b.sides[si]
	var foe: Dictionary = b.sides[1 - si]

	# forced switch after a faint
	if side.must_switch:
		if kind == "switch" and _valid_switch(side, index):
			side.active = index
			side.must_switch = false
			_log(b, "%s sent out %s!" % [side.name, GameData.mon_name(_active(side))])
			_broadcast_battle(b)
		return
	if foe.must_switch:
		return # wait for the other player to pick
	if not side.action.is_empty():
		return # already chose this turn

	match kind:
		"move":
			if index < 0 or index >= _active(side).moves.size():
				return
		"switch":
			if not _valid_switch(side, index) or index == side.active:
				return
		"run", "catch":
			if b.kind != "wild":
				return
		"forfeit":
			pass
		_:
			return
	side.action = {"kind": kind, "index": index}

	if kind == "forfeit":
		_log(b, "%s forfeited." % side.name)
		_end_battle(b, 1 - si)
		return

	# the wild side picks instantly
	if foe.pid == -1:
		foe.action = {"kind": "move", "index": rng.randi() % _active(foe).moves.size()}
	if b.sides[0].action.is_empty() or b.sides[1].action.is_empty():
		_broadcast_battle(b) # show "waiting for opponent"
		return
	_resolve_turn(b)


func _valid_switch(side: Dictionary, index: int) -> bool:
	return index >= 0 and index < side.party.size() and side.party[index].hp > 0


func _resolve_turn(b: Dictionary) -> void:
	var order := [0, 1]
	var prio := func(si: int) -> Array:
		var a: Dictionary = b.sides[si].action
		var mon := _active(b.sides[si])
		match a.kind:
			"switch", "run", "catch":
				return [10, mon.spd]
			"move":
				var mv: Dictionary = GameData.moves[mon.moves[a.index]]
				return [int(mv.get("priority", 0)), mon.spd]
		return [0, mon.spd]
	var p0: Array = prio.call(0)
	var p1: Array = prio.call(1)
	if p1[0] > p0[0] or (p1[0] == p0[0] and (p1[1] > p0[1] or (p1[1] == p0[1] and rng.randf() < 0.5))):
		order = [1, 0]

	for si in order:
		if b.over:
			break
		var side: Dictionary = b.sides[si]
		var a: Dictionary = side.action
		if _active(side).hp <= 0:
			continue # fainted before acting
		match a.kind:
			"switch":
				_log(b, "%s called back %s and sent out %s!" % [side.name,
					GameData.mon_name(_active(side)), GameData.mon_name(side.party[a.index])])
				side.active = a.index
			"run":
				if rng.randf() < 0.85:
					_log(b, "Got away safely!")
					_end_battle(b, -1)
				else:
					_log(b, "Couldn't get away!")
			"catch":
				_try_catch(b, si)
			"move":
				_do_move(b, si, 1 - si, a.index)

	for s in b.sides:
		s.action = {}
	b.turn += 1
	if not b.over:
		_broadcast_battle(b)


func _do_move(b: Dictionary, si: int, ti: int, move_index: int) -> void:
	var atk_side: Dictionary = b.sides[si]
	var def_side: Dictionary = b.sides[ti]
	var atk := _active(atk_side)
	var def := _active(def_side)
	var move_id: String = atk.moves[move_index]
	var mv: Dictionary = GameData.moves[move_id]
	var who := GameData.mon_name(atk) if atk_side.pid >= 0 else "Wild " + GameData.mon_name(atk)
	_log(b, "%s used %s!" % [who, mv.name])
	if rng.randi_range(1, 100) > int(mv.accuracy):
		_log(b, "It missed!")
		return
	var def_types: Array = GameData.monsters[def.species].types
	var mult := GameData.type_multiplier(mv.type, def_types)
	var stab := 1.5 if mv.type in GameData.monsters[atk.species].types else 1.0
	var crit := 1.5 if rng.randf() < 1.0 / 16.0 else 1.0
	var base_dmg: float = ((2.0 * atk.level / 5.0 + 2.0) * float(mv.power) * float(atk.atk) / float(def.def)) / 50.0 + 2.0
	var dmg := int(base_dmg * stab * mult * crit * rng.randf_range(0.85, 1.0))
	if mult > 0.0:
		dmg = max(dmg, 1)
	def.hp = max(0, def.hp - dmg)
	if crit > 1.0:
		_log(b, "A critical hit!")
	if mult >= 2.0:
		_log(b, "It's super effective!")
	elif mult > 0.0 and mult < 1.0:
		_log(b, "It's not very effective...")
	if def.hp <= 0:
		_on_faint(b, si, ti)


func _on_faint(b: Dictionary, winner_si: int, loser_si: int) -> void:
	var w_side: Dictionary = b.sides[winner_si]
	var l_side: Dictionary = b.sides[loser_si]
	var fainted := _active(l_side)
	var fname := GameData.mon_name(fainted) if l_side.pid >= 0 else "Wild " + GameData.mon_name(fainted)
	_log(b, "%s fainted!" % fname)
	if w_side.pid >= 0:
		var gain := int(fainted.level * (8 if b.kind == "wild" else 12))
		for line in GameData.give_xp(_active(w_side), gain):
			_log(b, line)
	# does the loser have anything left?
	for i in l_side.party.size():
		if l_side.party[i].hp > 0:
			l_side.must_switch = true
			_log(b, "%s must choose another monster." % l_side.name)
			return
	_end_battle(b, winner_si)


func _try_catch(b: Dictionary, si: int) -> void:
	var side: Dictionary = b.sides[si]
	var wild_side: Dictionary = b.sides[1 - si]
	var mon := _active(wild_side)
	var p: Dictionary = players[side.pid]
	_log(b, "%s threw a Catch Orb!" % side.name)
	var rate: float = GameData.monsters[mon.species].catch_rate / 255.0
	var chance := clampf(rate * (1.0 - 0.66 * mon.hp / float(mon.max_hp)) + 0.08, 0.05, 0.95)
	if rng.randf() < chance:
		_log(b, "Gotcha! %s was caught!" % GameData.mon_name(mon))
		if p.party.size() < GameData.PARTY_MAX:
			p.party.append(mon)
		else:
			p.box.append(mon)
			_log(b, "%s was sent to the storage box." % GameData.mon_name(mon))
		_dirty = true
		_end_battle(b, si)
	else:
		_log(b, "Oh no! It broke free!")


func _end_battle(b: Dictionary, winner_si: int) -> void:
	if b.over:
		return
	b.over = true
	if winner_si >= 0:
		b.result = "%s won!" % b.sides[winner_si].name
	else:
		b.result = "The battle ended."
	_log(b, b.result)

	for si in 2:
		var s: Dictionary = b.sides[si]
		if s.pid < 0:
			# wild monster: defeated / caught ones disappear, others go back to roaming
			if wilds.has(s.wild_id):
				if winner_si == si or winner_si == -1:
					wilds[s.wild_id].in_battle = false
				else:
					wilds.erase(s.wild_id)
			continue
		if not players.has(s.pid):
			continue
		var p: Dictionary = players[s.pid]
		if b.kind == "pvp":
			_heal_party(p) # friendly battles: everyone is healed afterwards
		elif not _has_healthy(p):
			_heal_party(p)
			p.pos = GameData.spawn_point(rng)
			_log(b, "%s hurried back to town to heal." % p.name)
			net.to_client(p.id, "s_teleport", [p.pos.x, p.pos.y])
		p.status = "free"
		p.battle = ""
		net.to_client(p.id, "s_party", [p.party])

	_broadcast_battle(b)
	for pid in b.spectators:
		if players.has(pid):
			players[pid].watching = ""
			players[pid].status = "free"
	battles.erase(b.id)
	_dirty = true


func _battle_state(b: Dictionary, viewer: int) -> Dictionary:
	var sides := []
	for s in b.sides:
		var party := []
		for m in s.party:
			party.append({"uid": m.uid, "species": m.species, "level": m.level, "hp": m.hp,
				"max_hp": m.max_hp, "moves": m.moves, "xp": m.xp})
		sides.append({"pid": s.pid, "name": s.name, "active": s.active, "party": party,
			"ready": not s.action.is_empty(), "must_switch": s.must_switch})
	return {"id": b.id, "kind": b.kind, "turn": b.turn, "sides": sides,
		"you": _side_index(b, viewer), "new": b.new.duplicate(), "log": b.log.duplicate(),
		"over": b.over, "result": b.result}


func _send_battle_to(b: Dictionary, pid: int) -> void:
	var state := _battle_state(b, pid)
	state.new = [] # a newly joined spectator just sees the log
	net.to_client(pid, "s_battle", [state])


func _broadcast_battle(b: Dictionary) -> void:
	var viewers := []
	for s in b.sides:
		if s.pid >= 0:
			viewers.append(s.pid)
	viewers.append_array(b.spectators)
	for pid in viewers:
		if players.has(pid):
			net.to_client(pid, "s_battle", [_battle_state(b, pid)])
	b.new.clear()


# ---------------------------------------------------------------- trades

func _start_trade(a: Dictionary, c: Dictionary) -> void:
	var id := _new_id("t")
	var trd := {"id": id, "a": a.id, "b": c.id, "offer": {a.id: "", c.id: ""},
		"confirm": {a.id: false, c.id: false}, "watchers": []}
	trades[id] = trd
	for p in [a, c]:
		_stop_watching(p)
		p.status = "trade"
		p.trade = id
	_send_trade(trd)


func _find_mon(p: Dictionary, uid: String) -> int:
	for i in p.party.size():
		if p.party[i].uid == uid:
			return i
	return -1


func on_trade_offer(pid: int, uid: String) -> void:
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or not trades.has(p.trade):
		return
	var trd: Dictionary = trades[p.trade]
	if uid != "" and _find_mon(p, uid) < 0:
		return
	trd.offer[pid] = uid
	for k in trd.confirm:
		trd.confirm[k] = false # any change resets both confirmations
	_send_trade(trd)


func on_trade_confirm(pid: int) -> void:
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or not trades.has(p.trade):
		return
	var trd: Dictionary = trades[p.trade]
	if trd.offer[trd.a] == "" or trd.offer[trd.b] == "":
		net.to_client(pid, "s_toast", ["Both players need to offer a monster."])
		return
	trd.confirm[pid] = true
	if trd.confirm[trd.a] and trd.confirm[trd.b]:
		var pa: Dictionary = players[trd.a]
		var pb: Dictionary = players[trd.b]
		var ia := _find_mon(pa, trd.offer[trd.a])
		var ib := _find_mon(pb, trd.offer[trd.b])
		if ia < 0 or ib < 0:
			_close_trade(trd.id, "Trade failed.")
			return
		var ma = pa.party[ia]
		var mb = pb.party[ib]
		pa.party[ia] = mb
		pb.party[ib] = ma
		var msg := "%s traded %s for %s's %s!" % [pa.name, GameData.mon_name(ma), pb.name, GameData.mon_name(mb)]
		_dirty = true
		_close_trade(trd.id, msg)
		_toast_all(msg, [trd.a, trd.b])
	else:
		_send_trade(trd)


func on_trade_cancel(pid: int) -> void:
	var p: Dictionary = players.get(pid, {})
	if p.is_empty() or not trades.has(p.trade):
		return
	_close_trade(p.trade, "%s cancelled the trade." % p.name)


func _close_trade(tid: String, msg: String) -> void:
	if not trades.has(tid):
		return
	var trd: Dictionary = trades[tid]
	trades.erase(tid)
	for pid in [trd.a, trd.b]:
		if players.has(pid):
			var p: Dictionary = players[pid]
			p.status = "free"
			p.trade = ""
			net.to_client(pid, "s_trade_closed")
			net.to_client(pid, "s_party", [p.party])
			net.to_client(pid, "s_toast", [msg])
	for pid in trd.watchers:
		if players.has(pid):
			players[pid].watching = ""
			players[pid].status = "free"
			net.to_client(pid, "s_trade_closed")
			net.to_client(pid, "s_toast", [msg])


func _trade_state(trd: Dictionary, viewer: int) -> Dictionary:
	var sides := []
	for pid in [trd.a, trd.b]:
		var p: Dictionary = players[pid]
		var party := []
		for m in p.party:
			party.append({"uid": m.uid, "species": m.species, "level": m.level, "hp": m.hp, "max_hp": m.max_hp})
		var offered := {}
		var oi := _find_mon(p, trd.offer[pid])
		if oi >= 0:
			offered = party[oi]
		sides.append({"pid": pid, "name": p.name, "party": party, "offer": offered, "confirmed": trd.confirm[pid]})
	var you := -1
	if viewer == trd.a: you = 0
	elif viewer == trd.b: you = 1
	return {"id": trd.id, "sides": sides, "you": you}


func _send_trade(trd: Dictionary) -> void:
	for pid in [trd.a, trd.b] + trd.watchers:
		if players.has(pid):
			net.to_client(pid, "s_trade", [_trade_state(trd, pid)])


# ---------------------------------------------------------------- misc

func _toast_all(msg: String, except: Array = []) -> void:
	for pid in players:
		if not pid in except:
			net.to_client(pid, "s_toast", [msg])
