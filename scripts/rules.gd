extends RefCounted
## 三人将棋のルール（盤の形・駒の動き・勝敗）。
## 画面や通信には関係しない、純粋な計算だけを置く。
##
## 盤：3人それぞれの陣地 h(0..2) が 段 r(0..4) × 筋 f(0..8)。
##   r=0 が自分の一番奥（玉のいる段）、r=4 が中央に接する段。
##   f=0..3 の先は左隣 (h+2) の陣地、f=5..8 の先は右隣 (h+1) の陣地。
##   真ん中の f=4（5筋）の先は、盤の中心にある三角形のマス「中央」。
## マス番号 = h*45 + r*9 + f、中央 = 135

const FU := 0
const KY := 1
const KE := 2
const GI := 3
const KI := 4
const KA := 5
const HI := 6
const OU := 7

const NAMES := ["歩", "香", "桂", "銀", "金", "角", "飛", "玉"]
const PROM_NAMES := ["と", "杏", "圭", "全", "金", "馬", "龍", "玉"]
const CAN_PROMOTE := [true, true, true, true, false, true, true, false]
const VALUE := [1, 3, 4, 5, 6, 8, 10, 50]
const HAND_KINDS := 7  # 歩〜飛

const GOLD_STEPS := [[1, -1], [1, 0], [1, 1], [0, -1], [0, 1], [-1, 0]]
const SILVER_STEPS := [[1, -1], [1, 0], [1, 1], [-1, -1], [-1, 1]]
const KING_STEPS := [[1, -1], [1, 0], [1, 1], [0, -1], [0, 1], [-1, -1], [-1, 0], [-1, 1]]
const ORTHO := [[1, 0], [-1, 0], [0, 1], [0, -1]]
const DIAG := [[1, 1], [1, -1], [-1, 1], [-1, -1]]

const FILES := 9
const RANKS := 5
const TOP := 4          ## 中央に接する段
const MID := 4          ## 5筋
const HALF := 45
const CENTER := 135
const CELLS := 136
const MAX_MOVES := 600
const DRAW := 3   ## winner がこの値なら引き分け（0..2 は勝者、-1 は対局中）

# 初期配置（自分から見て左から右）
const BACK_RANK := [KY, KE, GI, KI, OU, KI, GI, KE, KY]


# ---------- マスと駒の番号 ----------

static func idx(h: int, r: int, f: int) -> int:
	if h == 3:
		return CENTER
	return h * HALF + r * FILES + f

static func cell_h(i: int) -> int:
	return i / HALF

static func cell_r(i: int) -> int:
	return (i % HALF) / FILES

static func cell_f(i: int) -> int:
	return i % FILES

static func make_piece(owner: int, kind: int, promoted: bool) -> int:
	return 1 + owner * 16 + kind * 2 + (1 if promoted else 0)

static func p_owner(c: int) -> int:
	return (c - 1) / 16

static func p_kind(c: int) -> int:
	return ((c - 1) % 16) / 2

static func p_prom(c: int) -> bool:
	return (c - 1) % 2 == 1

static func piece_label(c: int) -> String:
	return PROM_NAMES[p_kind(c)] if p_prom(c) else NAMES[p_kind(c)]


# ---------- 新しい対局 ----------

static func new_game() -> Dictionary:
	var board: Array = []
	board.resize(CELLS)
	board.fill(0)
	for p in 3:
		for f in FILES:
			board[idx(p, 0, f)] = make_piece(p, BACK_RANK[f], false)
			board[idx(p, 2, f)] = make_piece(p, FU, false)
		board[idx(p, 1, 1)] = make_piece(p, KA, false)
		board[idx(p, 1, 7)] = make_piece(p, HI, false)
	var hands: Array = []
	for p in 3:
		var hnd: Array = []
		hnd.resize(HAND_KINDS)
		hnd.fill(0)
		hands.append(hnd)
	return {
		"board": board,
		"hands": hands,
		"turn": 0,
		"alive": [true, true, true],
		"winner": -1,
		"last_from": -1,
		"last_to": -1,
		"last_cap": false,
		"move_no": 0,
		"log": [],
	}

## 先手をくじ引きで決める
static func pick_first(state: Dictionary, names: Array) -> void:
	var t := randi() % 3
	state["turn"] = t
	state["log"].append("先手は %s（%s）" % [names[t], player_name_default(t)])

