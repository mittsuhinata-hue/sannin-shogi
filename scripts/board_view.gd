extends Control
## 六角形の盤と駒台を描き、クリックで駒を動かす。
##
## 軽く動かすための工夫：
##  ・盤の形（マスの多角形）は、大きさ・種類・向きが変わったときだけ計算する
##  ・盤の絵は子の層（board_layer）に描き、拡大・移動は層の位置と大きさを変えるだけ
##  ・描き直すのは、駒が動いたとき・選んだとき・拡大の倍率が変わって少し止まったとき

const Rules = preload("res://scripts/rules.gd")
const BoardLayer = preload("res://scripts/board_layer.gd")

signal move_chosen(m: Dictionary)
signal promotion_choice(m_no: Dictionary, m_yes: Dictionary)
signal selection_changed
signal piece_tapped(c: int)

const PLAYER_COLORS := [Color(0.80, 0.15, 0.15), Color(0.15, 0.30, 0.85), Color(0.10, 0.55, 0.20), Color(0.78, 0.58, 0.02), Color(0.55, 0.20, 0.70)]
const HALF_TINT := [Color(0.93, 0.80, 0.60), Color(0.88, 0.80, 0.66), Color(0.90, 0.84, 0.62), Color(0.94, 0.86, 0.58), Color(0.90, 0.80, 0.68)]
const CENTER_TINT := Color(0.86, 0.74, 0.55)
const LINE_COL := Color(0.25, 0.15, 0.05)
const HAND_ORDER := [6, 5, 4, 3, 2, 1, 0]  # 飛 角 金 銀 桂 香 歩

var state: Dictionary = {}
var view_seat := 0        ## 下に来る人
var my_seat := -1         ## いま操作できる人（-1 なら操作できない）
var names: Array = ["赤", "青", "緑", "黄", "紫"]

var selected_from := -1
var selected_drop := -1
var targets: Array = []   ## 選んだ駒の合法手

var _font: Font
var _layer: Node2D
# 盤の形（拡大1倍のときの座標）
var _polys: Array = []    ## マスごとの多角形
var _centers: Array = []
var _sizes: Array = []
var _center := Vector2.ZERO   ## 盤の中心（拡大1倍のとき）
var _radius := 100.0          ## 盤の半径（拡大1倍のとき）
var _tri_points := PackedVector2Array()   ## 全マスをまとめて塗るための三角形
var _tri_index := PackedInt32Array()
var _tri_cell := PackedInt32Array()       ## 三角形の頂点がどのマスのものか
var _grid := PackedVector2Array()         ## マスの線（まとめて1回で描く）
var _outline := PackedVector2Array()
var _hand_hits: Array = []  ## [Rect2, 席, 駒の種類]
var _rect_origin := Vector2.ZERO   ## 四角い盤の左上
var _rect_cell := 1.0              ## 四角い盤の1マスの大きさ

# ---- 拡大・移動 ----
const ZOOM_MIN := 1.0
const ZOOM_MAX := 3.0
const DRAG_START := 10.0   ## これ以上指やマウスが動いたら「なぞる」扱い（駒は選ばない）
var _zoom := 1.0
var _pan := Vector2.ZERO
var _drawn_variant := ""
var _drawn_zoom := 1.0     ## 盤の字をこの倍率に合わせて描いた
var _zoom_bar: HBoxContainer
var _press_pos := Vector2.ZERO
var _mouse_down := false
var _dragging := false
var _touches := {}          ## 指の番号 → 位置（2本指でつまむ操作に使う）
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO
var _no_click_until := 0    ## つまむ操作の直後は、離した指で駒を選ばない
var _touch_time := {}       ## 指の番号 → 最後に動いた時刻（ミリ秒）
var _tap_index := -1        ## 軽く押したか見ている指の番号
var _tap_pos := Vector2.ZERO
var _tap_ok := false
var _touch_drag := false
const STALE_TOUCH_MS := 3000
var _sharpen_timer: Timer   ## 拡大が止まったら字をくっきり描き直す


