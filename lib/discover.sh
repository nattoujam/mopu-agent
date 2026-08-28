#!/usr/bin/env bash

# ラベル付き Issue を JSON Lines で出力する
# {kind, number, title, body, actor, deps}
# 分解されたタスクは先に作られた Issue が後続の前提になるため、番号の昇順で返す。
# deps は同じ親を持ち、番号が若く、まだ open な sub-issue（＝PR が master に
# 入っていない前提タスク）で、poll.sh はこれが残るうちは着手を見送る。
# 子から親を辿れるのは GraphQL だけ（REST の issue.parent は null を返す）。
# IssueOrderField に NUMBER がないため、並べ替えは jq 側で行う
# shellcheck disable=SC2016  # $owner / $i は GraphQL と jq の変数
discover_labeled() {
  gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -f label="$LABEL_QUEUED" -f query='
    query($owner:String!, $name:String!, $label:String!) {
      repository(owner:$owner, name:$name) {
        issues(first:50, states:OPEN, labels:[$label], orderBy:{field:CREATED_AT, direction:ASC}) {
          nodes {
            number title body author { login }
            parent { number subIssues(first:100) { nodes { number state } } }
          }
        }
      }
    }' \
    --jq '.data.repository.issues.nodes | sort_by(.number)[] | . as $i
          | {kind:"issue", number, title, body, actor:.author.login,
             deps: [(.parent.subIssues.nodes // [])[]
                    | select(.state == "OPEN" and .number < $i.number) | .number]}' 2>/dev/null
}

# コメント本文から fenced code block を取り除いたうえで、
# 行頭のトリガーコマンドを探す。コードブロック内の例示に反応しないため
strip_code_blocks() {
  awk '/^[ \t]*```/ { infence = !infence; next } !infence'
}

# トリガー文字列を正規表現に埋め込むとエスケープ漏れが起きるため、bash の
# パターンマッチで判定する
is_trigger_line() {
  local line="${1#"${1%%[![:space:]]*}"}"
  [[ $line == "$TRIGGER_COMMAND" ]] && return 0
  [[ $line == "$TRIGGER_COMMAND "* ]] && return 0
  [[ $line == "$TRIGGER_COMMAND"$'\t'* ]] && return 0
  return 1
}

has_trigger() {
  local line
  while IFS= read -r line; do
    is_trigger_line "$line" && return 0
  done < <(printf '%s\n' "$1" | strip_code_blocks)
  return 1
}

# トリガー行以降を指示本文として取り出す
extract_instruction() {
  local line found=0
  while IFS= read -r line; do
    (( found )) || { is_trigger_line "$line" && found=1; }
    (( found )) && printf '%s\n' "$line"
  done < <(printf '%s\n' "$1" | strip_code_blocks)
}

# Issue/PR コメントと PR レビューコメントを走査する
# {kind, number, title, body, actor, comment, comment_id}
discover_comments() {
  # URL クエリでは "+09:00" の + が空白として解釈されるため UTC の Z 形式で渡す。
  # 取りこぼしを避けて 1 分さかのぼる（重複は seen-comments.txt で弾かれる）
  local since
  since=$(cat "$STATE_DIR/last-poll" 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
  since=$(date -u -d "$since -1 minute" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$since")

  # 取得は updated の降順のまま（since は updated_at 基準のため、per_page で溢れる
  # ときに窓の新しい側を落とさない）。処理順は取得後のソートで決める
  local raw
  raw=$(
    {
      gh api "repos/$REPO/issues/comments?sort=updated&direction=desc&per_page=100&since=$since" \
        --jq '.[] | {id, body, actor:.user.login, url:.html_url, issue_url, created_at}' 2>/dev/null
      gh api "repos/$REPO/pulls/comments?sort=updated&direction=desc&per_page=100&since=$since" \
        --jq '.[] | {id, body, actor:.user.login, url:.html_url, issue_url:.pull_request_url, created_at}' 2>/dev/null
    } | jq -sc 'sort_by((.issue_url | split("/") | last | tonumber), .created_at)[]'
  )

  [[ -n $raw ]] || return 0

  while IFS= read -r row; do
    [[ -n $row ]] || continue
    local id actor body number
    id=$(jq -r '.id' <<<"$row")
    actor=$(jq -r '.actor' <<<"$row")
    body=$(jq -r '.body' <<<"$row")

    grep -qxF "$id" "$SEEN_FILE" && continue
    [[ $body == *"$COMMENT_MARKER"* ]] && { echo "$id" >> "$SEEN_FILE"; continue; }
    is_allowed_actor "$actor" || continue
    has_trigger "$body" || continue

    number=$(jq -r '.issue_url' <<<"$row" | grep -oE '[0-9]+$')
    [[ -n $number ]] || continue

    local title
    title=$(gh issue view "$number" -R "$REPO" --json title --jq .title 2>/dev/null) || continue

    jq -nc --arg n "$number" --arg t "$title" \
      --arg b "$(gh issue view "$number" -R "$REPO" --json body --jq .body 2>/dev/null)" \
      --arg a "$actor" --arg c "$(extract_instruction "$body")" --arg id "$id" \
      '{kind:"comment", number:($n|tonumber), title:$t, body:$b, actor:$a, comment:$c, comment_id:$id}'
  done <<<"$raw"
}

mark_seen() {
  local id="$1"
  [[ -n $id ]] && echo "$id" >> "$SEEN_FILE"
}

# 初回実行時に過去のコメントを一斉処理しないための初期化
init_seen_baseline() {
  if [[ ! -f $STATE_DIR/last-poll ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-poll"
    log "初回実行のため、これ以降に投稿されたコメントのみを対象にします"
  fi
}

# 進行中（未マージ）のエージェント製 PR のブランチ名を列挙する。
# 手で作った agent/bot-check のようなブランチを拾わないよう prefix で絞る
list_open_agent_branches() {
  gh pr list -R "$REPO" --state open --limit 100 --json headRefName \
    --jq ".[].headRefName | select(startswith(\"$BRANCH_PREFIX\"))" 2>/dev/null
}
