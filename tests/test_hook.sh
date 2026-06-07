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
assert_eq "0" "$(meta_get "$pd1" hook_created_dir)"  "install: 既存 .claude dir は created_dir=0"

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

# 3b) .claude は在るが settings.local.json が無い → created_file=1, created_dir=0
wd3b="$scratch/case3b"; mkdir -p "$wd3b/.claude"
pd3b="$(peer_dir dironly)"
install_hook "$wd3b" "$pd3b"
assert_eq "1" "$(meta_get "$pd3b" hook_created_file)" "install: dir のみ存在は created_file=1"
assert_eq "0" "$(meta_get "$pd3b" hook_created_dir)"  "install: dir のみ存在は created_dir=0"

# --- uninstall_hook: 自分のエントリだけ撤去 ---

# 4) 既存ユーザ設定を残し、自分の hook だけ消える
wd4="$scratch/case4"; mkdir -p "$wd4/.claude"
cat > "$wd4/.claude/settings.local.json" <<'JSON'
{ "permissions": { "allow": ["Bash(ls:*)"] } }
JSON
pd4="$(peer_dir un4)"
install_hook "$wd4" "$pd4"
uninstall_hook "$wd4" "$pd4"
s4="$(cat "$wd4/.claude/settings.local.json")"
assert_contains     "$s4" "Bash(ls:*)"  "uninstall: 既存ユーザ設定は残る"
assert_not_contains "$s4" "on-stop.sh"   "uninstall: 自分の hook は消える"

# 5) 自分で作ったファイル/ディレクトリは削除
wd5="$scratch/case5"; mkdir -p "$wd5"
pd5="$(peer_dir un5)"
install_hook "$wd5" "$pd5"
uninstall_hook "$wd5" "$pd5"
assert_eq "no" "$([[ -f "$wd5/.claude/settings.local.json" ]] && echo yes || echo no)" "uninstall: 自作ファイルは削除"
assert_eq "no" "$([[ -d "$wd5/.claude" ]] && echo yes || echo no)" "uninstall: 自作の空 .claude も rmdir"

# 6) 同一 settings に 2 peer → 片方撤去でもう片方は残る
wd6="$scratch/case6"; mkdir -p "$wd6"
pdA="$(peer_dir twoA)"; pdB="$(peer_dir twoB)"
install_hook "$wd6" "$pdA"
install_hook "$wd6" "$pdB"
uninstall_hook "$wd6" "$pdA"
s6="$(cat "$wd6/.claude/settings.local.json")"
assert_not_contains "$s6" "$pdA/on-stop.sh" "uninstall: 撤去した peer のエントリは消える"
assert_contains     "$s6" "$pdB/on-stop.sh" "uninstall: 別 peer のエントリは残る"

# 4b) created_file=0（自作でない）なら、中身が空になってもファイルを消さず {} に更新
wd4b="$scratch/case4b"; mkdir -p "$wd4b/.claude"
printf '{}' > "$wd4b/.claude/settings.local.json"
pd4b="$(peer_dir un4b)"
install_hook "$wd4b" "$pd4b"
uninstall_hook "$wd4b" "$pd4b"
assert_eq "yes" "$([[ -f "$wd4b/.claude/settings.local.json" ]] && echo yes || echo no)" "uninstall: 自作でないファイルは空でも残す"
assert_eq "{}" "$(cat "$wd4b/.claude/settings.local.json")" "uninstall: 中身は {} に更新"

# 4c) settings 不在で uninstall を呼んでもクラッシュせず return 0
wd4c="$scratch/case4c"; mkdir -p "$wd4c"
pd4c="$(peer_dir un4c)"
uninstall_hook "$wd4c" "$pd4c"; rc4c=$?
assert_eq "0" "$rc4c" "uninstall: 不在ファイルは no-op で return 0"

# --- cmd_kill: --dir の settings を掃除する ---

# 7) kill が settings を掃除し、peer state dir も消す
wd7="$scratch/case7"; mkdir -p "$wd7"
pd7="$(peer_dir killme)"
install_hook "$wd7" "$pd7"
meta_set "$pd7" workdir "$wd7"
meta_set "$pd7" target ""
meta_set "$pd7" branch ""
cmd_kill killme >/dev/null 2>&1
assert_eq "no" "$([[ -f "$wd7/.claude/settings.local.json" ]] && echo yes || echo no)" "kill: --dir の settings を掃除"
assert_eq "no" "$([[ -d "$pd7" ]] && echo yes || echo no)" "kill: peer state dir を削除"

finish
