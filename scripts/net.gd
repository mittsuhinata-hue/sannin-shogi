extends Node
## 通信と対局の進行（自動読み込み名: Net）。
##
## ・ネット対戦：中継サーバー（Godot をヘッドレスで動かしたもの）に WebSocket でつなぐ。
##   サーバーは「部屋」をいくつでも持てる。部屋コードを知っている人が同じ部屋に入る。
##   盤面の正本はサーバーが持ち、合法か確かめてから部屋の全員に配る。
## ・この端末だけ：同じ部屋の仕組みを、この端末の中だけで動かす。

const Rules = preload("res://scripts/rules.gd")

signal room_changed        ## 部屋の顔ぶれが変わった
signal game_started
signal state_changed
signal message(text: String)
signal kicked_to_title

## Render に置いた中継サーバー。https のページからは wss:// でつなぐ。
const DEFAULT_SERVER := "wss://sannin-shogi.onrender.com"
const DEFAULT_PORT := 24565
const ID_CPU := 0
const ID_LOCAL := -2
const CPU_DELAY := 0.6
const UNDO_WAIT := 2.0
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

enum Mode { NONE, ONLINE, LOCAL, SERVER }

var mode: int = Mode.NONE
var my_name := "プレイヤー"

# ---- 部屋にいる人（この端末）から見た情報 ----
var room_code := ""
var members: Array = []   ## [{"id": int, "name": String}]
var owner_id := 0
var seats: Array = []     ## 3席 [{"id": int, "name": String}]  id 0=CPU, -2=この端末
var my_seat := -1
var state: Dictionary = {}
var in_game := false

# ---- サーバー側（とこの端末だけで遊ぶとき）の部屋 ----
var _rooms := {}          ## 部屋コード → room（Dictionary）
var _peer_room := {}      ## peer id → 部屋コード
var _local_room: Dictionary = {}

var _pending: Callable    ## 接続できたらやること
var test_rooms := false   ## サーバーのテスト用


func _process(_dt: float) -> void:
	if mode == Mode.SERVER:
		for code in _rooms.keys():
			_cpu_tick(_rooms[code])
	elif mode == Mode.LOCAL and not _local_room.is_empty():
		_cpu_tick(_local_room)


func is_owner() -> bool:
	return mode == Mode.ONLINE and owner_id == multiplayer.get_unique_id()


# =====================================================================
#  サーバーとして動く（Render 上で godot --headless -- --server）
# =====================================================================

func start_server(port: int) -> Error:
	leave()
	var p := WebSocketMultiplayerPeer.new()
	var err := p.create_server(port)
	if err != OK:
		print("サーバーを開始できません: ", err)
		return err
	multiplayer.multiplayer_peer = p
	multiplayer.peer_disconnected.connect(_server_peer_left)
	mode = Mode.SERVER
	print("三人将棋サーバー起動 ポート ", port)
	return OK


func _new_code() -> String:
	for _try in 100:
		var c := ""
		for i in 4:
			c += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not _rooms.has(c):
			return c
	return str(randi())


func _clean_name(n: String) -> String:
	var s := n.strip_edges().substr(0, 16)
	return s if s != "" else "プレイヤー"


@rpc("any_peer", "reliable")
func _create_room(player_name: String) -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	_server_leave_room(id)
	var code := _new_code()
	_rooms[code] = {"code": code, "members": [], "owner": id, "seats": [], "state": {}, "in_game": false, "cpu_at": 0.0}
	_server_join(id, code, player_name)


@rpc("any_peer", "reliable")
func _join_room(code: String, player_name: String) -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	code = code.strip_edges().to_upper()
	if not _rooms.has(code) and test_rooms and code != "":
		# テスト用：無い部屋コードに入ろうとしたら、その部屋を作る
		_rooms[code] = {"code": code, "members": [], "owner": id, "seats": [], "state": {}, "in_game": false, "cpu_at": 0.0}
	if not _rooms.has(code):
		_error.rpc_id(id, "部屋 %s が見つかりません" % code)
		return
	var room: Dictionary = _rooms[code]
	if room["in_game"]:
		_error.rpc_id(id, "部屋 %s はもう対局中です" % code)
		return
	if room["members"].size() >= 3:
		_error.rpc_id(id, "部屋 %s は満員です" % code)
		return
	_server_leave_room(id)
	_server_join(id, code, player_name)