static func copy_state(s: Dictionary) -> Dictionary:
	return s.duplicate(true)


# ---------- 盤の上を1歩進む ----------

## (dr, df) はその陣地 h の向きでの方向。
## 返り値 [h, r, f, dr, df]（中央の段を越えると相手の陣地に入り、向きが反転する）。
## 中央のマスに入ったときは [3, 0, 0, 0, 0]。盤の外なら []。
static func step(h: int, r: int, f: int, dr: int, df: int) -> Array:
	var nr := r + dr
	var nf := f + df
	if nf < 0 or nf >= FILES or nr < 0:
		return []
	if nr <= TOP:
		return [h, nr, nf, dr, df]
	if f == MID and nf == MID:
		return [3, 0, 0, 0, 0]   # 5筋をまっすぐ進むと中央
	# 中央の三角マスの角をはさんだ斜め：4筋・6筋の奥 ⇔ となりの人の5筋の奥
	if f == MID - 1 and nf == MID:
		return [(h + 2) % 3, TOP, MID, -1, -1]
	if f == MID + 1 and nf == MID:
		return [(h + 1) % 3, TOP, MID, -1, 1]
	var q := (h + 1) % 3 if nf > MID else (h + 2) % 3
	return [q, TOP, 8 - nf, -dr, -df]

## 中央のマスから、持ち主の向きで v=(前, 右) へ進んだ先（複数あり得る）。
## 前＝相手2人の5筋、後ろ＝自分の5筋。中央は5筋とだけつながり、横・斜めはない。
static func center_steps(owner: int, v: Array) -> Array:
	var out: Array = []
	var fwd: int = v[0]
	var side: int = v[1]
	if fwd == 0 or side != 0:
		return out
	var hs: Array = []
	if fwd > 0:
		for h in 3:
			if h != owner:
				hs.append(h)
	else:
		hs = [owner]
	for h in hs:
		out.append([h, TOP, MID, -1, 0])
	return out

## 持ち主から見た「前」が、その陣地の向きで +1 か -1 か。
## 自分の陣地では中央向きが前、相手の陣地ではその相手の奥向きが前。
static func orient(owner: int, h: int) -> int:
	return 1 if h == owner else -1

static func _ai(a: Array) -> int:
	return idx(a[0], a[1], a[2])

## マス i にいる owner の駒が、向き v に1歩進んだ先の一覧
static func _neighbors(owner: int, i: int, v: Array) -> Array:
	if i == CENTER:
		return center_steps(owner, v)
	var h := cell_h(i)
	var s := orient(owner, h)
	var a := step(h, cell_r(i), cell_f(i), s * v[0], s * v[1])
	return [] if a.is_empty() else [a]


# ---------- 駒の動き（自分の玉の安全は見ない） ----------

static func piece_targets(board: Array, i: int) -> Array:
	var c: int = board[i]
	if c == 0:
		return []
	var o := p_owner(c)
	var k := p_kind(c)
	var pr := p_prom(c)
	var steps: Array = []
	var slides: Array = []
	var knight := false
	match k:
		FU:
			steps = GOLD_STEPS if pr else [[1, 0]]
		KY:
			if pr: steps = GOLD_STEPS
			else: slides = [[1, 0]]
		KE:
			if pr: steps = GOLD_STEPS
			else: knight = true
		GI:
			steps = GOLD_STEPS if pr else SILVER_STEPS
		KI:
			steps = GOLD_STEPS
		KA:
			slides = DIAG
			if pr: steps = ORTHO
		HI:
			slides = ORTHO
			if pr: steps = DIAG
		OU:
			steps = KING_STEPS
	var out: Array = []
	for st in steps:
		for a in _neighbors(o, i, st):
			var t := _ai(a)
			if (board[t] == 0 or p_owner(board[t]) != o) and not out.has(t):
				out.append(t)
	for sl in slides:
		# 道が中央で分かれることがあるので、調べる道を積んでおく
		var rays: Array = []
		for first in _neighbors(o, i, sl):
			rays.append([first, cell_h(i)])
		while not rays.is_empty():
			var ray: Array = rays.pop_back()
			var cur: Array = ray[0]
			var from_h: int = ray[1]
			for _n in 30:
				var t := _ai(cur)
				if board[t] != 0:
					if p_owner(board[t]) != o and not out.has(t):
						out.append(t)
					break
				if not out.has(t):
					out.append(t)
				if t == CENTER:
					# 中央を通り抜けて、来た方向以外の5筋へ
					for h2 in 3:
						if h2 != from_h:
							rays.append([[h2, TOP, MID, -1, 0], 3])
					break
				from_h = cur[0]
				cur = step(cur[0], cur[1], cur[2], cur[3], cur[4])
				if cur.is_empty():
					break
	if knight:
		for a in _neighbors(o, i, [1, 0]):
			var lands: Array = []
			if a[0] == 3:
				for b0 in center_steps(o, [1, 0]):
					for side in [-1, 1]:
						var b := step(b0[0], b0[1], b0[2], b0[3], b0[3] * side)
						if not b.is_empty():
							lands.append(b)
			else:
				var s2: int = a[3]  # 1歩進んだあとの「前」の向き
				for side in [-1, 1]:
					var b := step(a[0], a[1], a[2], s2, s2 * side)
					if not b.is_empty():
						lands.append(b)
			for b in lands:
				var t := _ai(b)
				if (board[t] == 0 or p_owner(board[t]) != o) and not out.has(t):
					out.append(t)
	return out


