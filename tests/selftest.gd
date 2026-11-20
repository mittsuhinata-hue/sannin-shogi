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
			if a[0] == 3:
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
	# 2. 初期局面は3人とも同じ手の数
	var st := Rules.new_game()
	var counts := []
	for p in 3:
		counts.append(Rules.legal_moves(st, p).size())
	print("初期の合法手: ", counts)
	check(counts[0] == counts[1] and counts[1] == counts[2] and counts[0] > 0, "初期手数が違う")
	# 3. CPU同士で最後まで
	var wins := [0, 0, 0, 0]
	for g in 3:
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
			wins[st["winner"]] += 1
		print("対局%d: %d手 勝者=%d 時間=%dms 1手最大=%dms" % [g, n, st["winner"], Time.get_ticks_msec() - t0, worst])
		var tail: Array = st["log"]
		print("   最後: ", tail.slice(max(0, tail.size() - 3)))
	print("勝ち数: ", wins)
	print("RESULT: ", "OK" if fails == 0 else "FAIL %d" % fails)
	quit(0 if fails == 0 else 1)
