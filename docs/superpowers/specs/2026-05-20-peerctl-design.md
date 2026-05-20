# peerctl 設計ドキュメント

- 日付: 2026-05-20
- ステータス: 設計合意済み（実装計画はこれから）

## 背景・動機

複数の Claude Code を「1 オーケストレータ + 複数ピア」で並列に回したい。先行する
cmux（manaflow-ai/cmux）は Ghostty ベースの macOS ネイティブ GUI 端末で、これを
実現するが **Mac 専用**。Linux/sway 環境の kay が使うには、オーケストレータ欲しさに
VS Code + MCP 拡張（vscode-terminal-bridge）を導入する遠回りが必要だった。

検証の結果、必要な中核は「別端末でエージェントを起動・操作し、応答を回収する」だけで、
GUI 端末や MCP 層は本質要件ではないと判明した。本ツール `peerctl` は、その中核を
**tmux + git worktree + Claude Code hooks + JSONL transcript** だけで実装し、VS Code も
MCP サーバも持たない、端末非依存・移植可能なオーケストレーション CLI とする。

## 目的とスコープ

### やること（中核 5 原子操作 + ask）
- ピアの起動（worktree 隔離 + tmux + Stop hook 仕込み）
- ピアへのメッセージ送信
- ピアの応答受信（ターン完了をゲートにした確実な読み取り）
- ピア一覧・状態表示
- ピアの撤収

### やらないこと（YAGNI / cmux から意図的に削った分）
GUI・ブラウザ統合・タブ/ペイン UI・通知パネル・PR ステータス表示・font/find・
tmux が提供する以上の session restore。これらは tmux / sway / 既存ツール
（playwright-cli 等）に外出しする。

## 設計判断（合意済み）

| 論点 | 決定 | 理由 |
|---|---|---|
| 端末制御基盤 | **tmux** | 端末エミュレータ非依存で移植性が高い。`send-keys` が本文と Enter を別キーで送れる。設定ゼロ。SSH 透過 |
| 主体（オーケストレータ） | **両用 CLI（人 / claude どちらも叩ける）** | 原子操作は人/AI で同一。素な CLI 1 本で両対応 |
| 完了検知 | **Claude Code Stop hook** | ターン完了を確実に捕捉。idle ポーリングより堅牢 |
| 実装言語 | **bash + jq** | 新ランタイム不要、`git clone して即動く`。JSONL は jq で読める（実証済み） |
| セッション隔離 | **git worktree per peer**（`--no-git` で素 dir も可） | cwd 分離で transcript 名前空間が分かれ、作業も衝突しない |

## アーキテクチャ

### 状態ディレクトリ
`${XDG_RUNTIME_DIR:-/tmp}/peerctl/peers/<name>/`
- `meta` — name / tmux target（`peers:<name>`）/ worktree パス / branch。spawn 時に記録
- `signal` — Stop hook が毎ターン上書きする 1 行: `<完了epoch>\t<session_id>\t<transcript_path>`
  - 「端末 → session 特定」と「ターン完了検知」を 1 ファイルで兼ねる

tmux セッションは単一（`peers`）に集約し、ピアごとに window を切る。

### コンポーネント

- **`spawn <name> [--base <ref>] [--no-git] [--dir <path>]`**
  1. worktree 作成（`git worktree add`）。`--no-git` なら素の作業 dir を作る（会話専用ピア向け）
  2. その作業 dir の `.claude/settings.local.json` に Stop hook を書き込む（project 単位 = そのピアにだけ効く。gitignore 対象 = checkout 単位で独立）
  3. `tmux new-window -t peers -n <name> -c <workdir>` → `tmux send-keys ... 'claude' Enter`
  4. claude プロセスが起動するまで待つ（pane PID 配下に `claude` が現れるまでポーリング）
  5. `meta` 記録
- **`send <name> <msg>`**
  - `tmux send-keys -t peers:<name> -l -- "<msg>"`（本文・リテラル、Enter なし）
  - → `tmux send-keys -t peers:<name> Enter`（**独立した Enter**）
  - fire-and-forget。送信時刻を recv 用に控える
- **`recv <name> [--timeout S]`**
  - 送信時刻より `signal` の epoch が新しくなる（= Stop hook 発火 = ターン完了）まで待機
  - `signal` の `transcript_path` を読み、最終 user 行以降の `assistant` テキストブロックを抽出して出力
  - timeout で非ゼロ終了（ピアは殺さない）
- **`ask <name> <msg> [--timeout S]`** — send + recv の合成（主役 UX。VS Code 時の talk_to_agent 相当）
- **`list`** — ピア一覧。状態は `last_send > signal.epoch` なら working、逆なら idle
- **`kill <name> [--keep-worktree]`** — `tmux kill-window` → worktree 撤収（任意でブランチ削除）→ peer dir 掃除

### Stop hook（spawn が各作業 dir に生成）
```bash
#!/bin/bash
input=$(cat)
sid=$(jq -r '.session_id' <<<"$input")
tp=$(jq -r '.transcript_path' <<<"$input")
printf '%s\t%s\t%s\n' "$(date +%s)" "$sid" "$tp" > "<peerdir>/signal"
exit 0
```
- 確実に存在するフィールド（`session_id` / `transcript_path`）のみ依存。`output`（応答全文）は
  ペイロードに含まれる可能性があるが未確証のため使わない（含まれていれば transcript 読みを
  省ける最適化として後日検討）
- Stop は matcher 非対応で常時発火（今回はそれが望ましい）。exit 0 で抜けるためループしない

## データフロー（ask）
```
送信者 → send → tmux send-keys → ピア claude が応答生成
       → Stop hook 発火 → signal に (epoch, session_id, transcript_path) を上書き
recv → signal.epoch > 送信時刻 を検知 → transcript の最終 assistant ターンを抽出 → 返す
```
完了ゲート付きのため、応答途中で読んで欠ける問題が起きない。

## エラー処理
- `spawn`: 名前重複、git リポジトリ外（`--no-git` 未指定時）は明確なメッセージで失敗
- `send`/`recv`/`kill`: 未知のピア名は失敗
- `recv` timeout: 非ゼロ終了 + 「まだ working の可能性」を明示。ピアは生かしたまま
- send 時に claude 未起動: spawn 側で起動完了を待つことで構造的に回避
- JSONL schema 依存（最も脆い箇所）: 抽出ロジックを単一関数に隔離し、テスト対象にする

## テスト
1. spawn → `ask <name> "「OK」と返して"` → recv が "OK" を返す（手動検証の自動化版）
2. 2 段階送信が実際に submit されること（今回ハマった回帰テスト）
3. 遅いピア（考え込ませる）で recv が完了まで待つこと（早期/部分返しでない）
4. 別 worktree の複数ピア並行で混線しないこと
5. `recv` timeout 経路

## 未解決・留保
- Stop hook の `output` フィールド実在性は未確証（含まれれば transcript 読み省略の最適化余地）
- 複数ピアへの fan-out をオーケストレータ claude にどう自然に使わせるか（ドキュメント/プロンプト面）は実装後に整理
