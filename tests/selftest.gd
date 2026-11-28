extends SceneTree
## godot --headless -s tests/selftest.gd で実行するルールの自己テスト。

const Rules = preload("res://scripts/rules.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	if not cond:
		fails += 1
		print("NG: ", msg)

func _init() -> void:
	# 1. 1歩進んで逆向きに1歩戻ると元のマスに戻る
	for i in Rules.CENTER:
		for d in Rules.KING_STEPS:
			var a := Rules.step(Rules.cell_h(i), Rules.cell_r(i), Rules.cell_f(i), d[0], d[1])
			if a.is_empty():
				continue
			if a[0] == Rules.CH:
				# 中央に入れるなら、中央の玉からも戻ってこられる
				var found := false
				for o in 3:
					for v in Rules.KING_STEPS:
						for b in Rules.center_steps(o, v):
							if Rules.idx(b[0], b[1], b[2]) == i:
								found = true
				check(found, "中央から戻れない %d" % i)
				continue
			var b := Rules.step(a[0], a[1], a[2], -a[3], -a[4])
			check(not b.is_empty() and Rules.idx(b[0], b[1], b[2]) == i, "戻れない %d dir %s" % [i, str(d)])
	# 1b. 角は5筋の奥を越えて、となりの陣地まで斜めに進める。飛は中央を通り抜ける
	var empty: Array = []
	empty.resize(Rules.CELLS)
	empty.fill(0)
	var bb := empty.duplicate()
	bb[Rules.idx(0, 1, 1)] = Rules.make_piece(0, Rules.KA, false)
	var kt := Rules.piece_targets(bb, Rules.idx(0, 1, 1))
	check(kt.has(Rules.idx(1, 4, 3)) and kt.has(Rules.idx(1, 1, 0)), "角が真ん中で止まる %s" % str(kt))
	var rb := empty.duplicate()
	rb[Rules.idx(0, 1, 4)] = Rules.make_piece(0, Rules.HI, false)
	var rt := Rules.piece_targets(rb, Rules.idx(0, 1, 4))
	check(rt.has(Rules.CENTER) and rt.has(Rules.idx(1, 0, 4)) and rt.has(Rules.idx(2, 0, 4)), "飛が中央を通り抜けない")
	check(not rt.has(Rules.idx(0, 1, 4)), "飛が元のマスに戻る")
	print("角の行き先: %d マス / 飛の行き先: %d マス" % [kt.size(), rt.size()])
	# 1c. 王手をかけられた人がすぐ次に指す（赤が緑に王手 → 緑の番 → 次は赤）
	var cs := Rules.new_game()
	var cb: Array = empty.duplicate()
	for p in 3:
		cb[Rules.idx(p, 0, 4)] = Rules.make_piece(p, Rules.OU, false)
	cb[Rules.idx(2, 1, 0)] = Rules.make_piece(0, Rules.HI, false)
	cb[Rules.idx(1, 0, 0)] = Rules.make_piece(1, Rules.KY, false)
	cs["board"] = cb
	cs["turn"] = 0
	var cm := {"from": Rules.idx(2, 1, 0), "to": Rules.idx(2, 0, 0), "drop": -1, "promote": false}
	check(Rules.is_legal(cs, 0, cm), "王手の手が指せない")
	Rules.apply_move(cs, cm)
	check(cs["turn"] == 2, "王手された緑の番にならない（turn=%d）" % cs["turn"])
	var esc: Array = Rules.moves_from(cs, 2, Rules.idx(2, 0, 4))
	var em: Dictionary = esc[0]
	for x in esc:
		if Rules.cell_r(x["to"]) == 1:
			em = x
	Rules.apply_move(cs, em)
	check(cs["turn"] == 0, "王手のあとの順番がちがう（turn=%d）" % cs["turn"])
	print("王手の順番: ", cs["log"])
	# 1d. 打ち歩詰め：緑の玉を隅に追い詰め、赤が歩を打って詰ませる手は打てない
	var us := Rules.new_game()
	var ub: Array = empty.duplicate()
	ub[Rules.idx(0, 0, 4)] = Rules.make_piece(0, Rules.OU, false)
	ub[Rules.idx(1, 0, 4)] = Rules.make_piece(1, Rules.OU, false)
	ub[Rules.idx(2, 0, 0)] = Rules.make_piece(2, Rules.OU, false)
	ub[Rules.idx(2, 2, 0)] = Rules.make_piece(0, Rules.KI, false)  # 歩を守り、逃げ道もふさぐ
	ub[Rules.idx(2, 1, 2)] = Rules.make_piece(0, Rules.GI, false)  # 横の逃げ道をふさぐ
	us["board"] = ub
	us["turn"] = 0
	us["hands"][0][Rules.FU] = 1
	var mate_cell := Rules.idx(2, 1, 0)
	var drop_cells: Array = []
	for x in Rules.drops_of(us, 0, Rules.FU):
		drop_cells.append(x["to"])
	check(not drop_cells.has(mate_cell), "打ち歩詰めの場所に打ててしまう")
	check(drop_cells.has(Rules.idx(2, 3, 5)), "ふつうの場所に歩が打てない")
	ub[Rules.idx(2, 2, 0)] = 0  # 守りの金がなければ玉で歩を取れるので打てる
	ub[Rules.idx(2, 3, 1)] = Rules.make_piece(0, Rules.KY, false)  # 香で逃げ道だけふさぐ（歩は守らない）
	drop_cells.clear()
	for x in Rules.drops_of(us, 0, Rules.FU):
		drop_cells.append(x["to"])
	check(drop_cells.has(mate_cell), "詰まない歩打ちまで禁止されている")
	# 1e. 千日手：3人とも玉を行ったり来たりすると引き分け
	var ss := Rules.new_game()
	var sb: Array = empty.duplicate()
	for p in 3:
		sb[Rules.idx(p, 0, 4)] = Rules.make_piece(p, Rules.OU, false)
	ss["board"] = sb
	ss["turn"] = 0
	for _n in 40:
		if ss["winner"] >= 0:
			break
		var t: int = ss["turn"]
		var k := Rules.find_king(ss["board"], t)
		var dest := Rules.idx(t, 1, 4) if Rules.cell_r(k) == 0 else Rules.idx(t, 0, 4)
		Rules.apply_move(ss, {"from": k, "to": dest, "drop": -1, "promote": false})
	check(ss["winner"] == Rules.DRAW, "千日手で引き分けにならない（winner=%d, %d手）" % [ss["winner"], ss["move_no"]])
	print("千日手: %d手で %s" % [ss["move_no"], ss["log"][-1]])
	# 1f. 連続王手の千日手：赤が緑に王手をかけ続けると赤の負け
	var ps := Rules.new_game()
	var pb: Array = empty.duplicate()
	pb[Rules.idx(0, 0, 4)] = Rules.make_piece(0, Rules.OU, false)
	pb[Rules.idx(1, 0, 4)] = Rules.make_piece(1, Rules.OU, false)
	pb[Rules.idx(2, 1, 0)] = Rules.make_piece(2, Rules.OU, false)
	pb[Rules.idx(2, 0, 5)] = Rules.make_piece(0, Rules.HI, false)
	ps["board"] = pb
	ps["turn"] = 0
	for _n in 40:
		if not ps["alive"][0] or ps["winner"] >= 0:
			break
		var t: int = ps["turn"]
		if t == 0:
			var rk := Rules.idx(2, 0, 5) if ps["board"][Rules.idx(2, 0, 5)] != 0 else Rules.idx(2, 1, 5)
			var rd := Rules.idx(2, 1, 5) if rk == Rules.idx(2, 0, 5) else Rules.idx(2, 0, 5)
			Rules.apply_move(ps, {"from": rk, "to": rd, "drop": -1, "promote": false})
		elif t == 2:
			var k := Rules.find_king(ps["board"], 2)
			var dest := Rules.idx(2, 0, 0) if Rules.cell_r(k) == 1 else Rules.idx(2, 1, 0)
			check(Rules.is_legal(ps, 2, {"from": k, "to": dest, "drop": -1, "promote": false}), "緑の逃げ手が指せない")
			Rules.apply_move(ps, {"from": k, "to": dest, "drop": -1, "promote": false})
		else:
			check(false, "青の番になった（王手の順番がおかしい）")
			break
	check(not ps["alive"][0], "連続王手の千日手で赤が負けにならない")
	print("連続王手: ", ps["log"].slice(-3))
	# 2. 初期局面は3人とも同じ手の数
	var st := Rules.new_game()
	var counts := []
	for p in 3:
		counts.append(Rules.legal_moves(st, p).size())
	print("初期の合法手: ", counts)
	check(counts[0] == counts[1] and counts[1] == counts[2] and counts[0] > 0, "初期手数が違う")
	# 2b. 将棋の種類ごとに：盤の形・3人の手の数がそろうか・CPUが指し続けられるか
	var all_ids: Array = Rules.VARIANT_ORDER.duplicate()
	for vid0 in Rules.VARIANT_ORDER:
		for np in [2, 4, 5]:
			all_ids.append(Rules.variant_id_for(vid0, np))
	for vid in all_ids:
		var vs := Rules.new_game(vid)
		for i in (0 if Rules.RECT else Rules.CENTER):
			for d in Rules.KING_STEPS:
				var a := Rules.step(Rules.cell_h(i), Rules.cell_r(i), Rules.cell_f(i), d[0], d[1])
				if a.is_empty() or a[0] == Rules.CH:
					continue
				var b := Rules.step(a[0], a[1], a[2], -a[3], -a[4])
				check(not b.is_empty() and Rules.idx(b[0], b[1], b[2]) == i, "%s: 戻れない %d" % [vid, i])
		var cnt := []
		for p in Rules.PLAYERS:
			cnt.append(Rules.legal_moves(vs, p).size())
		check(cnt.count(cnt[0]) == cnt.size() and cnt[0] > 0, "%s: 手の数が人によって違う %s" % [vid, str(cnt)])
		if Rules.RECT:
			check(not vs["alive"][2], "%s: 1対1なのに3人目がいる" % vid)
		var pieces := 0
		for c in vs["board"]:
			if c != 0:
				pieces += 1
		var t0 := Time.get_ticks_msec()
		var worst := 0
		var n := 0
		while vs["winner"] < 0 and n < 60:
			var t1 := Time.get_ticks_msec()
			var m := Rules.cpu_choose(vs, vs["turn"])
			worst = max(worst, Time.get_ticks_msec() - t1)
			if m.is_empty():
				break
			check(Rules.is_legal(vs, vs["turn"], m), "%s: CPUの手が不正 %s" % [vid, str(m)])
			Rules.apply_move(vs, m)
			n += 1
		print("%s: マス%d 駒%d 初手の数%s 60手 %dms（1手最大%dms） 最後=%s" % [vid, Rules.CELLS, pieces, str(cnt), Time.get_ticks_msec() - t0, worst, vs["log"][-1]])
	Rules.set_variant("standard")
	# 3. CPU同士で最後まで
	var wins := {}
	for g in 2:
		seed(g)
		st = Rules.new_game()
		var t0 := Time.get_ticks_msec()
		var n := 0
		var worst := 0
		while st["winner"] < 0 and n < 600:
			var t1 := Time.get_ticks_msec()
			var m := Rules.cpu_choose(st, st["turn"])
			worst = max(worst, Time.get_ticks_msec() - t1)
			if m.is_empty():
				check(false, "合法手なしなのに手番")
				break
			check(Rules.is_legal(st, st["turn"], m), "CPUの手が不正")
			Rules.apply_move(st, m)
			# 盤と持ち駒の駒数が増えたり減ったりしていないか（脱落者以外）
			n += 1
		if st["winner"] >= 0:
			wins[st["winner"]] = wins.get(st["winner"], 0) + 1
		print("対局%d: %d手 勝者=%d 時間=%dms 1手最大=%dms" % [g, n, st["winner"], Time.get_ticks_msec() - t0, worst])
		var tail: Array = st["log"]
		print("   最後: ", tail.slice(max(0, tail.size() - 3)))
	print("勝ち数: ", wins)
	print("RESULT: ", "OK" if fails == 0 else "FAIL %d" % fails)
	quit(0 if fails == 0 else 1)
