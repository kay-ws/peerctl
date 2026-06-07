# peerctl `--dir` Stop hook ライフサイクル修正 — 設計

- 日付: 2026-06-07
- 対象: `~/project/peerctl`（main）
- 種別: バグ修正（`install_hook` / `cmd_kill` の挙動変更 + `uninstall_hook` 新規）

## 背景・問題

`spawn`/`ensure` は `install_hook` で `<workdir>/.claude/settings.local.json` に Stop hook
（`<peerdir>/on-stop.sh` を指す）を書き込み、recv のための signal を取得している。
現状この処理には実 dir（`--dir`）を指したときに顕在化する 2 つの欠陥がある。

1. **install の無条件上書き（データ損失）**
   `install_hook` は `cat > "$workdir/.claude/settings.local.json"` でファイルを丸ごと上書きする。
   `--dir` で実 dir（例: Obsidian vault）を指すと、ユーザが既に持っていた settings.local.json
   （permissions allowlist や独自 hook）が **spawn した瞬間に破壊される**。kill を待たずに起きる。

2. **kill の取り残し（壊れ hook）**
   `cmd_kill` は tmux window・worktree・peer state dir（`$pd`）を消すが、
   `<workdir>/.claude/settings.local.json` は触らない。worktree/mktemp の使い捨て dir は
   dir ごと消えるので無害だが、`--dir` の実 dir では hook 設定だけが残る。
   さらに `$pd/on-stop.sh`（runtime 下）は消えるため、残った設定は
   **存在しない command を毎ターン叩く壊れ hook** になる。次回 `cd <dir> && claude` のたびに発火し、
   対象が同期下（rclone/Syncthing）なら `.claude/` が伝播する。

実害は 2026-06-06 の Obsidian vault eval で実証済（手動除去で対処）。

### モード別の影響範囲

| spawn モード | workdir | install 上書き | kill 取り残し |
|---|---|---|---|
| worktree（既定） | `.peers/<name>` 使い捨て | 無害（既存ファイル無し） | 無害（dir ごと削除） |
| `--no-git` | `/tmp/peer-*` 使い捨て | 無害 | settings は無害（mktemp dir 自体の残存は別件） |
| **`--dir`** | 実 dir（vault 等） | **既存設定を破壊** | **壊れ hook を残す** |

実質 `--dir` ケースだけが対象だが、修正はモード非依存の不変条件として実装する。

## ゴール（不変条件）

> peerctl は `<workdir>/.claude/settings.local.json` に**自分の Stop hook エントリだけを足し引きする**。
> spawn でユーザの既存設定を壊さず、kill で自分のぶんだけ取り除いて、借りる前の状態に戻す。

採用方針は **マージ + マーカー除去**。自分のエントリの command パス（peer 固有の `$pd/on-stop.sh`）を
マーカーとして使うことで、同じ実 dir に複数 peer がいても自分のぶんだけ正確に消せる。

## 設計

### 1. `install_hook` — clobber をやめてマージに

- `on-stop.sh` の生成（`render_hook` → `$pd/on-stop.sh`、chmod +x）は現状のまま。
- settings.local.json の書き込みを jq マージに変更：
  - **ファイルが既存**: `jq -e .` でパース検証する。
    - **不正 JSON なら die**（壊さず「直すか削除してから再実行」と案内）。妥当なら土台にする。
  - **ファイル無し**: 土台は `{}`。`.claude` ディレクトリも無ければ作る。
  - `.hooks.Stop` 配列へ自分のエントリを **追加**（既存エントリは保持）:
    ```json
    { "hooks": [ { "type": "command", "command": "<pd>/on-stop.sh" } ] }
    ```
    `.hooks` / `.hooks.Stop` が未存在でも安全に作る（`.hooks.Stop = ((.hooks.Stop // []) + [$entry])`）。
  - 書き込みは `mktemp` + `mv` で atomic（ユーザのファイルを書き込み途中で壊さない）。
- kill 時の判断材料を meta に記録：
  - `hook_created_file`（settings.local.json を自分で新規作成したか: 0/1）
  - `hook_created_dir`（`.claude` を自分で新規作成したか: 0/1）
  - command パス（`$pd/on-stop.sh`）と settings パス（`<workdir>/.claude/settings.local.json`）は
    `pd`・`workdir` から導出できるので保存しない。

### 2. `uninstall_hook`（新規）— kill から呼ぶ

引数は `(workdir, pd)`。

- `<workdir>/.claude/settings.local.json` が無ければ no-op で return。
- `jq -e .` でパース不能（外部要因で不正 JSON 化）なら **触らず warn して return**（破壊回避）。
- jq で「inner の command が自分の `$pd/on-stop.sh` に一致するエントリ」だけ除去し、
  空になった `.hooks.Stop` / `.hooks` を prune する。
- 後始末：
  - `hook_created_file=1` かつ除去後の内容が `{}` → **ファイルを削除**。
    さらに `hook_created_dir=1` かつ `.claude` が空なら rmdir。
  - それ以外 → prune 済み内容を atomic（`mktemp` + `mv`）に書き戻す
    （＝ユーザ設定・他 peer のエントリは残る）。

### 3. `cmd_kill` — 呼び出し 1 行追加

- 既に meta から `workdir` を読み込み済みなので、`rm -rf "$pd"` の **前に**
  `uninstall_hook "$workdir" "$pd"` を挿入する。
- worktree/mktemp ケースでは settings が dir ごと消えるため uninstall は実質 no-op、害なし。

## テスト（自前ハーネス、`tests/test_hook.sh` 拡張）

既存スイートと同じ自前ハーネス（`tests/assert.sh`）で書く。bats 移行は別タスク。

1. 既存設定にマージ — ユーザの key / 別 hook を保ったまま自分のエントリが追加される
2. ファイル不在時は新規作成 — `.claude/settings.local.json` に自分のエントリのみ
3. 不正 JSON は install が die し、対象ファイルは無改変のまま
4. uninstall で自分のエントリだけ消え、既存ユーザ設定は残る
5. 自分で作ったファイルは uninstall で消滅（空なら `.claude` も rmdir）
6. 同一 settings に 2 エントリ（別 pd パス）→ 片方 uninstall でもう片方は残る

## 非ゴール（割り切り）

- **bats 移行** — 別タスク。今回は自前ハーネスで閉じる。
- **`--no-git` の mktemp workdir が kill で残る別リーク** — hook wart とは別件。
  settings クリーンアップ自体は無害に走るが、dir 削除はスコープ外。
- **runtime state dir が reboot で消えた場合の `--dir` stale エントリ** —
  自己識別マーカーなので将来 prune を後付け可能だが、今回は能動的 reconciler を作らない（既知の限界）。

## 影響を受けるファイル

- `peerctl` — `install_hook` 改修、`uninstall_hook` 追加、`cmd_kill` に 1 行、meta キー 2 個追加
- `tests/test_hook.sh` — テストケース追加
