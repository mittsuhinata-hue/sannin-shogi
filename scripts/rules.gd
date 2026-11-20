extends RefCounted
## 三人将棋のルール（盤の形・駒の動き・勝敗）。
## 画面や通信には関係しない、純粋な計算だけを置く。
##
## 盤：3人それぞれの陣地 h(0..2) が 段 r(0..RANKS-1) × 筋 f(0..FILES-1)。
##   r=0 が自分の一番奥（玉のいる段）、r=TOP が中央に接する段。
##   f<MID の先は左隣 (h+2) の陣地、f>MID の先は右隣 (h+1) の陣地。
##   真ん中の f=MID の先は、盤の中心にある三角形のマス「中央」。
## マス番号 = h*HALF + r*FILES + f、中央 = 3*HALF
##
## 将棋の種類（標準・ミニ・大きめ・大局将棋風）は VARIANTS で決める。
## 対局ごとに state["variant"] を持ち、計算の前に use(state) で切り替える。

# ---------- 駒の種類 ----------
const FU := 0
const KY := 1
const KE := 2
const GI := 3
const KI := 4
const KA := 5
const HI := 6
const OU := 7
const RYUMA := 8
const RYUO := 9
const SUIZO := 10
const TAISHI := 11
const MOKO := 12
const HIROKU := 13
const MOHYO := 14
const DOSHO := 15
const OGYO := 16
const HONCHO := 17
const JUGYO := 18
const HIGYU := 19
const HANSHA := 20
const KEIGEI := 21
const KIRIN := 22
const SHISHI := 23
const HOO := 24
const HONNO := 25
const CHUNIN := 26
const TESSHO := 27
const SEKISHO := 28
const DOSHO_E := 29
const MOKUSHO := 30
const MYOJIN := 31
const SHINCHO := 32
const AKURO := 33
const MOGYU := 34
const HIRYU := 35

# 持ち主から見た向き [前, 右]
const F_ := [1, 0]
const B_ := [-1, 0]
const L_ := [0, -1]
const R_ := [0, 1]
const FL := [1, -1]
const FR := [1, 1]
const BL := [-1, -1]
const BR := [-1, 1]

const GOLD_STEPS := [[1, -1], [1, 0], [1, 1], [0, -1], [0, 1], [-1, 0]]
const SILVER_STEPS := [[1, -1], [1, 0], [1, 1], [-1, -1], [-1, 1]]
const KING_STEPS := [[1, -1], [1, 0], [1, 1], [0, -1], [0, 1], [-1, -1], [-1, 0], [-1, 1]]
const ORTHO := [[1, 0], [-1, 0], [0, 1], [0, -1]]
const DIAG := [[1, 1], [1, -1], [-1, 1], [-1, -1]]

