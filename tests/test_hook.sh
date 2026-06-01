#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

PEERCTL_HOME="$(mktemp -d)"; export PEERCTL_HOME
workdir="$(mktemp -d)"
trap 'rm -rf "$PEERCTL_HOME" "$workdir"' EXIT

pd="$(peer_dir beta)"; mkdir -p "$pd"
install_hook "$workdir" "$pd"

settings="$workdir/.claude/settings.local.json"
assert_contains "$(cat "$settings")" "Stop" "settings has Stop hook"
assert_contains "$(cat "$settings")" "$pd/on-stop.sh" "settings points to hook script"

payload='{"session_id":"S123","transcript_path":"/tmp/x.jsonl","hook_event_name":"Stop","last_assistant_message":"all done"}'
printf '%s' "$payload" | bash "$pd/on-stop.sh"
assert_eq "S123"         "$(read_signal_field "$pd" 2)" "hook wrote session_id"
assert_eq "/tmp/x.jsonl" "$(read_signal_field "$pd" 3)" "hook wrote transcript_path"
assert_eq "all done"     "$(read_signal_field "$pd" 4)" "hook wrote last_assistant_message"
finish
