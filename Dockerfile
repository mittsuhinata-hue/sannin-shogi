# 三人将棋（Render 用）
# ・Caddy がゲームのページ（docs フォルダ）を配る
# ・Godot を画面なしで動かし、WebSocket で部屋をつなぐ（Caddy が通信をここへ回す）
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 caddy \
 && rm -rf /var/lib/apt/lists/*

ARG GODOT_VERSION=4.7.2
RUN wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip -O /tmp/godot.zip \
 && unzip /tmp/godot.zip -d /tmp/godot \
 && mv /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm -rf /tmp/godot /tmp/godot.zip

WORKDIR /app
COPY . .
# スクリプトの読み込み準備（失敗しても起動時にやり直すので止めない）
RUN godot --headless --path /app --import || true
RUN chmod +x /app/start.sh

ENV PORT=10000
ENV XDG_DATA_HOME=/tmp/caddy-data
ENV XDG_CONFIG_HOME=/tmp/caddy-config
EXPOSE 10000
CMD ["/app/start.sh"]
