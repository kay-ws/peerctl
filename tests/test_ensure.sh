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

win_count() { tmux list-windows -t "$PEERCTL_TMUX_SESSION" -F '#W' | awk -v n="$1" '$0==n{c++} END{print c+0}'; }

# 1) peer 不在なら ensure は spawn する（spawn と等価）
cmd_ensure epsilon --no-git
pd="$(peer_dir epsilon)"
assert_eq "$PEERCTL_TMUX_SESSION:epsilon" "$(meta_get "$pd" target)" "ensure: 不在なら spawn する"
assert_eq "1" "$(win_count epsilon)" "ensure: tmux window を1つ作る"

# 2) 既存なら冪等: die せず・重複生成せず・成功で返り・既存を報告
out="$(cmd_ensure epsilon --no-git 2>&1)"; rc=$?
assert_eq "0" "$rc" "ensure: 既存でも成功 (spawn のように die しない)"
assert_eq "1" "$(win_count epsilon)" "ensure: 重複 window を作らない"
assert_contains "$out" "already" "ensure: 既存を報告する"

cmd_kill epsilon

# 3) name 無しは die
out="$(cmd_ensure 2>&1)"; rc=$?
assert_eq "1" "$rc" "ensure: name 無しは die"

finish
