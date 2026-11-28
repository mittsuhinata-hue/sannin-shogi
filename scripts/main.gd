extends Control
## タイトル（部屋選び）と対局画面。画面の部品はすべてここで組み立てる。
## 起動時に -- --server を付けると、画面を出さずに中継サーバーとして動く。

const Rules = preload("res://scripts/rules.gd")
const BoardView = preload("res://scripts/board_view.gd")
const UiFont = preload("res://scripts/ui_font.gd")
const SETTINGS_PATH := "user://settings.cfg"
const VERSION := "2.7"   ## 直すたびに上げる（友だちの画面が新しいか見分けるため）

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
var _undo_btn: Button
var _main_opt: OptionButton
var _byo_opt: OptionButton
var _variant_opt: OptionButton
var _players_opt: OptionButton
var _hotseat_btn: Button
var _solo_btn: Button
var _level_opt: OptionButton
var _variant_note: Label
var _piece_info: Label
var _clock_row: Control
var _clock_label: Label
var _notice: Label   ## 対局中の通信のお知らせ（つなぎ直し中など）
var _side_panel: Control
var _players_box: BoxContainer
var _help: Label
var _buttons_row: Control
var _lobby_vbox: Control
var _portrait := false
var _warned_turn_key := ""

const MAIN_TIMES := [["なし", 0], ["1分", 60], ["3分", 180], ["5分", 300], ["10分", 600], ["20分", 1200]]
const BYO_TIMES := [["なし", 0], ["10秒", 10], ["20秒", 20], ["30秒", 30], ["60秒", 60]]


## 部屋の設定 [持ち時間, 秒読み, 種類] を欄に表示する
func _select_clock(clock: Array) -> void:
	for i in MAIN_TIMES.size():
		if MAIN_TIMES[i][1] == int(clock[0]):
			_main_opt.selected = i
	for i in BYO_TIMES.size():
		if BYO_TIMES[i][1] == int(clock[1]):
			_byo_opt.selected = i
	if clock.size() > 2:
		var vid := str(clock[2])
		var vi := Rules.VARIANT_ORDER.find(Rules.base_of(vid))
		if vi >= 0:
			_variant_opt.selected = vi
		_players_opt.selected = PLAYER_OPTS.find(Rules.players_of(vid))
	if clock.size() > 3:
		_level_opt.selected = clampi(int(clock[3]), 0, 2)
	_update_variant_labels()


func _apply_clock_setting() -> void:
	Net.main_sec = MAIN_TIMES[_main_opt.selected][1]
	Net.byo_sec = BYO_TIMES[_byo_opt.selected][1]
	Net.variant_id = Rules.variant_id_for(Rules.VARIANT_ORDER[_variant_opt.selected], _players_count())
	Net.cpu_level = _level_opt.selected
	_update_variant_labels()


## 人数に合わせて、種類の名前・説明・ボタンの文字を変える
func _update_variant_labels() -> void:
	var np := _players_count()
	for i in Rules.VARIANT_ORDER.size():
		var vid := Rules.variant_id_for(Rules.VARIANT_ORDER[i], np)
		_variant_opt.set_item_text(i, Rules.variant_info(vid)["name"])
	var cur := Rules.variant_id_for(Rules.VARIANT_ORDER[_variant_opt.selected], np)
	_variant_note.text = Rules.variant_info(cur)["note"]
	if _hotseat_btn:
		_hotseat_btn.text = "1台で%d人" % np
	if _solo_btn:
		_solo_btn.text = "ひとりで（CPU %d人と）" % (np - 1)


## 人数の欄の並び（三人・1対1・4人・5人）
const PLAYER_OPTS := [3, 2, 4, 5]

