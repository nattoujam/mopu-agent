#!/usr/bin/env bash

AGENT_DIR="${AGENT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export AGENT_DIR

# shellcheck disable=SC2034  # discover.sh / run-task.sh で参照
COMMENT_MARKER='<!-- gh-agent -->'

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { printf '%s \033[33m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
err()  { printf '%s \033[31m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit 1; }

load_config() {
  local cfg="$AGENT_DIR/config.env"
  [[ -f $cfg ]] || die "config.env がありません。config.env.example をコピーして設定してください"
  # shellcheck disable=SC1090
  source "$cfg"

  [[ -n ${REPO:-} ]] || die "config.env: REPO が未設定です"
  [[ $REPO == */* ]] || die "config.env: REPO は owner/repo 形式で指定してください (現在: $REPO)"

  # 第三者が書いた Issue/コメントを無条件で実行しないための必須ガード
  [[ -n ${ALLOWED_ACTORS:-} ]] || die "config.env: ALLOWED_ACTORS が空です。誰のタスクを実行するか明示してください"

  : "${DEFAULT_BRANCH:=main}"
  : "${TRIGGER_COMMAND:=/claude}"
  : "${LABEL_QUEUED:=agent:queued}"
  : "${LABEL_RUNNING:=agent:running}"
  : "${LABEL_DONE:=agent:done}"
  : "${LABEL_FAILED:=agent:failed}"
  : "${MODEL:=opus}"
  : "${TASK_TIMEOUT:=30m}"
  : "${MAX_TASK_BUDGET_USD:=3}"
  : "${MAX_5H_PERCENT:=50}"
  : "${MAX_7D_PERCENT:=80}"
  : "${MAX_TASKS_PER_RUN:=3}"
  declare -p EXTRA_ALLOWED_TOOLS >/dev/null 2>&1 || EXTRA_ALLOWED_TOOLS=()

  if [[ -n ${APP_ID:-} && -n ${APP_PRIVATE_KEY:-} ]]; then
    APP_PRIVATE_KEY="${APP_PRIVATE_KEY/#\~/$HOME}"
    [[ -f $APP_PRIVATE_KEY ]] || die "APP_PRIVATE_KEY が見つかりません: $APP_PRIVATE_KEY"
    [[ $(stat -c %a "$APP_PRIVATE_KEY") == 600 ]] \
      || warn "秘密鍵の権限が緩いです: chmod 600 $APP_PRIVATE_KEY を実行してください"
  fi

  REPO_SLUG="${REPO//\//__}"
  REPO_DIR="$AGENT_DIR/repos/$REPO_SLUG"
  STATE_DIR="$AGENT_DIR/state"
  SEEN_FILE="$STATE_DIR/seen-comments.txt"
  SPEND_FILE="$STATE_DIR/spend.jsonl"
  mkdir -p "$STATE_DIR" "$AGENT_DIR/logs" "$AGENT_DIR/worktrees" "$AGENT_DIR/repos"
  touch "$SEEN_FILE" "$SPEND_FILE"
  export REPO_SLUG REPO_DIR STATE_DIR SEEN_FILE SPEND_FILE
}

require_tools() {
  local missing=()
  for t in gh jq git claude flock timeout; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} == 0 )) || die "必要なコマンドがありません: ${missing[*]}"
  gh auth status >/dev/null 2>&1 || die "gh が未認証です。gh auth login を実行してください"
}

is_allowed_actor() {
  local actor="$1" a
  for a in $ALLOWED_ACTORS; do
    [[ $actor == "$a" ]] && return 0
  done
  return 1
}
