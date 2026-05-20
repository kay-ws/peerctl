#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

command -v tmux >/dev/null || { echo "SKIP: tmux 不在"; exit 0; }

export PEERCTL_HOME="$(mktemp -d)"
export PEERCTL_TMUX_SESSION="peerctl_test_$$"
export PEERCTL_AGENT="cat"   # claude の代わりに cat を起動（入力を待つだけ）
trap 'tmux kill-session -t "$PEERCTL_TMUX_SESSION" 2>/dev/null; rm -rf "$PEERCTL_HOME"' EXIT

cmd_spawn gamma --no-git
pd="$(peer_dir gamma)"
assert_eq "$PEERCTL_TMUX_SESSION:gamma" "$(meta_get "$pd" target)" "spawn recorded target"
assert_contains "$(tmux list-windows -t "$PEERCTL_TMUX_SESSION" -F '#W')" "gamma" "tmux window exists"
assert_contains "$(cmd_list)" "gamma" "list shows peer"

cmd_kill gamma
assert_eq "" "$(meta_get "$pd" target)" "kill removed peer dir (meta gone)"
finish