## 駒の決まり。
##  n=盤に出す字、full=名前、d=動きの説明、step=1マス、slide=どこまでも、lim=[[向き,最大マス数]]、
##  jump=[[1歩目,2歩目]]（間を跳び越す）、lion=2マス以内どこでも、promo=成ったら何の動きになるか（-1は成れない）、
##  pl=成ったときの字（空なら promo の駒の字）、royal=取られてはいけない駒、v=CPU用の値打ち、dead=相手陣の奥から何段は動けない
const PIECES := [
	{"n": "歩", "full": "歩兵", "d": "前に1マス", "step": [[1, 0]], "promo": KI, "pl": "と", "v": 1, "dead": 1},
	{"n": "香", "full": "香車", "d": "前にどこまでも", "slide": [[1, 0]], "promo": KI, "pl": "杏", "v": 3, "dead": 1},
	{"n": "桂", "full": "桂馬", "d": "前に2・横に1の所へ跳ぶ", "jump": [[[1, 0], [1, -1]], [[1, 0], [1, 1]]], "promo": KI, "pl": "圭", "v": 4, "dead": 2},
	{"n": "銀", "full": "銀将", "d": "斜め4方向と前に1マス", "step": SILVER_STEPS, "promo": KI, "pl": "全", "v": 5},
	{"n": "金", "full": "金将", "d": "斜め後ろ以外に1マス", "step": GOLD_STEPS, "v": 6},
	{"n": "角", "full": "角行", "d": "斜めにどこまでも", "slide": DIAG, "promo": RYUMA, "pl": "馬", "v": 8},
	{"n": "飛", "full": "飛車", "d": "縦横にどこまでも", "slide": ORTHO, "promo": RYUO, "pl": "龍", "v": 10},
	{"n": "玉", "full": "玉将", "d": "全方向に1マス", "step": KING_STEPS, "royal": true, "v": 50},
	{"n": "馬", "full": "龍馬", "d": "斜めにどこまでも＋縦横に1マス", "slide": DIAG, "step": ORTHO, "v": 11},
	{"n": "龍", "full": "龍王", "d": "縦横にどこまでも＋斜めに1マス", "slide": ORTHO, "step": DIAG, "v": 13},
	{"n": "象", "full": "酔象", "d": "真後ろ以外に1マス（成ると太子）", "step": [[1, 0], [1, -1], [1, 1], [0, -1], [0, 1], [-1, -1], [-1, 1]], "promo": TAISHI, "v": 6},
	{"n": "太", "full": "太子", "d": "全方向に1マス（玉と同じく大事な駒）", "step": KING_STEPS, "royal": true, "v": 40},
	{"n": "虎", "full": "盲虎", "d": "真前以外に1マス", "step": [[1, -1], [1, 1], [0, -1], [0, 1], [-1, 0], [-1, -1], [-1, 1]], "promo": HIROKU, "v": 6},
	{"n": "鹿", "full": "飛鹿", "d": "縦にどこまでも＋全方向に1マス", "slide": [[1, 0], [-1, 0]], "step": KING_STEPS, "v": 10},
	{"n": "豹", "full": "猛豹", "d": "前3方向と後ろ3方向に1マス", "step": [[1, 0], [1, -1], [1, 1], [-1, 0], [-1, -1], [-1, 1]], "promo": KA, "v": 5},
	{"n": "銅", "full": "銅将", "d": "前3方向と真後ろに1マス", "step": [[1, 0], [1, -1], [1, 1], [-1, 0]], "promo": OGYO, "v": 4},
	{"n": "横", "full": "横行", "d": "横にどこまでも＋縦に1マス", "slide": [[0, -1], [0, 1]], "step": [[1, 0], [-1, 0]], "promo": HONCHO, "v": 7},
	{"n": "猪", "full": "奔猪", "d": "横と斜めにどこまでも", "slide": [[0, -1], [0, 1], [1, -1], [1, 1], [-1, -1], [-1, 1]], "v": 11},
	{"n": "竪", "full": "竪行", "d": "縦にどこまでも＋横に1マス", "slide": [[1, 0], [-1, 0]], "step": [[0, -1], [0, 1]], "promo": HIGYU, "v": 6},
	{"n": "牛", "full": "飛牛", "d": "縦と斜めにどこまでも", "slide": [[1, 0], [-1, 0], [1, -1], [1, 1], [-1, -1], [-1, 1]], "v": 11},
	{"n": "反", "full": "反車", "d": "前と後ろにどこまでも", "slide": [[1, 0], [-1, 0]], "promo": KEIGEI, "v": 5},
	{"n": "鯨", "full": "鯨鯢", "d": "前・後ろ・斜め後ろにどこまでも", "slide": [[1, 0], [-1, 0], [-1, -1], [-1, 1]], "v": 8},
	{"n": "麒", "full": "麒麟", "d": "斜めに1マス＋縦横の2マス先へ跳ぶ", "step": DIAG, "jump": [[[1, 0], [1, 0]], [[-1, 0], [-1, 0]], [[0, -1], [0, -1]], [[0, 1], [0, 1]]], "promo": SHISHI, "v": 9},
	{"n": "獅", "full": "獅子", "d": "2マス以内ならどこへでも（間を跳び越せる）", "lion": true, "v": 20},
	{"n": "鳳", "full": "鳳凰", "d": "縦横に1マス＋斜めの2マス先へ跳ぶ", "step": ORTHO, "jump": [[[1, -1], [1, -1]], [[1, 1], [1, 1]], [[-1, -1], [-1, -1]], [[-1, 1], [-1, 1]]], "promo": HONNO, "v": 9},
	{"n": "奔", "full": "奔王", "d": "全方向にどこまでも", "slide": KING_STEPS, "v": 18},
	{"n": "仲", "full": "仲人", "d": "前と後ろに1マス（成ると酔象）", "step": [[1, 0], [-1, 0]], "promo": SUIZO, "v": 2},
	{"n": "鉄", "full": "鉄将", "d": "前3方向に1マス", "step": [[1, 0], [1, -1], [1, 1]], "promo": KI, "v": 3},
	{"n": "石", "full": "石将", "d": "斜め前に1マス", "step": [[1, -1], [1, 1]], "promo": KI, "v": 2},
	{"n": "土", "full": "土将", "d": "前と横に1マス", "step": [[1, 0], [0, -1], [0, 1]], "promo": KI, "v": 2},
	{"n": "木", "full": "木将", "d": "斜め前に2マスまで", "lim": [[[1, -1], 2], [[1, 1], 2]], "promo": KI, "v": 3},
	{"n": "猫", "full": "猫刄", "d": "斜めに1マス", "step": DIAG, "promo": MOKO, "v": 3},
	{"n": "嗔", "full": "嗔猪", "d": "縦横に1マス", "step": ORTHO, "promo": MOHYO, "v": 3},
	{"n": "狼", "full": "悪狼", "d": "前3方向と横に1マス", "step": [[1, 0], [1, -1], [1, 1], [0, -1], [0, 1]], "promo": KI, "v": 4},
	{"n": "猛", "full": "猛牛", "d": "縦横に2マスまで", "lim": [[[1, 0], 2], [[-1, 0], 2], [[0, -1], 2], [[0, 1], 2]], "promo": HIGYU, "v": 7},
	{"n": "竜", "full": "飛龍", "d": "斜めに2マスまで", "lim": [[[1, -1], 2], [[1, 1], 2], [[-1, -1], 2], [[-1, 1], 2]], "promo": RYUMA, "v": 7},
]

