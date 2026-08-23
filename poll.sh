#!/usr/bin/env bash
set -uo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AGENT_DIR/lib/common.sh"

DRY_RUN=0
IGNORE_BUDGET=0
ONLY_TASK=""

usage() {
  cat <<'EOF'
使い方: ./poll.sh [オプション]

  --dry-run           検出したタスクを表示するだけで実行しない
  --ignore-budget     利用枠のゲートを無視して実行する
  --task <番号>       指定した Issue 番号だけを処理する（ラベル不要）
  -h, --help          このヘルプ
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run)       DRY_RUN=1 ;;
    --ignore-budget) IGNORE_BUDGET=1 ;;
    --task)          ONLY_TASK="${2:?--task には Issue 番号が必要です}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "不明なオプション: $1" ;;
  esac
  shift
done

require_tools
load_config

source "$AGENT_DIR/lib/github-app.sh"
source "$AGENT_DIR/lib/budget.sh"
source "$AGENT_DIR/lib/workspace.sh"
source "$AGENT_DIR/lib/run-task.sh"
source "$AGENT_DIR/lib/discover.sh"

exec 9>"$STATE_DIR/poll.lock"
flock -n 9 || die "別の poll.sh が実行中です"

setup_app_auth

RATE_LIMIT_HIT=0

gate() {
  (( IGNORE_BUDGET )) && { log "利用枠のゲートを無視します (--ignore-budget)"; return 0; }
  check_budget
}

# --- タスクの収集 ---
init_seen_baseline
tasks=""

if [[ -n $ONLY_TASK ]]; then
  tasks=$(gh issue view "$ONLY_TASK" -R "$REPO" --json number,title,body,author \
    --jq '{kind:"issue", number, title, body, actor:.author.login}' 2>/dev/null) \
    || die "Issue #$ONLY_TASK を取得できませんでした"
else
  tasks=$(discover_labeled)
  comments=$(discover_comments)
  [[ -n $comments ]] && tasks=$(printf '%s\n%s' "$tasks" "$comments")
fi

tasks=$(grep -v '^$' <<<"$tasks")

if [[ -z $tasks ]]; then
  log "処理するタスクはありません"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-poll"
  exit 0
fi

log "$(wc -l <<<"$tasks") 件のタスクを検出しました"

if (( DRY_RUN )); then
  while IFS= read -r t; do
    jq -r '"  [\(.kind)] #\(.number) \(.title)  (by \(.actor))"' <<<"$t"
  done <<<"$tasks"
  gate
  exit 0
fi

# --- 実行 ---
processed=0
while IFS= read -r t; do
  [[ -n $t ]] || continue
  (( processed >= MAX_TASKS_PER_RUN )) && { log "1回の上限 ($MAX_TASKS_PER_RUN 件) に達しました"; break; }
  (( RATE_LIMIT_HIT )) && { warn "レート上限に達したため以降のタスクを中止します"; break; }

  actor=$(jq -r '.actor' <<<"$t")
  if ! is_allowed_actor "$actor"; then
    warn "許可されていないユーザーのタスクをスキップします: $actor"
    continue
  fi

  # タスクごとに枠を確認し、連続処理で閾値を跨がないようにする
  if ! gate; then
    warn "利用枠のため以降のタスクを中止します"
    break
  fi

  kind=$(jq -r '.kind' <<<"$t")
  number=$(jq -r '.number' <<<"$t")
  title=$(jq -r '.title' <<<"$t")
  body=$(jq -r '.body' <<<"$t")
  comment=$(jq -r '.comment // ""' <<<"$t")
  comment_id=$(jq -r '.comment_id // ""' <<<"$t")

  ensure_repo
  run_task "$kind" "$number" "$title" "$body" "$comment"
  mark_seen "$comment_id"
  (( processed++ ))
done <<<"$tasks"

date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-poll"
log "完了: $processed 件を処理しました"
