#!/usr/bin/env bash
# 差し戻しのあった PR がマージされたら、そこから次に守る基準の案を作らせ、対象リポジトリに Issue として出す。
# 基準を置く .claude/rules/ は Claude Code の保護パスで、エージェントの権限では書けないため、置くのは人間に任せる

# lib/project-memory.sh の上限（PROJECT_MEMORY_MAX_CHARS）の半分。上限に届くと載らない指示が出るため、その手前で棚卸しする
LEARN_TIDY_CHARS="${LEARN_TIDY_CHARS:-30000}"
LEARN_KNOWN_MAX_CHARS=20000
LEARN_MAX_ISSUES=3
LEARN_ISSUE_URLS=""

learn_issues_file() { printf '%s/learn-issues.txt' "$REPO_STATE_DIR"; }
learn_tidy_file() { printf '%s/learn-tidy' "$REPO_STATE_DIR"; }

# PR の head は、マージ後にブランチが消されても refs/pull/<n>/head に残る。refs/remotes の
# 下に置くと ensure_repo の fetch --prune に消されるので、別の名前空間に取る
fetch_pr_head() {
  git -C "$REPO_DIR" fetch --quiet origin "+refs/pull/$1/head:refs/mopu/pr/$1"
}

learn_memory_hash() {
  project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH" | sha1sum | cut -d' ' -f1
}