const NAMES := ["歩", "香", "桂", "銀", "金", "角", "飛", "玉"]
const HAND_KINDS := 7  # 持ち駒にできるのは 歩〜飛

# ---------- 将棋の種類 ----------

const _E := -1  # 空きマス

## rows は自分の一番奥の段から順に、左から右へ。
## check=true なら王手放置は反則で詰みで決着（標準・ミニ）。
## check=false なら玉（royal の駒）を全部取られたら負け（大きめ・大局将棋風、中将棋と同じ）。
const VARIANTS := {
	"standard": {
		"name": "標準（9筋）", "files": 9, "ranks": 5, "zone": 3, "drops": true, "check": true, "zoom": 3.0,
		"note": "9筋×5段。取った駒を打てる。詰みで勝ち負け",
		"rows": [
			[KY, KE, GI, KI, OU, KI, GI, KE, KY],
			[_E, KA, _E, _E, _E, _E, _E, HI, _E],
			[FU, FU, FU, FU, FU, FU, FU, FU, FU],
		],
	},
	"mini": {
		"name": "ミニ（5筋）", "files": 5, "ranks": 3, "zone": 1, "drops": true, "check": true, "zoom": 2.0,
		"note": "5筋×3段の小さな盤。取った駒を打てる。詰みで勝ち負け",
		"rows": [
			[HI, GI, OU, KI, KA],
			[FU, FU, FU, FU, FU],
		],
	},
	"chu": {
		"name": "大きめ（13筋）", "files": 13, "ranks": 7, "zone": 3, "drops": false, "check": false, "zoom": 4.0,
		"note": "13筋×7段。中将棋の駒が入る。取った駒は使えない。玉（と太子）を全部取られたら負け",
		"rows": [
			[KY, MOHYO, DOSHO, GI, KI, MOKO, OU, SUIZO, KI, GI, DOSHO, MOHYO, KY],
			[HANSHA, _E, KA, _E, KIRIN, _E, SHISHI, _E, HOO, _E, KA, _E, HANSHA],
			[OGYO, JUGYO, HI, RYUMA, RYUO, _E, HONNO, _E, RYUO, RYUMA, HI, JUGYO, OGYO],
			[FU, FU, FU, FU, FU, FU, FU, FU, FU, FU, FU, FU, FU],
			[_E, _E, _E, CHUNIN, _E, _E, _E, _E, _E, CHUNIN, _E, _E, _E],
		],
	},
	"taikyoku": {
		"name": "大局将棋風（25筋）", "files": 25, "ranks": 9, "zone": 4, "drops": false, "check": false, "zoom": 7.0,
		"note": "25筋×9段の特大の盤。大局将棋の駒を約36種類。取った駒は使えない。玉（と太子）を全部取られたら負け",
		"half_rows": [
			# [左から12マス, 真ん中] 右側は左の鏡写し
			[[KY, KE, SEKISHO, TESSHO, DOSHO_E, MOKUSHO, DOSHO, GI, KI, MOHYO, MOKO, SUIZO], OU],
			[[HANSHA, _E, MYOJIN, _E, SHINCHO, _E, AKURO, _E, KIRIN, _E, HOO, _E], SHISHI],
			[[OGYO, JUGYO, KA, _E, HIRYU, _E, MOGYU, _E, HI, RYUMA, RYUO, _E], HONNO],
			[[AKURO, MYOJIN, SHINCHO, DOSHO_E, TESSHO, SEKISHO, MOKUSHO, DOSHO, MOGYU, HIRYU, OGYO, JUGYO], SUIZO],
			[[FU, FU, FU, FU, FU, FU, FU, FU, FU, FU, FU, FU], FU],
			[[_E, _E, _E, _E, _E, _E, CHUNIN, _E, _E, _E, _E, _E], _E],
		],
	},
}
const VARIANT_ORDER := ["standard", "mini", "chu", "taikyoku"]

