#!/bin/bash

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/assert.sh"
source "$here/../peerctl"
set +eu +o pipefail

# usage がコマンド一覧を含む
out="$(usage 2>&1)"
assert_contains "$out" "spawn" "usage lists spawn"
assert_contains "$out" "ask" "usage lists ask"
finish
