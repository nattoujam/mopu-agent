#!/usr/bin/env bash

PLAN_FILE_NAME='.mopu-agent-plan.json'
PLAN_MARKER='<!-- mopu-agent:plan -->'
PLAN_APPROVED_MARKER='<!-- mopu-agent:plan-approved -->'
APPROVE_WORD='approve'

# 分解で生まれた Issue を再分解させないための判定。本文のマーカーは自分で
# 埋めるので確実に効き、parent_issue_url は GitHub 上で手動で紐付けられた
# sub issue も拾える。親のない Issue ではこのキー自体が存在しない
is_sub_issue() {
  local number="$1" body="$2"
  [[ $body == *"$SUB_ISSUE_MARKER"* ]] && return 0
  [[ -n $(gh api "repos/$REPO/issues/$number" --jq '.parent_issue_url // empty' 2>/dev/null) ]]
}

validate_plan() {
  jq -e --argjson max "$MAX_SUB_ISSUES" '
    (.sub_issues | type) == "array"
    and (.sub_issues | length) >= 1
    and (.sub_issues | length) <= $max
    and all(.sub_issues[]; (.title | type) == "string" and (.title | length) > 0)' "$1" >/dev/null 2>&1
}

# 作成した sub issue を "- #番号 タイトル" の行として標準出力へ返す
create_sub_issues() {
  local parent="$1" plan="$2" count i title body resp num id
  count=$(jq '.sub_issues | length' "$plan")
  for (( i = 0; i < count; i++ )); do
    title=$(jq -r ".sub_issues[$i].title" "$plan")
    body=$(jq -r ".sub_issues[$i].body // \"\"" "$plan")
    body=$(printf '%s\n\n---\n%s\n%s #%s -->\n' \
      "$body" "$COMMENT_MARKER" "$SUB_ISSUE_MARKER" "$parent")

    if ! resp=$(gh api "repos/$REPO/issues" \
      -f "title=$title" -f "body=$body" -f "labels[]=$LABEL_QUEUED" 2>&1)
    then
      warn "sub issue の作成に失敗しました: $title"
      warn "$(head -3 <<<"$resp")"
      continue
    fi

    num=$(jq -r '.number' <<<"$resp")
    id=$(jq -r '.id' <<<"$resp")

    # 親子の紐付けだけ失敗しても、作成済みの Issue は残して先へ進む
    if ! gh api -X POST "repos/$REPO/issues/$parent/sub_issues" \
      -F "sub_issue_id=$id" >/dev/null 2>&1
    then
      warn "#$num を #$parent の sub issue に紐付けられませんでした"
    fi

    printf -- '- #%s %s\n' "$num" "$title"
  done
}

render_plan_comment() {
  local plan="$1" reason count i title outline
  reason=$(jq -r '.reason // ""' "$plan")
  count=$(jq '.sub_issues | length' "$plan")

  printf 'このタスクは 1 つの PR には大きいので、次のように分けて進めようと思います。この分け方でよいですか？\n\n'
  [[ -n $reason ]] && printf '%s\n\n' "$reason"
  for (( i = 0; i < count; i++ )); do
    title=$(jq -r ".sub_issues[$i].title" "$plan")
    outline=$(jq -r ".sub_issues[$i].outline // \"\"" "$plan")
    printf '%s. **%s**' "$((i + 1))" "$title"
    [[ -n $outline ]] && printf ' — %s' "$outline"
    printf '\n'
  done
  printf '\n上から順に、前の PR がマージされてから次に着手します。\n\n'
  printf -- '- 承認: `%s %s` とコメント\n' "$TRIGGER_COMMAND" "$APPROVE_WORD"
  printf -- '- 修正: `%s` に続けて直してほしい点を書く\n' "$TRIGGER_COMMAND"
  printf -- '- 却下: ラベル `%s` を外すか Issue を閉じる\n\n' "$LABEL_AWAITING"
  printf '<details><summary>各 sub issue の本文（承認時はこの内容で作成します。手で直しても構いません）</summary>\n\n```json\n%s\n```\n\n</details>\n\n%s\n' \
    "$(jq . "$plan")" "$PLAN_MARKER"
}

propose_plan() {
  local task_id="$1" number="$2" plan="$3" cost="$4" pct_before="$5" task_dir="$6"

  if ! validate_plan "$plan"; then
    err "[$task_id] $PLAN_FILE_NAME の内容が不正です"
    set_labels "$number" "$LABEL_FAILED"
    post_report "$(printf 'タスク分解の結果を解釈できませんでした（sub_issues は 1〜%s 件の配列で、各要素に空でない title が必要です）。\n\n```json\n%s\n```' \
      "$MAX_SUB_ISSUES" "$(head -c 3000 "$plan")")"
    record_spend "$task_id" "$cost" "$pct_before" ""
    log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
    return 1
  fi

  log "[$task_id] 分解案を提案します ($(jq '.sub_issues | length' "$plan") 件)"
  set_labels "$number" "$LABEL_AWAITING"
  post_report "$(render_plan_comment "$plan")"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after"
  remove_workspace "$task_dir"
  log "[$task_id] 承認待ち: \`$TRIGGER_COMMAND $APPROVE_WORD\` のコメントで sub issue を作成します"
  return 0
}

latest_plan_comment() {
  local number="$1" found
  found=$(gh api --paginate "repos/$REPO/issues/$number/comments" 2>/dev/null \
    | jq -c --arg m "$PLAN_MARKER" '.[] | select(.body | contains($m)) | {id, body}' | tail -1)
  [[ -n $found ]] || return 1
  printf '%s' "$found"
}

