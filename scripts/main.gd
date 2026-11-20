extends Control
## タイトル（部屋選び）と対局画面。画面の部品はすべてここで組み立てる。
## 起動時に -- --server を付けると、画面を出さずに中継サーバーとして動く。

const Rules = preload("res://scripts/rules.gd")
const BoardView = preload("res://scripts/board_view.gd")
const UiFont = preload("res://scripts/ui_font.gd")
const SETTINGS_PATH := "user://settings.cfg"

var _font: Font

# タイトル
var _lobby_root: Control
var _name_edit: LineEdit
var _code_edit: LineEdit
var _server_edit: LineEdit
var _status: Label
var _entry_box: Control        ## 部屋に入る前の部品
var _room_box: Control         ## 部屋に入ったあとの部品
var _room_code_label: Label
var _lobby_list: Label
var _start_btn: Button
var _wait_label: Label
var _copy_btn: Button

# 対局
var _game_root: Control
var _board: BoardView
var _turn_label: Label
var _player_boxes: Array = []   ## 席ごと {"title": Label, "hand": HFlowContainer}
var _log: RichTextLabel
var _rematch_btn: Button
var _resign_btn: Button
var _promo: ConfirmationDialog
var _promo_moves: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--server"):
		_run_server(args)
		return

	_font = UiFont.make(false)
	var th := Theme.new()
	th.default_font = _font
	th.default_font_size = 18
	theme = th
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.13, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_build_lobby()
	_build_game()
	_load_settings()
	_read_url_room()
	_show_lobby()

	Net.room_changed.connect(_on_room_changed)
	Net.game_started.connect(_on_game_started)
	Net.state_changed.connect(_refresh_game)
	Net.message.connect(func(t): _status.text = t)
	Net.kicked_to_title.connect(_show_lobby)
	_handle_cmdline(args)


func _run_server(args: PackedStringArray) -> void:
	var port := Net.DEFAULT_PORT
	if OS.has_environment("PORT"):
		port = int(OS.get_environment("PORT"))
	for a in args:
		if a.begins_with("--port="):
			port = int(a.substr(7))
	Net.test_rooms = args.has("--test")
	Net.start_server(port)


# ---------- 設定の保存 ----------

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		_name_edit.text = cf.get_value("main", "name", _name_edit.text)
		_server_edit.text = cf.get_value("main", "server", Net.DEFAULT_SERVER)


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("main", "name", _player_name())
	cf.set_value("main", "server", _server_url())
	cf.save(SETTINGS_PATH)


## Web版で「...?room=ABCD」のリンクから開かれたら、部屋コードを入れておく
func _read_url_room() -> void:
	if not OS.has_feature("web"):
		return
	var q = JavaScriptBridge.eval("window.location.search", true)
	if typeof(q) != TYPE_STRING:
		return
	for part in String(q).trim_prefix("?").split("&"):
		if part.begins_with("room="):
			_code_edit.text = part.substr(5).to_upper()
			_status.text = "招待された部屋のコードを入れました。名前を確かめて「部屋に入る」を押してください"
		elif part.begins_with("server="):
			_server_edit.text = part.substr(7).uri_decode()


# ---------- 起動時の指定（テスト用） ----------
# 例: godot -- --server --port=24565 --test
#     godot -- --server-url=ws://127.0.0.1:24565 --join-room=TEST --name=A --start-when=3 --auto

var _auto := false
var _start_when := 0

