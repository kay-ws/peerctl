# peerctl `--dir` Stop hook ライフサイクル修正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `install_hook` の無条件上書きと `cmd_kill` の hook 取り残しを、jq マージ + マーカー除去で解消し、`<workdir>/.claude/settings.local.json` を「借りる前の状態に戻す」ようにする。

**Architecture:** `install_hook` を `cat >`（clobber）から jq マージへ置換し、自分のエントリだけを `.hooks.Stop` に足す。新規 `uninstall_hook` が自分の command パスをマーカーに該当エントリだけ抜き、自分で作ったファイル/ディレクトリは削除する。`cmd_kill` が `rm -rf "$pd"` の前に `uninstall_hook` を呼ぶ。

**Tech Stack:** bash, jq（既存 hard dependency）, 自前テストハーネス（`tests/assert.sh`、bats は使わない）

設計 spec: `docs/superpowers/specs/2026-06-07-peerctl-dir-hook-lifecycle-design.md`

注意: push は行わない。commit は local のみ（GitHub への push は kay が別途判断）。

---

## File Structure

- `peerctl` — `install_hook` 改修 / `uninstall_hook` 追加 / `cmd_kill` に 1 行 / meta キー 2 個（`hook_created_file`, `hook_created_dir`）
- `tests/assert.sh` — `assert_not_contains` ヘルパ追加
- `tests/test_hook.sh` — テストケース追加（既存の case 0 は維持）

---

## Task 1: install_hook をマージ方式に置換

**Files:**
- Modify: `peerctl`（`install_hook`、現状 30-45 行）
- Modify: `tests/test_hook.sh`（既存 trap の直後と末尾 `finish` の直前）

- [ ] **Step 1: テスト用 scratch root を追加**

`tests/test_hook.sh` の `trap 'rm -rf "$PEERCTL_HOME" "$workdir"' EXIT`（11 行目）の **直後** に以下を挿入する:

```bash
scratch="$(mktemp -d)"
trap 'rm -rf "$PEERCTL_HOME" "$workdir" "$scratch"' EXIT
```

- [ ] **Step 2: install マージの失敗テストを書く**

`tests/test_hook.sh` の末尾 `finish` 行の **直前** に以下を挿入する:

```bash
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
```

- [ ] **Step 3: テストを実行して失敗を確認**

Run: `bash tests/test_hook.sh`
Expected: FAILURES（旧 install_hook は clobber するため case 1 の「既存保持」が落ち、die しないため case 3 の rc/メッセージが落ちる）

- [ ] **Step 4: install_hook を置換**

`peerctl` の `install_hook`（30-45 行、`# workdir に Stop hook 用の...` コメント行から閉じ `}` まで）を以下で置換する:

```bash
# workdir の .claude/settings.local.json に自分の Stop hook を「マージ」で足す。
# 既存ファイルは壊さず（不正 JSON なら die）、自分のエントリだけ追加する。
# kill 時の後始末判断のため created_file/created_dir を meta に記録する。
install_hook() {
  local workdir="$1" pd="$2"
  mkdir -p "$pd"
  render_hook "$pd" > "$pd/on-stop.sh"
  chmod +x "$pd/on-stop.sh"

  local cmd_path="$pd/on-stop.sh"
  local claude_dir="$workdir/.claude"
  local settings="$claude_dir/settings.local.json"
  local created_dir=0 created_file=0 base_json

  if [[ -f "$settings" ]]; then
    jq -e . "$settings" >/dev/null 2>&1 \
      || die "install: $settings は不正な JSON です。修正するか削除してから再実行してください"
    base_json="$(cat "$settings")"
  else
    created_file=1
    base_json='{}'
  fi

  [[ -d "$claude_dir" ]] || created_dir=1
  mkdir -p "$claude_dir"

  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$cmd_path" \
    '.hooks.Stop = ((.hooks.Stop // []) + [{hooks:[{type:"command",command:$cmd}]}])' \
    <<<"$base_json" > "$tmp"
  mv "$tmp" "$settings"

  meta_set "$pd" hook_created_file "$created_file"
  meta_set "$pd" hook_created_dir "$created_dir"
}
```

- [ ] **Step 5: テストを実行して成功を確認**

Run: `bash tests/test_hook.sh`
Expected: ALL PASS（既存 case 0 + 新規 case 1-3）

- [ ] **Step 6: commit**