# いまの種類の決まり（use / set_variant で切り替わる）
static var VARIANT_ID := ""
static var FILES := 9
static var RANKS := 5
static var TOP := 4          ## 中央に接する段
static var MID := 4          ## 真ん中の筋
static var HALF := 45
static var CENTER := 135
static var CELLS := 136
static var ZONE := 3         ## 相手陣の奥から何段で成れるか
static var DROPS := true     ## 取った駒を打てるか
static var CHECK_RULE := true  ## 王手放置が反則か（false なら玉を取ったら勝ち）

const MAX_MOVES := 600
const DRAW := 3   ## winner がこの値なら引き分け（0..2 は勝者、-1 は対局中）

static var _ver := 0           ## 盤が変わるたびに増える（利きの表の作り直し判定用）
static var _att_board = null
static var _att_ver := -1
static var _att_maps: Array = []


static func set_variant(id: String) -> void:
	if not VARIANTS.has(id):
		id = "standard"
	if id == VARIANT_ID:
		return
	var v: Dictionary = VARIANTS[id]
	VARIANT_ID = id
	FILES = v["files"]
	RANKS = v["ranks"]
	TOP = RANKS - 1
	MID = (FILES - 1) / 2
	HALF = FILES * RANKS
	CENTER = 3 * HALF
	CELLS = CENTER + 1
	ZONE = v["zone"]
	DROPS = v["drops"]
	CHECK_RULE = v["check"]
	_att_board = null

static func use(state: Dictionary) -> void:
	set_variant(str(state.get("variant", "standard")))

static func variant_info(id: String = "") -> Dictionary:
	return VARIANTS.get(id if id != "" else VARIANT_ID, VARIANTS["standard"])

static func _rows_of(v: Dictionary) -> Array:
	if v.has("rows"):
		return v["rows"]
	var out: Array = []
	for hr in v["half_rows"]:
		var left: Array = hr[0]
		var right := left.duplicate()
		right.reverse()
		out.append(left + [hr[1]] + right)
	return out


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

## 駒の番号：1 + 持ち主 + 3×(種類×2 + 成り)
static func make_piece(owner: int, kind: int, promoted: bool) -> int:
	return 1 + owner + 3 * (kind * 2 + (1 if promoted else 0))

static func p_owner(c: int) -> int:
	return (c - 1) % 3

static func p_kind(c: int) -> int:
	return ((c - 1) / 3) / 2

static func p_prom(c: int) -> bool:
	return ((c - 1) / 3) % 2 == 1

## その駒がいま従う動きの決まり（成っていれば成った先の駒の動き）
static func move_def(kind: int, prom: bool) -> Dictionary:
	var d: Dictionary = PIECES[kind]
	if prom and d.get("promo", -1) >= 0:
		return PIECES[d["promo"]]
	return d

static func can_promote(kind: int) -> bool:
	return PIECES[kind].get("promo", -1) >= 0

static func kind_name(kind: int) -> String:
	return PIECES[kind]["n"]

static func piece_label(c: int) -> String:
	var d: Dictionary = PIECES[p_kind(c)]
	if p_prom(c) and d.get("promo", -1) >= 0:
		return d["pl"] if d.get("pl", "") != "" else PIECES[d["promo"]]["n"]
	return d["n"]