# ---------- 王手の判定 ----------

static func find_king(board: Array, pl: int) -> int:
	var want := make_piece(pl, OU, false)
	for i in CELLS:
		if board[i] == want:
			return i
	return -1

static func is_attacked(board: Array, target: int, defender: int, alive: Array) -> bool:
	for i in CELLS:
		var c: int = board[i]
		if c == 0:
			continue
		var o := p_owner(c)
		if o == defender or not alive[o]:
			continue
		if piece_targets(board, i).has(target):
			return true
	return false

static func in_check(board: Array, pl: int, alive: Array) -> bool:
	var k := find_king(board, pl)
	if k < 0:
		return false
	return is_attacked(board, k, pl, alive)


# ---------- 成り ----------

static func in_zone(pl: int, i: int) -> bool:
	return i != CENTER and cell_h(i) != pl and cell_r(i) <= 2

static func must_promote(kind: int, pl: int, t: int) -> bool:
	if t == CENTER or cell_h(t) == pl:
		return false
	var r := cell_r(t)
	if kind == FU or kind == KY:
		return r == 0
	if kind == KE:
		return r <= 1
	return false


# ---------- 二歩 ----------

## 持ち主から見た縦の筋（中央をまたいでも続く）に、自分の成っていない歩があるか。
static func pawn_on_line(board: Array, pl: int, t: int) -> bool:
	var pawn := make_piece(pl, FU, false)
	if t == CENTER:
		for h in 3:
			for r in RANKS:
				if board[idx(h, r, MID)] == pawn:
					return true
		return false
	var h := cell_h(t)
	var s := orient(pl, h)
	for dir in [1, -1]:
		var cur := [h, cell_r(t), cell_f(t), s * dir, 0]
		for _n in 30:
			var a := step(cur[0], cur[1], cur[2], cur[3], cur[4])
			if a.is_empty():
				break
			var ti := _ai(a)
			if board[ti] == pawn:
				return true
			if ti == CENTER:
				break
			cur = a
	return false

static func drop_ok(board: Array, pl: int, kind: int, t: int) -> bool:
	if board[t] != 0:
		return false
	if must_promote(kind, pl, t):
		return false  # 動けない場所には打てない
	if kind == FU and pawn_on_line(board, pl, t):
		return false
	return true


# ---------- 合法手 ----------

static func _apply_board(board: Array, pl: int, m: Dictionary) -> Array:
	var b := board.duplicate()
	if m["drop"] >= 0:
		b[m["to"]] = make_piece(pl, m["drop"], false)
	else:
		var c: int = b[m["from"]]
		b[m["to"]] = make_piece(pl, p_kind(c), p_prom(c) or m["promote"])
		b[m["from"]] = 0
	return b

static func _safe(state: Dictionary, pl: int, m: Dictionary) -> bool:
	var b := _apply_board(state["board"], pl, m)
	return not in_check(b, pl, state["alive"])