# 指示が閾値を超えていて、前回の棚卸しから中身が変わっていれば棚卸しする。棚卸しの Issue が
# 閉じられたときに、同じ中身のまま出し直さないため
tidy_task() {
  local chars
  chars=$(project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH" | wc -m)
  (( chars > LEARN_TIDY_CHARS )) || return 0
  [[ $(learn_memory_hash) != "$(cat "$(learn_tidy_file)" 2>/dev/null)" ]] || return 0
  jq -nc --argjson c "$chars" '{kind: "tidy", number: 0, title: "判断の基準の棚卸し", body: "", actor: "", chars: $c}'
}

learn_tasks() {
  [[ ${LEARN_ENABLED:-false} == true ]] || return 0
  ensure_repo
  local t
  t=$(discover learn-source)
  if [[ -n $t ]]; then
    printf '%s\n' "$t"
    return 0
  fi
  tidy_task
}

mark_learned() {
  printf '%s\t%s\n' "$1" "$2" >> "$LEARNED_FILE"
}

build_learn_prompt() {
  local t="$1" n i
  {
    echo "# タスク"
    echo
    jq -r '"マージされた PR #\(.number)「\(.title)」（\(.url)）では、エージェントが出した変更に人間が差し戻しを付けた。差し戻しから、次から守る判断の基準の案を出すこと。"' <<<"$t"
    echo
    jq -r '"## 元の Issue #\(.issue)「\(.issue_title)」"' <<<"$t"
    echo
    echo '```'
    jq -r '.issue_body | if . == "" then "(本文なし)" else . end' <<<"$t"
    echo '```'
    echo
    echo "## PR の本文"
    echo
    echo '```'
    jq -r '.body | if . == "" then "(本文なし)" else . end' <<<"$t"
    echo '```'
    echo
    echo "## 差し戻しのコメント（古い順）"
    n=$(jq '.comments | length' <<<"$t")
    for (( i = 0; i < n; i++ )); do
      echo
      jq -r --argjson i "$i" '.comments[$i] | "### \(.created_at) \(.actor)\(if .path then "（\(.path) への行コメント）" else "" end)\n\n\(.url)"' <<<"$t"
      echo
      echo '```'
      jq -r --argjson i "$i" '.comments[$i].instruction' <<<"$t"
      echo '```'
    done
    (( n )) || { echo; echo "（コメントを取得できなかった。コミットの前後から読み取ること）"; }
    echo
    echo "## PR のコミット"
    echo
    jq -r '"`git log --reverse --format=fuller -p \(.merge_commit)^1..refs/mopu/pr/\(.number)` で、この PR のコミットを古い順に読める。コミットの日時を上のコメントの日時と突き合わせると、差し戻しの前後で何が変わったかが分かる。"' <<<"$t"
  } | head -c 60000
}

# 対応済み（completed）で閉じた案は、基準として対象リポジトリの指示に入っているので載せない
build_known_issues_context() {
  local file numbers
  file=$(learn_issues_file)
  [[ -s $file ]] || return 0
  numbers=$(cut -f1 "$file" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
  gh issue list -R "$REPO" --state all --limit 500 --json number,title,body,state,stateReason 2>/dev/null \
    | jq -r --argjson ns "$numbers" '
        map(select(.number as $n | $ns | index($n)) | select(.state == "OPEN" or .stateReason != "COMPLETED"))
        | sort_by(.number) | reverse
        | if length == 0 then empty else
            "### 既に出した案\n\n次の案は、Issue として人間の対応を待っているか、人間が採らないと決めて閉じた。同じ趣旨の案は出さないこと。\n"
            + (map((.body | rindex("\n\n---\n")) as $i
                   | "\n#### #\(.number)「\(.title)」（\(if .state == "OPEN" then "対応待ち" else "却下" end)）\n\n\(if $i then .body[:$i] else .body end | .[:2000])")
               | join("\n"))
          end' \
    | head -c "$LEARN_KNOWN_MAX_CHARS"
}

learn_schema() {
  jq -nc --argjson max "$LEARN_MAX_ISSUES" '{
    type: "object",
    properties: {
      issues: {type: "array", maxItems: $max, items: {
        type: "object",
        properties: {title: {type: "string"}, body: {type: "string"}},
        required: ["title", "body"], additionalProperties: false}},
      skipped: {type: "array", items: {
        type: "object",
        properties: {url: {type: "string"}, reason: {type: "string"}},
        required: ["url", "reason"], additionalProperties: false}}
    },
    required: ["issues"], additionalProperties: false}'
}

# 学習のエージェントには読むことしかさせない。書き込みの許可、ホスト側のコマンド、
# push を前提にした CI の Stop hook を外す
learn_agent_settings() {
  local task_dir="$1" out="$2"
  build_agent_settings "$task_dir" "$out.base" || return 1
  jq --arg tools "$AGENT_DIR/tools" \
    '.permissions.allow |= map(select((startswith("Edit(") or contains($tools)) | not))
     | .sandbox.excludedCommands = []
     | .sandbox.filesystem.allowWrite = []
     | del(.hooks.Stop)' "$out.base" > "$out" || return 1
  rm -f "$out.base"
}

# 作った Issue は、作った時点で控える。途中で失敗してやり直したときに、作り済みの案を
# 既に出した案としてプロンプトに載せ、同じ Issue を二重に作らせないため
publish_learn_issues() {
  local issues="$1" footer="$2" source="$3" n i title body out url
  n=$(jq '.issues | length' <<<"$issues")
  for (( i = 0; i < n; i++ )); do
    title=$(jq -r --argjson i "$i" '.issues[$i].title' <<<"$issues")
    body=$(jq -r --argjson i "$i" '.issues[$i].body' <<<"$issues")
    out=$(gh issue create -R "$REPO" --title "$title" --body "$body"$'\n\n---\n'"$footer"$'\n'"$COMMENT_MARKER") || return 1
    url=$(grep -oE 'https://[^ ]+/issues/[0-9]+' <<<"$out" | tail -1)
    printf '%s\t%s\n' "${url##*/}" "$source" >> "$(learn_issues_file)"
    LEARN_ISSUE_URLS+="${LEARN_ISSUE_URLS:+ }$url"
  done
}

# run_learn_task_body の local の task_id / kind / number / title / cost / pct_before / task_dir を読むため、その中からしか呼べない。
# 学習の失敗は数え、上限まで次のポーリングでやり直す。棚卸しは指示の中身が変わるまで出し直さない
learn_failed() {
  fail_task "$task_id" "$1"
  notify "❌ **失敗** $(issue_ref "$REPO") $title"$'\n'"\`$task_id\`"$'\n'"$(md_quote "$1")"
  [[ $kind == learn ]] && mark_learned "$number" failed
  [[ $kind == tidy ]] && learn_memory_hash > "$(learn_tidy_file)"
  record_spend "$task_id" "${cost:-0}" "$pct_before" "" failed
  [[ -d $task_dir ]] && log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
  return 1
}

# 使い方: run_learn_task（CURRENT_TASK_JSON に learn / tidy のタスク）
run_learn_task() {
  local rc=0
  TASK_OUTCOME_FILE=""
  run_learn_task_body || rc=$?
  if [[ -n $TASK_OUTCOME_FILE && ! -f $TASK_OUTCOME_FILE ]]; then
    if (( rc == 0 )); then record_outcome true; else record_outcome false "終了コード $rc で中断しました"; fi
  fi
  TASK_OUTCOME_FILE=""
  return "$rc"
}

run_learn_task_body() {
  local t="$CURRENT_TASK_JSON" kind number title task_id task_dir wt log_dir
  kind=$(jq -r '.kind' <<<"$t")
  number=$(jq -r '.number' <<<"$t")
  title=$(jq -r '.title' <<<"$t")
  task_id="${kind}-${number}-$(date +%Y%m%d-%H%M%S)"
  task_dir="$WORKTREES_DIR/$task_id"
  wt=$(workspace_repo "$task_dir")
  log_dir="$TASK_LOGS_DIR/$task_id"
  mkdir -p "$log_dir"
  TASK_OUTCOME_FILE="$log_dir/outcome.json"
  jq -c --arg c "$AGENT_COMMIT" '. + {commit: $c}' <<<"$t" > "$log_dir/$TASK_FILE_NAME"
  LEARN_ISSUE_URLS=""

  local pct_before="$USAGE_5H" cost=0
  [[ -z $pct_before ]] && parse_usage "$(fetch_usage)" && pct_before="$USAGE_5H"

  log "[$task_id] 開始: ${title}$([[ $kind == learn ]] && printf '（#%s）' "$number")"

  if [[ $kind == learn ]] && ! fetch_pr_head "$number"; then
    learn_failed "PR #$number の head を取得できませんでした"
    return 1
  fi
  # 案は、マージ後に積まれた変更も含めた今のベースブランチに合わせて書かせる
  if ! { mkdir -p "$task_dir" && git -C "$REPO_DIR" worktree add --quiet --detach "$wt" "origin/$BASE_BRANCH"; }; then
    learn_failed "worktree の準備に失敗しました"
    return 1
  fi

  local sys_prompt
  if [[ $kind == learn ]]; then
    sys_prompt=$(cat "$AGENT_DIR/prompts/learn.md")
    local known
    known=$(build_known_issues_context)
    [[ -n $known ]] && sys_prompt+=$'\n\n'"$known"
  else
    sys_prompt=$(sed -e "s/%%CHARS%%/$LEARN_TIDY_CHARS/g" "$AGENT_DIR/prompts/tidy.md")
  fi
  sys_prompt+=$'\n\n'"$(cat "$AGENT_DIR/prompts/read-only.md")"

  local memory
  memory=$(project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH")
  if [[ -n $memory ]]; then
    sys_prompt+=$'\n\n'"$memory"
    printf '%s\n' "$memory" > "$log_dir/project-memory.md"
  fi

  local prompt
  if [[ $kind == learn ]]; then
    prompt=$(build_learn_prompt "$t")
  else
    prompt="# タスク"$'\n\n'"対象リポジトリの指示が $(jq -r '.chars' <<<"$t") 文字になった。\`.claude/rules/\` の棚卸しの案を出すこと。"
  fi

  local settings="$log_dir/settings.json"
  learn_agent_settings "$task_dir" "$settings" || { learn_failed "エージェントの設定を作れませんでした"; return 1; }

  local rc=0
  # shellcheck disable=SC2034  # invoke_agent が読む
  AGENT_GH_TOKEN=""
  AGENT_JSON_SCHEMA=$(learn_schema)
  invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "" "" || rc=$?
  # shellcheck disable=SC2034  # invoke_agent が読む
  AGENT_JSON_SCHEMA=""

  local is_error rl_status issues
  is_error=$(jq -r 'select(.type=="result") | .is_error' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  cost=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  rl_status=$(jq -r 'select(.type=="rate_limit_event") | .rate_limit_info.status' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  if [[ $rl_status == allowed_warning || $rl_status == rejected ]]; then
    warn "[$task_id] レート上限イベント: $rl_status"
    # shellcheck disable=SC2034  # poll.sh のループが参照
    RATE_LIMIT_HIT=1
  fi

  if (( rc != 0 )) || [[ $is_error == true ]]; then
    learn_failed "エージェントの実行に失敗しました (exit=$rc, is_error=$is_error)"
    return 1
  fi
  issues=$(jq -c 'select(.type=="result") | .structured_output // empty' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  if [[ -z $issues ]] || ! jq -e '.issues | type == "array"' <<<"$issues" >/dev/null 2>&1; then
    learn_failed "エージェントが案を構造化出力で返しませんでした"
    return 1
  fi

  # 案にしなかった判断は Issue が無いと GitHub に残らないので、ログにも出す
  local skipped
  skipped=$(jq -r '(.skipped // [])[] | "- \(.url): \(.reason)"' <<<"$issues")
  if [[ -n $skipped ]]; then
    printf '%s\n' "$skipped" > "$log_dir/skipped.md"
    log "[$task_id] 案にしなかった差し戻し:"$'\n'"$skipped"
    issues=$(jq -c 'if (.issues | length) > 0
      then .issues[-1].body += "\n\n<details>\n<summary>案にしなかった差し戻し</summary>\n\n" + (.skipped | map("- \(.url): \(.reason)") | join("\n")) + "\n\n</details>"
      else . end' <<<"$issues")
  fi

  if (( $(jq '.issues | length' <<<"$issues") == 0 )); then
    log "[$task_id] 案にするものはありませんでした"
    [[ $kind == learn ]] && mark_learned "$number" no-change
    [[ $kind == tidy ]] && learn_memory_hash > "$(learn_tidy_file)"
    record_spend "$task_id" "$cost" "$pct_before" "" no-change
    remove_workspace "$task_dir"
    return 0
  fi

  local footer source
  if [[ $kind == learn ]]; then
    footer=$(jq -r '"#\(.number)（\(.url)）の差し戻しから、mopu-agent が出した案です。"' <<<"$t")
    source="$number"
  else
    footer="対象リポジトリの指示の棚卸しとして、mopu-agent が出した案です。"
    source=tidy
  fi
  if ! publish_learn_issues "$issues" "$footer" "$source"; then
    learn_failed "Issue を作れませんでした${LEARN_ISSUE_URLS:+（作れたもの: $LEARN_ISSUE_URLS）}"
    return 1
  fi

  [[ $kind == learn ]] && mark_learned "$number" issue
  [[ $kind == tidy ]] && learn_memory_hash > "$(learn_tidy_file)"
  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after" issue
  remove_workspace "$task_dir"
  log "[$task_id] 完了: $LEARN_ISSUE_URLS (推定 \$$(printf '%.2f' "$cost"), 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
  notify "📚 **学習の案** $(issue_ref "$REPO") $title"$'\n'"- ${LEARN_ISSUE_URLS// /$'\n'- }"
  return 0
}