func _players_count() -> int:
	return PLAYER_OPTS[clampi(_players_opt.selected, 0, PLAYER_OPTS.size() - 1)]
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
	_apply_layout()
	get_tree().root.size_changed.connect(_apply_layout)
	_web_input(_name_edit, "名前を入れてください（16文字まで）")
	_web_input(_code_edit, "部屋コードを入れてください")
	_load_settings()
	_read_url_room()
	_show_lobby()

	Net.room_changed.connect(_on_room_changed)
	Net.game_started.connect(_on_game_started)
	Net.state_changed.connect(_refresh_game)
	Net.message.connect(_on_net_message)
	Net.kicked_to_title.connect(_show_lobby)
	_handle_cmdline(args)


## 画面の向きに合わせて並べ方を変える。
## 縦長（スマホの縦持ち）：画面の基準を 540×960 にし、盤を上・情報を下に置く。
func _apply_layout() -> void:
	var ws := Vector2(DisplayServer.window_get_size())
	if ws.x <= 0 or ws.y <= 0:
		return
	var portrait := ws.y > ws.x * 1.1
	var base := Vector2i(540, 960) if portrait else Vector2i(1280, 800)
	if get_window().content_scale_size != base:
		get_window().content_scale_size = base
	_portrait = portrait
	# 実際の画面での論理的な大きさ（aspect=expand なので短い方が基準に合う）
	var sc: float = min(ws.x / base.x, ws.y / base.y)
	var logical := ws / sc

	_game_root.vertical = portrait
	_players_box.vertical = not portrait
	_help.visible = not portrait
	for pb in _player_boxes:
		pb["hand"].visible = false   # 持ち駒は盤の駒台で見る（枠の中には出さない）
	if portrait:
		_board.size_flags_vertical = Control.SIZE_FILL
		_board.custom_minimum_size = Vector2(0, min(logical.x * 1.28, logical.y * 0.66))
		_side_panel.custom_minimum_size = Vector2(0, 0)
		_side_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_buttons_row.get_parent().move_child(_buttons_row, _players_box.get_index() + 1)
		_lobby_vbox.custom_minimum_size = Vector2(min(480.0, logical.x - 60.0), 0)
	else:
		_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_board.custom_minimum_size = Vector2(0, 0)
		_side_panel.custom_minimum_size = Vector2(340, 0)
		_side_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_buttons_row.get_parent().move_child(_buttons_row, -1)
		_lobby_vbox.custom_minimum_size = Vector2(540, 0)


func _on_net_message(t: String) -> void:
	_status.text = t
	if _game_root.visible:
		# 対局中は右の欄に出す。つなぎ直せたら少しして消す
		_notice.text = t
		_notice.visible = true
		if t.begins_with("つなぎ直しました"):
			get_tree().create_timer(4.0).timeout.connect(func():
				if _notice.text == t:
					_notice.visible = false)


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
		_main_opt.selected = clampi(cf.get_value("main", "main_index", 0), 0, MAIN_TIMES.size() - 1)
		_byo_opt.selected = clampi(cf.get_value("main", "byo_index", 0), 0, BYO_TIMES.size() - 1)
		_variant_opt.selected = clampi(cf.get_value("main", "variant_index", 0), 0, Rules.VARIANT_ORDER.size() - 1)
		_players_opt.selected = clampi(cf.get_value("main", "players_index", 0), 0, PLAYER_OPTS.size() - 1)
		_level_opt.selected = clampi(cf.get_value("main", "cpu_level", 1), 0, 2)
	_apply_clock_setting()


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("main", "name", _player_name())
	cf.set_value("main", "server", _server_url())
	cf.set_value("main", "main_index", _main_opt.selected)
	cf.set_value("main", "byo_index", _byo_opt.selected)
	cf.set_value("main", "variant_index", _variant_opt.selected)
	cf.set_value("main", "players_index", _players_opt.selected)
	cf.set_value("main", "cpu_level", _level_opt.selected)
	cf.save(SETTINGS_PATH)


