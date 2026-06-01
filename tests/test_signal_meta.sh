#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

PEERCTL_HOME="$(mktemp -d)"; export PEERCTL_HOME
trap 'rm -rf "$PEERCTL_HOME"' EXIT

pd="$(peer_dir alpha)"
mkdir -p "$pd"
assert_eq "$PEERCTL_HOME/peers/alpha" "$pd" "peer_dir path"

meta_set "$pd" target "peers:alpha"
meta_set "$pd" workdir "/tmp/wt alpha"
assert_eq "peers:alpha"   "$(meta_get "$pd" target)"  "meta roundtrip target"
assert_eq "/tmp/wt alpha" "$(meta_get "$pd" workdir)" "meta roundtrip workdir with space"
assert_eq ""              "$(meta_get "$pd" missing)" "meta missing key empty"

printf '%s\t%s\t%s\t%s\n' 1000 sid-1 /tmp/t.jsonl "task complete" > "$pd/signal"
assert_eq "1000"           "$(read_signal_epoch "$pd")"   "signal epoch"
assert_eq "/tmp/t.jsonl"   "$(read_signal_field "$pd" 3)" "signal transcript field"
assert_eq "task complete"  "$(read_signal_field "$pd" 4)" "signal last_assistant_message field"
finish
