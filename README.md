# peerctl

VS Code も MCP も使わず、tmux + git worktree + Claude Code Stop hook + JSONL transcript だけで
「1 オーケストレータ + 複数ピア」の Claude Code 並列オーケストレーションを行う単一 bash CLI。

## 依存
- bash, jq, tmux, git, coreutils

## 使い方
```bash
peerctl spawn alpha            # worktree + tmux window で claude ピアを起動
peerctl ask alpha "実装して"   # 送信して応答（ターン完了）を待って返す
peerctl list                   # ピア一覧と状態 (idle/working)
peerctl kill alpha             # ピアと worktree を撤収

# 送受信を分けたい場合
peerctl send alpha "調べて"
peerctl recv alpha --timeout 60

# コードを触らない会話専用ピアは worktree 不要
peerctl spawn talker --no-git
```

## 仕組み
- **送信**: `tmux send-keys` で本文と Enter を別キーとして送る（TUI の bracketed paste で
  改行が吸われ Enter が確定しない問題を構造的に回避）
- **受信**: spawn 時に各ピアへ Stop hook を仕込み、ピアがターンを終えると
  `signal` ファイルに `session_id` と `transcript_path` を書く。recv はそれを待って
  transcript の最終 assistant ターンを抽出する
- **隔離**: ピアごとに git worktree（`--no-git` で素ディレクトリ）。cwd が分かれるので
  transcript の名前空間も作業も衝突しない

## 環境変数
- `PEERCTL_HOME` 状態ディレクトリ（既定 `$XDG_RUNTIME_DIR/peerctl`）
- `PEERCTL_TMUX_SESSION` tmux セッション名（既定 `peers`）
- `PEERCTL_AGENT` ピアで起動するコマンド（既定 `claude`）

## テスト
```bash
for t in tests/test_*.sh; do bash "$t"; done   # 単体（外部依存ゼロ、claude 不要）
bash tests/smoke.sh                            # end-to-end（実 claude + tmux 必須、手動）
```

## ライセンス
MIT License — 詳細は [LICENSE](LICENSE) を参照。
