extends Control
## 六角形の盤と駒台を描き、クリックで駒を動かす。

const Rules = preload("res://scripts/rules.gd")

signal move_chosen(m: Dictionary)
signal promotion_choice(m_no: Dictionary, m_yes: Dictionary)
signal selection_changed

const PLAYER_COLORS := [Color(0.80, 0.15, 0.15), Color(0.15, 0.30, 0.85), Color(0.10, 0.55, 0.20)]
const HALF_TINT := [Color(0.93, 0.80, 0.60), Color(0.88, 0.80, 0.66), Color(0.90, 0.84, 0.62)]
const CENTER_TINT := Color(0.86, 0.74, 0.55)
const LINE_COL := Color(0.25, 0.15, 0.05)
const HAND_ORDER := [6, 5, 4, 3, 2, 1, 0]  # 飛 角 金 銀 桂 香 歩

var state: Dictionary = {}
var view_seat := 0        ## 下に来る人
var my_seat := -1         ## いま操作できる人（-1 なら操作できない）
var names: Array = ["赤", "青", "緑"]

var selected_from := -1
var selected_drop := -1
var targets: Array = []   ## 選んだ駒の合法手

var _font: Font
var _polys: Array = []    ## マスごとの多角形
var _centers: Array = []
var _sizes: Array = []
var _center := Vector2.ZERO
var _radius := 100.0
var _hand_hits: Array = []  ## [Rect2, 席, 駒の種類]


func _ready() -> void:
	_font = preload("res://scripts/ui_font.gd").make(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_rebuild)
	_rebuild()


func set_state(s: Dictionary) -> void:
	state = s
	clear_selection()
	queue_redraw()


func clear_selection() -> void:
	selected_from = -1
	selected_drop = -1
	targets = []
	selection_changed.emit()
	queue_redraw()


func set_view_seat(seat: int) -> void:
	if seat != view_seat:
		view_seat = seat
		_rebuild()


func select_drop(kind: int) -> void:
	if not _can_act():
		return
	if selected_drop == kind:
		clear_selection()
		return
	selected_from = -1
	selected_drop = kind
	targets = Rules.drops_of(state, my_seat, kind)
	Sfx.play("select")
	selection_changed.emit()
	queue_redraw()


func _can_act() -> bool:
	return not state.is_empty() and my_seat >= 0 and state["turn"] == my_seat and state["winner"] < 0


# ---------- 形の計算 ----------

func _hex_v(j: int) -> Vector2:
	var a0 := deg_to_rad(90.0 + (2 * view_seat + 0.5) * 60.0)
	var a := a0 - deg_to_rad(60.0) * posmod(j, 6)
	return _center + _radius * Vector2(cos(a), sin(a))

func _hex_m(j: int) -> Vector2:
	return (_hex_v(j) + _hex_v(j + 1)) * 0.5

## 中央の三角形の頂点（h と h+1 の境目の上）
func _q(h: int) -> Vector2:
	var m := _hex_m(2 * posmod(h, 3) + 1)
	return _center + (m - _center).normalized() * _radius * 0.11

## 陣地 h の (筋u, 段v) 座標 → 画面上の点。u:0..9, v:0..5
func _pt(h: int, u: float, v: float) -> Vector2:
	var k := 2 * h
	var back := _hex_v(k).lerp(_hex_v(k + 1), u / 9.0)
	var inner: Vector2
	if u <= 4.0:
		inner = _hex_m(k - 1).lerp(_q(h - 1), u / 4.0)
	elif u <= 5.0:
		inner = _q(h - 1).lerp(_q(h), u - 4.0)
	else:
		inner = _q(h).lerp(_hex_m(k + 1), (u - 5.0) / 4.0)
	return back.lerp(inner, v / 5.0)


