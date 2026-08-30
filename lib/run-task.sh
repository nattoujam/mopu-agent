#!/usr/bin/env bash


post_comment() {
  local issue="$1" body="$2"
  printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body" \
    | gh issue comment "$issue" -R "$REPO" --body-file - >/dev/null
}

# 報告の宛先。タスクの番号は元 Issue に読み替えるが、報告まで Issue 側へ流すと
# PR で受けた指示とその結果が別のページに分かれてしまうため、指示が来た
# コメントと同じ場所に返す
REPLY_KIND=issue
REPLY_NUMBER=""
REPLY_COMMENT_ID=""

set_reply_target() {
  local number="$1" task="${2:-}" rn
  REPLY_KIND=issue
  REPLY_NUMBER="$number"
  REPLY_COMMENT_ID=""

  [[ -n $task ]] || return 0
  rn=$(jq -r '.reply_number // empty' <<<"$task" 2>/dev/null)
  [[ -n $rn ]] || return 0

  REPLY_NUMBER="$rn"
  REPLY_KIND=$(jq -r '.reply_kind // "issue"' <<<"$task")
  REPLY_COMMENT_ID=$(jq -r '.comment_id // ""' <<<"$task")
}

# PR のレビューコメントは専用エンドポイントを使わないと同じスレッドに入らない。
# 会話タブのコメントには返信スレッドがないので、通常のコメントで返す
post_report() {
  local body="$1"
  if [[ $REPLY_KIND == review && -n $REPLY_COMMENT_ID ]]; then
    if gh api -X POST "repos/$REPO/pulls/$REPLY_NUMBER/comments/$REPLY_COMMENT_ID/replies" \
      -f "body=$(printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body")" >/dev/null 2>&1
    then
      return 0
    fi
    warn "レビューコメント $REPLY_COMMENT_ID への返信に失敗しました。#$REPLY_NUMBER にコメントします"
  fi
  post_comment "$REPLY_NUMBER" "$body"
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

# レビュアーの指定に失敗しても PR 自体は成立させる
request_review() {
  local task_id="$1" branch="$2" reviewer="${REPO%%/*}" out
  if ! out=$(gh pr edit "$branch" -R "$REPO" --add-reviewer "$reviewer" 2>&1); then
    warn "[$task_id] レビュアー '$reviewer' を指定できませんでした: $out"
  fi
}

PLAN_FILE_NAME='.mopu-agent-plan.json'

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
    if (.sub_issues | type) != "array" then false
    elif (.sub_issues | length) < 1 or (.sub_issues | length) > $max then false
    else all(.sub_issues[]; (.title | type) == "string" and (.title | length) > 0)
    end' "$1" >/dev/null 2>&1
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

# 分解パス。sub issue を作って親 Issue にまとめをコメントする
handle_plan() {
  local task_id="$1" number="$2" plan="$3" result="$4" cost="$5" pct_before="$6" task_dir="$7"

  if ! validate_plan "$plan"; then
    err "[$task_id] $PLAN_FILE_NAME の内容が不正です"
    set_labels "$number" "$LABEL_FAILED"
    post_report "$(printf 'タスク分解の結果を解釈できませんでした（sub_issues は 1〜%s 件の配列で、各要素に空でない title が必要です）。\n\n```json\n%s\n```' \
      "$MAX_SUB_ISSUES" "$(head -c 3000 "$plan")")"
    record_spend "$task_id" "$cost" "$pct_before" ""
    log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
    return 1
  fi

  local summary reason created
  summary=$(jq -r '.summary // ""' "$plan")
  reason=$(jq -r '.reason // ""' "$plan")

  log "[$task_id] タスクを分解します ($(jq '.sub_issues | length' "$plan") 件)"
  created=$(create_sub_issues "$number" "$plan")

  if [[ -z $created ]]; then
    err "[$task_id] sub issue を 1 件も作成できませんでした"
    set_labels "$number" "$LABEL_FAILED"
    post_report "タスク分解は行いましたが、sub issue の作成に失敗しました。ログ: \`$(agent_relpath "$AGENT_DIR/logs/$task_id")\`"
    record_spend "$task_id" "$cost" "$pct_before" ""
    log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
    return 1
  fi

  set_labels "$number" "$LABEL_DONE"
  post_report "$(
    printf '%s\n\n---\n\n**このタスクは大きいため、実装せず分解しました。**\n\n' "${result:-}"
    [[ -n $summary ]] && printf '%s\n\n' "$summary"
    [[ -n $reason ]]  && printf '理由: %s\n\n' "$reason"
    printf '**作成した sub issue**:\n%s\n\n' "$created"
    printf 'それぞれに `%s` が付いています。次回のポーリングから順に実装されます。\n\n' "$LABEL_QUEUED"
    printf '推定コスト: $%s\n' "$cost"
  )"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after"
  remove_workspace "$task_dir"
  log "[$task_id] 分解完了: $(wc -l <<<"$created") 件の sub issue を作成しました"
  return 0
}

