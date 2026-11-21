extends SceneTree
## godot --headless -s tests/cpu_level_test.gd
## CPUの強さごとの対戦成績と、1手にかかる時間を調べる。

const Rules = preload("res://scripts/rules.gd")

func _play(vid: String, levels: Array, max_moves: int) -> Array:
	var st := Rules.new_game(vid)
	var worst := [0, 0, 0]
	var n := 0
	while st["winner"] < 0 and n < max_moves:
		var t: int = st["turn"]
		st["cpu_level"] = levels[t]
		var t1 := Time.get_ticks_msec()
		var m := Rules.cpu_choose(st, t)
		worst[levels[t]] = max(worst[levels[t]], Time.get_ticks_msec() - t1)
		if m.is_empty():
			Rules.resign(st, t)
			continue
		if not Rules.is_legal(st, t, m):
			print("NG: 不正な手 ", vid, m)
			return [-9, worst, n]
		Rules.apply_move(st, m)
		n += 1
	return [st["winner"], worst, n]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var games := 6
	for a in args:
		if a.begins_with("--games="):
			games = int(a.substr(8))
	# 1. 強い vs 弱い、強い vs ふつう（1対1・標準）
	for pair in [[2, 0], [2, 1], [1, 0]]:
		var w := {}
		for g in games:
			seed(100 + g)
			var lv := [pair[0], pair[1], 1] if g % 2 == 0 else [pair[1], pair[0], 1]
			var r := _play("standard_2p", lv, 400)
			var key: String = "引き分け" if r[0] < 0 or r[0] == Rules.DRAW else Rules.CPU_LEVEL_NAMES[lv[r[0]]]
			w[key] = w.get(key, 0) + 1
		print("1対1 %s 対 %s: %s" % [Rules.CPU_LEVEL_NAMES[pair[0]], Rules.CPU_LEVEL_NAMES[pair[1]], str(w)])
	# 2. 三人：強い1人 vs 弱い・ふつう
	var w3 := {}
	for g in games:
		seed(200 + g)
		var lv := [0, 1, 2]
		lv.shuffle()
		var r := _play("standard", lv, 600)
		var key: String = "引き分け" if r[0] < 0 or r[0] == Rules.DRAW else Rules.CPU_LEVEL_NAMES[lv[r[0]]]
		w3[key] = w3.get(key, 0) + 1
	print("三人 弱い・ふつう・強い: ", w3)
	# 3. 種類ごとの「強い」の1手の時間
	var ids: Array = Rules.VARIANT_ORDER.duplicate()
	for v in Rules.VARIANT_ORDER:
		ids.append(v + "_2p")
	for vid in ids:
		seed(7)
		var r := _play(vid, [2, 2, 2], 40)
		print("%s: 強いの1手最大 %dms（40手）" % [vid, r[1][2]])
	quit()
