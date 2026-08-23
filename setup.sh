#!/usr/bin/env bash
set -uo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AGENT_DIR/lib/common.sh"
source "$AGENT_DIR/lib/github-app.sh"

require_tools
load_config

log "対象リポジトリ: $REPO"

if use_github_app; then
  setup_app_auth
else
  log "GitHub App 未設定のため、あなた自身のアカウントで投稿します"
fi

create_label() {
  local name="$1" color="$2" desc="$3"
  if gh label create "$name" -R "$REPO" --color "$color" --description "$desc" 2>/dev/null; then
    log "ラベルを作成しました: $name"
  else
    log "ラベルは既に存在します: $name"
  fi
}

create_label "$LABEL_QUEUED"  "1d76db" "gh-agent: 処理待ち"
create_label "$LABEL_RUNNING" "fbca04" "gh-agent: 実行中"
create_label "$LABEL_DONE"    "0e8a16" "gh-agent: 完了"
create_label "$LABEL_FAILED"  "d73a4a" "gh-agent: 失敗"

log "サンドボックスの依存を確認します"
for t in bwrap socat rg; do
  if command -v "$t" >/dev/null 2>&1; then
    log "  ✓ $t"
  else
    warn "  ✗ $t が見つかりません。sudo pacman -S ${t/bwrap/bubblewrap} でインストールしてください"
  fi
done

log "セットアップ完了。./poll.sh --dry-run で動作を確認してください"