static func moves_from(state: Dictionary, pl: int, i: int) -> Array:
	var board: Array = state["board"]
	var c: int = board[i]
	var out: Array = []
	if c == 0 or p_owner(c) != pl:
		return out
	var k := p_kind(c)
	var pr := p_prom(c)
	for t in piece_targets(board, i):
		var options := [false]
		if not pr and CAN_PROMOTE[k] and (in_zone(pl, i) or in_zone(pl, t)):
			options = [true] if must_promote(k, pl, t) else [false, true]
		for op in options:
			var m := {"from": i, "to": t, "drop": -1, "promote": op}
			if _safe(state, pl, m):
				out.append(m)
	return out

static func drops_of(state: Dictionary, pl: int, kind: int) -> Array:
	var out: Array = []
	if state["hands"][pl][kind] <= 0:
		return out
	var board: Array = state["board"]
	var checked := in_check(board, pl, state["alive"])
	for t in CELLS:
		if not drop_ok(board, pl, kind, t):
			continue
		var m := {"from": -1, "to": t, "drop": kind, "promote": false}
		if checked and not _safe(state, pl, m):
			continue
		if kind == FU and _pawn_drop_mate(state, pl, t):
			continue
		out.append(m)
	return out


## 打ち歩詰め：歩を打って王手をかけた相手が、どう指しても逃げられなくなるか
static func _pawn_drop_mate(state: Dictionary, pl: int, t: int) -> bool:
	var b: Array = state["board"].duplicate()
	b[t] = make_piece(pl, FU, false)
	var hit := piece_targets(b, t)
	for o in 3:
		if o == pl or not state["alive"][o]:
			continue
		var k := find_king(b, o)
		if k < 0 or not hit.has(k):
			continue
		var s2 := {"board": b, "hands": state["hands"].duplicate(true), "alive": state["alive"]}
		s2["hands"][pl][FU] -= 1
		if not has_legal_move(s2, o):
			return true
	return false

static func legal_moves(state: Dictionary, pl: int) -> Array:
	var out: Array = []
	var board: Array = state["board"]
	for i in CELLS:
		if board[i] != 0 and p_owner(board[i]) == pl:
			out.append_array(moves_from(state, pl, i))
	for k in HAND_KINDS:
		out.append_array(drops_of(state, pl, k))
	return out

static func has_legal_move(state: Dictionary, pl: int) -> bool:
	var board: Array = state["board"]
	for i in CELLS:
		if board[i] != 0 and p_owner(board[i]) == pl:
			if not moves_from(state, pl, i).is_empty():
				return true
	for k in HAND_KINDS:
		if not drops_of(state, pl, k).is_empty():
			return true
	return false

static func is_legal(state: Dictionary, pl: int, m: Dictionary) -> bool:
	if not (m.has("from") and m.has("to") and m.has("drop") and m.has("promote")):
		return false
	var list: Array
	if int(m["drop"]) >= 0:
		if int(m["drop"]) >= HAND_KINDS:
			return false
		list = drops_of(state, pl, int(m["drop"]))
	else:
		if int(m["from"]) < 0 or int(m["from"]) >= CELLS:
			return false
		list = moves_from(state, pl, int(m["from"]))
	for x in list:
		if x["to"] == int(m["to"]) and x["promote"] == bool(m["promote"]):
			return true
	return false


# ---------- 手を進める ----------

static func eliminate(state: Dictionary, pl: int, reason: String) -> void:
	if not state["alive"][pl]:
		return
	state["alive"][pl] = false
	var board: Array = state["board"]
	for i in CELLS:
		if board[i] != 0 and p_owner(board[i]) == pl:
			board[i] = 0
	state["hands"][pl].fill(0)
	state["log"].append("%s: %s" % [player_name_default(pl), reason])

static func player_name_default(p: int) -> String:
	return ["赤", "青", "緑"][p]

static func alive_count(state: Dictionary) -> int:
	var n := 0
	for a in state["alive"]:
		if a: n += 1
	return n

static func _check_winner(state: Dictionary) -> bool:
	if alive_count(state) <= 1:
		for p in 3:
			if state["alive"][p]:
				state["winner"] = p
		return true
	return false