func _handle_cmdline(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--name="):
			_name_edit.text = a.substr(7)
		elif a.begins_with("--server-url="):
			_server_edit.text = a.substr(13)
		elif a == "--auto":
			_auto = true
		elif a.begins_with("--start-when="):
			_start_when = int(a.substr(13))
	for a in args:
		if a == "--local":
			Net.start_local.call_deferred(1, _player_name())
		elif a == "--demo-hands":
			(func():
				for p in 3:
					Net.state["hands"][p] = [3, 1, 1, 1, 2, 1, 1]
				Net.state_changed.emit()).call_deferred()
		elif a.begins_with("--shot="):
			var path := a.substr(7)
			get_tree().create_timer(25.0 if _auto else 4.0).timeout.connect(func():
				get_viewport().get_texture().get_image().save_png(path)
				get_tree().quit())
		elif a.begins_with("--join-room="):
			_code_edit.text = a.substr(12)
			_on_join()
		elif a == "--create-room":
			_on_create()
	if DisplayServer.get_name() == "headless":
		Net.message.connect(func(t): print("[%s] %s" % [_player_name(), t]))
	if _start_when > 0:
		Net.room_changed.connect(func():
			if Net.is_owner() and not Net.in_game and Net.members.size() >= _start_when:
				Net.start_game())
	if _auto:
		Net.state_changed.connect(_auto_play)
	Net.state_changed.connect(func():
		if not Net.state.is_empty() and DisplayServer.get_name() == "headless":
			var lg: Array = Net.state["log"]
			if lg.size() > 0:
				print("[%s] %s" % [_player_name(), lg[-1]])
			if Net.state["winner"] >= 0:
				print("[%s] GAME OVER winner=%d" % [_player_name(), Net.state["winner"]])
				get_tree().create_timer(1.0).timeout.connect(get_tree().quit))


func _auto_play() -> void:
	var s := Net.controllable_seat()
	if s < 0 or Net.state["turn"] != s:
		return
	var st := Rules.copy_state(Net.state)
	get_tree().create_timer(0.05).timeout.connect(func():
		var m := Rules.cpu_choose(st, s)
		if not m.is_empty():
			Net.submit_move(m))


# ---------- タイトル画面 ----------

func _build_lobby() -> void:
	_lobby_root = CenterContainer.new()
	_lobby_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_lobby_root)
	var panel := PanelContainer.new()
	_lobby_root.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(540, 0)
	margin.add_child(v)

	var title := Label.new()
	title.text = "三人将棋"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := Label.new()
	sub.text = "六角形の盤で3人が戦う将棋。最後まで玉が残った人の勝ち"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	v.add_child(sub)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "名前"
	_name_edit.text = "プレイヤー"
	_name_edit.max_length = 16
	v.add_child(_row("名前", _name_edit))

	# --- 部屋に入る前 ---
	var entry := VBoxContainer.new()
	entry.add_theme_constant_override("separation", 10)
	_entry_box = entry
	v.add_child(entry)
	var make_btn := _btn("部屋を作って友だちを招待する", _on_create)
	make_btn.custom_minimum_size = Vector2(0, 48)
	entry.add_child(make_btn)
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "例: AB12"
	_code_edit.max_length = 8
	var hb := HBoxContainer.new()
	hb.add_child(_code_edit)
	_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var join_btn := _btn("部屋に入る", _on_join)
	join_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	join_btn.custom_minimum_size = Vector2(140, 0)
	hb.add_child(join_btn)
	entry.add_child(_row("部屋コード", hb))
	entry.add_child(HSeparator.new())
	var hb3 := HBoxContainer.new()
	hb3.add_theme_constant_override("separation", 10)
	hb3.add_child(_btn("ひとりで（CPU 2人と）", func(): Net.start_local(1, _player_name())))
	hb3.add_child(_btn("1台で3人", func(): Net.start_local(3, _player_name())))
	entry.add_child(hb3)
	_server_edit = LineEdit.new()
	_server_edit.text = Net.DEFAULT_SERVER
	_server_edit.add_theme_font_size_override("font_size", 13)
	var srow := _row("サーバー", _server_edit)
	srow.modulate = Color(1, 1, 1, 0.6)
	entry.add_child(srow)

	# --- 部屋に入ったあと ---
	var room := VBoxContainer.new()
	room.add_theme_constant_override("separation", 10)
	_room_box = room
	v.add_child(room)
	_room_code_label = Label.new()
	_room_code_label.add_theme_font_size_override("font_size", 30)
	_room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	room.add_child(_room_code_label)
	_copy_btn = _btn("招待リンクをコピー", _on_copy)
	room.add_child(_copy_btn)
	_lobby_list = Label.new()
	room.add_child(_lobby_list)
	_start_btn = _btn("対局開始（空き席はCPU）", func(): Net.start_game())
	_start_btn.custom_minimum_size = Vector2(0, 48)
	room.add_child(_start_btn)
	_wait_label = Label.new()
	_wait_label.text = "部屋を作った人が開始するのを待っています"
	room.add_child(_wait_label)
	room.add_child(_btn("部屋を出る", func():
		Net.leave()
		_status.text = ""
		_show_lobby()))

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	v.add_child(_status)


func _row(label: String, ctl: Control) -> Control:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(110, 0)
	h.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctl)
	return h


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b


func _player_name() -> String:
	var n := _name_edit.text.strip_edges()
	return n if n != "" else "プレイヤー"


func _server_url() -> String:
	var u := _server_edit.text.strip_edges()
	return u if u != "" else Net.DEFAULT_SERVER


func _on_create() -> void:
	_save_settings()
	Net.create_room(_server_url(), _player_name())


