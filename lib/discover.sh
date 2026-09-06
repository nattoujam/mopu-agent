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

# PR へのコメントは PR 番号で届くが、タスクの番号は元 Issue のものでなければ
# ならない。PR 番号のままだと agent/issue-<PR番号> という別のブランチで作業して
# しまい、進行中 PR のゲートも「その PR 自身のタスク」と認識できずに弾く。
# エージェントが作った PR はブランチ名に元 Issue 番号を持つのでそこから戻す
resolve_issue_number() {
  local number="$1" head suffix
  head=$(gh pr view "$number" -R "$REPO" --json headRefName --jq .headRefName 2>/dev/null)
  suffix="${head#"$BRANCH_PREFIX"}"
  if [[ -n $head && $suffix != "$head" && $suffix =~ ^[0-9]+$ ]]; then
    printf '%s' "$suffix"
  else
    printf '%s' "$number"
  fi
}

# Issue/PR コメントと PR レビューコメントを走査する
# {kind, number, title, body, actor, comments:[{id, actor, instruction, reply_kind, reply_number, url}]}
# number は作業対象の Issue 番号、comments[].reply_* は返信先（コメントが実際に
# 置かれている Issue / PR とスレッド）を指す。
# 同じ作業対象へのコメントは 1 タスクに畳む。同じブランチを触る以上、別々の
# セッションで順に処理しても後のセッションが前の変更を読み直すだけで、
# 指示どうしの矛盾も見つけられない
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
        --jq '.[] | {id, body, actor:.user.login, url:.html_url, issue_url, created_at, reply_kind:"issue"}' 2>/dev/null
      gh api "repos/$REPO/pulls/comments?sort=updated&direction=desc&per_page=100&since=$since" \
        --jq '.[] | {id, body, actor:.user.login, url:.html_url, issue_url:.pull_request_url, created_at, reply_kind:"review"}' 2>/dev/null
    } | jq -sc 'sort_by((.issue_url | split("/") | last | tonumber), .created_at)[]'
  )

  [[ -n $raw ]] || return 0

  # PR 番号から Issue 番号への読み替えは API を叩くので、同じ PR では使い回す
  local -A resolved=()
  local hits=""
  while IFS= read -r row; do
    [[ -n $row ]] || continue
    local id actor body reply_kind reply_number number
    id=$(jq -r '.id' <<<"$row")
    actor=$(jq -r '.actor' <<<"$row")
    body=$(jq -r '.body' <<<"$row")
    reply_kind=$(jq -r '.reply_kind' <<<"$row")

    grep -qxF "$id" "$SEEN_FILE" && continue
    [[ $body == *"$COMMENT_MARKER"* ]] && { echo "$id" >> "$SEEN_FILE"; continue; }
    is_allowed_actor "$actor" || continue
    has_trigger "$body" || continue

    reply_number=$(jq -r '.issue_url' <<<"$row" | grep -oE '[0-9]+$')
    [[ -n $reply_number ]] || continue
    number="${resolved[$reply_number]:-}"
    if [[ -z $number ]]; then
      number=$(resolve_issue_number "$reply_number")
      resolved[$reply_number]="$number"
    fi

    hits+=$(jq -nc --arg n "$number" --arg a "$actor" --arg id "$id" \
      --arg c "$(extract_instruction "$body")" \
      --arg rk "$reply_kind" --arg rn "$reply_number" \
      --arg url "$(jq -r '.url' <<<"$row")" \
      '{number:($n|tonumber), id:$id, actor:$a, instruction:$c,
        reply_kind:$rk, reply_number:($rn|tonumber), url:$url}')$'\n'
  done <<<"$raw"

  [[ -n $hits ]] || return 0

  # Issue 本文とタイトルは畳んだあとに 1 回だけ引く
  local grouped number title body
  grouped=$(grep -v '^$' <<<"$hits" | jq -sc 'group_by(.number)[]')
  while IFS= read -r g; do
    [[ -n $g ]] || continue
    number=$(jq -r '.[0].number' <<<"$g")
    title=$(gh issue view "$number" -R "$REPO" --json title --jq .title 2>/dev/null) || continue
    body=$(gh issue view "$number" -R "$REPO" --json body --jq .body 2>/dev/null)
    jq -c --arg t "$title" --arg b "$body" \
      '{kind:"comment", number:.[0].number, title:$t, body:$b, actor:.[0].actor,
        comments: map({id, actor, instruction, reply_kind, reply_number, url})}' <<<"$g"
  done <<<"$grouped"
}

# --retry は記録済みのコメントを再処理するため、追記の前に重複を弾く
mark_seen() {
  local id="$1"
  [[ -n $id ]] || return 0
  grep -qxF "$id" "$SEEN_FILE" || echo "$id" >> "$SEEN_FILE"
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
