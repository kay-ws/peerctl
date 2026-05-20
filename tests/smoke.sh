#!/bin/bash

set -euo pipefail
# 実 claude + tmux を使う end-to-end。CI でなく手動で実行する。
here="$(cd "$(dirname "$0")" && pwd)"
PC="$here/../peerctl"

PEERCTL_HOME="$(mktemp -d)"; export PEERCTL_HOME
export PEERCTL_TMUX_SESSION="peerctl_smoke_$$"
cleanup() { "$PC" kill smoke 2>/dev/null || true; tmux kill-session -t "$PEERCTL_TMUX_SESSION" 2>/dev/null || true; rm -rf "$PEERCTL_HOME"; }
trap cleanup EXIT

echo "== spawn =="
"$PC" spawn smoke --no-git
echo "== claude 起動を待つ (8s) =="
sleep 8
echo "== ask =="
reply="$("$PC" ask smoke '「スモークOK」とだけ短く返して' --timeout 90)"
echo "reply: $reply"
case "$reply" in
  *スモークOK*) echo "SMOKE PASS" ;;
  *) echo "SMOKE FAIL"; exit 1 ;;
esac