func _on_join() -> void:
	_save_settings()
	Net.join_room(_server_url(), _code_edit.text, _player_name())


func _invite_text() -> String:
	if OS.has_feature("web"):
		var base = JavaScriptBridge.eval("window.location.origin + window.location.pathname", true)
		if typeof(base) == TYPE_STRING:
			return "%s?room=%s" % [base, Net.room_code]
	return Net.room_code


func _on_copy() -> void:
	DisplayServer.clipboard_set(_invite_text())
	_status.text = "コピーしました：%s　友だちに送ってください" % _invite_text()


func _on_room_changed() -> void:
	var lines := ["参加者（%d/3）:" % Net.members.size()]
	for p in Net.members:
		lines.append("・" + str(p["name"]) + ("（部屋を作った人）" if p["id"] == Net.owner_id else ""))
	_lobby_list.text = "\n".join(lines)
	if not Net.in_game:
		_show_lobby()


func _show_lobby() -> void:
	_lobby_root.visible = true
	_game_root.visible = false
	var in_room := Net.room_code != ""
	_entry_box.visible = not in_room
	_room_box.visible = in_room
	_room_code_label.text = "部屋コード：%s" % Net.room_code
	_start_btn.visible = Net.is_owner()
	_wait_label.visible = in_room and not Net.is_owner()
	_copy_btn.text = "招待リンクをコピー" if OS.has_feature("web") else "部屋コードをコピー"



# ---------- 対局画面 ----------

func _build_game() -> void:
	_game_root = HBoxContainer.new()
	_game_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_game_root)

	_board = BoardView.new()
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.size_flags_stretch_ratio = 3.0
	_game_root.add_child(_board)
	_board.move_chosen.connect(func(m): Net.submit_move(m))
	_board.promotion_choice.connect(_ask_promotion)
	_board.selection_changed.connect(_refresh_hands)

	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(340, 0)
	_game_root.add_child(side_panel)
	var margin := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 10)
	side_panel.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	margin.add_child(v)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 22)
	_turn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_turn_label)

	for p in 3:
		var box := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.22, 0.19, 0.16)
		sb.border_color = BoardView.PLAYER_COLORS[p]
		sb.set_border_width_all(2)
		sb.set_content_margin_all(6)
		sb.set_corner_radius_all(4)
		box.add_theme_stylebox_override("panel", sb)
		var bv := VBoxContainer.new()
		box.add_child(bv)
		var t := Label.new()
		t.add_theme_color_override("font_color", BoardView.PLAYER_COLORS[p].lightened(0.35))
		bv.add_child(t)
		var hand := HFlowContainer.new()
		bv.add_child(hand)
		v.add_child(box)
		_player_boxes.append({"title": t, "hand": hand})

	var lg := Label.new()
	lg.text = "棋譜"
	v.add_child(lg)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.add_theme_font_size_override("normal_font_size", 15)
	v.add_child(_log)

	var help := Label.new()
	help.text = "駒をクリック→緑のマスへ。持ち駒は駒台（右下）かボタンを押してから打つ。右クリックで選択解除"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 13)
	v.add_child(help)

	var hb := HBoxContainer.new()
	_resign_btn = _btn("投了", func(): Net.resign())
	hb.add_child(_resign_btn)
	_rematch_btn = _btn("もう一局", _on_rematch)
	hb.add_child(_rematch_btn)
	hb.add_child(_btn("タイトルへ", func():
		Net.leave()
		_status.text = ""
		_show_lobby()))
	v.add_child(hb)

	_promo = ConfirmationDialog.new()
	_promo.title = "成りますか？"
	_promo.dialog_text = "この駒を成りますか？"
	_promo.ok_button_text = "成る"
	_promo.cancel_button_text = "成らない"
	_promo.confirmed.connect(func(): if _promo_moves.size() == 2: Net.submit_move(_promo_moves[1]))
	_promo.canceled.connect(func(): if _promo_moves.size() == 2: Net.submit_move(_promo_moves[0]))
	add_child(_promo)


func _ask_promotion(m_no: Dictionary, m_yes: Dictionary) -> void:
	_promo_moves = [m_no, m_yes]
	_promo.popup_centered()


func _on_game_started() -> void:
	_lobby_root.visible = false
	_game_root.visible = true
	_prev_move_no = 0
	_prev_alive = 3
	_prev_winner = -1
	Sfx.play("start")
	_refresh_game()


var _prev_move_no := 0
var _prev_alive := 3
var _prev_winner := -1