func _rebuild() -> void:
	_center = size * 0.5
	_radius = min(size.x / 2.0, size.y / 1.732) * 0.90
	_polys.clear()
	_centers.clear()
	_sizes.clear()
	for i in Rules.CELLS:
		var poly: PackedVector2Array
		var c: Vector2
		if i == Rules.CENTER:
			poly = PackedVector2Array([_q(0), _q(1), _q(2)])
			c = _center
		else:
			var h := Rules.cell_h(i)
			var r := Rules.cell_r(i)
			var f := Rules.cell_f(i)
			poly = PackedVector2Array([_pt(h, f, r), _pt(h, f + 1, r), _pt(h, f + 1, r + 1), _pt(h, f, r + 1)])
			c = _pt(h, f + 0.5, r + 0.5)
		_polys.append(poly)
		_centers.append(c)
		var m := INF
		for e in poly.size():
			m = min(m, poly[e].distance_to(poly[(e + 1) % poly.size()]))
		if i == Rules.CENTER:
			m *= 0.75
		_sizes.append(m)
	queue_redraw()


func _forward_dir(owner: int, i: int) -> Vector2:
	if i == Rules.CENTER:
		return (_center - _hex_m(2 * owner)).normalized()
	var h := Rules.cell_h(i)
	var s := Rules.orient(owner, h)
	var u := Rules.cell_f(i) + 0.5
	var v := Rules.cell_r(i) + 0.5
	return (_pt(h, u, v + 0.3 * s) - _pt(h, u, v - 0.3 * s)).normalized()


# ---------- 描画 ----------

func _draw() -> void:
	if _polys.is_empty():
		return
	# 外枠
	var outline := PackedVector2Array()
	for j in 7:
		outline.append(_hex_v(j))
	draw_colored_polygon(outline, Color(0.45, 0.30, 0.15))
	var target_cells := {}
	for m in targets:
		target_cells[m["to"]] = true
	var check_king := -1
	if not state.is_empty() and state["winner"] < 0:
		var t: int = state["turn"]
		if Rules.in_check(state["board"], t, state["alive"]):
			check_king = Rules.find_king(state["board"], t)
	for i in Rules.CELLS:
		var col: Color = CENTER_TINT
		if i != Rules.CENTER:
			var h := Rules.cell_h(i)
			col = HALF_TINT[h]
			if not state.is_empty() and not state["alive"][h]:
				col = col.darkened(0.25)
		if not state.is_empty() and (i == state["last_to"] or i == state["last_from"]):
			col = col.lerp(Color(1.0, 0.65, 0.2), 0.45)
		if i == selected_from:
			col = col.lerp(Color(1, 1, 0.2), 0.6)
		if i == check_king:
			col = col.lerp(Color(1, 0.1, 0.1), 0.55)
		if target_cells.has(i):
			col = col.lerp(Color(0.3, 0.9, 0.4), 0.45)
		draw_colored_polygon(_polys[i], col)
		var pl: PackedVector2Array = _polys[i].duplicate()
		pl.append(pl[0])
		draw_polyline(pl, LINE_COL, 1.2, true)
	# 3人の陣地の境目だけ少し太く
	for h in 3:
		draw_line(_hex_m(2 * h + 1), _q(h), LINE_COL, 2.5, true)
	draw_polyline(outline, Color(0.2, 0.1, 0.0), 4.0, true)
	if state.is_empty():
		return
	var board: Array = state["board"]
	for i in Rules.CELLS:
		if board[i] != 0:
			_draw_piece(_centers[i], _forward_dir(Rules.p_owner(board[i]), i).angle() + PI / 2.0,
				_sizes[i] * 0.46, board[i])
	_draw_hands()