# .result は複数行なので、行単位の tail では最終行しか取れない。
# 最後の result イベントを取り出してから中身を読む
last_result() {
  jq -rs 'map(select(.type=="result")) | last | .result // empty' "$1" 2>/dev/null
}

# 失敗したタスクが残していった作業ディレクトリのうち、その Issue の最新のもの
find_leftover_task() {
  local number="$1"
  find "$AGENT_DIR/worktrees" -mindepth 1 -maxdepth 1 -type d \
    \( -name "issue-${number}-*" -o -name "comment-${number}-*" \) 2>/dev/null \
    | sort | tail -1
}

TASK_FILE_NAME='task.json'

# --retry で前回のタスクをそのまま再現するための控え。Issue 本文から組み直すと
# コメント由来のタスクでは指示だったコメント本文が失われる。作業ツリーではなく
# ログ側に置くのは、エージェントの cwd から見えない場所に保つため
# commit は実行時の記録なので、引き継ぐタスクからは落とす
load_leftover_task() {
  local dir
  dir=$(find_leftover_task "$1")
  [[ -n $dir ]] || return 1
  jq -ec 'del(.commit)' "$AGENT_DIR/logs/${dir##*/}/$TASK_FILE_NAME" 2>/dev/null
}

# タスクの会話 ID を Issue 番号ごとに控える。--retry の再開と、PR コメントへの
# 対応で前回の会話を引き継ぐために使う。作業ツリーと違って成功時にも消さないので、
# レビューが数日後に来ても、その PR を書いたときの判断から続けられる
record_session() {
  local number="$1" sid="$2" tmp
  [[ -n $sid && $sid != null ]] || return 0
  [[ -f $SESSION_FILE ]] || echo '{}' > "$SESSION_FILE"
  tmp="$SESSION_FILE.tmp"
  if jq --arg n "$number" --arg s "$sid" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$n] = {session_id: $s, updated: $t}' "$SESSION_FILE" > "$tmp" 2>/dev/null
  then
    mv "$tmp" "$SESSION_FILE"
  else
    rm -f "$tmp"
    warn "会話 ID を記録できませんでした: #$number"
  fi
}

forget_session() {
  local number="$1" tmp
  [[ -f $SESSION_FILE ]] || return 0
  tmp="$SESSION_FILE.tmp"
  if jq --arg n "$number" 'del(.[$n])' "$SESSION_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SESSION_FILE"
  else
    rm -f "$tmp"
  fi
}

session_of_issue() {
  [[ -f $SESSION_FILE ]] || return 0
  jq -r --arg n "$1" '.[$n].session_id // empty' "$SESSION_FILE" 2>/dev/null
}