## 盤面が変わったときに鳴らす音を決める
func _play_sounds(st: Dictionary) -> void:
	var moved: bool = st["move_no"] > _prev_move_no
	var alive := Rules.alive_count(st)
	if moved:
		Sfx.play("capture" if st.get("last_cap", false) else "koma")
	if st["winner"] >= 0 and _prev_winner < 0:
		get_tree().create_timer(0.2).timeout.connect(func(): Sfx.play("win"))
	elif alive < _prev_alive:
		get_tree().create_timer(0.2).timeout.connect(func(): Sfx.play("out"))
	elif moved and st["winner"] < 0 and Rules.in_check(st["board"], st["turn"], st["alive"]):
		get_tree().create_timer(0.15).timeout.connect(func(): Sfx.play("check"))
	_prev_move_no = st["move_no"]
	_prev_alive = alive
	_prev_winner = st["winner"]


func _refresh_game() -> void:
	if Net.state.is_empty():
		return
	var st := Net.state
	var ctl := Net.controllable_seat()
	var names: Array = []
	for s in Net.seats:
		names.append(s["name"])
	_board.names = names
	_board.my_seat = ctl
	if Net.mode == Net.Mode.LOCAL:
		if ctl >= 0:
			_board.set_view_seat(ctl)
	elif Net.my_seat >= 0:
		_board.set_view_seat(Net.my_seat)
	_board.set_state(st)
	_play_sounds(st)

	var t: int = st["turn"]
	if st["winner"] == Rules.DRAW:
		_turn_label.text = "対局終了：引き分け"
	elif st["winner"] >= 0:
		_turn_label.text = "対局終了：%s の勝ち！" % names[st["winner"]]
	else:
		var who: String = names[t]
		if ctl == t:
			_turn_label.text = "あなたの番です（%s）" % who if Net.mode != Net.Mode.LOCAL else "%s の番です" % who
		else:
			_turn_label.text = "%s の番です" % who
		if Rules.in_check(st["board"], t, st["alive"]):
			_turn_label.text += "　王手！"
	var col_seat: int = t if st["winner"] < 0 or st["winner"] == Rules.DRAW else st["winner"]
	_turn_label.add_theme_color_override("font_color", BoardView.PLAYER_COLORS[col_seat].lightened(0.4))

	for p in 3:
		var title: Label = _player_boxes[p]["title"]
		var mark := ""
		if not st["alive"][p]:
			mark = "（脱落）"
		elif st["winner"] < 0 and t == p:
			mark = "　◀ 手番"
		var me := "（あなた）" if Net.mode != Net.Mode.LOCAL and p == Net.my_seat else ""
		title.text = "%s%s%s" % [names[p], me, mark]
	_refresh_hands()

	var lines: Array = st["log"]
	_log.text = "\n".join(lines.slice(max(0, lines.size() - 200)))
	_resign_btn.disabled = ctl < 0 and not (Net.mode != Net.Mode.LOCAL and Net.my_seat >= 0 and st["alive"][Net.my_seat] and st["winner"] < 0)
	_rematch_btn.visible = Net.is_owner() or Net.mode == Net.Mode.LOCAL
	_rematch_btn.disabled = st["winner"] < 0


func _on_rematch() -> void:
	Net.start_game()


func _refresh_hands() -> void:
	if Net.state.is_empty():
		return
	var st := Net.state
	var ctl := Net.controllable_seat()
	for p in 3:
		var hand: HFlowContainer = _player_boxes[p]["hand"]
		for c in hand.get_children():
			c.queue_free()
		var any := false
		for k in [6, 5, 4, 3, 2, 1, 0]:
			var n: int = st["hands"][p][k]
			if n <= 0:
				continue
			any = true
			if p != ctl:
				# 相手の持ち駒は文字で大きく見せる
				var l := Label.new()
				l.text = Rules.NAMES[k] + ("×%d" % n if n > 1 else "")
				l.add_theme_font_size_override("font_size", 20)
				l.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8))
				hand.add_child(l)
				continue
			var b := Button.new()
			b.text = Rules.NAMES[k] + ("×%d" % n if n > 1 else "")
			b.disabled = not (p == ctl and st["turn"] == p)
			if _board.selected_drop == k and p == ctl:
				b.modulate = Color(0.6, 1.0, 0.6)
			var kind: int = k
			b.pressed.connect(func(): _board.select_drop(kind))
			hand.add_child(b)
		if not any:
			var l := Label.new()
			l.text = "持ち駒なし"
			l.add_theme_font_size_override("font_size", 14)
			l.modulate = Color(1, 1, 1, 0.5)
			hand.add_child(l)
