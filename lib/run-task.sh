#!/usr/bin/env bash


post_comment() {
  local issue="$1" body="$2"
  printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body" \
    | gh issue comment "$issue" -R "$REPO" --body-file - >/dev/null
}

# 付いていないラベルの削除は gh がエラーにするため、追加と削除を分けて実行する
set_labels() {
  local issue="$1" add="$2" l
  if ! gh issue edit "$issue" -R "$REPO" --add-label "$add" >/dev/null 2>&1; then
    warn "ラベル '$add' を付けられませんでした（setup.sh でラベルを作成してください）。既存のラベルは変更しません"
    return 0
  fi
  for l in "$LABEL_QUEUED" "$LABEL_RUNNING" "$LABEL_DONE" "$LABEL_FAILED"; do
    [[ $l == "$add" ]] && continue
    gh issue edit "$issue" -R "$REPO" --remove-label "$l" >/dev/null 2>&1 || true
  done
}

build_prompt() {
  local kind="$1" number="$2" title="$3" body="$4" comment="$5"
  {
    echo "# タスク"
    echo
    if [[ $kind == comment ]]; then
      echo "GitHub の #$number に次のコメントが投稿されました。この指示に対応してください。"
      echo
      echo '```'
      printf '%s\n' "$comment"
      echo '```'
      echo
      echo "## 背景: #$number「$title」の本文"
    else
      echo "GitHub Issue #$number「$title」に対応してください。"
      echo
      echo "## Issue 本文"
    fi
    echo
    echo '```'
    printf '%s\n' "${body:-(本文なし)}"
    echo '```'
  } | head -c 60000
}