```bash
git add peerctl tests/test_hook.sh
git commit -m "修正: install_hook を clobber からマージに変更し既存設定を保護

- cat > での無条件上書きをやめ、jq で自分の Stop hook だけを追加
- 既存ファイルが不正 JSON なら die（無改変）
- kill の後始末用に hook_created_file/hook_created_dir を meta に記録

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: uninstall_hook を追加

**Files:**
- Modify: `tests/assert.sh`（`finish` の直前に `assert_not_contains` 追加）
- Modify: `tests/test_hook.sh`（末尾 `finish` の直前）
- Modify: `peerctl`（`install_hook` 関数の直後に `uninstall_hook` を追加）

- [ ] **Step 1: assert_not_contains ヘルパを追加**

`tests/assert.sh` の `finish() {`（24 行目）の **直前** に以下を挿入する:

```bash
assert_not_contains() {
  local hay="$1" needle="$2" msg="${3:-not_contains}"
  if [[ "$hay" == *"$needle"* ]]; then
    printf 'FAIL %s\n  %q unexpectedly found in %q\n' "$msg" "$needle" "$hay" >&2
    _pc_fail=1
  else
    printf 'ok   %s\n' "$msg"
  fi
}
```

- [ ] **Step 2: uninstall の失敗テストを書く**

`tests/test_hook.sh` の末尾 `finish` 行の **直前** に以下を挿入する:

```bash
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
```

- [ ] **Step 3: テストを実行して失敗を確認**

Run: `bash tests/test_hook.sh`
Expected: FAILURES（`uninstall_hook` 未定義のため case 4-6 のアサーションが落ちる）

- [ ] **Step 4: uninstall_hook を実装**

`peerctl` の `install_hook` 関数の閉じ `}` の **直後** に以下を追加する:

```bash
# install_hook が足した自分の Stop hook エントリだけを撤去する。command パス
# （peer 固有の on-stop.sh）をマーカーに使うので、同じ dir に複数 peer が居ても
# 自分のぶんだけ消える。外部要因で不正 JSON 化していたら触らない。自分で作った
# ファイル/.claude は（中身が空になったら）削除する。
uninstall_hook() {
  local workdir="$1" pd="$2"
  local settings="$workdir/.claude/settings.local.json"
  [[ -f "$settings" ]] || return 0
  jq -e . "$settings" >/dev/null 2>&1 || {
    printf 'peerctl: warning: %s は不正な JSON のため hook を撤去せず残します\n' "$settings" >&2
    return 0
  }

  local cmd_path="$pd/on-stop.sh"
  local created_file created_dir
  created_file="$(meta_get "$pd" hook_created_file)"
  created_dir="$(meta_get "$pd" hook_created_dir)"

  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$cmd_path" '
    .hooks.Stop = ((.hooks.Stop // []) | map(select(
      ([.hooks[]?.command] | any(. == $cmd)) | not
    )))
    | if (.hooks.Stop // []) == [] then del(.hooks.Stop) else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end
  ' "$settings" > "$tmp"

  if [[ "$created_file" == "1" && "$(cat "$tmp")" == "{}" ]]; then
    rm -f "$settings" "$tmp"
    [[ "$created_dir" == "1" ]] && rmdir "$workdir/.claude" 2>/dev/null || true
  else
    mv "$tmp" "$settings"
  fi
}
```

- [ ] **Step 5: テストを実行して成功を確認**

Run: `bash tests/test_hook.sh`
Expected: ALL PASS

- [ ] **Step 6: commit**

```bash
git add peerctl tests/assert.sh tests/test_hook.sh
git commit -m "機能: uninstall_hook を追加し自分の Stop hook だけ撤去

- command パスをマーカーに該当エントリだけ jq で除去、空なら prune
- 自分で作ったファイル/.claude は中身が空になれば削除
- 不正 JSON 化していたら触らず warn（破壊回避）
- テスト用に assert_not_contains を追加

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: cmd_kill から uninstall_hook を呼ぶ

**Files:**
- Modify: `tests/test_hook.sh`（末尾 `finish` の直前）
- Modify: `peerctl`（`cmd_kill`、`rm -rf "$pd"` の直前）

- [ ] **Step 1: kill 統合の失敗テストを書く**

`tests/test_hook.sh` の末尾 `finish` 行の **直前** に以下を挿入する（tmux 不要: target/branch を空にして window 操作・worktree 削除を skip させる）:

```bash
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
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_hook.sh`
Expected: FAILURES（cmd_kill が uninstall を呼ばず、case 7 の「settings 掃除」が落ちる。`peer state dir 削除` は元から通る）

- [ ] **Step 3: cmd_kill に呼び出しを追加**

`peerctl` の `cmd_kill` 内、worktree 削除の `fi`（247-248 行付近）の直後・`rm -rf "$pd"` の **直前** に以下の 1 行を挿入する:

```bash
  [[ -n "$workdir" ]] && uninstall_hook "$workdir" "$pd" || true
```

挿入後の該当部分は次の形になる:

```bash
  if [[ $keep -eq 0 && -n "$branch" && -n "$workdir" ]]; then
    git worktree remove --force "$workdir" 2>/dev/null || true
  fi
  [[ -n "$workdir" ]] && uninstall_hook "$workdir" "$pd" || true
  rm -rf "$pd"
  printf 'killed peer %s\n' "$name"
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_hook.sh`
Expected: ALL PASS

- [ ] **Step 5: 全テストと shellcheck で回帰確認**

Run: `for t in tests/test_*.sh; do echo "== $t =="; bash "$t"; done`
Expected: 各ファイルが ALL PASS（tmux 不在環境では tmux 依存テストは `SKIP:` 表示で exit 0）

Run: `shellcheck -S warning peerctl`
Expected: 警告ゼロ（出力なし）

- [ ] **Step 6: commit**

```bash
git add peerctl tests/test_hook.sh
git commit -m "修正: cmd_kill が --dir の Stop hook を撤去するように

- rm -rf \"\$pd\" の前に uninstall_hook を呼び、--dir 実 dir に残る
  壊れ hook を防ぐ（worktree/mktemp は dir ごと消えるので no-op）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- install のマージ化（不正 JSON で die、created フラグ記録）→ Task 1 ✓
- uninstall（マーカー除去・prune・自作ファイル削除・不正 JSON で warn）→ Task 2 ✓
- cmd_kill から呼ぶ → Task 3 ✓
- テスト 6 ケース（spec のテスト節）→ case 1-6 に対応、case 7 で kill 統合を追加 ✓
- 非ゴール（bats / mktemp dir leak / reboot stale）→ 触れていない ✓

**Placeholder scan:** TBD/TODO 無し。各コード step は完全なコードを掲載。✓

**Type consistency:** meta キー名 `hook_created_file` / `hook_created_dir` は install（書き込み）と uninstall（読み込み）で一致。関数名 `install_hook` / `uninstall_hook`、command マーカー `$pd/on-stop.sh` も全タスクで一致。✓
