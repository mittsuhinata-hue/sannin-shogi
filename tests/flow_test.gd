extends SceneTree
## godot --headless -s tests/flow_test.gd
## 人数ごと・種類ごとに、部屋の流れ（指す・待った・投了・時間切れ・CPU・もう一局）を通しで試す。
## Net を「この端末だけで遊ぶ」モードで動かし、表の大きさや手番の決まりが崩れないかを毎手確かめる。

const Rules = preload("res://scripts/rules.gd")
const NetScript = preload("res://scripts/net.gd")

var net
var fails := 0
var notes: Array = []

func check(cond: bool, msg: String) -> void:
	if not cond:
		fails += 1
		if fails <= 60:
			print("NG: ", msg)

## 毎手の点検：表の大きさ・手番・駒の数
func audit(tag: String) -> void:
	var st: Dictionary = net.state
	Rules.use(st)
	var ns: int = Rules.NSEAT
	check(st["alive"].size() == ns, "%s: alive の長さ %d != %d" % [tag, st["alive"].size(), ns])
	check(st["hands"].size() == ns, "%s: hands の長さ" % tag)
	if st.has("bank"):
		check(st["bank"].size() == ns, "%s: bank の長さ %d" % [tag, st["bank"].size()])
	check(net.seats.size() >= Rules.PLAYERS, "%s: 席が足りない %d" % [tag, net.seats.size()])
	check(st["board"].size() == Rules.CELLS, "%s: 盤のマスの数" % tag)
	if st["winner"] < 0:
		var t: int = st["turn"]
		check(t >= 0 and t < ns and st["alive"][t], "%s: 手番 %d が生きていない" % [tag, t])
		check(Rules.alive_count(st) >= 2, "%s: 1人しか残っていないのに対局中" % tag)
		check(Rules.has_legal_move(st, t), "%s: 手番の人に指せる手がない" % tag)
	else:
		check(st["winner"] == Rules.DRAW or (st["winner"] < ns and st["alive"][st["winner"]]), "%s: 勝者がおかしい %d" % [tag, st["winner"]])
	for i in Rules.CELLS:
		var c: int = st["board"][i]
		if c != 0:
			var o := Rules.p_owner(c)
			check(o < ns and st["alive"][o], "%s: 脱落した人・ない席の駒が盤にある（マス%d 持ち主%d）" % [tag, i, o])
			break

func pieces_total(st: Dictionary) -> int:
	var n := 0
	for c in st["board"]:
		if c != 0:
			n += 1
	for h in st["hands"]:
		for k in h:
			n += k
	return n

## CPU の番なら、すぐ指させる
func run_cpu() -> void:
	var room: Dictionary = net._local_room
	for _k in 10:
		var st: Dictionary = net.state
		if st["winner"] >= 0 or room["seats"][st["turn"]]["id"] != NetScript.ID_CPU:
			return
		var before: int = st["move_no"]
		var alive_before := Rules.alive_count(st)
		room["cpu_at"] = 0.001
		net._cpu_tick(room)
		st = net.state
		check(st["move_no"] > before or Rules.alive_count(st) < alive_before or st["winner"] >= 0, "CPUが指さない（%s 手番%d）" % [st["variant"], st["turn"]])

## 人の番：くじ引きで合法手を1つ指す
func human_move(tag: String) -> bool:
	var st: Dictionary = net.state
	var t: int = st["turn"]
	var ms: Array = Rules.legal_moves(st, t)
	if ms.is_empty():
		check(false, "%s: 人の番なのに指せる手がない" % tag)
		return false
	var m: Dictionary = ms.pick_random()
	var before: int = st["move_no"]
	check(net.controllable_seat() == t, "%s: 手番の人が操作できない（席%d 操作できる席%d）" % [tag, t, net.controllable_seat()])
	net.submit_move(m)
	var after: Dictionary = net.state
	check(after["move_no"] == before + 1 or Rules.alive_count(after) < Rules.alive_count(st) or after["winner"] >= 0, "%s: 人の手が反映されない（席%d %s）" % [tag, t, str(m)])
	return true

