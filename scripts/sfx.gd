extends Node
## 効果音（自動読み込み名: Sfx）。音のファイルは使わず、起動時に波形を計算して作る。
## 使い方: Sfx.play("koma")

const RATE := 22050

var volume_db := 0.0
var _streams := {}
var _players: Array = []


func _ready() -> void:
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_streams["koma"] = _make(_koma)
	_streams["capture"] = _make(_capture)
	_streams["select"] = _make(_select)
	_streams["check"] = _make(_check)
	_streams["out"] = _make(_out)
	_streams["win"] = _make(_win)
	_streams["start"] = _make(_start)


func play(name: String) -> void:
	if not _streams.has(name):
		return
	for p in _players:
		if not p.playing:
			p.stream = _streams[name]
			p.volume_db = volume_db
			p.play()
			return
	_players[0].stream = _streams[name]
	_players[0].play()


# ---------- 波形を作る ----------

func _make(gen: Callable) -> AudioStreamWAV:
	var samples: PackedFloat32Array = gen.call()
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clamp(samples[i], -1.0, 1.0) * 32000.0)
		data.encode_s16(i * 2, v)
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s


func _buf(sec: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(sec * RATE))
	b.fill(0.0)
	return b


## 木の駒を盤に置く「パチッ」
func _click(b: PackedFloat32Array, at: float, amp: float, pitch: float) -> void:
	var start := int(at * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in int(0.09 * RATE):
		var j := start + i
		if j >= b.size():
			break
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0) * exp(-t * 900.0)
		var body := sin(TAU * pitch * t) * exp(-t * 70.0) * 0.6
		var thump := sin(TAU * pitch * 0.22 * t) * exp(-t * 40.0) * 0.5
		b[j] += amp * (noise * 0.8 + body + thump)


func _tone(b: PackedFloat32Array, at: float, dur: float, freq: float, amp: float) -> void:
	var start := int(at * RATE)
	for i in int(dur * RATE):
		var j := start + i
		if j >= b.size():
			break
		var t := float(i) / RATE
		var env: float = min(1.0, t * 200.0) * exp(-t * 4.0 / dur)
		b[j] += amp * env * (sin(TAU * freq * t) + 0.3 * sin(TAU * freq * 2.0 * t))


func _koma() -> PackedFloat32Array:
	var b := _buf(0.12)
	_click(b, 0.0, 0.8, 820.0)
	return b


func _capture() -> PackedFloat32Array:
	var b := _buf(0.2)
	_click(b, 0.0, 0.6, 700.0)
	_click(b, 0.07, 0.9, 900.0)
	return b


func _select() -> PackedFloat32Array:
	var b := _buf(0.04)
	_click(b, 0.0, 0.25, 1500.0)
	return b


func _check() -> PackedFloat32Array:
	var b := _buf(0.45)
	_tone(b, 0.0, 0.18, 880.0, 0.35)
	_tone(b, 0.16, 0.28, 1175.0, 0.35)
	return b


func _out() -> PackedFloat32Array:
	var b := _buf(0.8)
	var notes := [523.0, 440.0, 349.0, 262.0]
	for n in notes.size():
		_tone(b, n * 0.15, 0.3, notes[n], 0.3)
	return b


func _win() -> PackedFloat32Array:
	var b := _buf(1.2)
	var notes := [523.0, 659.0, 784.0, 1047.0]
	for n in notes.size():
		_tone(b, n * 0.13, 0.5 if n == 3 else 0.25, notes[n], 0.3)
	return b


func _start() -> PackedFloat32Array:
	var b := _buf(0.6)
	_tone(b, 0.0, 0.25, 659.0, 0.3)
	_tone(b, 0.12, 0.4, 988.0, 0.3)
	return b
