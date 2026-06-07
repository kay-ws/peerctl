#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

PEERCTL_HOME="$(mktemp -d)"; export PEERCTL_HOME
workdir="$(mktemp -d)"
scratch="$(mktemp -d)"
trap 'rm -rf "$PEERCTL_HOME" "$workdir" "$scratch"' EXIT

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
# --- install_hook: マージ方式 ---

# 1) 既存設定にマージ（ユーザの permissions / 別 hook を保持しつつ自分の Stop を追加）
wd1="$scratch/case1"; mkdir -p "$wd1/.claude"
cat > "$wd1/.claude/settings.local.json" <<'JSON'
{ "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "/keep/me.sh" } ] } ] } }
JSON
pd1="$(peer_dir merge1)"
install_hook "$wd1" "$pd1"
s1="$(cat "$wd1/.claude/settings.local.json")"
assert_contains "$s1" "Bash(ls:*)"     "install: 既存 permissions を保持"
assert_contains "$s1" "/keep/me.sh"    "install: 既存 PreToolUse hook を保持"
assert_contains "$s1" "$pd1/on-stop.sh" "install: 自分の Stop hook を追加"
assert_eq "0" "$(meta_get "$pd1" hook_created_file)" "install: 既存ファイルは created_file=0"

# 2) ファイル不在なら新規作成（自分のエントリのみ、created フラグ=1）
wd2="$scratch/case2"; mkdir -p "$wd2"
pd2="$(peer_dir create2)"
install_hook "$wd2" "$pd2"
assert_contains "$(cat "$wd2/.claude/settings.local.json")" "$pd2/on-stop.sh" "install: 不在時はファイル作成"
assert_eq "1" "$(meta_get "$pd2" hook_created_file)" "install: 新規作成は created_file=1"
assert_eq "1" "$(meta_get "$pd2" hook_created_dir)"  "install: .claude 作成で created_dir=1"

# 3) 不正 JSON は die し、対象ファイルは無改変
wd3="$scratch/case3"; mkdir -p "$wd3/.claude"
printf '{ this is not json' > "$wd3/.claude/settings.local.json"
before3="$(cat "$wd3/.claude/settings.local.json")"
pd3="$(peer_dir bad3)"
out3="$( install_hook "$wd3" "$pd3" 2>&1 )"; rc3=$?
assert_eq "1" "$rc3" "install: 不正 JSON は die"
assert_contains "$out3" "不正" "install: 不正 JSON のエラーメッセージ"
assert_eq "$before3" "$(cat "$wd3/.claude/settings.local.json")" "install: 不正 JSON ファイルは無改変"

finish