func _ready() -> void:
	_font = preload("res://scripts/ui_font.gd").make(true)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_layer = BoardLayer.new()
	_layer.view = self
	_layer.show_behind_parent = true   # 盤は駒台（親に描く）より後ろに
	add_child(_layer)
	_build_zoom_bar()
	_sharpen_timer = Timer.new()
	_sharpen_timer.one_shot = true
	_sharpen_timer.wait_time = 0.18
	_sharpen_timer.timeout.connect(func():
		if not is_equal_approx(_drawn_zoom, _zoom):
			_layer.queue_redraw())
	add_child(_sharpen_timer)
	resized.connect(_rebuild)
	_rebuild()


func _build_zoom_bar() -> void:
	_zoom_bar = HBoxContainer.new()
	_zoom_bar.add_theme_constant_override("separation", 4)
	for item in [["＋", func(): _zoom_at(_view_center(), 1.35)], ["－", func(): _zoom_at(_view_center(), 1.0 / 1.35)], ["全体", reset_zoom]]:
		var b := Button.new()
		b.text = item[0]
		b.custom_minimum_size = Vector2(44, 40)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(item[1])
		_zoom_bar.add_child(b)
	add_child(_zoom_bar)
	_zoom_bar.size = _zoom_bar.get_combined_minimum_size()


func _redraw() -> void:
	queue_redraw()
	if _layer:
		_layer.queue_redraw()


# ---------- 拡大・移動 ----------

## 画面上での盤の中心
func _view_center() -> Vector2:
	return _center + _pan

## 画面の点 → 盤の座標（拡大1倍のとき）
func _to_board(p: Vector2) -> Vector2:
	return (p - _layer.position) / _zoom

## 拡大・移動を層に反映する（描き直しはしない）
func _apply_view() -> void:
	var lim: float = _radius * (_zoom - 1.0)
	_pan.x = clamp(_pan.x, -lim, lim)
	_pan.y = clamp(_pan.y, -lim * 0.9, lim * 0.9)
	if _layer:
		_layer.scale = Vector2(_zoom, _zoom)
		_layer.position = _center + _pan - _center * _zoom
	if _zoom_bar:
		_zoom_bar.position = Vector2(6, size.y - _zoom_bar.size.y - 6)
		if _tall_many():
			# 縦画面の4人・5人は左下にも駒台を置くので、ボタンは下の真ん中へ
			_zoom_bar.position.x = (size.x - _zoom_bar.size.x) * 0.5


## 縦画面で、下の段にも相手の駒台を置く人数か
func _tall_many() -> bool:
	return _is_tall() and not Rules.RECT and Rules.N >= 4


func reset_zoom() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	_apply_view()
	_sharpen_timer.start()


## 画面の点 p を中心に、factor 倍に拡大する（p の下にあるマスは動かない）
func _zoom_at(p: Vector2, factor: float) -> void:
	var zmax: float = Rules.variant_info().get("zoom", ZOOM_MAX)
	var nz: float = clamp(_zoom * factor, ZOOM_MIN, zmax)
	if is_equal_approx(nz, _zoom):
		return
	var b := _to_board(p)
	_zoom = nz
	var new_pos := p - b * _zoom
	_pan = new_pos + _center * _zoom - _center
	_apply_view()
	_sharpen_timer.start()


func _pan_by(d: Vector2) -> void:
	if _zoom <= 1.001:
		return
	_pan += d
	_apply_view()


# ---------- 盤面・選択 ----------

func set_state(s: Dictionary) -> void:
	state = s
	var vid := str(s.get("variant", "standard"))
	if vid != _drawn_variant:
		# 種類が変わったら盤の形を作り直し、拡大も戻す
		_drawn_variant = vid
		Rules.use(s)
		_zoom = 1.0
		_pan = Vector2.ZERO
		_rebuild()
	clear_selection()


func clear_selection() -> void:
	selected_from = -1
	selected_drop = -1
	targets = []
	selection_changed.emit()
	_redraw()


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
	_redraw()


func _can_act() -> bool:
	return not state.is_empty() and my_seat >= 0 and state["turn"] == my_seat and state["winner"] < 0


# ---------- 形の計算（拡大1倍の座標） ----------

