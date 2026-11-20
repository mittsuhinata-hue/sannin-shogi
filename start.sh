#!/bin/sh
# 対戦サーバー（止まったら自動で起動し直す）
(
	while true; do
		godot --headless --path /app -- --server --port=24565
		echo "対戦サーバーが止まったので起動し直します"
		sleep 1
	done
) &

# ページを配りつつ、通信を対戦サーバーへ回す
exec caddy run --config /app/Caddyfile --adapter caddyfile
