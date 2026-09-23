#!/usr/bin/env bash

AGENT_DIR="${AGENT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export AGENT_DIR

# shellcheck disable=SC2034  # discover.ts / run-task.sh で参照
COMMENT_MARKER='<!-- mopu-agent -->'
# 分解で作られた sub issue の目印。これが本文にある Issue は再分解させない
# shellcheck disable=SC2034  # run-task.sh で参照
SUB_ISSUE_MARKER='<!-- mopu-agent:sub-of'
# shellcheck disable=SC2034  # discover.ts / run-task.sh / poll.sh で参照
BRANCH_PREFIX='agent/issue-'
# タスク用ディレクトリの中で worktree を置く場所。エージェントの cwd はここ
# shellcheck disable=SC2034  # workspace.sh / run-task.sh で参照
REPO_SUBDIR='repo'
# shellcheck disable=SC2034  # run-task.sh / plan.sh / setup.sh で参照
LABEL_QUEUED='agent:queued'
# shellcheck disable=SC2034
LABEL_RUNNING='agent:running'
# shellcheck disable=SC2034
LABEL_AWAITING='agent:awaiting-approval'
# shellcheck disable=SC2034
LABEL_DONE='agent:done'
# shellcheck disable=SC2034
LABEL_FAILED='agent:failed'
SETTINGS_FILE="$AGENT_DIR/state/settings.json"
SETTINGS_SCHEMA="$AGENT_DIR/settings/schema.json"
APP_KEY_FILE="$AGENT_DIR/state/secrets/github-app.pem"

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { printf '%s \033[33m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
err()  { printf '%s \033[31m%s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Issue コメントは公開されるため、サーバーのユーザー名を含む絶対パスは載せない
agent_relpath() { printf '%s' "${1#"$AGENT_DIR"/}"; }

# どのコードが出したログなのかを後から追うための短縮 SHA。作業ツリーに
# 未コミットの変更があるときは -dirty を付ける（その SHA だけでは
# 動いていたコードを再現できないため）
agent_commit() {
  local sha
  sha=$(git -C "$AGENT_DIR" rev-parse --short HEAD 2>/dev/null) || { printf 'unknown'; return; }
  [[ -n $(git -C "$AGENT_DIR" status --porcelain 2>/dev/null) ]] && sha+='-dirty'
  printf '%s' "$sha"
}

repo_names() {
  jq -r '(.repos // {}) | keys[]' "$SETTINGS_FILE"
}

# 出力は eval される。値は画面から誰でも入れられるので、型を足すときも必ず @sh を通すこと
settings_env() {
  jq -r --slurpfile schema "$SETTINGS_SCHEMA" --arg repo "${1:-}" '
    $schema[0] as $s
    | def assign($defs; $vals):
        $defs | to_entries[]
        | .value as $d
        | ($vals[.key] // $d.default) as $v
        | if $d.type == "list" then
            if $d.shell == "array" then "\($d.env)=(\($v | map(@sh) | join(" ")))"
            else "\($d.env)=\($v | join(" ") | @sh)" end
          else "\($d.env)=\($v | tostring | @sh)" end;
    "APP_ID=\(.github_app.app_id // "" | tostring | @sh)",
    assign($s.global; .global // {}),
    if $repo == "" then empty
    elif (.repos // {}) | has($repo) | not then error("設定にないリポジトリです: \($repo)")
    else "REPO=\($repo | @sh)", assign($s.repo; .repos[$repo]) end
  ' "$SETTINGS_FILE"
}

# owner には _ が使えないので、最初の __ で分ければ repo 名に __ が入っていても取り違えない
repo_of_task_dir() {
  local dir rel slug
  dir=$(realpath -m -- "$1")
  [[ $dir == "$AGENT_DIR/worktrees/"* ]] || return 1
  rel="${dir#"$AGENT_DIR/worktrees/"}"
  slug="${rel%%/*}"
  [[ $rel == "$slug/"?* && ${rel#"$slug/"} != */* && $slug == ?*__?* ]] || return 1
  printf '%s/%s' "${slug%%__*}" "${slug#*__}"
}

load_global_config() {
  local cfg="$AGENT_DIR/config.env" env legacy=0
  if [[ -f $cfg ]]; then
    grep -qE "^[[:space:]]*(REPO|APP_ID|APP_PRIVATE_KEY)=[\"']?[^\"'[:space:]]" "$cfg" && legacy=1
    # shellcheck disable=SC1090
    source "$cfg"
  fi

  if [[ ! -f $SETTINGS_FILE ]]; then
    (( legacy )) && die "設定がコンソールへ移りました。tools/migrate-config で config.env から移行してください"
    die "設定がありません。./console.sh を起動し、画面の「設定」から登録してください"
  fi
  (( legacy )) && warn "config.env の REPO や APP_ID などは使われません。tools/migrate-config で整理してください"

  STATE_DIR="$AGENT_DIR/state"
  if [[ ! -d $STATE_DIR/repos ]] && [[ -e $STATE_DIR/last-poll || -e $STATE_DIR/sessions.json || -e $STATE_DIR/seen-comments.txt ]]; then
    die "state がリポジトリごとの配置になっていません。poll とコンソールを止めて tools/migrate-multi-repo を実行してください"
  fi

  env=$(settings_env) || die "state/settings.json を読めません"
  eval "$env"

  : "${CLAUDE_BIN:=claude}"

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

  APP_PRIVATE_KEY=""
  if [[ -n $APP_ID ]]; then
    APP_PRIVATE_KEY="$APP_KEY_FILE"
    [[ -f $APP_PRIVATE_KEY ]] \
      || die "GitHub App の秘密鍵がありません。コンソールで App を削除して登録し直してください"
    [[ $(stat -c %a "$APP_PRIVATE_KEY") == 600 ]] \
      || die "秘密鍵の権限が 600 ではありません: $(agent_relpath "$APP_PRIVATE_KEY")"
  fi

  AGENT_COMMIT="$(agent_commit)"
  SPEND_FILE="$STATE_DIR/spend.jsonl"
  mkdir -p "$STATE_DIR"
  touch "$SPEND_FILE"
  export AGENT_COMMIT STATE_DIR SPEND_FILE
}

load_config() {
  local repo="${1:-}" names env
  load_global_config
  if [[ -z $repo ]]; then
    mapfile -t names < <(repo_names)
    (( ${#names[@]} > 0 )) || die "リポジトリが設定されていません。コンソールの「設定」で登録してください"
    (( ${#names[@]} == 1 )) || die "リポジトリが複数あります。--repo で指定してください (${names[*]})"
    repo="${names[0]}"
  fi
  env=$(settings_env "$repo") || die "リポジトリの設定を読めません: $repo"
  eval "$env"

  [[ $REPO == */* ]] || die "設定: リポジトリは owner/repo 形式で指定してください (現在: $REPO)"

  # 第三者が書いた Issue/コメントを無条件で実行しないための必須ガード
  [[ -n ${ALLOWED_ACTORS:-} ]] || die "設定: $REPO のタスクを受け付けるユーザーが空です。誰のタスクを実行するか明示してください"

  REPO_SLUG="${REPO//\//__}"
  REPO_DIR="$AGENT_DIR/repos/$REPO_SLUG"
  REPO_STATE_DIR="$STATE_DIR/repos/$REPO_SLUG"
  WORKTREES_DIR="$AGENT_DIR/worktrees/$REPO_SLUG"
  TASK_LOGS_DIR="$AGENT_DIR/logs/$REPO_SLUG"
  SEEN_FILE="$REPO_STATE_DIR/seen-comments.txt"
  SESSION_FILE="$REPO_STATE_DIR/sessions.json"
  LAST_POLL_FILE="$REPO_STATE_DIR/last-poll"
  mkdir -p "$REPO_STATE_DIR" "$WORKTREES_DIR" "$TASK_LOGS_DIR" "$AGENT_DIR/repos"
  touch "$SEEN_FILE"
  # discover.ts は設定を解釈せず、ここで確定した値を環境変数から受け取る
  export REPO_SLUG REPO_DIR REPO_STATE_DIR WORKTREES_DIR TASK_LOGS_DIR SEEN_FILE SESSION_FILE LAST_POLL_FILE
  export REPO TRIGGER_COMMAND LABEL_QUEUED ALLOWED_ACTORS BRANCH_PREFIX COMMENT_MARKER
}

require_tools() {
  local missing=()
  for t in gh jq git flock timeout node bwrap socat; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} == 0 )) || die "必要なコマンドがありません: ${missing[*]}"
  gh auth status >/dev/null 2>&1 || die "gh が未認証です。gh auth login を実行してください"
  # failIfUnavailable にしてあるので、ここで落とさないとタスクごとに同じ失敗を繰り返す
  bwrap --ro-bind / / --dev /dev --unshare-all true 2>/dev/null \
    || die "bwrap がユーザー名前空間を作れません。docs/isolation.md の「前提」を参照してください"
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
  for l in "$LABEL_QUEUED" "$LABEL_RUNNING" "$LABEL_AWAITING" "$LABEL_DONE" "$LABEL_FAILED"; do
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