func _server_join(id: int, code: String, player_name: String) -> void:
	var room: Dictionary = _rooms[code]
	room["members"].append({"id": id, "name": _clean_name(player_name)})
	_peer_room[id] = code
	_room_info.rpc_id(id, code)
	_send_members(room)
	print("部屋 %s に参加 (%d人)" % [code, room["members"].size()])


func _send_members(room: Dictionary) -> void:
	for m in room["members"]:
		_members_update.rpc_id(m["id"], room["members"], room["owner"], room["in_game"])


@rpc("any_peer", "reliable")
func _start_room() -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	var room := _room_of(id)
	if room.is_empty() or room["owner"] != id:
		return
	var seats_new: Array = []
	for i in 3:
		if i < room["members"].size():
			seats_new.append({"id": room["members"][i]["id"], "name": room["members"][i]["name"]})
		else:
			seats_new.append({"id": ID_CPU, "name": "CPU%d" % i})
	room["seats"] = seats_new
	room["state"] = Rules.new_game()
	Rules.pick_first(room["state"], _seat_names(seats_new))
	room["in_game"] = true
	for m in room["members"]:
		_begin.rpc_id(m["id"], seats_new)
	_send_members(room)
	_push(room)


@rpc("any_peer", "reliable")
func _req_move(m: Dictionary) -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	var room := _room_of(id)
	if not room.is_empty():
		_room_try_move(room, _seat_in(room, id), m)


@rpc("any_peer", "reliable")
func _req_resign() -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	var room := _room_of(id)
	if room.is_empty() or room["state"].is_empty():
		return
	var seat := _seat_in(room, id)
	if seat >= 0:
		Rules.resign(room["state"], seat)
		room["prev"] = {}   # 投了のあとは待ったできない
		room["state"]["undo_seat"] = -1
		_push(room)


@rpc("any_peer", "reliable")
func _leave_room() -> void:
	if mode == Mode.SERVER:
		_server_leave_room(multiplayer.get_remote_sender_id())


func _server_peer_left(id: int) -> void:
	_server_leave_room(id)


func _server_leave_room(id: int) -> void:
	if not _peer_room.has(id):
		return
	var code: String = _peer_room[id]
	_peer_room.erase(id)
	if not _rooms.has(code):
		return
	var room: Dictionary = _rooms[code]
	for i in range(room["members"].size() - 1, -1, -1):
		if room["members"][i]["id"] == id:
			room["members"].remove_at(i)
	if room["members"].is_empty():
		_rooms.erase(code)
		print("部屋 %s を閉じました" % code)
		return
	if room["owner"] == id:
		room["owner"] = room["members"][0]["id"]
	if room["in_game"]:
		for s in room["seats"]:
			if s["id"] == id:
				s["id"] = ID_CPU
				s["name"] = str(s["name"]) + "（切断→CPU）"
		for m in room["members"]:
			_seats_update.rpc_id(m["id"], room["seats"])
		_push(room)
	_send_members(room)


func _room_of(id: int) -> Dictionary:
	if _peer_room.has(id) and _rooms.has(_peer_room[id]):
		return _rooms[_peer_room[id]]
	return {}


# =====================================================================
#  部屋の進行（サーバーとこの端末だけの両方で使う）
# =====================================================================

func _seat_names(s: Array) -> Array:
	var out: Array = []
	for x in s:
		out.append(str(x["name"]))
	return out


func _seat_in(room: Dictionary, id: int) -> int:
	for i in room["seats"].size():
		if room["seats"][i]["id"] == id:
			return i
	return -1


