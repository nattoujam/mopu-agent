#!/usr/bin/env bash

AGENT_DIR="${AGENT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export AGENT_DIR

# shellcheck disable=SC2034  # discover.sh / run-task.sh で参照
COMMENT_MARKER='<!-- mopu-agent -->'
# 分解で作られた sub issue の目印。これが本文にある Issue は再分解させない
# shellcheck disable=SC2034  # run-task.sh で参照
SUB_ISSUE_MARKER='<!-- mopu-agent:sub-of'
# shellcheck disable=SC2034  # run-task.sh / poll.sh で参照
BRANCH_PREFIX='agent/issue-'
# タスク用ディレクトリの中で worktree を置く場所。エージェントの cwd は
# タスク用ディレクトリなので、リポジトリはこの名前の相対パスで見える。
# settings/agent-settings.json の "Bash(git -C repo ...)" も同じ名前を指すので、
# 変えるなら両方を直すこと
# shellcheck disable=SC2034  # workspace.sh で参照
REPO_SUBDIR='repo'

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { printf '%s \033[33m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
err()  { printf '%s \033[31m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Issue コメントは公開されるため、サーバーのユーザー名を含む絶対パスは載せない
agent_relpath() { printf '%s' "${1#"$AGENT_DIR"/}"; }

load_config() {
  local cfg="$AGENT_DIR/config.env"
  [[ -f $cfg ]] || die "config.env がありません。config.env.example をコピーして設定してください"
  # shellcheck disable=SC1090
  source "$cfg"

  [[ -n ${REPO:-} ]] || die "config.env: REPO が未設定です"
  [[ $REPO == */* ]] || die "config.env: REPO は owner/repo 形式で指定してください (現在: $REPO)"

  # 第三者が書いた Issue/コメントを無条件で実行しないための必須ガード
  [[ -n ${ALLOWED_ACTORS:-} ]] || die "config.env: ALLOWED_ACTORS が空です。誰のタスクを実行するか明示してください"

  : "${TRIGGER_COMMAND:=/claude}"
  : "${LABEL_QUEUED:=agent:queued}"
  : "${LABEL_RUNNING:=agent:running}"
  : "${LABEL_DONE:=agent:done}"
  : "${LABEL_FAILED:=agent:failed}"
  : "${MODEL:=opus}"
  : "${CLAUDE_BIN:=claude}"
  : "${TASK_TIMEOUT:=30m}"
  : "${MAX_TASK_BUDGET_USD:=3}"
  : "${MAX_5H_PERCENT:=50}"
  : "${MAX_7D_PERCENT:=80}"
  : "${MAX_TASKS_PER_RUN:=3}"
  : "${MAX_SUB_ISSUES:=5}"
  : "${MAX_OPEN_AGENT_PRS:=1}"
  declare -p EXTRA_ALLOWED_TOOLS >/dev/null 2>&1 || EXTRA_ALLOWED_TOOLS=()

  # エージェントは cd したうえで起動するため、パス指定は AGENT_DIR 基準で
  # 絶対パスに直しておく
  if [[ $CLAUDE_BIN == */* ]]; then
    [[ $CLAUDE_BIN == /* ]] || CLAUDE_BIN="$AGENT_DIR/${CLAUDE_BIN#./}"
    [[ -x $CLAUDE_BIN ]] || die "config.env: CLAUDE_BIN を実行できません: $CLAUDE_BIN"
  else
    command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
      || die "config.env: CLAUDE_BIN が見つかりません: $CLAUDE_BIN"
  fi
  export CLAUDE_BIN

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
  for t in gh jq git flock timeout; do
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

# ラベルが未作成のまま poll.sh を走らせると、set_labels の付与だけが失敗して
# 削除は通るため、Issue に付いていた agent:queued が外れてしまう
require_labels_ready() {
  local existing missing=() l
  existing=$(gh label list -R "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null) \
    || die "ラベル一覧を取得できませんでした: $REPO"
  for l in "$LABEL_QUEUED" "$LABEL_RUNNING" "$LABEL_DONE" "$LABEL_FAILED"; do
    grep -qxF -- "$l" <<<"$existing" || missing+=("$l")
  done
  (( ${#missing[@]} == 0 )) \
    || die "ラベルが未作成です (${missing[*]})。先に ./setup.sh を実行してください"
}

# config で明示されていればそれを優先する（PR のベースを既定ブランチ以外に
# したい場合があるため）。gh で引く都合上、App 認証を張った後に呼ぶ
resolve_base_branch() {
  [[ -n ${BASE_BRANCH:-} ]] && return 0
  BASE_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)
  [[ -n $BASE_BRANCH ]] || die "既定ブランチを取得できませんでした: $REPO"
  log "ベースブランチ: $BASE_BRANCH"
}
