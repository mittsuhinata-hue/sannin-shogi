extends RefCounted
## 日本語フォントの用意。
## res://fonts/jp.ttf（または .otf）があればそれを使う。Web版ではこれが必要。
## なければパソコンに入っているフォントを使う。

const FILES := ["res://fonts/jp.ttf", "res://fonts/jp.otf"]

static func make(bold := false) -> Font:
	for p in FILES:
		if ResourceLoader.exists(p):
			var f: Font = load(p)
			if not bold:
				return f
			var fv := FontVariation.new()
			fv.base_font = f
			fv.variation_embolden = 0.7
			return fv
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Yu Gothic UI", "Yu Gothic", "Meiryo", "MS Gothic", "Noto Sans CJK JP", "Noto Sans JP"])
	sf.font_weight = 700 if bold else 400
	return sf