func _room_try_move(room: Dictionary, seat: int, m: Dictionary) -> void:
	var st: Dictionary = room["state"]
	if st.is_empty() or st["winner"] >= 0 or seat < 0 or seat != st["turn"]:
		return
	if not Rules.is_legal(st, seat, m):
		return
	# 待ったに備えて、指す前の盤面をとっておく（手番ごとに1回まで）
	var used: Array = room.get("undo_used", [false, false, false])
	var undoable: bool = not used[seat]
	used[seat] = false
	room["undo_used"] = used
	var before := Rules.copy_state(st)
	Rules.apply_move(st, m)
	room["prev"] = before if undoable else {}
	st["undo_seat"] = seat if undoable and st["winner"] < 0 else -1
	_push(room)


## 待った：いま指したばかりの人が、次の人が指す前に取り消す
func _room_undo(room: Dictionary, seat: int) -> void:
	var st: Dictionary = room["state"]
	var prev: Dictionary = room.get("prev", {})
	if seat < 0 or st.is_empty() or prev.is_empty() or st["winner"] >= 0 or st.get("undo_seat", -1) != seat:
		return
	room["prev"] = {}
	prev["undo_seat"] = -1
	prev["log"].append("%s が待った" % str(room["seats"][seat]["name"]))
	room["undo_used"][seat] = true
	room["state"] = prev
	_push(room)


## 部屋の全員に盤面を送る。CPU の番なら少し待ってから指す。
func _push(room: Dictionary) -> void:
	var st: Dictionary = room["state"]
	if mode == Mode.LOCAL:
		state = st
		state_changed.emit()
	else:
		for m in room["members"]:
			_sync.rpc_id(m["id"], st)
	room["cpu_at"] = 0.0
	if not st.is_empty() and st["winner"] < 0 and room["seats"][st["turn"]]["id"] == ID_CPU:
		# 人が指した直後は、待ったできるように少し長めに待つ
		var wait := UNDO_WAIT if st.get("undo_seat", -1) >= 0 else CPU_DELAY
		room["cpu_at"] = Time.get_ticks_msec() / 1000.0 + wait


func _cpu_tick(room: Dictionary) -> void:
	if room.get("cpu_at", 0.0) <= 0.0 or Time.get_ticks_msec() / 1000.0 < room["cpu_at"]:
		return
	room["cpu_at"] = 0.0
	var st: Dictionary = room["state"]
	if st.is_empty() or st["winner"] >= 0:
		return
	var t: int = st["turn"]
	if room["seats"][t]["id"] != ID_CPU:
		return
	var m := Rules.cpu_choose(st, t)
	if m.is_empty():
		Rules.resign(st, t)
	else:
		Rules.apply_move(st, m)
	room["prev"] = {}
	st["undo_seat"] = -1
	_push(room)


# =====================================================================
#  プレイヤー側
# =====================================================================

func _connect(url: String, then: Callable) -> void:
	leave()
	var p := WebSocketMultiplayerPeer.new()
	var err := p.create_client(url)
	if err != OK:
		message.emit("接続を始められませんでした（エラー %d）" % err)
		return
	multiplayer.multiplayer_peer = p
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_failed)
		multiplayer.server_disconnected.connect(_on_server_gone)
	mode = Mode.ONLINE
	_pending = then
	message.emit("サーバーに接続中…（しばらく使われていないと、起きるまで1分ほどかかります）")


func create_room(url: String, player_name: String) -> void:
	my_name = player_name
	_connect(url, func(): _create_room.rpc_id(1, my_name))


func join_room(url: String, code: String, player_name: String) -> void:
	my_name = player_name
	var c := code.strip_edges().to_upper()
	if c == "":
		message.emit("部屋コードを入れてください")
		return
	_connect(url, func(): _join_room.rpc_id(1, c, my_name))


func start_game() -> void:
	if mode == Mode.ONLINE:
		_start_room.rpc_id(1)
	elif mode == Mode.LOCAL:
		var humans := 0
		for s in seats:
			if s["id"] == ID_LOCAL:
				humans += 1
		start_local(humans, my_name)


func _on_connected() -> void:
	if mode != Mode.ONLINE:
		return
	message.emit("接続しました")
	if _pending.is_valid():
		_pending.call()


