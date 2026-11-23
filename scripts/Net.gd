extends Node
## Networking hub (autoload "Net").
## Every RPC lives here so the node path (/root/Net) is the same on all peers.
## The server is authoritative: clients only send requests, the server decides.
##
## Hosting from the game menu makes this computer peer 1 (server + player).
## Running with  --server  (e.g. Godot --headless -- --server) starts a
## dedicated server with no local player.

const DEFAULT_PORT := 9080
const ServerLogic := preload("res://scripts/Server.gd")

signal connected_ok
signal connection_failed(reason: String)
signal welcomed(me: Dictionary)
signal world_updated(players: Array, wilds: Array)
signal battle_updated(state: Dictionary)
signal battle_closed
signal request_received(kind: String, from_id: int, from_name: String)
signal trade_updated(state: Dictionary)
signal trade_closed
signal party_updated(party: Array)
signal teleported(pos: Vector2i)
signal toast(msg: String)

var server = null # ServerLogic instance, only on the server
var my_id := 0
var save_path := "user://server_save.json"
var pending_hello := {}


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): connection_failed.emit("Could not reach the server."))
	multiplayer.server_disconnected.connect(func(): connection_failed.emit("Lost connection to the server."))
	if "--server" in OS.get_cmdline_user_args() or "--server" in OS.get_cmdline_args():
		var port := DEFAULT_PORT
		var env_port := OS.get_environment("PORT")
		if env_port.is_valid_int():
			port = int(env_port)
		start_server(port)


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


# ---------------------------------------------------------------- start / join

func start_server(port: int) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	server = ServerLogic.new()
	server.name = "ServerLogic"
	server.net = self
	add_child(server)
	multiplayer.peer_disconnected.connect(server.on_peer_disconnected)
	print("Server listening on port %d" % port)
	return OK


func host_and_play(port: int, player_name: String, starter: String) -> Error:
	var err := start_server(port)
	if err != OK:
		return err
	my_id = 1
	c_hello(player_name, starter) # runs locally, we are the server
	return OK


func join(address: String, player_name: String, starter: String) -> Error:
	var url := address.strip_edges()
	for prefix in ["https://", "http://"]:
		if url.begins_with(prefix):
			url = url.substr(prefix.length())
	url = url.trim_suffix("/")
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		if _page_is_https():
			# a secure web page may only open secure (wss) connections
			url = "wss://" + url
		else:
			if not ":" in url:
				url += ":%d" % DEFAULT_PORT
			url = "ws://" + url
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	pending_hello = {"name": player_name, "starter": starter}
	return OK


func _page_is_https() -> bool:
	if not OS.has_feature("web"):
		return false
	return str(JavaScriptBridge.eval("window.location.protocol")) == "https:"


func _on_connected() -> void:
	my_id = multiplayer.get_unique_id()
	connected_ok.emit()
	to_server("c_hello", [pending_hello.name, pending_hello.starter])


# ---------------------------------------------------------------- helpers

## Client -> server. Works for remote clients and for the host's own player.
func to_server(method: String, args: Array = []) -> void:
	if multiplayer.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)


## Server -> one client. If the client is the host itself, call directly.
func to_client(pid: int, method: String, args: Array = []) -> void:
	if pid == multiplayer.get_unique_id():
		callv(method, args)
	elif pid in multiplayer.get_peers():
		callv("rpc_id", [pid, method] + args)


func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


# ---------------------------------------------------------------- client -> server

@rpc("any_peer", "reliable")
func c_hello(player_name: String, starter: String) -> void:
	if server: server.on_hello(_sender(), player_name, starter)

@rpc("any_peer", "reliable")
func c_move(x: int, y: int, dir: int) -> void:
	if server: server.on_move(_sender(), Vector2i(x, y), dir)

@rpc("any_peer", "reliable")
func c_battle_action(kind: String, index: int) -> void:
	if server: server.on_battle_action(_sender(), kind, index)

@rpc("any_peer", "reliable")
func c_request(kind: String, target: int) -> void:
	if server: server.on_request(_sender(), kind, target)

@rpc("any_peer", "reliable")
func c_respond(kind: String, from_id: int, accept: bool) -> void:
	if server: server.on_respond(_sender(), kind, from_id, accept)

@rpc("any_peer", "reliable")
func c_watch(target: int) -> void:
	if server: server.on_watch(_sender(), target)

@rpc("any_peer", "reliable")
func c_stop_watching() -> void:
	if server: server.on_stop_watching(_sender())

@rpc("any_peer", "reliable")
func c_trade_offer(uid: String) -> void:
	if server: server.on_trade_offer(_sender(), uid)

@rpc("any_peer", "reliable")
func c_trade_confirm() -> void:
	if server: server.on_trade_confirm(_sender())

@rpc("any_peer", "reliable")
func c_trade_cancel() -> void:
	if server: server.on_trade_cancel(_sender())

@rpc("any_peer", "reliable")
func c_set_lead(index: int) -> void:
	if server: server.on_set_lead(_sender(), index)


# ---------------------------------------------------------------- server -> client

@rpc("authority", "reliable")
func s_welcome(me: Dictionary) -> void:
	welcomed.emit(me)

@rpc("authority", "unreliable_ordered")
func s_world(players: Array, wilds: Array) -> void:
	world_updated.emit(players, wilds)

@rpc("authority", "reliable")
func s_battle(state: Dictionary) -> void:
	battle_updated.emit(state)

@rpc("authority", "reliable")
func s_battle_closed() -> void:
	battle_closed.emit()

@rpc("authority", "reliable")
func s_request(kind: String, from_id: int, from_name: String) -> void:
	request_received.emit(kind, from_id, from_name)

@rpc("authority", "reliable")
func s_trade(state: Dictionary) -> void:
	trade_updated.emit(state)

@rpc("authority", "reliable")
func s_trade_closed() -> void:
	trade_closed.emit()

@rpc("authority", "reliable")
func s_party(party: Array) -> void:
	party_updated.emit(party)

@rpc("authority", "reliable")
func s_teleport(x: int, y: int) -> void:
	teleported.emit(Vector2i(x, y))

@rpc("authority", "reliable")
func s_toast(msg: String) -> void:
	toast.emit(msg)
