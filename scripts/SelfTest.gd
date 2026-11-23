extends Node
## Automated smoke test. Run scenes/SelfTest.tscn: hosts a local world, adds two
## bot players, and runs a wild battle, a catch, a PvP battle, spectating and trades.

var fails := 0
var main: Node
var _tick := 0.0


func _process(delta: float) -> void:
	_tick += delta
	if _tick >= 1.0:
		_tick = 0.0
		print("tick frame=%d wilds=%d" % [Engine.get_process_frames(), Net.server.wilds.size() if Net.server else -1])


func check(cond: bool, what: String) -> void:
	if cond:
		print("PASS  ", what)
	else:
		fails += 1
		printerr("FAIL  ", what)


func _ready() -> void:
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute("res://_shots")
	await shot("menu")
	Net.save_path = "user://selftest_save.json"
	DirAccess.remove_absolute("user://selftest_save.json")
	var err := Net.host_and_play(9091, "Tester", "embertail")
	check(err == OK, "host starts")
	await get_tree().create_timer(0.3).timeout
	var s = Net.server
	var world = main.get_node_or_null("World")
	check(world != null, "world created for host")

	s.on_hello(1001, "Bot", "splashkit")
	s.on_hello(1002, "bot", "sproutling")
	check(s.players[1002].name == "bot2", "duplicate names get a number")
	check(s.wilds.size() > 0, "wild monsters spawned")
	await get_tree().create_timer(0.3).timeout
	check(world.wilds.size() > 0, "client sees wild monsters")
	check(world.players.size() == 2, "client sees other players")
	world.my_pos = Vector2i(12, 13)
	await get_tree().create_timer(0.3).timeout
	await shot("world")

	# --- wild battle (host)
	var host = s.players[1]
	host.party[0].level = 30
	GameData.calc_stats(host.party[0])
	host.party[0].hp = host.party[0].max_hp
	check(_start_wild(s, 1), "walking into a wild monster starts a battle")
	await get_tree().process_frame
	check(world.battle_panel.visible, "battle screen opens")
	await get_tree().create_timer(0.6).timeout
	await shot("battle")
	# regression: the host's own buttons must come back after attacking
	await _skip_text(world)
	check(world.battle_ui_ready(), "battle menu appears after the intro text")
	world._open_moves()
	await get_tree().process_frame
	await shot("battle_moves")
	world._act("move", 0)
	await _skip_text(world)
	check(world.battle_ui_ready(), "host gets the menu back after attacking")
	check(_run_battle(s, [1]), "wild battle finishes")
	check(host.status == "free", "host free after battle")
	world._close_battle()

	# --- catching
	var before: int = host.party.size() + host.box.size()
	var caught := false
	for attempt in 8:
		host.party[0].hp = host.party[0].max_hp
		if not _start_wild(s, 1):
			continue
		for i in 40:
			if host.battle == "":
				break
			s.on_battle_action(1, "catch", 0)
		if host.party.size() + host.box.size() > before:
			caught = true
			break
	check(caught, "catching a wild monster adds it to the party")
	world._close_battle()

	# --- pvp battle between bots, host watches
	var b1 = s.players[1001]
	var b2 = s.players[1002]
	b1.party.append(GameData.make_monster("dustbun", 6, "x1"))
	b2.party.append(GameData.make_monster("buzzlet", 6, "x2"))
	s.on_request(1001, "battle", 1002)
	s.on_respond(1002, "battle", 1001, true)
	check(b1.status == "battle" and b2.status == "battle", "pvp battle starts after accept")
	s.on_watch(1, 1001)
	await get_tree().process_frame
	check(host.status == "watching", "host can watch a battle")
	check(world.battle_panel.visible and world.battle_state.you == -1, "spectator view opens")
	check(_run_battle(s, [1001, 1002]), "pvp battle finishes (with switching)")
	check(host.status == "free", "spectator freed after battle")
	world._close_battle()

	# --- trade host <-> bot
	s.on_request(1, "trade", 1001)
	s.on_respond(1001, "trade", 1, true)
	await get_tree().process_frame
	check(world.trade_panel.visible, "trade screen opens")
	var hu: String = host.party[0].uid
	var bu: String = b1.party[0].uid
	s.on_trade_offer(1, hu)
	s.on_trade_offer(1001, bu)
	await get_tree().process_frame
	await shot("trade")
	s.on_watch(1002, 1)
	check(b2.status == "watching", "others can watch a trade")
	s.on_trade_confirm(1)
	s.on_trade_confirm(1001)
	check(host.party[0].uid == bu and b1.party[0].uid == hu, "trade swaps the monsters")
	check(host.status == "free" and b2.status == "free", "everyone free after trade")
	await get_tree().process_frame
	check(not world.trade_panel.visible, "trade screen closes")

	# --- disconnect mid battle
	s.on_request(1001, "battle", 1002)
	s.on_respond(1002, "battle", 1001, true)
	s.on_peer_disconnected(1002)
	check(b1.status == "free" and not s.players.has(1002), "leaving mid-battle ends it cleanly")

	world.open_party("world")
	await get_tree().process_frame
	await shot("party")
	world._close_menus()
	world.open_start_menu()
	await get_tree().process_frame
	await shot("start_menu")
	world._close_menus()
	for pn in Gb.PALETTE_ORDER:
		Palette.apply(pn)
		await get_tree().process_frame
		await shot("palette_" + pn.replace(" ", "_"))
	Palette.apply("Pocket grey")
	print("SELFTEST DONE: %d failure(s)" % fails)
	for i in 20:
		await get_tree().create_timer(0.25).timeout
		print("alive ", i)
	# leave running so the output can be read


func _start_wild(s, pid: int) -> bool:
	var p = s.players[pid]
	for w in s.wilds.values():
		if w.in_battle:
			continue
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var n: Vector2i = w.pos + d
			if GameData.walkable(n) and s._occupied_by_wild(n) == "":
				p.pos = n
				s.on_move(pid, w.pos, 0)
				return p.status == "battle"
	return false


func _run_battle(s, pids: Array) -> bool:
	for i in 200:
		var bid: String = s.players[pids[0]].battle
		if bid == "" or not s.battles.has(bid):
			return true
		var b = s.battles[bid]
		for pid in pids:
			if not s.battles.has(bid):
				return true
			var side = b.sides[s._side_index(b, pid)]
			if side.must_switch:
				for j in side.party.size():
					if side.party[j].hp > 0:
						s.on_battle_action(pid, "switch", j)
						break
			else:
				s.on_battle_action(pid, "move", i % side.party[side.active].moves.size())
	return false


func shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_shots/%s.png" % shot_name)


func _skip_text(world) -> void:
	for i in 300:
		if not world.battle_text.is_busy():
			break
		world.battle_text.advance()
		await get_tree().process_frame
	await get_tree().process_frame