func _on_failed() -> void:
	if mode != Mode.ONLINE:
		return
	leave()
	message.emit("サーバーにつながりませんでした。少し待ってからもう一度押してください")
	kicked_to_title.emit()


func _on_server_gone() -> void:
	if mode != Mode.ONLINE:
		return
	leave()
	message.emit("サーバーとの接続が切れました")
	kicked_to_title.emit()


@rpc("authority", "reliable")
func _room_info(code: String) -> void:
	room_code = code
	message.emit("部屋 %s に入りました" % code)
	room_changed.emit()


@rpc("authority", "reliable")
func _members_update(list: Array, owner: int, playing: bool) -> void:
	members = list
	owner_id = owner
	in_game = playing
	room_changed.emit()


@rpc("authority", "reliable")
func _error(text: String) -> void:
	message.emit(text)


@rpc("authority", "reliable")
func _begin(s: Array) -> void:
	seats = s
	my_seat = -1
	var me := multiplayer.get_unique_id()
	for i in seats.size():
		if seats[i]["id"] == me:
			my_seat = i
	in_game = true
	game_started.emit()


@rpc("authority", "reliable")
func _seats_update(s: Array) -> void:
	seats = s
	state_changed.emit()


@rpc("authority", "reliable")
func _sync(s: Dictionary) -> void:
	state = s
	state_changed.emit()


## この端末だけで遊ぶ。humans: 人が操作する席の数（残りはCPU）
func start_local(humans: int, player_name: String) -> void:
	leave()
	mode = Mode.LOCAL
	my_name = player_name
	seats = []
	for i in 3:
		if i < humans:
			var nm := player_name if humans == 1 else Rules.player_name_default(i)
			seats.append({"id": ID_LOCAL, "name": nm})
		else:
			seats.append({"id": ID_CPU, "name": "CPU%d" % i})
	my_seat = 0 if humans == 1 else -1
	in_game = true
	_local_room = {"members": [], "seats": seats, "state": Rules.new_game(), "cpu_at": 0.0}
	Rules.pick_first(_local_room["state"], _seat_names(seats))
	state = _local_room["state"]
	game_started.emit()
	_push(_local_room)


func leave() -> void:
	if mode == Mode.ONLINE and multiplayer.multiplayer_peer is WebSocketMultiplayerPeer \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_leave_room.rpc_id(1)
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.NONE
	room_code = ""
	members = []
	owner_id = 0
	seats = []
	my_seat = -1
	state = {}
	in_game = false
	_local_room = {}
	_rooms = {}
	_peer_room = {}
	_pending = Callable()


## いまこの端末で動かせる席（なければ -1）
func controllable_seat() -> int:
	if state.is_empty() or state["winner"] >= 0:
		return -1
	if mode == Mode.LOCAL:
		var t: int = state["turn"]
		return t if seats[t]["id"] == ID_LOCAL else -1
	return my_seat


func submit_move(m: Dictionary) -> void:
	match mode:
		Mode.LOCAL:
			_room_try_move(_local_room, state["turn"], m)
		Mode.ONLINE:
			_req_move.rpc_id(1, m)


## この端末で「待った」を押せるか
func can_undo() -> bool:
	if state.is_empty() or state["winner"] >= 0:
		return false
	var u: int = state.get("undo_seat", -1)
	if u < 0:
		return false
	if mode == Mode.LOCAL:
		return seats[u]["id"] == ID_LOCAL
	return u == my_seat


func undo() -> void:
	match mode:
		Mode.LOCAL:
			_room_undo(_local_room, state.get("undo_seat", -1))
		Mode.ONLINE:
			_req_undo.rpc_id(1)


@rpc("any_peer", "reliable")
func _req_undo() -> void:
	if mode != Mode.SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	var room := _room_of(id)
	if not room.is_empty():
		_room_undo(room, _seat_in(room, id))


func resign() -> void:
	match mode:
		Mode.LOCAL:
			var t := controllable_seat()
			if t >= 0:
				Rules.resign(state, t)
				_local_room["prev"] = {}
				state["undo_seat"] = -1
				_push(_local_room)
		Mode.ONLINE:
			_req_resign.rpc_id(1)
