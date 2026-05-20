#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

assert_eq "クリーン受信OK" "$(extract_last_reply "$here/fixtures/simple.jsonl")" "string content"
assert_eq "完了しました"   "$(extract_last_reply "$here/fixtures/array_with_tool.jsonl")" "array content, text only"
assert_eq "a2"             "$(extract_last_reply "$here/fixtures/multi_turn.jsonl")" "last turn only"
finish