# --retry で渡す前回の失敗の情報。何が起きて、何がやりかけで残っているか
build_retry_context() {
  local prev_log="$1" wt="$2" result stderr changes
  [[ -f $prev_log/stream.jsonl ]] && result=$(last_result "$prev_log/stream.jsonl")
  [[ -s $prev_log/stderr.log ]] && stderr=$(tail -20 "$prev_log/stderr.log")
  changes=$(git -C "$wt" status --porcelain)
  {
    echo "## 前回の実行について"
    echo
    echo "このタスクの前回の実行は失敗し、その作業ツリーをそのまま引き継いでいます。"
    echo "やりかけの変更が残っているので、最初からやり直さず続きから進めてください。"
    # 報告自体が markdown（コードフェンス入り）なので、囲まずにそのまま置く
    if [[ -n ${result:-} ]]; then
      echo; echo "### 前回の報告"; echo; printf '%s\n' "$result"
    fi
    if [[ -n ${stderr:-} ]]; then
      echo; echo "### 前回の stderr"; echo; echo '```'; printf '%s\n' "$stderr"; echo '```'
    fi
    echo; echo "### 引き継いだ未コミットの変更"; echo; echo '```'
    printf '%s\n' "${changes:-（なし）}"
    echo '```'
  } | head -c 20000
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

# 使い方: invoke_agent <タスクディレクトリ> <ログディレクトリ> <プロンプト> <システムプロンプト> <設定ファイル> [再開する会話 ID]
invoke_agent() {
  local task_dir="$1" log_dir="$2" prompt="$3" sys_prompt="$4" settings="$5" resume_id="${6:-}"
  local -a resume_args=()

  # --fork-session で会話を分岐させる。元の会話をそのまま残せるので、再開した
  # 先で失敗しても同じ地点から何度でもやり直せる
  if [[ -n $resume_id ]]; then
    resume_args=(--resume "$resume_id" --fork-session)
    # 同じタスク説明が会話の中で二度目になるため、新しい依頼ではないと断っておく
    sys_prompt+=$'\n\n'"## 会話の再開について

これは以前の会話の続きです。上のタスク説明は改めて渡したもので、新しい依頼では
ありません。前回読んだファイルや下した判断は、そのまま引き継いで構いません。"
  fi

  (
    cd "$task_dir" || exit 1
    # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB は使わない。これを立てると sandbox の
    # filesystem isolation が強制的に維持され、sandbox.enabled=false でも
    # bwrap が起動する（このホストは AppArmor の userns 制限で必ず失敗する）。
    # 子プロセスへ渡したくない認証情報は代わりにここで落とす
    unset GH_TOKEN GITHUB_TOKEN
    timeout "$TASK_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
      "${resume_args[@]}" \
      --settings "$settings" \
      --setting-sources '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --append-system-prompt "$sys_prompt" \
      --output-format stream-json --verbose \
      --model "$MODEL" \
      --max-budget-usd "$MAX_TASK_BUDGET_USD"
  ) > "$log_dir/stream.jsonl" 2> "$log_dir/stderr.log"
}

# 使い方: run_task <kind:issue|comment> <issue番号> <タイトル> <本文> <コメント本文>
run_task() {
  local kind="$1" number="$2" title="$3" body="$4" comment="${5:-}"
  local task_id
  task_id="${kind}-${number}-$(date +%Y%m%d-%H%M%S)"
  set_reply_target "$number" "${CURRENT_TASK_JSON:-}"
  local branch="${BRANCH_PREFIX}${number}"
  local task_dir="$AGENT_DIR/worktrees/$task_id"

  # --retry では新しい worktree を作らず、前回の失敗が残したものを使う
  local prev_dir="" prev_log=""
  if (( ${RETRY:-0} )); then
    prev_dir=$(find_leftover_task "$number")
    if [[ -n $prev_dir ]]; then
      task_dir="$prev_dir"
      prev_log="$AGENT_DIR/logs/${prev_dir##*/}"
    else
      warn "[$task_id] 引き継げる作業ツリーがないため、通常どおり新規に作成します"
    fi
  fi

  local wt="$task_dir/repo"
  local plan_file="$task_dir/$PLAN_FILE_NAME"
  local log_dir="$AGENT_DIR/logs/$task_id"
  mkdir -p "$log_dir"
  [[ -n ${CURRENT_TASK_JSON:-} ]] \
    && jq -c --arg c "$AGENT_COMMIT" '. + {commit: $c}' <<<"$CURRENT_TASK_JSON" \
      > "$log_dir/$TASK_FILE_NAME"

  # --ignore-budget ではゲートを通らず USAGE_5H が空になるため取り直す
  local pct_before="$USAGE_5H"
  [[ -z $pct_before ]] && parse_usage "$(fetch_usage)" && pct_before="$USAGE_5H"

  # shellcheck disable=SC2034  # poll.sh の同時進行ゲートが参照
  LAST_TASK_OPENED_PR=0

  log "[$task_id] 開始: #$number $title"
  set_labels "$number" "$LABEL_RUNNING"

  local ok=0
  if [[ -n $prev_dir ]]; then
    log "[$task_id] 前回の作業ツリーを引き継ぎます: $(agent_relpath "$prev_dir")"
    resume_workspace "$branch" "$task_dir" && ok=1
  else
    create_workspace "$branch" "$task_dir" && ok=1
  fi
  if (( ! ok )); then
    err "[$task_id] worktree の準備に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_report "エージェントの作業ツリー準備に失敗しました。ブランチ \`$branch\` が使用中でないか確認してください。"
    return 1
  fi

  local sys_prompt no_decompose=0
  sys_prompt=$(cat "$AGENT_DIR/prompts/issue.md")
  [[ $kind == comment ]] && sys_prompt+=$'\n\n'$(cat "$AGENT_DIR/prompts/command.md")

  # 再開時にタスク分解へ逸れると、やりかけの変更が宙に浮く
  if [[ -n $prev_dir ]]; then
    no_decompose=1
    sys_prompt+=$'\n\n'"## タスク分解について

これは中断したタスクの再開です。分解せず、残っている作業を仕上げること。"
  elif is_sub_issue "$number" "$body"; then
    no_decompose=1
    sys_prompt+=$'\n\n'"## タスク分解について

この Issue は既に分解されたタスクの一部です。これ以上分解せず、そのまま実装すること。"
  else
    sys_prompt+=$'\n\n'"$(sed "s/%%MAX_SUB_ISSUES%%/$MAX_SUB_ISSUES/g" "$AGENT_DIR/prompts/decompose.md")"
  fi

  local prompt
  prompt=$(build_prompt "$kind" "$number" "$title" "$body" "$comment")
  [[ -n $prev_dir ]] && prompt+=$'\n\n'"$(build_retry_context "$prev_log" "$wt")"

  # Read/Edit のパス制限は worktree の絶対パスでしか正しく効かないため、
  # 実行のたびに設定を生成する（"//" が絶対パスのプレフィックス）。
  # Write ルールは Claude Code が参照しない（書き込み系は Edit がカバーする）
  local settings="$log_dir/settings.json" extra_json='[]'
  # 権限ルールは "Bash(npm test:*)" のように空白を含むため配列で受け取る
  (( ${#EXTRA_ALLOWED_TOOLS[@]} )) && \
    extra_json=$(printf '%s\n' "${EXTRA_ALLOWED_TOOLS[@]}" | jq -R . | jq -sc .)
  # sandbox を切っているので、エージェント自身の設定・認証情報を守るのは
  # この deny ルールだけになる
  local -a secret_paths=("$AGENT_DIR/config.env" "$AGENT_DIR/state")
  use_github_app && secret_paths+=("$APP_PRIVATE_KEY")
  local deny_json
  deny_json=$(printf '%s\n' "${secret_paths[@]}" \
    | jq -R 'sub("^/";"") | "Read(//\(.))", "Read(//\(.)/**)"' | jq -sc .)

  jq --arg wt "$task_dir" --argjson extra "$extra_json" --argjson deny "$deny_json" \
    '.permissions.allow = (
        ["Read(//\($wt)/**)", "Edit(//\($wt)/**)"]
        + $extra + .permissions.allow)
     | .permissions.deny = ($deny + .permissions.deny)' \
    "$AGENT_DIR/settings/agent-settings.json" > "$settings" || return 1

  # 既存ブランチを引き継いだ場合、既にあるコミットを「今回の成果」と誤認しないよう
  # 実行前の HEAD を控えておく
  local head_before
  head_before=$(git -C "$wt" rev-parse HEAD)
  # --retry で引き継いだコミットは push されていないので、今回の成果に含める。
  # ここを実行前の HEAD にすると、前回コミットまで進んでいたタスクが
  # 「コード変更なし」と判定されて push も PR 作成もされない
  if [[ -n $prev_dir ]]; then
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      head_before=$(git -C "$wt" rev-parse "origin/$branch")
    else
      head_before=$(git -C "$wt" merge-base HEAD "origin/$BASE_BRANCH")
    fi
  fi

  # 前回の会話を引き継ぐ条件。--retry は中断したタスクの再開、コメントは自分が
  # 出した PR へのレビュー対応で、どちらも前回の続きになる
  local resume_id=""
  if (( ${RETRY:-0} )) || [[ $kind == comment ]]; then
    resume_id=$(session_of_issue "$number")
    [[ -n $resume_id ]] && log "[$task_id] 前回の会話を再開します: $resume_id"
  fi

  local rc=0
  invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "$resume_id" || rc=$?

  # 保持期間を過ぎた会話は再開できない。この失敗は課金ゼロで即座に返るので、
  # 会話なしでやり直す。前回の情報はプロンプト側にも入っているため、
  # 再開できなくてもタスク自体は成立する
  if [[ -n $resume_id ]] && (( rc != 0 )) \
    && grep -q 'No conversation found with session ID' "$log_dir/stderr.log" 2>/dev/null
  then
    warn "[$task_id] 会話 $resume_id が見つかりません。新しい会話で実行します"
    forget_session "$number"
    resume_id=""
    rc=0
    invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "" || rc=$?
  fi

  local result is_error cost
  result=$(last_result "$log_dir/stream.jsonl")
  is_error=$(jq -r 'select(.type=="result") | .is_error' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  cost=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)

  local subtype session_id
  subtype=$(jq -r 'select(.type=="result") | .subtype' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  session_id=$(jq -r 'select(.type=="result") | .session_id // empty' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)

  # 打ち切りで終わった会話を引き継ぐと、膨らんだ context のまま再開して同じ壁に
  # ぶつかる。timeout(1) の 124 と --max-budget-usd による打ち切りがこれにあたる
  if (( rc == 124 )) || [[ $subtype == error_max_budget_usd ]]; then
    warn "[$task_id] 打ち切りで終わったため、この会話は引き継ぎません (${subtype:-timeout})"
    forget_session "$number"
  else
    record_session "$number" "$session_id"
  fi

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
    post_report "$(printf 'エージェントの実行に失敗しました (exit=%s)。\n\n%s\n\n```\n%s\n```\n\nログ: `%s`' \
      "$rc" "${result:-}" "${detail:-（stderr なし）}" "$(agent_relpath "$log_dir")")"
    record_spend "$task_id" "$cost" "$pct_before" ""
    log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
    return 1
  fi

  if [[ -f $plan_file ]]; then
    if (( no_decompose )); then
      warn "[$task_id] 分解済みタスクなので $PLAN_FILE_NAME を無視します"
      rm -f "$plan_file"
    else
      handle_plan "$task_id" "$number" "$plan_file" "$result" "$cost" "$pct_before" "$task_dir"
      return $?
    fi
  fi

  if [[ $(git -C "$wt" rev-parse HEAD) == "$head_before" ]]; then
    if [[ -n $(git -C "$wt" status --porcelain) ]]; then
      err "[$task_id] コミットされていない変更が残っています"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf '%s\n\nコミットに失敗した可能性があります。作業ツリーに未コミットの変更が残っているため保全しました。\n\nworktree: `%s`' \
        "${result:-（応答なし）}" "$(agent_relpath "$wt")")"
      record_spend "$task_id" "$cost" "$pct_before" ""
      log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
      return 1
    fi

    log "[$task_id] コード変更なし。結果のみコメントします"
    set_labels "$number" "$LABEL_DONE"
    post_report "${result:-（応答なし）}"
    record_spend "$task_id" "$cost" "$pct_before" ""
    remove_workspace "$task_dir"
    return 0
  fi

  log "[$task_id] push します: $branch"
  local -a push_env=()
  use_github_app && push_env=(env "GIT_ASKPASS=$(app_git_askpass)" "GH_TOKEN=$GH_TOKEN")
  if ! "${push_env[@]}" git -C "$wt" push --quiet -u origin "$branch" --force-with-lease; then
    err "[$task_id] push に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_report "作業は完了しましたが push に失敗しました。worktree: \`$(agent_relpath "$wt")\`"
    record_spend "$task_id" "$cost" "$pct_before" ""
    return 1
  fi

  # 既存 PR があれば作り直さず、追加コミットをそのまま反映させる
  local pr_url pr_out
  pr_url=$(gh pr view "$branch" -R "$REPO" --json url --jq .url 2>/dev/null)
  if [[ -z $pr_url ]]; then
    if pr_out=$(gh pr create -R "$REPO" \
      --base "$BASE_BRANCH" --head "$branch" \
      --title "$title" \
      --body "$(printf 'Closes #%s\n\n%s\n\n---\n%s' "$number" "$result" "$COMMENT_MARKER")" 2>&1)
    then
      pr_url=$(grep -oE 'https://[^ ]+/pull/[0-9]+' <<<"$pr_out" | tail -1)
      request_review "$task_id" "$branch"
    else
      err "[$task_id] PR の作成に失敗しました: $pr_out"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf 'ブランチ `%s` は push 済みですが、PR の作成に失敗しました。\n\n```\n%s\n```' "$branch" "$pr_out")"
      record_spend "$task_id" "$cost" "$pct_before" ""
      return 1
    fi
  fi

  # shellcheck disable=SC2034  # poll.sh の同時進行ゲートが参照
  LAST_TASK_OPENED_PR=1

  set_labels "$number" "$LABEL_DONE"
  post_report "$(printf '%s\n\n**PR**: %s\n\n**コミット**:\n%s\n\n推定コスト: $%s' \
    "$result" "$pr_url" "$(commit_subjects "$wt" "$head_before")" "$cost")"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after"
  remove_workspace "$task_dir"
  log "[$task_id] 完了: $pr_url (推定 \$$cost, 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
  return 0
}