## 盤のふちの多角形（人数×2 角形）の頂点 j。陣地 h の奥の辺は頂点 2h〜2h+1
func _hex_v(j: int) -> Vector2:
	var n := Rules.N
	var stp := 180.0 / n
	var a0 := deg_to_rad(90.0 + (2 * view_seat + 0.5) * stp)
	var a := a0 - deg_to_rad(stp) * posmod(j, 2 * n)
	return _center + _radius * Vector2(cos(a), sin(a))

## 半径1の盤のふちの、横・縦の半分の幅（盤を画面に収める大きさの計算用）
func _poly_extent() -> Vector2:
	var n := Rules.N
	var stp := 180.0 / n
	var a0 := deg_to_rad(90.0 + (2 * view_seat + 0.5) * stp)
	var ex := Vector2.ZERO
	for j in 2 * n:
		var a := a0 - deg_to_rad(stp) * j
		ex.x = max(ex.x, abs(cos(a)))
		ex.y = max(ex.y, abs(sin(a)))
	return ex

func _hex_m(j: int) -> Vector2:
	return (_hex_v(j) + _hex_v(j + 1)) * 0.5

## 中央の三角形の頂点（h と h+1 の境目の上）。真ん中の筋の幅がほかの筋とそろう大きさにする
func _q(h: int) -> Vector2:
	var m := _hex_m(2 * posmod(h, Rules.N) + 1)
	var d := _radius * cos(PI / (2 * Rules.N)) / (2.0 * sin(PI / Rules.N) * Rules.MID + 1.0)
	return _center + (m - _center).normalized() * d

## 陣地 h の (筋u, 段v) 座標 → 盤上の点。u:0..FILES, v:0..RANKS
func _pt(h: int, u: float, v: float) -> Vector2:
	var k := 2 * h
	var files := float(Rules.FILES)
	var mid := float(Rules.MID)
	var back := _hex_v(k).lerp(_hex_v(k + 1), u / files)
	var inner: Vector2
	if u <= mid:
		inner = _hex_m(k - 1).lerp(_q(h - 1), u / mid)
	elif u <= mid + 1.0:
		inner = _q(h - 1).lerp(_q(h), u - mid)
	else:
		inner = _q(h).lerp(_hex_m(k + 1), (u - mid - 1.0) / mid)
	return back.lerp(inner, v / float(Rules.RANKS))


## 駒台1つ分の [マスの大きさ, 横の間隔, 幅, 高さ]
func _hand_metrics() -> Array:
	var base: float = size.x * 0.075 if _is_tall() else size.y * 0.05
	var slot: float = clamp(base, 22.0, 40.0)
	if _is_tall() and not Rules.RECT and Rules.N >= 5:
		slot = min(slot, (size.x / 3.0 - 20.0) / 5.0)   # 上に3人分並べる
	var step_x := slot * 1.25
	return [slot, step_x, step_x * 4 + 12.0, 24.0 + slot * 2 + 10.0]


## 縦長（スマホの縦画面など）のときは、駒台を盤の上下に置く
func _is_tall() -> bool:
	return size.y > size.x * 1.15


## 四角い盤（1対1）で、下に来る席（0か1）
func _rect_view() -> int:
	return 1 if view_seat == 1 else 0


## 四角い盤の形を計算する
func _rebuild_rect() -> void:
	# 名前の札（上）と拡大ボタン（下）に重ならないよう、上下に少しすき間を空ける
	var area := Rect2(0, 36, size.x, size.y - 36 - 50)
	if Rules.DROPS:
		var band: float = _hand_metrics()[3] + 6.0
		if _is_tall():
			area = Rect2(0, band, size.x, size.y - band * 2.0)
		else:
			area = Rect2(_hand_metrics()[2] + 10.0, 0, size.x - (_hand_metrics()[2] + 10.0) * 2.0, size.y)
	var w := float(Rules.FILES)
	var h := float(Rules.RANKS)
	var cell: float = min(area.size.x / w, area.size.y / h) * 0.96
	_center = area.get_center()
	_radius = max(w, h) * cell * 0.5
	var origin := _center - Vector2(w, h) * cell * 0.5
	_rect_origin = origin
	_rect_cell = cell
	var flip := _rect_view() == 1
	for i in Rules.CELLS:
		var x := i % Rules.FILES
		var y := i / Rules.FILES
		var col := (Rules.FILES - 1 - x) if flip else x
		var row := y if flip else (Rules.RANKS - 1 - y)
		var p0 := origin + Vector2(col, row) * cell
		var poly := PackedVector2Array([p0, p0 + Vector2(cell, 0), p0 + Vector2(cell, cell), p0 + Vector2(0, cell)])
		_add_cell_shape(i, poly, p0 + Vector2(cell, cell) * 0.5, cell)
	var br := origin + Vector2(w, h) * cell
	_outline = PackedVector2Array([origin, Vector2(br.x, origin.y), br, Vector2(origin.x, br.y), origin])