## Web版では入力欄を押すと、ブラウザの入力画面を出す。
## （Godot の入力欄は、ブラウザだと日本語入力やスマホのキーボードが効かないことがあるため）
func _web_input(edit: LineEdit, question: String) -> void:
	if not OS.has_feature("web"):
		return
	edit.editable = false
	edit.add_theme_color_override("font_uneditable_color", Color(0.95, 0.95, 0.95))
	edit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	edit.gui_input.connect(func(ev: InputEvent):
		# スマホのタッチもマウスのクリックとして届く
		if not (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT):
			return
		edit.accept_event()
		var js := "window.prompt(%s, %s)" % [JSON.stringify(question), JSON.stringify(edit.text)]
		var r = JavaScriptBridge.eval(js, true)
		if typeof(r) == TYPE_STRING:
			var t := String(r).strip_edges().substr(0, edit.max_length if edit.max_length > 0 else 32)
			if t != "":
				edit.text = t
				_save_settings())


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
var _undo_pressed_at := -1
var _start_when := 0

func _handle_cmdline(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--name="):
			_name_edit.text = a.substr(7)
		elif a.begins_with("--server-url="):
			_server_edit.text = a.substr(13)
		elif a == "--auto":
			_auto = true
		elif a.begins_with("--variant="):
			Net.variant_id = a.substr(10)
		elif a == "--auto-undo":
			Net.state_changed.connect(func():
				if _undo_pressed_at >= 0:
					print("[%s] （テスト）待った %s（%d手→%d手）" % [_player_name(), "成功" if Net.state["move_no"] < _undo_pressed_at else "失敗", _undo_pressed_at, Net.state["move_no"]])
					_undo_pressed_at = -1
				if Net.mode == Net.Mode.ONLINE and Net.can_undo() and randf() < 0.5:
					_undo_pressed_at = Net.state["move_no"]
					Net.undo())
		elif a.begins_with("--deaf-after="):
			get_tree().create_timer(float(a.substr(13))).timeout.connect(func():
				print("[%s] （テスト）ここから受け取らないふり" % _player_name())
				Net.test_deaf = true)
		elif a.begins_with("--level="):
			Net.cpu_level = int(a.substr(8))
		elif a.begins_with("--main="):
			Net.main_sec = int(a.substr(7))
		elif a.begins_with("--byo="):
			Net.byo_sec = int(a.substr(6))
		elif a.begins_with("--drop-after="):
			get_tree().create_timer(float(a.substr(13))).timeout.connect(func():
				print("[%s] --- 通信をわざと切ります ---" % _player_name())
				Net.simulate_drop())
		elif a.begins_with("--quit-after-sec="):
			get_tree().create_timer(float(a.substr(17))).timeout.connect(get_tree().quit)
		elif a.begins_with("--start-when="):
			_start_when = int(a.substr(13))
	for a in args:
		if a == "--local":
			Net.start_local.call_deferred(1, _player_name())
		elif a == "--demo-hands":
			(func():
				for p in Net.state["hands"].size():
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
		elif a == "--undo-test":
			_undo_test.call_deferred()
	if DisplayServer.get_name() == "headless":
		Net.message.connect(func(t): print("[%s] %s" % [_player_name(), t]))
	if _start_when > 0:
		Net.room_changed.connect(func():
			if Net.is_owner() and not Net.in_game and str(Net.room_clock[2]) != Net.variant_id:
				Net.set_clock(Net.main_sec, Net.byo_sec)   # テスト用：自分で選んだ種類を部屋に伝える
			elif Net.is_owner() and not Net.in_game and Net.members.size() >= _start_when:
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


## 待ったの動作確認（この端末だけの対局で）
func _undo_test() -> void:
	var firsts := {}
	for i in 12:
		Net.start_local(1, "T")
		firsts[Net.state["turn"]] = true
	print("先手に選ばれた席: ", firsts.keys())
	while Net.state["turn"] != 0:
		await get_tree().process_frame
	var n0: int = Net.state["move_no"]
	Net.submit_move(Rules.cpu_choose(Net.state, 0))
	var ok1: bool = Net.can_undo() and Net.state["move_no"] == n0 + 1
	Net.undo()
	var ok2: bool = Net.state["move_no"] == n0 and Net.state["turn"] == 0 and not Net.can_undo()
	Net.submit_move(Rules.cpu_choose(Net.state, 0))
	var ok3 := not Net.can_undo()   # 1手番に2回目の待ったはできない
	print("待ったテスト: 指した直後=%s 取り消し=%s 2回目は不可=%s" % [ok1, ok2, ok3])
	print("最後の棋譜: ", Net.state["log"].slice(-3))
	get_tree().quit()


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
	_lobby_vbox = v
	margin.add_child(v)

	var title := Label.new()
	title.text = "三人将棋"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := Label.new()
	sub.text = "2〜5人で遊べる将棋。3人以上は多角形の盤で、最後まで玉が残った人の勝ち"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	v.add_child(sub)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "名前"
	_name_edit.text = "プレイヤー"
	_name_edit.max_length = 16
	v.add_child(_row("名前", _name_edit))

	_main_opt = OptionButton.new()
	for item in MAIN_TIMES:
		_main_opt.add_item(item[0])
	_byo_opt = OptionButton.new()
	for item in BYO_TIMES:
		_byo_opt.add_item(item[0])
	for o in [_main_opt, _byo_opt]:
		o.item_selected.connect(func(_i):
			_apply_clock_setting()
			Net.set_clock(Net.main_sec, Net.byo_sec)
			_save_settings())
	var th_row := HBoxContainer.new()
	th_row.add_child(_main_opt)
	var byo_l := Label.new()
	byo_l.text = "　秒読み"
	th_row.add_child(byo_l)
	th_row.add_child(_byo_opt)
	_main_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_byo_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 将棋の種類
	_variant_opt = OptionButton.new()
	for vid in Rules.VARIANT_ORDER:
		_variant_opt.add_item(Rules.VARIANTS[vid]["name"])
	_variant_opt.item_selected.connect(func(_i):
		_apply_clock_setting()
		Net.set_clock(Net.main_sec, Net.byo_sec)
		_save_settings())
	_variant_note = Label.new()
	_variant_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_variant_note.add_theme_font_size_override("font_size", 14)
	_variant_note.modulate = Color(1, 1, 1, 0.75)
	# 部屋に入る前は「部屋を作る」ボタンの上、入ったあとは部屋の画面に置く（_show_lobby で移す）
	# 人数（三人・1対1）
	_players_opt = OptionButton.new()
	_players_opt.add_item("三人（六角形の盤）")
	_players_opt.add_item("1対1（四角い盤）")
	_players_opt.add_item("4人（八角形の盤）")
	_players_opt.add_item("5人（十角形の盤）")
	_players_opt.item_selected.connect(func(_i):
		_apply_clock_setting()
		Net.set_clock(Net.main_sec, Net.byo_sec)
		_save_settings())
	# CPUの強さ
	_level_opt = OptionButton.new()
	for nm in Rules.CPU_LEVEL_NAMES:
		_level_opt.add_item(nm)
	_level_opt.selected = 1
	_level_opt.item_selected.connect(func(_i):
		_apply_clock_setting()
		Net.set_clock(Net.main_sec, Net.byo_sec)
		_save_settings())
	var rules_box := VBoxContainer.new()
	rules_box.add_child(_row("人数", _players_opt))
	rules_box.add_child(_row("種類", _variant_opt))
	rules_box.add_child(_variant_note)
	rules_box.add_child(_row("持ち時間", th_row))
	rules_box.add_child(_row("CPUの強さ", _level_opt))
	_clock_row = rules_box

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
	_solo_btn = _btn("ひとりで（CPU 2人と）", func(): Net.start_local(1, _player_name()))
	hb3.add_child(_solo_btn)
	_hotseat_btn = _btn("1台で3人", func(): Net.start_local(_players_count(), _player_name()))
	hb3.add_child(_hotseat_btn)
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
	if OS.has_feature("web"):
		_status.text = "名前や部屋コードは、欄を押すと入力画面が出ます"
	v.add_child(_status)

	var ver := Label.new()
	ver.text = "版 %s" % VERSION
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ver.add_theme_font_size_override("font_size", 12)
	ver.modulate = Color(1, 1, 1, 0.45)
	v.add_child(ver)


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
	var lines := ["参加者（%d/%d）:" % [Net.members.size(), Rules.players_of(str(Net.room_clock[2]) if Net.room_clock.size() > 2 else "standard")]]
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
	# 部屋では、作った人の制限時間が使われる
	# 持ち時間の欄を、いまの画面の正しい場所へ移す
	var want_parent: Control = _room_box if in_room else _entry_box
	if _clock_row.get_parent() != want_parent:
		if _clock_row.get_parent():
			_clock_row.get_parent().remove_child(_clock_row)
		want_parent.add_child(_clock_row)
	want_parent.move_child(_clock_row, 1 if in_room else 0)
	# 部屋では、作った人の設定が使われる（入った人は見るだけ）
	if in_room:
		_select_clock(Net.room_clock)
	else:
		_select_clock([Net.main_sec, Net.byo_sec, Net.variant_id, Net.cpu_level])
	_main_opt.disabled = in_room and not Net.is_owner()
	_byo_opt.disabled = _main_opt.disabled
	_variant_opt.disabled = _main_opt.disabled
	_players_opt.disabled = _main_opt.disabled
	_level_opt.disabled = _main_opt.disabled
	_copy_btn.text = "招待リンクをコピー" if OS.has_feature("web") else "部屋コードをコピー"



# ---------- 対局画面 ----------

func _build_game() -> void:
	_game_root = BoxContainer.new()   # 横長なら盤｜欄、縦長なら盤／欄（_apply_layout で切り替え）
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
	_board.piece_tapped.connect(func(c): _piece_info.text = Rules.piece_help(c))

	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(340, 0)
	_side_panel = side_panel
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
	_clock_label = Label.new()
	_clock_label.add_theme_font_size_override("font_size", 20)
	v.add_child(_clock_label)
	_piece_info = Label.new()
	_piece_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_piece_info.add_theme_font_size_override("font_size", 15)
	_piece_info.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	_piece_info.custom_minimum_size = Vector2(60, 0)
	v.add_child(_piece_info)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_notice.visible = false
	v.add_child(_notice)
	var tick := Timer.new()
	tick.wait_time = 0.25
	tick.autostart = true
	tick.timeout.connect(_update_clock)
	add_child(tick)

	_players_box = BoxContainer.new()
	_players_box.vertical = true
	_players_box.add_theme_constant_override("separation", 6)
	v.add_child(_players_box)
	for p in Rules.SEATS_MAX:
		var box := PanelContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.custom_minimum_size = Vector2(60, 0)
		bv.add_child(t)
		var clk := Label.new()
		clk.add_theme_font_size_override("font_size", 16)
		clk.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		clk.custom_minimum_size = Vector2(60, 0)
		bv.add_child(clk)
		var hand := HFlowContainer.new()
		bv.add_child(hand)
		_players_box.add_child(box)
		_player_boxes.append({"title": t, "hand": hand, "clock": clk, "box": box})

	var lg := Label.new()
	lg.text = "棋譜"
	v.add_child(lg)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.add_theme_font_size_override("normal_font_size", 15)
	v.add_child(_log)

	var help := Label.new()
	help.text = "駒をクリック→緑のマスへ。持ち駒は駒台（右下）の駒を押してから打つ。ホイールで拡大、ドラッグで移動、右クリックで選択解除"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 13)
	v.add_child(help)
	_help = help

	var hb := HBoxContainer.new()
	_buttons_row = hb
	_undo_btn = _btn("待った", func(): Net.undo())
	_undo_btn.tooltip_text = "いま指した手を取り消す（次の人が指す前・手番ごとに1回まで）"
	hb.add_child(_undo_btn)
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
	_prev_alive = Rules.alive_count(Net.state) if not Net.state.is_empty() else 3
	_prev_winner = -1
	if Net.rejoined:
		Net.rejoined = false   # つなぎ直しただけなので、開始の音は鳴らさない
		_prev_move_no = Net.state.get("move_no", 0) if not Net.state.is_empty() else 999999
	else:
		_notice.visible = false
		_piece_info.text = "駒を押すと、名前と動きがここに出ます"
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
	elif st["move_no"] < _prev_move_no:
		Sfx.play("select")  # 待った
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

	for p in Rules.SEATS_MAX:
		_player_boxes[p]["box"].visible = p < Rules.PLAYERS   # 1対1では3人目の枠を出さない
		if p >= st["alive"].size():
			continue
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
	_undo_btn.disabled = not Net.can_undo()
	_rematch_btn.visible = Net.is_owner() or Net.mode == Net.Mode.LOCAL
	_rematch_btn.disabled = st["winner"] < 0


## 考え中の時間と残り時間を表示する
func _update_clock() -> void:
	if not _game_root.visible or Net.state.is_empty():
		return
	var st := Net.state
	if st["winner"] >= 0:
		_clock_label.text = ""
		return
	var el := Net.turn_elapsed()
	var t: int = st["turn"]
	var text := "考え中 %s" % Net.fmt_time(el)
	var col := Color(0.9, 0.9, 0.9)
	if Net.has_clock(st):
		var info := _clock_info(st, t, el)
		text += "　" + info[0]
		if info[1] <= 10.0:
			col = Color(1.0, 0.35, 0.3)
			# 自分の番で残り10秒を切ったら1回だけ知らせる
			var key := "%d/%d/%s" % [t, st["move_no"], info[0].left(2)]
			if Net.controllable_seat() == t and _warned_turn_key != key:
				_warned_turn_key = key
				Sfx.play("check")
	_clock_label.text = text
	_clock_label.add_theme_color_override("font_color", col)
	# 3人それぞれの持ち時間
	for p in st["alive"].size():
		var lbl: Label = _player_boxes[p]["clock"]
		if not Net.has_clock(st) or not st["alive"][p]:
			lbl.text = ""
			continue
		var info := _clock_info(st, p, el if p == t else 0.0)
		lbl.text = info[0]
		lbl.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4) if p == t and info[1] <= 10.0 else Color(0.85, 0.85, 0.85))


## [表示する文字, 残り秒] を返す。持ち時間が残っていれば持ち時間、なければ秒読み
func _clock_info(st: Dictionary, p: int, el: float) -> Array:
	var bank: float = float(st["bank"][p]) - el
	var byo: int = st.get("byo", 0)
	if bank > 0.0:
		var label := "持ち時間 %s" % Net.fmt_time(ceil(bank))
		if byo > 0:
			label += "（秒読み%d秒）" % byo
		return [label, bank + (byo if byo > 0 else 0)]
	if byo > 0:
		var rest: float = byo + bank
		return ["秒読み %d" % int(ceil(max(rest, 0.0))), rest]
	return ["持ち時間 0:00", 0.0]


func _on_rematch() -> void:
	Net.start_game()


func _refresh_hands() -> void:
	# 持ち駒は盤の駒台で見せるので、枠の中の持ち駒ボタンは作らない（軽くするため）
	if Net.state.is_empty() or not _player_boxes[0]["hand"].visible:
		return
	var st := Net.state
	var ctl := Net.controllable_seat()
	for p in st["hands"].size():
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