## 駒の名前と動きの説明（画面の案内用）
static func piece_help(c: int) -> String:
	var d := move_def(p_kind(c), p_prom(c))
	var name: String = d["full"]
	if p_prom(c):
		name = "%s（%sが成った駒）" % [name, PIECES[p_kind(c)]["full"]]
	var text := "%s：%s" % [name, d["d"]]
	if not p_prom(c) and can_promote(p_kind(c)):
		text += "。成ると%s" % PIECES[PIECES[p_kind(c)]["promo"]]["full"]
	return text

static func is_royal(c: int) -> bool:
	return c != 0 and move_def(p_kind(c), p_prom(c)).get("royal", false)

static func piece_value(c: int) -> int:
	return move_def(p_kind(c), p_prom(c)).get("v", 3)


# ---------- 新しい対局 ----------

static func new_game(variant: String = "standard") -> Dictionary:
	set_variant(variant)
	var board: Array = []
	board.resize(CELLS)
	board.fill(0)
	var rows := _rows_of(VARIANTS[VARIANT_ID])
	for p in 3:
		for r in rows.size():
			var row: Array = rows[r]
			for f in FILES:
				if row[f] >= 0:
					board[idx(p, r, f)] = make_piece(p, row[f], false)
	var hands: Array = []
	for p in 3:
		var hnd: Array = []
		hnd.resize(HAND_KINDS)
		hnd.fill(0)
		hands.append(hnd)
	return {
		"variant": VARIANT_ID,
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
		return [3, 0, 0, 0, 0]   # 真ん中の筋をまっすぐ進むと中央
	# 中央の三角マスの角をはさんだ斜め：真ん中の両隣の筋の奥 ⇔ となりの人の真ん中の筋の奥
	if f == MID - 1 and nf == MID:
		return [(h + 2) % 3, TOP, MID, -1, -1]
	if f == MID + 1 and nf == MID:
		return [(h + 1) % 3, TOP, MID, -1, 1]
	var q := (h + 1) % 3 if nf > MID else (h + 2) % 3
	return [q, TOP, (FILES - 1) - nf, -dr, -df]

## 中央のマスから、持ち主の向きで v=(前, 右) へ進んだ先（複数あり得る）。
## 前＝相手2人の真ん中の筋、後ろ＝自分の真ん中の筋。中央は真ん中の筋とだけつながる。
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

## 駒の居場所 [h, r, f, s]（s はその陣地での「前」の向き）。中央は [3, 0, 0, 0]
static func _start(owner: int, i: int) -> Array:
	if i == CENTER:
		return [3, 0, 0, 0]
	var h := cell_h(i)
	return [h, cell_r(i), cell_f(i), orient(owner, h)]

## 居場所 pos から、持ち主の向き v に1歩進んだ先の一覧（中央では分かれることがある）
static func _adv(owner: int, pos: Array, v: Array) -> Array:
	if pos[0] == 3:
		var out: Array = []
		for a in center_steps(owner, v):
			out.append([a[0], a[1], a[2], -int(v[0])])
		return out
	var s: int = pos[3]
	var a := step(pos[0], pos[1], pos[2], s * v[0], s * v[1])
	if a.is_empty():
		return []
	if a[0] == 3:
		return [[3, 0, 0, 0]]
	return [[a[0], a[1], a[2], s if a[0] == pos[0] else -s]]

static func _pi(pos: Array) -> int:
	return CENTER if pos[0] == 3 else idx(pos[0], pos[1], pos[2])

## マス i にいる owner の駒が、向き v に1歩進んだ先の一覧（二歩の確認などで使う）
static func _neighbors(owner: int, i: int, v: Array) -> Array:
	var out: Array = []
	for p in _adv(owner, _start(owner, i), v):
		out.append([p[0], p[1], p[2]])
	return out


# ---------- 駒の動き（自分の玉の安全は見ない） ----------

static func piece_targets(board: Array, i: int) -> Array:
	var c: int = board[i]
	if c == 0:
		return []
	var o := p_owner(c)
	var d := move_def(p_kind(c), p_prom(c))
	var start := _start(o, i)
	var out := {}
	for v in d.get("step", []):
		for p in _adv(o, start, v):
			_add_if(board, o, _pi(p), out)
	for v in d.get("slide", []):
		_slide(board, o, start, v, 999, out)
	for item in d.get("lim", []):
		_slide(board, o, start, item[0], item[1], out)
	for seq in d.get("jump", []):
		var ps: Array = [start]
		for v in seq:
			var nx: Array = []
			for p in ps:
				nx.append_array(_adv(o, p, v))
			ps = nx
		for p in ps:
			_add_if(board, o, _pi(p), out)
	if d.get("lion", false):
		for v1 in KING_STEPS:
			for p1 in _adv(o, start, v1):
				_add_if(board, o, _pi(p1), out)
				for v2 in KING_STEPS:
					for p2 in _adv(o, p1, v2):
						var t := _pi(p2)
						if t != i:
							_add_if(board, o, t, out)
	return out.keys()

static func _add_if(board: Array, o: int, t: int, out: Dictionary) -> void:
	if board[t] == 0 or p_owner(board[t]) != o:
		out[t] = true

## どこまでも（または n マスまで）進む。駒に当たったら止まる。中央では道が分かれる。
static func _slide(board: Array, o: int, start: Array, v: Array, n: int, out: Dictionary) -> void:
	var front: Array = [start]
	var seen := {}
	for _k in min(n, 60):
		var nx: Array = []
		for p in front:
			for q in _adv(o, p, v):
				var t := _pi(q)
				if seen.has(t):
					continue
				seen[t] = true
				if board[t] != 0:
					if p_owner(board[t]) != o:
						out[t] = true
					continue
				out[t] = true
				nx.append(q)
		if nx.is_empty():
			break
		front = nx


# ---------- 王手・利き ----------

static func find_king(board: Array, pl: int) -> int:
	var want := make_piece(pl, OU, false)
	for i in CELLS:
		if board[i] == want:
			return i
	return -1

static func royal_cells(board: Array, pl: int) -> Array:
	var out: Array = []
	for i in CELLS:
		var c: int = board[i]
		if c != 0 and p_owner(c) == pl and is_royal(c):
			out.append(i)
	return out

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

## 3人それぞれの駒が利いているマスの表（同じ盤なら作り直さない）
static func attack_maps(board: Array) -> Array:
	if is_same(board, _att_board) and _att_ver == _ver:
		return _att_maps
	var maps: Array = [{}, {}, {}]
	for i in CELLS:
		var c: int = board[i]
		if c == 0:
			continue
		var m: Dictionary = maps[p_owner(c)]
		for t in piece_targets(board, i):
			m[t] = true
	_att_board = board
	_att_ver = _ver
	_att_maps = maps
	return maps

static func in_check(board: Array, pl: int, alive: Array) -> bool:
	if CHECK_RULE:
		var k := find_king(board, pl)
		if k < 0:
			return false
		return is_attacked(board, k, pl, alive)
	var maps := attack_maps(board)
	for k in royal_cells(board, pl):
		for o in 3:
			if o != pl and alive[o] and maps[o].has(k):
				return true
	return false


# ---------- 成り ----------

static func in_zone(pl: int, i: int) -> bool:
	return i != CENTER and cell_h(i) != pl and cell_r(i) < ZONE

static func must_promote(kind: int, pl: int, t: int) -> bool:
	if t == CENTER or cell_h(t) == pl:
		return false
	var dead: int = PIECES[kind].get("dead", 0)
	return dead > 0 and cell_r(t) < dead


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
		for _n in 60:
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
	if not CHECK_RULE:
		return true   # 玉を取ったら勝ちの種類では、王手を放っておいてもよい
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
		if not pr and can_promote(k) and (in_zone(pl, i) or in_zone(pl, t)):
			options = [true] if must_promote(k, pl, t) else [false, true]
		for op in options:
			var m := {"from": i, "to": t, "drop": -1, "promote": op}
			if _safe(state, pl, m):
				out.append(m)
	return out

static func drops_of(state: Dictionary, pl: int, kind: int) -> Array:
	var out: Array = []
	if not DROPS or kind >= HAND_KINDS or state["hands"][pl][kind] <= 0:
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
			if not CHECK_RULE:
				if not piece_targets(board, i).is_empty():
					return true
			elif not moves_from(state, pl, i).is_empty():
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
	_ver += 1
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
	use(state)
	var pl: int = state["turn"]
	var board: Array = state["board"]
	var to := int(m["to"])
	var text := ""
	state["last_cap"] = false
	if int(m["drop"]) >= 0:
		var k := int(m["drop"])
		board[to] = make_piece(pl, k, false)
		state["hands"][pl][k] -= 1
		text = "%s打" % kind_name(k)
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
			_ver += 1
			if is_royal(cap) and (CHECK_RULE or royal_cells(board, co).is_empty()):
				text += " %sを取った！" % piece_label(cap)
				state["move_no"] += 1
				state["log"].append("%s %d手目 %s" % [player_name_default(pl), state["move_no"], text])
				state["last_to"] = to
				eliminate(state, co, "玉を取られた")
				advance_turn(state)
				return
			if DROPS and p_kind(cap) < HAND_KINDS:
				state["hands"][pl][p_kind(cap)] += 1
			text += "（%sを取る）" % piece_label(cap)
	_ver += 1
	state["last_to"] = to
	state["move_no"] += 1
	state["log"].append("%s %d手目 %s" % [player_name_default(pl), state["move_no"], text])
	var gave_check := false
	for o in 3:
		if o != pl and state["alive"][o] and in_check(board, o, state["alive"]):
			gave_check = true
	advance_turn(state)
	if state["winner"] < 0:
		_record_position(state, pl, gave_check)


# ---------- 千日手 ----------

static func _position_key(state: Dictionary) -> int:
	return ("%s|%s|%d|%s" % [state["board"], state["hands"], state["turn"], state["alive"]]).hash()

## 局面を覚え、同じ局面が4回目なら千日手にする。
## その間ずっと王手をかけ続けた人がいればその人の負け、いなければ引き分け。
static func _record_position(state: Dictionary, mover: int, gave_check: bool) -> void:
	if not state.has("positions"):
		state["positions"] = []
		state["movers"] = []
		state["checks"] = []
	var key := _position_key(state)
	var positions: Array = state["positions"]
	positions.append(key)
	state["movers"].append(mover)
	state["checks"].append(gave_check)
	if positions.count(key) < 4:
		return
	var first := positions.find(key)
	for x in 3:
		if not state["alive"][x]:
			continue
		var moved := 0
		var all_check := true
		for j in range(first + 1, positions.size()):
			if state["movers"][j] == x:
				moved += 1
				if not state["checks"][j]:
					all_check = false
		if moved > 0 and all_check:
			state["log"].append("千日手（%sの連続王手）" % player_name_default(x))
			var was_turn: bool = state["turn"] == x
			eliminate(state, x, "連続王手の千日手で負け")
			_reset_positions(state)
			if not _check_winner(state) and was_turn:
				advance_turn(state)
			return
	state["winner"] = DRAW
	state["log"].append("千日手（同じ局面が4回）で引き分け")


static func _reset_positions(state: Dictionary) -> void:
	state["positions"] = []
	state["movers"] = []
	state["checks"] = []

## 時間切れ：その人の負け
static func timeout(state: Dictionary, pl: int) -> void:
	use(state)
	if not state["alive"][pl] or state["winner"] >= 0:
		return
	var was_turn: bool = state["turn"] == pl
	eliminate(state, pl, "時間切れ")
	if was_turn:
		advance_turn(state)
	else:
		_check_winner(state)

static func resign(state: Dictionary, pl: int) -> void:
	use(state)
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
	use(state)
	if not CHECK_RULE:
		return _cpu_big(state, pl)
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
			score += piece_value(cap) * 10.0
		if m["promote"]:
			score += 6.0
		if is_attacked(b, to, pl, state["alive"]):
			score -= piece_value(moved) * 9.0
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

## 大きい盤用の速いCPU：相手の利きの表を1回だけ作り、取る・逃げる・取られないを見る
static func _cpu_big(state: Dictionary, pl: int) -> Dictionary:
	var board: Array = state["board"]
	var maps := attack_maps(board)
	var danger := {}
	for o in 3:
		if o != pl and state["alive"][o]:
			danger.merge(maps[o])
	var best := {}
	var best_score := -1e9
	for i in CELLS:
		var c: int = board[i]
		if c == 0 or p_owner(c) != pl:
			continue
		var val := piece_value(c)
		var k := p_kind(c)
		for t in piece_targets(board, i):
			var score := randf() * 2.0
			var cap: int = board[t]
			if cap != 0:
				score += piece_value(cap) * 10.0 + (1000.0 if is_royal(cap) else 0.0)
			if danger.has(t):
				score -= val * (60.0 if is_royal(c) else 9.0)
			if danger.has(i):
				score += val * 5.0
			var prom := false
			if not p_prom(c) and can_promote(k) and (in_zone(pl, i) or in_zone(pl, t)):
				prom = true
				score += 4.0
			if score > best_score:
				best_score = score
				best = {"from": i, "to": t, "drop": -1, "promote": prom}
	return best