func play_game(vid: String, humans: int, moves: int, undo_rate: float) -> void:
	net.variant_id = vid
	net.main_sec = 0
	net.byo_sec = 0
	net.start_local(humans, "テスト")
	var st: Dictionary = net.state
	var tag := "%s/人%d" % [vid, humans]
	audit(tag + " 開始")
	var start_pieces := pieces_total(st)
	for n in moves:
		run_cpu()
		st = net.state
		if st["winner"] >= 0:
			break
		var t: int = st["turn"]
		if net._local_room["seats"][t]["id"] != NetScript.ID_LOCAL:
			continue
		var before_no: int = st["move_no"]
		var before_turn := t
		if not human_move(tag):
			break
		audit("%s %d手" % [tag, n])
		# 待った：指した直後なら取り消せて、手番が戻る。もう一度は待ったできない
		if randf() < undo_rate and net.state["winner"] < 0:
			if net.can_undo():
				net.undo()
				check(net.state["move_no"] == before_no and net.state["turn"] == before_turn, "%s: 待ったで戻らない" % tag)
				check(not net.can_undo(), "%s: 待ったが2回できる" % tag)
				audit(tag + " 待った後")
				human_move(tag)
				check(not net.can_undo(), "%s: 待ったの後の手でまた待ったできる" % tag)
			else:
				check(net._local_room["seats"][before_turn]["id"] != NetScript.ID_LOCAL or net.state["winner"] >= 0 or net.state.get("undo_seat", -1) != before_turn,
					"%s: 待ったできるはずなのにできない" % tag)
		if Rules.DROPS:
			check(pieces_total(net.state) <= start_pieces, "%s: 駒が増えた" % tag)

func test_resign_and_timeout(vid: String) -> void:
	var np := Rules.players_of(vid)
	net.variant_id = vid
	net.main_sec = 60
	net.byo_sec = 0
	net.start_local(np, "テスト")
	var tag := vid + " 投了/時間切れ"
	audit(tag)
	for _n in 6:
		human_move(tag)
	# 手番でない人の投了
	var st: Dictionary = net.state
	var t: int = st["turn"]
	var other := (t + 1) % Rules.NSEAT
	while not st["alive"][other]:
		other = (other + 1) % Rules.NSEAT
	Rules.resign(st, other)
	net._push(net._local_room)
	check(not net.state["alive"][other], tag + ": 投了した人が残っている")
	audit(tag + " 手番でない人の投了")
	if net.state["winner"] < 0:
		check(net.state["turn"] == t, tag + ": 手番でない人の投了で手番が変わった")
	# 手番の人の時間切れ
	while net.state["winner"] < 0:
		st = net.state
		t = st["turn"]
		st["bank"][t] = 0.0
		net._local_room["turn_start"] = NetScript._now() - 5.0
		net._time_tick(net._local_room)
		check(not net.state["alive"][t] or net.state["winner"] >= 0, tag + ": 時間切れで負けにならない（席%d）" % t)
		audit(tag + " 時間切れ")
	check(net.state["winner"] >= 0 and net.state["winner"] != Rules.DRAW, tag + ": 最後の1人が勝ちにならない")
	# もう一局：新しい対局がきれいに始まる
	net.start_game()
	check(net.state["winner"] < 0 and net.state["move_no"] == 0 and Rules.alive_count(net.state) == Rules.PLAYERS, tag + ": もう一局がきれいに始まらない")
	check(not net.can_undo(), tag + ": もう一局の最初から待ったできる")
	audit(tag + " もう一局")

func _initialize() -> void:
	net = NetScript.new()
	root.add_child.call_deferred(net)
	_run.call_deferred()

func _run() -> void:
	await process_frame
	seed(12345)
	var ids: Array = []
	for b in Rules.VARIANT_ORDER:
		for np in Rules.PLAYER_COUNTS:
			ids.append(Rules.variant_id_for(b, np))
	for vid in ids:
		var np := Rules.players_of(vid)
		var t0 := Time.get_ticks_msec()
		var big: bool = Rules.base_of(vid) in ["chu", "taikyoku"]
		# 全員が人（1台で遊ぶ）・待ったを多めに
		play_game(vid, np, 20 if big else 60, 0.3)
		# 1人 vs CPU
		play_game(vid, 1, 10 if big else 40, 0.2)
		test_resign_and_timeout(vid)
		print("%s: %dms  失敗の合計 %d" % [vid, Time.get_ticks_msec() - t0, fails])
	print("RESULT: ", "OK" if fails == 0 else "FAIL %d" % fails)
	quit(0 if fails == 0 else 1)