## マス1つ分の形を登録する（塗り用の三角形と線もまとめて作る）
func _add_cell_shape(i: int, poly: PackedVector2Array, c: Vector2, m: float) -> void:
	_polys.append(poly)
	_centers.append(c)
	_sizes.append(m)
	var base := _tri_points.size()
	for e in poly.size():
		var a: Vector2 = poly[e]
		var b: Vector2 = poly[(e + 1) % poly.size()]
		_grid.append(a)
		_grid.append(b)
		_tri_points.append(a)
		_tri_cell.append(i)
	for e in range(1, poly.size() - 1):
		_tri_index.append(base)
		_tri_index.append(base + e)
		_tri_index.append(base + e + 1)


## 盤の形を計算し直す（大きさ・種類・向きが変わったときだけ）
func _rebuild() -> void:
	if Rules.RECT:
		_polys.clear()
		_centers.clear()
		_sizes.clear()
		_tri_points = PackedVector2Array()
		_tri_index = PackedInt32Array()
		_tri_cell = PackedInt32Array()
		_grid = PackedVector2Array()
		_rebuild_rect()
		_apply_view()
		_redraw()
		return
	var ex := _poly_extent()
	if _is_tall() and Rules.DROPS:
		var band: float = _hand_metrics()[3] + 6.0
		var area_h := size.y - band * 2.0
		_center = Vector2(size.x * 0.5, band + area_h * 0.5)
		_radius = min(size.x / (2.0 * ex.x), area_h / (2.0 * ex.y)) * 0.97
	elif Rules.N >= 5 and Rules.DROPS:
		# 5人：駒台を左右の真ん中にも置くので、その分あけて盤を置く
		var side: float = _hand_metrics()[2] + 10.0
		_center = size * 0.5
		_radius = min((size.x - side * 2.0) / (2.0 * ex.x), size.y / (2.0 * ex.y)) * 0.97
	else:
		_center = size * 0.5
		_radius = min(size.x / (2.0 * ex.x), size.y / (2.0 * ex.y)) * (0.90 if Rules.DROPS else 0.97)
	_polys.clear()
	_centers.clear()
	_sizes.clear()
	_tri_points = PackedVector2Array()
	_tri_index = PackedInt32Array()
	_tri_cell = PackedInt32Array()
	_grid = PackedVector2Array()
	for i in Rules.CELLS:
		var poly: PackedVector2Array
		var c: Vector2
		if i == Rules.CENTER:
			poly = PackedVector2Array()
			for h in Rules.N:
				poly.append(_q(h))
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
		var base := _tri_points.size()
		for e in poly.size():
			var a: Vector2 = poly[e]
			var b: Vector2 = poly[(e + 1) % poly.size()]
			m = min(m, a.distance_to(b))
			_grid.append(a)
			_grid.append(b)
			_tri_points.append(a)
			_tri_cell.append(i)
		for e in range(1, poly.size() - 1):
			_tri_index.append(base)
			_tri_index.append(base + e)
			_tri_index.append(base + e + 1)
		if i == Rules.CENTER:
			m *= 0.75
		_sizes.append(m)
	_outline = PackedVector2Array()
	for j in 2 * Rules.N + 1:
		_outline.append(_hex_v(j))
	_apply_view()
	_redraw()


func _forward_dir(owner: int, i: int) -> Vector2:
	if Rules.RECT:
		return Vector2(0, -1) if owner == _rect_view() else Vector2(0, 1)
	if i == Rules.CENTER:
		return (_center - _hex_m(2 * owner)).normalized()
	var h := Rules.cell_h(i)
	var s := Rules.orient(owner, h)
	var u := Rules.cell_f(i) + 0.5
	var v := Rules.cell_r(i) + 0.5
	return (_pt(h, u, v + 0.3 * s) - _pt(h, u, v - 0.3 * s)).normalized()


