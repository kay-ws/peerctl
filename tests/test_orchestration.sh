#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

command -v tmux >/dev/null || { echo "SKIP: tmux 不在"; exit 0; }

PEERCTL_HOME="$(mktemp -d)"; export PEERCTL_HOME
export PEERCTL_TMUX_SESSION="peerctl_test_$$"
export PEERCTL_AGENT="cat"   # claude の代わりに cat を起動（入力を待つだけ）
export PEERCTL_SPAWN_WAIT=0  # stub は ready マーカーを出さないので待ちを無効化
trap 'tmux kill-session -t "$PEERCTL_TMUX_SESSION" 2>/dev/null; rm -rf "$PEERCTL_HOME"' EXIT

cmd_spawn gamma --no-git
pd="$(peer_dir gamma)"
assert_eq "$PEERCTL_TMUX_SESSION:gamma" "$(meta_get "$pd" target)" "spawn recorded target"
assert_contains "$(tmux list-windows -t "$PEERCTL_TMUX_SESSION" -F '#W')" "gamma" "tmux window exists"
assert_contains "$(cmd_list)" "gamma" "list shows peer"

cmd_kill gamma
assert_eq "" "$(meta_get "$pd" target)" "kill removed peer dir (meta gone)"

# recv 単体: signal とフィクスチャ transcript を仕込み、送信時刻より新しければ応答を返す
pd2="$(peer_dir delta)"; mkdir -p "$pd2"
meta_set "$pd2" target "$PEERCTL_TMUX_SESSION:delta"
echo 0 > "$pd2/last_send"
printf '%s\t%s\t%s\n' "$(($(date +%s)+1))" "Sx" "$here/fixtures/simple.jsonl" > "$pd2/signal"
assert_eq "クリーン受信OK" "$(cmd_recv delta --timeout 2)" "recv returns last reply"
finish