func _draw_piece(pos: Vector2, rot: float, sz: float, c: int, label := "") -> void:
	var owner := Rules.p_owner(c)
	draw_set_transform(pos, rot, Vector2.ONE)
	var shape := PackedVector2Array([
		Vector2(0, -1.0) * sz, Vector2(0.62, -0.62) * sz, Vector2(0.78, 0.92) * sz,
		Vector2(-0.78, 0.92) * sz, Vector2(-0.62, -0.62) * sz])
	draw_colored_polygon(shape, Color(0.98, 0.90, 0.70))
	var closed := shape.duplicate()
	closed.append(shape[0])
	var pc: Color = PLAYER_COLORS[owner]
	draw_polyline(closed, pc, max(2.0, sz * 0.14), true)
	var text := label if label != "" else Rules.piece_label(c)
	var fs := int(sz * 1.15)
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var tc := pc.darkened(0.15)
	if Rules.p_prom(c):
		tc = Color(0.85, 0.05, 0.05) if owner != 0 else Color(0.55, 0.0, 0.4)
	draw_string(_font, Vector2(-w / 2.0, fs * 0.42), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 盤の四隅の空きに駒台を描く。下の人＝右下、右上の辺の人＝右上、左上の辺の人＝左上。
func _draw_hands() -> void:
	_hand_hits.clear()
	var slot: float = clamp(size.y * 0.05, 24.0, 40.0)
	var cols := 4
	var step_x := slot * 1.25
	var w := step_x * cols + 12.0
	var title_h := 24.0
	var h := title_h + slot * 2 + 10.0
	var spots := {
		view_seat: Vector2(size.x - w - 6, size.y - h - 6),
		(view_seat + 1) % 3: Vector2(size.x - w - 6, 6),
		(view_seat + 2) % 3: Vector2(6, 6),
	}
	for p in 3:
		var origin: Vector2 = spots[p]
		var rect := Rect2(origin, Vector2(w, h))
		var turn_now: bool = state["winner"] < 0 and state["turn"] == p and state["alive"][p]
		draw_rect(rect, Color(0.62, 0.45, 0.25) if state["alive"][p] else Color(0.35, 0.30, 0.25))
		draw_rect(rect, PLAYER_COLORS[p].lightened(0.2 if turn_now else 0.0), false, 4.0 if turn_now else 2.0)
		var title: String = ("▶ " if turn_now else "") + str(names[p])
		if not state["alive"][p]:
			title += "（脱落）"
		var fs := 16
		draw_string(_font, origin + Vector2(6, 18), title, HORIZONTAL_ALIGNMENT_LEFT, w - 10, fs, Color(1, 1, 1))
		var n := 0
		for k in HAND_ORDER:
			var cnt: int = state["hands"][p][k]
			if cnt <= 0:
				continue
			var cell := origin + Vector2(6 + (n % cols) * step_x, title_h + 4 + (n / cols) * slot)
			var cell_rect := Rect2(cell, Vector2(slot, slot))
			if p == my_seat and selected_drop == k:
				draw_rect(cell_rect, Color(0.3, 0.9, 0.4, 0.7))
			_draw_piece(cell + Vector2(slot / 2, slot / 2), 0.0, slot * 0.40, Rules.make_piece(p, k, false))
			if cnt > 1:
				var np := cell + Vector2(slot * 0.86, slot * 0.92)
				draw_string(_font, np + Vector2(1, 1), str(cnt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0, 0.7))
				draw_string(_font, np, str(cnt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 0.85))
			_hand_hits.append([cell_rect, p, k])
			n += 1
		if n == 0:
			draw_string(_font, origin + Vector2(8, title_h + slot), "持ち駒なし", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))


# ---------- 操作 ----------

func _cell_at(p: Vector2) -> int:
	for i in Rules.CELLS:
		if Geometry2D.is_point_in_polygon(p, _polys[i]):
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			clear_selection()
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if not _can_act():
			return
		for hit in _hand_hits:
			if hit[0].has_point(event.position):
				if hit[1] == my_seat:
					select_drop(hit[2])
				return
		var i := _cell_at(event.position)
		if i < 0:
			clear_selection()
			return
		var hits: Array = []
		for m in targets:
			if m["to"] == i:
				hits.append(m)
		if not hits.is_empty():
			if hits.size() == 1:
				move_chosen.emit(hits[0])
			else:
				var m_no: Dictionary = hits[0] if not hits[0]["promote"] else hits[1]
				var m_yes: Dictionary = hits[1] if not hits[0]["promote"] else hits[0]
				promotion_choice.emit(m_no, m_yes)
			clear_selection()
			return
		var c: int = state["board"][i]
		if c != 0 and Rules.p_owner(c) == my_seat:
			selected_drop = -1
			selected_from = i
			targets = Rules.moves_from(state, my_seat, i)
			Sfx.play("select")
			selection_changed.emit()
			queue_redraw()
		else:
			clear_selection()