# ---------- 描画 ----------

## 盤の層に描く（cv は board_layer）
func draw_board(cv: CanvasItem) -> void:
	if _polys.is_empty():
		return
	_drawn_zoom = _zoom
	cv.draw_colored_polygon(_outline, Color(0.45, 0.30, 0.15))
	var target_cells := {}
	for m in targets:
		target_cells[m["to"]] = true
	var check_king := -1
	if not state.is_empty() and state["winner"] < 0:
		var t: int = state["turn"]
		if Rules.in_check(state["board"], t, state["alive"]):
			check_king = Rules.find_king(state["board"], t)
	# マスの色を決めて、全マスを1回でまとめて塗る
	var cell_col: Array = []
	cell_col.resize(Rules.CELLS)
	for i in Rules.CELLS:
		var col: Color = CENTER_TINT
		if i != Rules.CENTER:
			var h := Rules.cell_h(i)
			col = HALF_TINT[h]
			if not state.is_empty() and not Rules.RECT and not state["alive"][h]:
				col = col.darkened(0.25)
		if not state.is_empty() and (i == state["last_to"] or i == state["last_from"]):
			col = col.lerp(Color(1.0, 0.65, 0.2), 0.45)
		if i == selected_from:
			col = col.lerp(Color(1, 1, 0.2), 0.6)
		if i == check_king:
			col = col.lerp(Color(1, 0.1, 0.1), 0.55)
		if target_cells.has(i):
			col = col.lerp(Color(0.3, 0.9, 0.4), 0.45)
		cell_col[i] = col
	var colors := PackedColorArray()
	colors.resize(_tri_points.size())
	for k in _tri_points.size():
		colors[k] = cell_col[_tri_cell[k]]
	RenderingServer.canvas_item_add_triangle_array(cv.get_canvas_item(), _tri_index, _tri_points, colors)
	cv.draw_multiline(_grid, LINE_COL, 1.0)
	if Rules.RECT:
		# 成れる場所の境目（本物の将棋盤の星の代わり）
		var w := Rules.FILES * _rect_cell
		for rr in [Rules.ZONE, Rules.RANKS - Rules.ZONE]:
			var yy: float = _rect_origin.y + rr * _rect_cell
			cv.draw_line(Vector2(_rect_origin.x, yy), Vector2(_rect_origin.x + w, yy), LINE_COL, 2.2)
	else:
		# 陣地の境目だけ少し太く
		for h in Rules.N:
			cv.draw_line(_hex_m(2 * h + 1), _q(h), LINE_COL, 2.5)
	var closed := _outline.duplicate()
	cv.draw_polyline(closed, Color(0.2, 0.1, 0.0), 4.0)
	if state.is_empty():
		return
	var board: Array = state["board"]
	for i in Rules.CELLS:
		if board[i] != 0:
			_draw_piece(cv, _centers[i], _forward_dir(Rules.p_owner(board[i]), i).angle() + PI / 2.0,
				_sizes[i] * 0.46, board[i], _zoom)


## 駒を1つ描く。text_zoom は字をくっきり描くための倍率（盤の層は拡大されるので、その分大きな字で描いて縮める）
func _draw_piece(cv: CanvasItem, pos: Vector2, rot: float, sz: float, c: int, text_zoom := 1.0) -> void:
	var owner := Rules.p_owner(c)
	cv.draw_set_transform(pos, rot, Vector2.ONE)
	var shape := PackedVector2Array([
		Vector2(0, -1.0) * sz, Vector2(0.62, -0.62) * sz, Vector2(0.78, 0.92) * sz,
		Vector2(-0.78, 0.92) * sz, Vector2(-0.62, -0.62) * sz])
	cv.draw_colored_polygon(shape, Color(0.98, 0.90, 0.70))
	var closed := shape.duplicate()
	closed.append(shape[0])
	var pc: Color = PLAYER_COLORS[owner]
	cv.draw_polyline(closed, pc, max(1.5, sz * 0.14))
	var text := Rules.piece_label(c)
	var tz: float = max(text_zoom, 1.0)
	var fs := int(sz * 1.15 * tz)
	if fs < 2:
		cv.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var tc := pc.darkened(0.15)
	if Rules.p_prom(c):
		tc = Color(0.85, 0.05, 0.05) if owner != 0 else Color(0.55, 0.0, 0.4)
	cv.draw_set_transform(pos, rot, Vector2.ONE / tz)
	cv.draw_string(_font, Vector2(-w / 2.0, fs * 0.42), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)
	cv.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 自分（親）に描くのは駒台だけ（盤の上に重なる、拡大しない部分）
