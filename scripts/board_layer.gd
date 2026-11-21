extends Node2D
## 盤の絵だけを描く層。拡大・移動のときはこの層の位置と大きさを変えるだけで、描き直さない。

var view: Control   ## 親の BoardView


func _draw() -> void:
	if view:
		view.draw_board(self)