# コメント本文から plan.json を取り出す。Web UI で編集されると改行が CRLF になる
plan_from_comment() {
  jq -r '.body' <<<"$1" | awk '
    { sub(/\r$/, "") }
    /^```json$/ { inblock = 1; next }
    /^```$/ && inblock { exit }
    inblock { print }'
}

is_approve_instruction() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  [[ $s == "$TRIGGER_COMMAND $APPROVE_WORD" ]]
}

# 承認コメントを含むタスクなら、そのコメント ID を返す
is_approve_task() {
  local task="$1" n i instruction
  [[ $(jq -r '.kind' <<<"$task") == comment ]] || return 1
  n=$(jq '(.comments // []) | length' <<<"$task")
  for (( i = 0; i < n; i++ )); do
    instruction=$(jq -r ".comments[$i].instruction" <<<"$task")
    if is_approve_instruction "$instruction"; then
      jq -r ".comments[$i].id" <<<"$task"
      return 0
    fi
  done
  return 1
}

# 使い方: approve_plan_task <タスク JSON>
# 承認コメントのタスクでなければ 1 を返し、呼び出し元がエージェントに渡す
approve_plan_task() {
  local task="$1" number n i id approve_id
  approve_id=$(is_approve_task "$task") || return 1
  n=$(jq '(.comments // []) | length' <<<"$task")
  number=$(jq -r '.number' <<<"$task")
  set_reply_target "$number" "$task"

  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".comments[$i].id" <<<"$task")
    [[ $id == "$approve_id" ]] && continue
    post_report "分解案の承認と同じ回に届いたため、この指示は処理していません。sub issue の作成後に改めて投稿してください。" \
      "$(jq -r ".comments[$i].reply_kind" <<<"$task")" "$(jq -r ".comments[$i].reply_number" <<<"$task")" "$id"
  done

  local comment plan created
  if ! comment=$(latest_plan_comment "$number"); then
    warn "#$number に承認待ちの分解案がありません"
    post_report "承認待ちの分解案がありません。分解が必要なら \`$LABEL_QUEUED\` を付け直してください。"
    return 0
  fi

  plan=$(mktemp)
  plan_from_comment "$comment" > "$plan"
  if ! validate_plan "$plan"; then
    err "#$number の分解案を解釈できません"
    set_labels "$number" "$LABEL_FAILED"
    post_report "分解案の plan.json を解釈できませんでした。コメントを編集した場合は JSON として正しいか確認してください。"
    rm -f "$plan"
    return 0
  fi

  log "#$number の分解案を承認: sub issue を作成します ($(jq '.sub_issues | length' "$plan") 件)"
  created=$(create_sub_issues "$number" "$plan")
  rm -f "$plan"
  if [[ -z $created ]]; then
    err "#$number の sub issue を 1 件も作成できませんでした"
    set_labels "$number" "$LABEL_FAILED"
    post_report "分解案は承認されましたが、sub issue の作成に失敗しました。"
    return 0
  fi

  # 同じ案を二度承認して sub issue を重複させないよう、案のマーカーを書き換える
  gh api -X PATCH "repos/$REPO/issues/comments/$(jq -r '.id' <<<"$comment")" \
    -f "body=$(jq -r '.body' <<<"$comment" | sed "s|$PLAN_MARKER|$PLAN_APPROVED_MARKER|")" >/dev/null 2>&1 \
    || warn "#$number の分解案コメントを承認済みに更新できませんでした"

  set_labels "$number" "$LABEL_DONE"
  post_report "$(
    printf '**分解案を承認しました。作成した sub issue**:\n%s\n\n' "$created"
    printf 'それぞれに `%s` が付いています。次回のポーリングから順に実装され、すべて閉じたらこの Issue も自動で閉じます。\n' "$LABEL_QUEUED"
  )"
  log "#$number 分解完了: $(wc -l <<<"$created") 件の sub issue を作成しました"
  return 0
}

# sub issue の PR は sub issue しか閉じないため、親はここで閉じる。
# subIssuesSummary.completed は not planned の扱いが文書化されていないので state で数える
COMPLETED_PARENTS_QUERY='
  query($owner:String!, $name:String!, $label:String!) {
    repository(owner:$owner, name:$name) {
      issues(first:50, states:OPEN, labels:[$label]) {
        nodes { number title subIssues(first:100) { nodes { number state } } }
      }
    }
  }'

close_completed_parents() {
  local rows row number title subs
  rows=$(gh api graphql -f "owner=${REPO%%/*}" -f "name=${REPO#*/}" -f "label=$LABEL_DONE"       -f "query=$COMPLETED_PARENTS_QUERY" 2>/dev/null     | jq -c '.data.repository.issues.nodes[]?
        | select((.subIssues.nodes | length) > 0 and all(.subIssues.nodes[]; .state == "CLOSED"))
        | {number, title, subs: [.subIssues.nodes[].number]}')
  [[ -n $rows ]] || return 0

  while IFS= read -r row; do
    number=$(jq -r '.number' <<<"$row")
    title=$(jq -r '.title' <<<"$row")
    subs=$(jq -r '.subs | map("#\(.)") | join(", ")' <<<"$row")
    if (( ${DRY_RUN:-0} )); then
      log "sub issue ($subs) がすべて閉じているため閉じます（dry-run）: #$number $title"
      continue
    fi
    if post_comment "$number" "sub issue ($subs) がすべて閉じたので、この Issue を閉じます。"       && gh issue close "$number" -R "$REPO" --reason completed >/dev/null 2>&1
    then
      log "sub issue ($subs) がすべて閉じたため閉じました: #$number $title"
    else
      warn "#$number を閉じられませんでした"
    fi
  done <<<"$rows"
}