func _draw() -> void:
	if state.is_empty() or _polys.is_empty():
		return
	_draw_hands()


## 盤の四隅の空きに駒台を描く。下の人＝右下、右上の辺の人＝右上、左上の辺の人＝左上。
func _draw_hands() -> void:
	_hand_hits.clear()
	var hm := _hand_metrics()
	var slot: float = hm[0]
	var cols := 4
	var step_x: float = hm[1]
	var w: float = hm[2]
	var title_h := 24.0
	var h: float = hm[3]
	if not Rules.DROPS:
		# 取った駒を使わない種類：駒台は出さず、名前の札だけ出す
		w = 150.0
		h = 28.0
	var ns := Rules.NSEAT
	var vs := clampi(view_seat, 0, ns - 1)
	var br := Vector2(size.x - w - 6, size.y - h - 6)
	var tr := Vector2(size.x - w - 6, 6)
	var tl := Vector2(6, 6)
	var bl := Vector2(6, size.y - h - 6 - (0.0 if _tall_many() else 44.0))   # 横画面の左下は拡大ボタンをよける
	var spots := {}
	if ns == 3:
		spots = {vs: br, (vs + 1) % 3: tr, (vs + 2) % 3: tl}
	elif ns == 4:
		spots = {vs: br, (vs + 1) % 4: tr, (vs + 2) % 4: tl, (vs + 3) % 4: bl}
	else:
		# 5人：自分は右下、右どなりから左回りに並べる
		var second := Vector2(size.x * 0.5 - w * 0.5, 6) if _is_tall() else Vector2(size.x - w - 6, size.y * 0.5 - h * 0.5)
		if _is_tall():
			spots = {vs: br, (vs + 1) % 5: tr, (vs + 2) % 5: second, (vs + 3) % 5: tl, (vs + 4) % 5: bl}
		else:
			spots = {vs: br, (vs + 1) % 5: second, (vs + 2) % 5: tr, (vs + 3) % 5: tl, (vs + 4) % 5: bl}
	for p in ns:
		if p >= Rules.PLAYERS:
			continue   # 1対1では3人目の席は出さない
		var origin: Vector2 = spots[p]
		if Rules.PLAYERS == 2 and p != view_seat:
			origin = Vector2(6, 6)   # 1対1の相手は左上
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
			_draw_piece(self, cell + Vector2(slot / 2, slot / 2), 0.0, slot * 0.40, Rules.make_piece(p, k, false))
			if cnt > 1:
				var np := cell + Vector2(slot * 0.86, slot * 0.92)
				draw_string(_font, np + Vector2(1, 1), str(cnt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0, 0.7))
				draw_string(_font, np, str(cnt), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 0.85))
			_hand_hits.append([cell_rect, p, k])
			n += 1
		if n == 0 and Rules.DROPS:
			draw_string(_font, origin + Vector2(8, title_h + slot), "持ち駒なし", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))


# ---------- 操作 ----------

