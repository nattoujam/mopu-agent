#!/usr/bin/env bash

LEARN_KNOWN_MAX_CHARS=20000
LEARN_MAX_ISSUES=3
LEARN_ACTIONS_MAX_BYTES=200000
LEARN_ISSUE_URLS=""

learn_issues_file() { printf '%s/learn-issues.txt' "$REPO_STATE_DIR"; }

# PR の head は、マージ後にブランチが消されても refs/pull/<n>/head に残る。refs/remotes の
# 下に置くと ensure_repo の fetch --prune に消されるので、別の名前空間に取る
fetch_pr_head() {
  git -C "$REPO_DIR" fetch --quiet origin "+refs/pull/$1/head:refs/mopu/pr/$1"
}

learn_tasks() {
  [[ ${LEARN_ENABLED:-false} == true ]] || return 0
  ensure_repo
  discover learn-source
}

mark_learned() {
  jq -r --arg s "$2" '.prs[] | "\(.number)\t\($s)"' <<<"$1" >> "$LEARNED_FILE"
}

summarize_actions() {
  jq -r '
    def clip($n): if length > $n then .[:$n] + "…" else . end;
    if .type == "system" and .subtype == "init" then "--- エージェントの呼び出し ---"
    elif .type == "assistant" then
      .message.content[]?
      | if .type == "text" then "[発言] " + (.text | clip(2000))
        elif .type == "thinking" and (.thinking // "") != "" then "[思考] " + (.thinking | clip(2000))
        elif .type == "tool_use" then
          "[\(.name)] " + (.input | (.command // .file_path // .pattern // .url // .query // tojson) | tostring | clip(300))
        else empty end
    elif .type == "user" then
      .message.content[]?
      | select(type == "object" and .type == "tool_result" and .is_error == true)
      | "[エラー] " + (.content | if type == "string" then . else map(.text? // "") | join("") end | clip(300))
    else empty end' "$1" 2>/dev/null
}

write_action_logs() {
  local pr="$1" out_dir="$2" issue merged_stamp dir name
  issue=$(jq -r '.issue' <<<"$pr")
  merged_stamp=$(date -d "$(jq -r '.merged_at' <<<"$pr")" +%Y%m%d-%H%M%S) || return 1
  mkdir -p "$out_dir"
  while IFS= read -r dir; do
    name=${dir##*/}
    [[ ${name: -15} > $merged_stamp ]] && continue
    [[ -s $dir/stream.jsonl ]] || continue
    summarize_actions "$dir/stream.jsonl" | head -c "$LEARN_ACTIONS_MAX_BYTES" > "$out_dir/$name.md"
    printf '%s\n' "$out_dir/$name.md"
  done < <(find "$TASK_LOGS_DIR" -mindepth 1 -maxdepth 1 -type d \( -name "issue-$issue-*" -o -name "comment-$issue-*" \) 2>/dev/null \
             | sed -E 's/.*-([0-9]{8}-[0-9]{6})$/\1 &/' | sort | cut -d' ' -f2-)
}

build_learn_prompt() {
  local t="$1" actions_dir="$2" n i j pr count
  local -a logs
  n=$(jq '.prs | length' <<<"$t")
  {
    echo "# タスク"
    echo
    echo "差し戻しのあった次の $n 件の PR がマージされた。これらのタスクでのエージェントの行動を振り返り、対象リポジトリの指示の変更案を出すこと。"
    for (( j = 0; j < n; j++ )); do
      pr=$(jq -c --argjson j "$j" '.prs[$j]' <<<"$t")
      echo
      jq -r '"## PR #\(.number)「\(.title)」（\(.url)）"' <<<"$pr"
      echo
      jq -r '"### 元の Issue #\(.issue)「\(.issue_title)」"' <<<"$pr"
      echo
      echo '```'
      jq -r '.issue_body | if . == "" then "(本文なし)" else . end' <<<"$pr"
      echo '```'
      echo
      echo "### PR の本文"
      echo
      echo '```'
      jq -r '.body | if . == "" then "(本文なし)" else . end' <<<"$pr"
      echo '```'
      echo
      echo "### 差し戻しのコメント（古い順）"
      count=$(jq '.comments | length' <<<"$pr")
      for (( i = 0; i < count; i++ )); do
        echo
        jq -r --argjson i "$i" '.comments[$i] | "#### \(.created_at) \(.actor)\(if .path then "（\(.path) への行コメント）" else "" end)\n\n\(.url)"' <<<"$pr"
        echo
        echo '```'
        jq -r --argjson i "$i" '.comments[$i].instruction' <<<"$pr"
        echo '```'
      done
      (( count )) || { echo; echo "（コメントを取得できなかった。コミットの前後から読み取ること）"; }
      echo
      echo "### PR のコミット"
      echo
      jq -r '"`git log --reverse --format=fuller -p \(.merge_commit)^1..refs/mopu/pr/\(.number)` で、この PR のコミットを古い順に読める。コミットの日時を上のコメントの日時と突き合わせると、差し戻しの前後で何が変わったかが分かる。"' <<<"$pr"
      echo
      echo "### エージェントの行動ログ（古い順）"
      echo
      mapfile -t logs < <(write_action_logs "$pr" "$actions_dir/$(jq -r '.number' <<<"$pr")")
      if (( ${#logs[@]} )); then
        printf -- '- %s\n' "${logs[@]}"
      else
        echo "（残っていない。コミットの順から推すこと）"
      fi
    done
  } | head -c 60000
}

build_known_issues_context() {
  local file numbers
  file=$(learn_issues_file)
  [[ -s $file ]] || return 0
  numbers=$(cut -f1 "$file" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
  gh issue list -R "$REPO" --state all --limit 500 --json number,title,body,state,stateReason 2>/dev/null \
    | jq -r --argjson ns "$numbers" '
        map(select(.number as $n | $ns | index($n)))
        | sort_by(.number) | reverse
        | if length == 0 then empty else
            "### これまでに出した案（新しい順）\n"
            + (map("\n#### #\(.number)「\(.title)」（\(if .state == "OPEN" then "対応待ち" elif .stateReason == "COMPLETED" then "採用" else "却下" end)）\n\n"
                   + (.body | split("\n\n---\n")[0] | split("<details>")[0] | .[:1500]))
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
# フェーズの Stop hook を外す
learn_agent_settings() {
  local task_dir="$1" out="$2" actions_dir="$3"
  build_agent_settings "$task_dir" "$out.base" || return 1
  jq --arg mopu "$MOPU_BIN" --arg actions "$actions_dir" \
    '.permissions.allow |= (map(select((startswith("Edit(") or contains($mopu)) | not))
                            + ["Read(\($actions | sub("^/"; "//"))/**)"])
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

# run_learn_task_body の local の t / task_id / title / cost / pct_before / task_dir を読むため、その中からしか呼べない
learn_failed() {
  err "[$task_id] $1"
  record_outcome false "$1"
  notify "❌ **失敗** $(issue_ref "$REPO") $title"$'\n'"\`$task_id\`"$'\n'"$(md_quote "$1")"
  mark_learned "$t" failed
  record_spend "$task_id" "${cost:-0}" "$pct_before" "" failed
  [[ -d $task_dir ]] && log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
  return 1
}

record_outcome() {
  [[ -n $TASK_OUTCOME_FILE ]] || return 0
  jq -nc --argjson ok "$1" --arg reason "${2:-}" \
    '{ok: $ok} + (if $reason == "" then {} else {reason: $reason} end)' > "$TASK_OUTCOME_FILE"
}

# 使い方: run_learn_task（CURRENT_TASK_JSON に learn のタスク）
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
  local t="$CURRENT_TASK_JSON" number title task_id task_dir wt log_dir actions_dir pr_numbers n
  number=$(jq -r '.number' <<<"$t")
  title=$(jq -r '.title' <<<"$t")
  pr_numbers=$(jq -r '.prs[].number' <<<"$t")
  task_id="learn-${number}-$(date +%Y%m%d-%H%M%S)"
  task_dir="$WORKTREES_DIR/$task_id"
  wt=$(workspace_repo "$task_dir")
  actions_dir="$task_dir/actions"
  log_dir="$TASK_LOGS_DIR/$task_id"
  mkdir -p "$log_dir"
  TASK_OUTCOME_FILE="$log_dir/outcome.json"
  jq -c --arg c "$AGENT_COMMIT" '. + {commit: $c}' <<<"$t" > "$log_dir/$TASK_FILE_NAME"
  LEARN_ISSUE_URLS=""

  local pct_before="$USAGE_5H" cost=0
  [[ -z $pct_before ]] && parse_usage "$(fetch_usage)" && pct_before="$USAGE_5H"

  log "[$task_id] 開始: $title"

  for n in $pr_numbers; do
    if ! fetch_pr_head "$n"; then
      learn_failed "PR #$n の head を取得できませんでした"
      return 1
    fi
  done
  # 案は、マージ後に積まれた変更も含めた今のベースブランチに合わせて書かせる
  if ! { mkdir -p "$task_dir" && git -C "$REPO_DIR" worktree add --quiet --detach "$wt" "origin/$BASE_BRANCH"; }; then
    learn_failed "worktree の準備に失敗しました"
    return 1
  fi

  local sys_prompt known
  sys_prompt=$(cat "$AGENT_DIR/prompts/learn.md")
  known=$(build_known_issues_context)
  [[ -n $known ]] && sys_prompt+=$'\n\n'"$known"
  sys_prompt+=$'\n\n'"$(cat "$AGENT_DIR/prompts/read-only.md")"

  local memory
  memory=$(project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH")
  if [[ -n $memory ]]; then
    sys_prompt+=$'\n\n'"$memory"
    printf '%s\n' "$memory" > "$log_dir/project-memory.md"
  fi

  local prompt
  prompt=$(build_learn_prompt "$t" "$actions_dir")

  local settings="$log_dir/settings.json"
  learn_agent_settings "$task_dir" "$settings" "$actions_dir" || { learn_failed "エージェントの設定を作れませんでした"; return 1; }

  local rc=0
  # shellcheck disable=SC2034  # invoke_agent が読む
  AGENT_GH_TOKEN=""
  AGENT_JSON_SCHEMA=$(learn_schema)
  invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "" \
    "$(duration_seconds "$TASK_TIMEOUT")" "$MAX_TASK_BUDGET_USD" || rc=$?
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
    mark_learned "$t" no-change
    record_spend "$task_id" "$cost" "$pct_before" "" no-change
    remove_workspace "$task_dir"
    return 0
  fi

  local footer
  footer=$(jq -r '"\(.prs | map("#\(.number)") | join("・")) の差し戻しを振り返って、mopu-agent が出した案です。"' <<<"$t")
  if ! publish_learn_issues "$issues" "$footer" "$(paste -sd, <<<"$pr_numbers")"; then
    learn_failed "Issue を作れませんでした${LEARN_ISSUE_URLS:+（作れたもの: $LEARN_ISSUE_URLS）}"
    return 1
  fi

  mark_learned "$t" issue
  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after" issue
  remove_workspace "$task_dir"
  log "[$task_id] 完了: $LEARN_ISSUE_URLS (推定 \$$(printf '%.2f' "$cost"), 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
  notify "📚 **学習の案** $(issue_ref "$REPO") $title"$'\n'"- ${LEARN_ISSUE_URLS// /$'\n'- }"
  return 0
}