# 使い方: run_task <kind:issue|comment> <issue番号> <タイトル> <本文> <コメント本文>
run_task() {
  local kind="$1" number="$2" title="$3" body="$4" comment="${5:-}"
  local task_id
  task_id="${kind}-${number}-$(date +%Y%m%d-%H%M%S)"
  local branch="agent/issue-$number"
  local wt="$AGENT_DIR/worktrees/$task_id"
  local log_dir="$AGENT_DIR/logs/$task_id"
  mkdir -p "$log_dir"

  # --ignore-budget ではゲートを通らず USAGE_5H が空になるため取り直す
  local pct_before="$USAGE_5H"
  [[ -z $pct_before ]] && parse_usage "$(fetch_usage)" && pct_before="$USAGE_5H"

  log "[$task_id] 開始: #$number $title"
  set_labels "$number" "$LABEL_RUNNING"

  if ! create_worktree "$branch" "$wt"; then
    err "[$task_id] worktree の作成に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_comment "$number" "エージェントの作業ツリー作成に失敗しました。ブランチ \`$branch\` が使用中でないか確認してください。"
    return 1
  fi

  local sys_prompt
  sys_prompt=$(cat "$AGENT_DIR/prompts/issue.md")
  [[ $kind == comment ]] && sys_prompt+=$'\n\n'$(cat "$AGENT_DIR/prompts/command.md")

  local prompt
  prompt=$(build_prompt "$kind" "$number" "$title" "$body" "$comment")

  # Read/Edit/Write のパス制限は worktree の絶対パスでしか正しく効かないため、
  # 実行のたびに設定を生成する（"//" が絶対パスのプレフィックス）
  local settings="$log_dir/settings.json" extra_json='[]'
  # 権限ルールは "Bash(npm test:*)" のように空白を含むため配列で受け取る
  (( ${#EXTRA_ALLOWED_TOOLS[@]} )) && \
    extra_json=$(printf '%s\n' "${EXTRA_ALLOWED_TOOLS[@]}" | jq -R . | jq -sc .)
  jq --arg wt "$wt" --argjson extra "$extra_json" \
    '.permissions.allow = (
        ["Read(//\($wt)/**)", "Edit(//\($wt)/**)", "Write(//\($wt)/**)"]
        + $extra + .permissions.allow)' \
    "$AGENT_DIR/settings/agent-settings.json" > "$settings" || return 1

  # 既存ブランチを引き継いだ場合、既にあるコミットを「今回の成果」と誤認しないよう
  # 実行前の HEAD を控えておく
  local head_before
  head_before=$(git -C "$wt" rev-parse HEAD)

  local rc=0
  (
    cd "$wt" || exit 1
    # SUBPROCESS_ENV_SCRUB は子プロセスから Anthropic/クラウドの認証情報を剥がす。
    # これを設定すると permission mode は default に強制されるため、権限は
    # settings の allow / deny ルールだけで決まる（--permission-mode は効かない）
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
    timeout "$TASK_TIMEOUT" claude -p "$prompt" \
      --settings "$settings" \
      --setting-sources '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --append-system-prompt "$sys_prompt" \
      --output-format stream-json --verbose \
      --model "$MODEL" \
      --max-budget-usd "$MAX_TASK_BUDGET_USD"
  ) > "$log_dir/stream.jsonl" 2> "$log_dir/stderr.log" || rc=$?

  local result is_error cost
  result=$(jq -r 'select(.type=="result") | .result // empty' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  is_error=$(jq -r 'select(.type=="result") | .is_error' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  cost=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)

  # 枠の非常ブレーキ。allowed_warning / rejected を検知したら呼び出し元に伝える
  local rl_status
  rl_status=$(jq -r 'select(.type=="rate_limit_event") | .rate_limit_info.status' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  if [[ $rl_status == allowed_warning || $rl_status == rejected ]]; then
    warn "[$task_id] レート上限イベント: $rl_status"
    # shellcheck disable=SC2034  # poll.sh のループが参照
    RATE_LIMIT_HIT=1
  fi

  if (( rc != 0 )) || [[ $is_error == true ]]; then
    err "[$task_id] 失敗 (exit=$rc, is_error=$is_error)"
    local detail
    detail=$(tail -20 "$log_dir/stderr.log")
    set_labels "$number" "$LABEL_FAILED"
    post_comment "$number" "$(printf 'エージェントの実行に失敗しました (exit=%s)。\n\n%s\n\n```\n%s\n```\n\nログ: `%s`' \
      "$rc" "${result:-}" "${detail:-（stderr なし）}" "$log_dir")"
    record_spend "$task_id" "$cost" "$pct_before" ""
    log "[$task_id] worktree を調査用に残します: $wt"
    return 1
  fi

  if [[ $(git -C "$wt" rev-parse HEAD) == "$head_before" ]]; then
    if [[ -n $(git -C "$wt" status --porcelain) ]]; then
      err "[$task_id] コミットされていない変更が残っています"
      set_labels "$number" "$LABEL_FAILED"
      post_comment "$number" "$(printf '%s\n\nコミットに失敗した可能性があります。作業ツリーに未コミットの変更が残っているため保全しました。\n\nworktree: `%s`' \
        "${result:-（応答なし）}" "$wt")"
      record_spend "$task_id" "$cost" "$pct_before" ""
      log "[$task_id] worktree を調査用に残します: $wt"
      return 1
    fi

    log "[$task_id] コード変更なし。結果のみコメントします"
    set_labels "$number" "$LABEL_DONE"
    post_comment "$number" "${result:-（応答なし）}"
    record_spend "$task_id" "$cost" "$pct_before" ""
    remove_worktree "$wt"
    return 0
  fi

  log "[$task_id] push します: $branch"
  local -a push_env=()
  use_github_app && push_env=(env "GIT_ASKPASS=$(app_git_askpass)" "GH_TOKEN=$GH_TOKEN")
  if ! "${push_env[@]}" git -C "$wt" push --quiet -u origin "$branch" --force-with-lease; then
    err "[$task_id] push に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_comment "$number" "作業は完了しましたが push に失敗しました。worktree: \`$wt\`"
    record_spend "$task_id" "$cost" "$pct_before" ""
    return 1
  fi

  # 既存 PR があれば作り直さず、追加コミットをそのまま反映させる
  local pr_url pr_out
  pr_url=$(gh pr view "$branch" -R "$REPO" --json url --jq .url 2>/dev/null)
  if [[ -z $pr_url ]]; then
    if pr_out=$(gh pr create -R "$REPO" --draft \
      --base "$BASE_BRANCH" --head "$branch" \
      --title "$title" \
      --body "$(printf 'Closes #%s\n\n%s\n\n---\n%s' "$number" "$result" "$COMMENT_MARKER")" 2>&1)
    then
      pr_url=$(grep -oE 'https://[^ ]+/pull/[0-9]+' <<<"$pr_out" | tail -1)
    else
      err "[$task_id] PR の作成に失敗しました: $pr_out"
      set_labels "$number" "$LABEL_FAILED"
      post_comment "$number" "$(printf 'ブランチ `%s` は push 済みですが、PR の作成に失敗しました。\n\n```\n%s\n```' "$branch" "$pr_out")"
      record_spend "$task_id" "$cost" "$pct_before" ""
      return 1
    fi
  fi

  set_labels "$number" "$LABEL_DONE"
  post_comment "$number" "$(printf '%s\n\n**PR**: %s\n\n**コミット**:\n%s\n\n推定コスト: $%s' \
    "$result" "$pr_url" "$(commit_subjects "$wt" "$head_before")" "$cost")"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after"
  remove_worktree "$wt"
  log "[$task_id] 完了: $pr_url (推定 \$$cost, 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
  return 0
}