## 手番を次の人に回す。動けない人は詰みとして脱落させる。
## 王手をかけられた人がいれば、その人が先に指す（そのあとはその人の次から順に回る）。
static func advance_turn(state: Dictionary) -> void:
	if _check_winner(state):
		return
	if state["move_no"] >= MAX_MOVES:
		state["winner"] = DRAW
		state["log"].append("%d手に達したので引き分け" % MAX_MOVES)
		return
	var p: int = state["turn"]
	for k in [1, 2]:
		var q: int = (p + k) % 3
		if not state["alive"][q] or not in_check(state["board"], q, state["alive"]):
			continue
		if has_legal_move(state, q):
			state["turn"] = q
			state["log"].append("　→ %sに王手！%sが先に指す" % [player_name_default(q), player_name_default(q)])
			return
		eliminate(state, q, "詰み（王手から逃げられない）")
		if _check_winner(state):
			return
	for _n in 6:
		p = (p + 1) % 3
		if not state["alive"][p]:
			continue
		if has_legal_move(state, p):
			state["turn"] = p
			return
		eliminate(state, p, "詰み（指せる手がない）")
		if _check_winner(state):
			return

static func apply_move(state: Dictionary, m: Dictionary) -> void:
	var pl: int = state["turn"]
	var board: Array = state["board"]
	var to := int(m["to"])
	var text := ""
	state["last_cap"] = false
	if int(m["drop"]) >= 0:
		var k := int(m["drop"])
		board[to] = make_piece(pl, k, false)
		state["hands"][pl][k] -= 1
		text = "%s打" % NAMES[k]
		state["last_from"] = -1
	else:
		var from := int(m["from"])
		var c: int = board[from]
		var cap: int = board[to]
		var promote := bool(m["promote"])
		board[to] = make_piece(pl, p_kind(c), p_prom(c) or promote)
		board[from] = 0
		text = piece_label(c) + ("成" if promote else "")
		state["last_from"] = from
		if cap != 0:
			state["last_cap"] = true
			var co := p_owner(cap)
			if p_kind(cap) == OU:
				text += " 玉を取った！"
				state["move_no"] += 1
				state["log"].append("%s %d手目 %s" % [player_name_default(pl), state["move_no"], text])
				state["last_to"] = to
				eliminate(state, co, "玉を取られた")
				advance_turn(state)
				return
			state["hands"][pl][p_kind(cap)] += 1
			text += "（%sを取る）" % NAMES[p_kind(cap)]
	state["last_to"] = to
	state["move_no"] += 1
	state["log"].append("%s %d手目 %s" % [player_name_default(pl), state["move_no"], text])
	advance_turn(state)

static func resign(state: Dictionary, pl: int) -> void:
	if not state["alive"][pl] or state["winner"] >= 0:
		return
	var was_turn: bool = state["turn"] == pl
	eliminate(state, pl, "投了")
	if was_turn:
		advance_turn(state)
	else:
		_check_winner(state)


# ---------- コンピュータ ----------

static func cpu_choose(state: Dictionary, pl: int) -> Dictionary:
	var moves: Array = []
	var board0: Array = state["board"]
	for i in CELLS:
		if board0[i] != 0 and p_owner(board0[i]) == pl:
			moves.append_array(moves_from(state, pl, i))
	# 打つ手は数が多いので、くじ引きで一部だけ考える
	var drops: Array = []
	for k in HAND_KINDS:
		drops.append_array(drops_of(state, pl, k))
	drops.shuffle()
	moves.append_array(drops.slice(0, 25))
	if moves.is_empty():
		return {}
	var board: Array = state["board"]
	var best: Dictionary = moves[0]
	var best_score := -99999.0
	for m in moves:
		var score := randf() * 2.0
		var b := _apply_board(board, pl, m)
		var to: int = m["to"]
		var moved: int = b[to]
		if m["drop"] < 0 and board[to] != 0:
			var cap: int = board[to]
			score += VALUE[p_kind(cap)] * 10.0 * (3.0 if p_prom(cap) else 1.0)
		if m["promote"]:
			score += 6.0
		if is_attacked(b, to, pl, state["alive"]):
			score -= VALUE[p_kind(moved)] * 9.0
		# 相手に王手をかける手を少し好む
		for o in 3:
			if o != pl and state["alive"][o] and in_check(b, o, state["alive"]):
				score += 4.0
		if m["drop"] >= 0:
			score -= 1.0
		if score > best_score:
			best_score = score
			best = m
	return best