## 画面の点にあるマス（なければ -1）
func _cell_at(p: Vector2) -> int:
	var b := _to_board(p)
	for i in Rules.CELLS:
		if Geometry2D.is_point_in_polygon(b, _polys[i]):
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	# --- 指（スマホ）：1本指で軽く押すと選ぶ・なぞると移動、2本指でつまむと拡大 ---
	# ブラウザが指をマウスに置き換えた操作は、2本指のあとで止まることがあるので使わず、指の操作を直接見る
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_down(event.index, event.position)
		else:
			_touch_up(event.index, event.position, true)
		accept_event()
		return
	if event is InputEventScreenDrag:
		_touches[event.index] = event.position
		_touch_time[event.index] = Time.get_ticks_msec()
		if _touches.size() >= 2 and _pinch_dist > 0.0:
			var pts: Array = _touches.values()
			var d: float = pts[0].distance_to(pts[1])
			var mid: Vector2 = (pts[0] + pts[1]) * 0.5
			if d > 1.0:
				_zoom_at(mid, d / _pinch_dist)
			_pan_by(mid - _pinch_mid)
			_pinch_dist = max(d, 1.0)
			_pinch_mid = mid
		elif event.index == _tap_index and _touches.size() == 1:
			if not _touch_drag and event.position.distance_to(_tap_pos) > DRAG_START:
				_touch_drag = true
				_tap_ok = false
			if _touch_drag:
				_pan_by(event.relative)
		accept_event()
		return

	# --- マウス：ホイールで拡大、なぞって移動、軽く押して選ぶ ---
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		return   # 指をマウスに置き換えたもの（指の操作は上で扱った）
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, 1.15)
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / 1.15)
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			clear_selection()
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			_mouse_down = true
			_dragging = false
			_press_pos = event.position
		else:
			var was_click := _mouse_down and not _dragging
			_mouse_down = false
			_dragging = false
			if was_click:
				_click(event.position)
		return
	if event is InputEventMouseMotion and _mouse_down:
		if not _dragging and event.position.distance_to(_press_pos) > DRAG_START:
			_dragging = true
		if _dragging:
			_pan_by(event.relative)


## 指が触れた
func _touch_down(idx: int, pos: Vector2) -> void:
	var now := Time.get_ticks_msec()
	# 離したことを受け取れなかった古い指の記録が残っていたら捨てる（残ると、押すたびに2本指と思ってしまう）
	for k in _touches.keys():
		if now - int(_touch_time.get(k, 0)) > STALE_TOUCH_MS:
			_touches.erase(k)
			_touch_time.erase(k)
	if _touches.is_empty():
		_pinch_dist = 0.0
	_touches[idx] = pos
	_touch_time[idx] = now
	if _touches.size() == 1:
		_tap_index = idx
		_tap_pos = pos
		_tap_ok = true
		_touch_drag = false
	else:
		_tap_ok = false   # 2本目の指：軽く押したことにはしない
		if _touches.size() == 2:
			_start_pinch()


## 指が離れた。inside=false は盤の外で離れたとき（その場合は選ばない）
func _touch_up(idx: int, pos: Vector2, inside: bool) -> void:
	if not _touches.has(idx):
		return
	_touches.erase(idx)
	_touch_time.erase(idx)
	if _pinch_dist > 0.0 and _touches.size() < 2:
		_pinch_dist = 0.0
		_no_click_until = Time.get_ticks_msec() + 300
	if idx == _tap_index:
		_tap_index = -1
		var ok := _tap_ok and inside and _touches.is_empty() and Time.get_ticks_msec() >= _no_click_until
		_tap_ok = false
		_touch_drag = false
		if ok:
			_click(pos)


## 指を盤の外で離しても、離したことは必ず受け取る
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and not event.pressed and _touches.has(event.index):
		if not get_global_rect().has_point(event.position):
			_touch_up(event.index, Vector2.ZERO, false)
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT and _mouse_down:
		if not get_global_rect().has_point(event.position):
			_mouse_down = false
			_dragging = false

func _start_pinch() -> void:
	var pts: Array = _touches.values()
	_pinch_dist = max(pts[0].distance_to(pts[1]), 1.0)
	_pinch_mid = (pts[0] + pts[1]) * 0.5
	_dragging = true


## 軽く押したとき：駒台の駒、盤の駒、行き先を選ぶ
func _click(pos: Vector2) -> void:
	# 駒台は盤の上に重なっているので先に調べる
	for hit in _hand_hits:
		if hit[0].has_point(pos):
			if hit[1] == my_seat and _can_act():
				select_drop(hit[2])
			return
	var i := _cell_at(pos)
	# どの駒でも、押せば名前と動きを案内する（自分の番でなくても）
	if i >= 0 and not state.is_empty() and state["board"][i] != 0:
		piece_tapped.emit(state["board"][i])
	if not _can_act():
		return
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
		_redraw()
	else:
		clear_selection()
