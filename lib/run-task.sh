#!/usr/bin/env bash


post_comment() {
  local issue="$1" body="$2"
  printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body" \
    | gh issue comment "$issue" -R "$REPO" --body-file - >/dev/null
}

# 報告の宛先。タスクの番号は元 Issue に読み替えるが、報告まで Issue 側へ流すと
# PR で受けた指示とその結果が別のページに分かれてしまうため、指示が来た
# コメントと同じ場所に返す。複数のコメントを畳んだタスクでは最後のコメントを
# 代表とし、失敗の報告と PR のまとめだけをそこへ返す
REPLY_KIND=issue
REPLY_NUMBER=""
REPLY_COMMENT_ID=""

set_reply_target() {
  local number="$1" task="${2:-}" last
  REPLY_KIND=issue
  REPLY_NUMBER="$number"
  REPLY_COMMENT_ID=""

  [[ -n $task ]] || return 0
  last=$(jq -c '(.comments // []) | last // empty' <<<"$task" 2>/dev/null)
  [[ -n $last ]] || return 0

  REPLY_NUMBER=$(jq -r '.reply_number' <<<"$last")
  REPLY_KIND=$(jq -r '.reply_kind // "issue"' <<<"$last")
  REPLY_COMMENT_ID=$(jq -r '.id // ""' <<<"$last")
}

# PR のレビューコメントは専用エンドポイントを使わないと同じスレッドに入らない。
# 会話タブのコメントには返信スレッドがないので、通常のコメントで返す
post_report() {
  local body="$1" kind="${2:-$REPLY_KIND}" number="${3:-$REPLY_NUMBER}" cid="${4:-$REPLY_COMMENT_ID}"
  if [[ $kind == review && -n $cid ]]; then
    if gh api -X POST "repos/$REPO/pulls/$number/comments/$cid/replies" \
      -f "body=$(printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body")" >/dev/null 2>&1
    then
      return 0
    fi
    warn "レビューコメント $cid への返信に失敗しました。#$number にコメントします"
  fi
  post_comment "$number" "$body"
}

join_report() {
  local body="$1" summary="$2"
  [[ -n $body && -n $summary ]] && body+=$'\n\n---\n\n'
  printf '%s%s' "$body" "$summary"
}

REPLIES_FILE_NAME='.mopu-agent-replies.json'

# コメントごとの返信を、それが投稿されたスレッドへ返す。エージェントが書かなかった
# ID は最終メッセージで埋める。PR リンクなどのまとめは繰り返しても意味がないので、
# 代表（最後のコメント）にだけ付ける
post_replies() {
  local task="$1" replies="$2" fallback="$3" summary="$4"
  local n i id kind number reply
  n=$(jq '(.comments // []) | length' <<<"$task" 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] || n=0

  if (( n == 0 )); then
    post_report "$(join_report "$fallback" "$summary")"
    return 0
  fi

  for (( i = 0; i < n; i++ )); do
    id=$(jq -r ".comments[$i].id" <<<"$task")
    kind=$(jq -r ".comments[$i].reply_kind" <<<"$task")
    number=$(jq -r ".comments[$i].reply_number" <<<"$task")
    reply=""
    [[ -f $replies ]] && reply=$(jq -r --arg id "$id" '.replies[$id] // empty' "$replies" 2>/dev/null)
    [[ -n $reply ]] || reply="$fallback"
    (( i == n - 1 )) && reply=$(join_report "$reply" "$summary")
    [[ -n $reply ]] || continue
    post_report "$reply" "$kind" "$number" "$id"
  done
}

# 付いていないラベルの削除は gh がエラーにするため、追加と削除を分けて実行する
set_labels() {
  local issue="$1" add="$2" l
  if ! gh issue edit "$issue" -R "$REPO" --add-label "$add" >/dev/null 2>&1; then
    warn "ラベル '$add' を付けられませんでした（setup.sh でラベルを作成してください）。既存のラベルは変更しません"
    return 0
  fi
  for l in "$LABEL_QUEUED" "$LABEL_RUNNING" "$LABEL_AWAITING" "$LABEL_DONE" "$LABEL_FAILED"; do
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

# .result は複数行なので、行単位の tail では最終行しか取れない。
# 最後の result イベントを取り出してから中身を読む
last_result() {
  jq -rs 'map(select(.type=="result")) | last | .result // empty' "$1" 2>/dev/null
}

# 失敗したタスクが残していった作業ディレクトリのうち、その Issue の最新のもの
find_leftover_task() {
  local number="$1"
  find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d \
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
  # comments を持たない古い控えは、指示が落ちないよう 1 件の配列に寄せる
  jq -ec 'del(.commit)
    | if (.comments | type) == "array" then .
      else
        .comments = (if (.comment_id // "") == "" then []
                     else [{id: .comment_id, actor: .actor, instruction: (.comment // ""),
                            reply_kind: (.reply_kind // "issue"),
                            reply_number: (.reply_number // .number), url: ""}]
                     end)
        | del(.comment, .comment_id, .reply_kind, .reply_number)
      end' "$TASK_LOGS_DIR/${dir##*/}/$TASK_FILE_NAME" 2>/dev/null
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

build_pending_plan_context() {
  {
    echo "## 承認待ちの分解案"
    echo
    echo "この Issue には、前回のセッションが提案した分解案が承認待ちで残っています。"
    echo "上のコメントはその案への返答です。案を直す指示なら、同じ判定基準で"
    echo "作り直した案を計画ファイルに書いてください（実装はしない）。"
    echo "分解せずに実装するよう指示されたなら、案は捨ててそのまま実装して構いません。"
    echo
    echo '```json'
    plan_from_comment "$1"
    echo '```'
  }
}

build_prompt() {
  local kind="$1" number="$2" title="$3" body="$4" task="${5:-}"
  {
    echo "# タスク"
    echo
    if [[ $kind == comment ]]; then
      local n i id url instruction
      n=$(jq '(.comments // []) | length' <<<"$task" 2>/dev/null)
      [[ $n =~ ^[0-9]+$ ]] || n=0
      if (( n > 1 )); then
        echo "GitHub の #$number に次の $n 件のコメントが投稿されました。**そのすべて**に対応してください。"
      else
        echo "GitHub の #$number に次のコメントが投稿されました。この指示に対応してください。"
      fi
      echo
      for (( i = 0; i < n; i++ )); do
        id=$(jq -r ".comments[$i].id" <<<"$task")
        url=$(jq -r ".comments[$i].url // \"\"" <<<"$task")
        instruction=$(jq -r ".comments[$i].instruction" <<<"$task")
        printf '### コメント %s\n\n' "$id"
        [[ -n $url ]] && printf '%s\n\n' "$url"
        echo '```'
        printf '%s\n' "$instruction"
        echo '```'
        echo
      done
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

# 使い方: build_agent_settings <タスクディレクトリ> <出力ファイル>
# パス制限は絶対パスでしか正しく効かないため、タスクごとに生成する
# （"//" が絶対パスのプレフィックス）。Write ルールは Claude Code が参照しない
# （書き込み系は Edit がカバーする）
build_agent_settings() {
  local task_dir="$1" out="$2"
  local wt="$task_dir/$REPO_SUBDIR"

  # permissions の Read は Read ツールに、sandbox の denyRead は Bash にしか効かない
  local -a secret_paths=("$AGENT_DIR/config.env" "$AGENT_DIR/state")
  use_github_app && secret_paths+=("$APP_PRIVATE_KEY")
  local secrets_json
  secrets_json=$(printf '%s\n' "${secret_paths[@]}" | jq -R . | jq -sc .)
  local tools="$AGENT_DIR/tools"

  # worktree のコミットは共有の .git（repos/<slug>/.git）へ書くので、そこだけ
  # 書き込みを開ける。ただし hooks と config はホストが後で git push を実行する
  # ときに読まれる＝任意コード実行の経路なので閉じる。worktree 側の .git は
  # gitdir を指すただのファイルで、書き換えると別の hooks を差し込めるため同様に閉じる
  jq --arg wt "$wt" --arg task_dir "$task_dir" --arg repo_git "$REPO_DIR/.git" \
     --argjson secrets "$secrets_json" --arg tools "$tools" \
    'def abs: sub("^/"; "//");
     ["\($tools)/push-branch", "\($tools)/dispatch-workflow *"] as $host_cmds
     | .permissions.allow = (
        ["Read(\($task_dir | abs)/**)", "Edit(\($task_dir | abs)/**)"]
        + ($host_cmds | map("Bash(\(.))")) + .permissions.allow)
     | .sandbox.excludedCommands = $host_cmds
     | .hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "\($tools)/guard-host-commands"}]}]
     | .permissions.deny = (
        ($secrets | map("Read(\(. | abs))", "Read(\(. | abs)/**)"))
        + ["Edit(\($wt | abs)/.git)", "Edit(\($wt | abs)/.git/**)"]
        + .permissions.deny)
     | .sandbox.filesystem = {
        allowWrite: [$task_dir, $repo_git],
        denyWrite: ["\($wt)/.git", "\($repo_git)/hooks", "\($repo_git)/config"],
        denyRead: $secrets
       }' \
    "$AGENT_DIR/settings/agent-settings.json" > "$out"
}

# 使い方: invoke_agent <タスクディレクトリ> <ログディレクトリ> <プロンプト> <システムプロンプト> <設定ファイル> <ブランチ> [再開する会話 ID]
invoke_agent() {
  local task_dir="$1" log_dir="$2" prompt="$3" sys_prompt="$4" settings="$5" branch="$6" resume_id="${7:-}"
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
    cd "$task_dir/$REPO_SUBDIR" || exit 1
    # sandbox.credentials は Bash の子プロセスにしか効かない（WebFetch は本体側で動く）
    unset GH_TOKEN GITHUB_TOKEN
    [[ -n ${AGENT_GH_TOKEN:-} ]] && export GH_TOKEN="$AGENT_GH_TOKEN"
    export MOPU_TASK_DIR="$task_dir" MOPU_BRANCH="$branch"
    # ~/.npm や ~/.cache は sandbox から書けないので、キャッシュをタスク側に持たせる
    export npm_config_cache="$task_dir/.npm-cache" XDG_CACHE_HOME="$task_dir/.cache"
    # sandbox 内の Bash は prompt を経ずに自動承認されるので dontAsk に拒否されない
    timeout "$TASK_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
      "${resume_args[@]}" \
      --settings "$settings" \
      --permission-mode dontAsk \
      --setting-sources '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --append-system-prompt "$sys_prompt" \
      --output-format stream-json --verbose \
      --model "$MODEL" \
      --max-budget-usd "$MAX_TASK_BUDGET_USD" </dev/null
  ) > "$log_dir/stream.jsonl" 2> "$log_dir/stderr.log"
}

# 使い方: run_task <kind:issue|comment> <issue番号> <タイトル> <本文>
# コメントの内容と返信先は CURRENT_TASK_JSON の comments から読む
run_task() {
  local kind="$1" number="$2" title="$3" body="$4"
  local task_id
  task_id="${kind}-${number}-$(date +%Y%m%d-%H%M%S)"
  set_reply_target "$number" "${CURRENT_TASK_JSON:-}"
  local branch="${BRANCH_PREFIX}${number}"
  local task_dir="$WORKTREES_DIR/$task_id"

  # --retry では新しい worktree を作らず、前回の失敗が残したものを使う
  local prev_dir="" prev_log=""
  if (( ${RETRY:-0} )); then
    prev_dir=$(find_leftover_task "$number")
    if [[ -n $prev_dir ]]; then
      task_dir="$prev_dir"
      prev_log="$TASK_LOGS_DIR/${prev_dir##*/}"
    else
      warn "[$task_id] 引き継げる作業ツリーがないため、通常どおり新規に作成します"
    fi
  fi

  local wt="$task_dir/repo"
  local plan_file="$task_dir/$PLAN_FILE_NAME"
  local replies_file="$task_dir/$REPLIES_FILE_NAME"
  # --retry で引き継いだ作業ツリーには前回の返信が残っている
  rm -f "$replies_file"
  local log_dir="$TASK_LOGS_DIR/$task_id"
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

  if [[ -n $SETUP_CMD ]]; then
    local setup_log="$log_dir/setup.log" setup_rc=0
    log "[$task_id] 依存を準備します: $SETUP_CMD"
    run_setup "$wt" "$setup_log" || setup_rc=$?
    if (( setup_rc )); then
      err "[$task_id] 依存の準備に失敗しました (exit=$setup_rc)"
      [[ -s $setup_log ]] && warn "$(tail -20 "$setup_log")"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf '依存の準備コマンドが失敗しました (exit=%s%s)。\n\n```\n%s\n```\n\n```\n%s\n```\n\nログ: `%s`' \
        "$setup_rc" "$( (( setup_rc == 124 )) && printf ': %s で打ち切り' "$SETUP_TIMEOUT" )" \
        "$SETUP_CMD" "$(tail -20 "$setup_log")" "$(agent_relpath "$setup_log")")"
      log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
      return 1
    fi
  fi

  local sys_prompt no_decompose=0
  sys_prompt=$(cat "$AGENT_DIR/prompts/issue.md")
  AGENT_GH_TOKEN=""
  if use_github_app; then
    AGENT_GH_TOKEN=$(app_token_with "$AGENT_TOKEN_PERMISSIONS") \
      || warn "[$task_id] エージェント用トークンを取得できません。App に Actions: Read を付与すると CI の結果を読めます"
  fi
  sys_prompt+=$'\n\n'"$(sed -e "s|%%PUSH_CMD%%|$AGENT_DIR/tools/push-branch|g" \
    -e "s|%%BRANCH%%|$branch|g" "$AGENT_DIR/prompts/ci.md")"
  if (( ${#DISPATCH_WORKFLOWS[@]} )); then
    sys_prompt+=$'\n'"- 手動起動（\`workflow_dispatch\`）は \`$AGENT_DIR/tools/dispatch-workflow <workflow.yml> [key=value ...]\` で行う。ブランチは自分のものに固定され、起動できるのは次だけ: $(printf '`%s` ' "${DISPATCH_WORKFLOWS[@]}")。先に push しておくこと。他のコマンドと繋がず単独で呼ぶ"
  else
    sys_prompt+=$'\n'"- 手動起動（\`workflow_dispatch\`）はできない。push で起動するワークフローだけが使える"
  fi
  [[ -n $AGENT_GH_TOKEN ]] || sys_prompt+=$'\n\n'"この環境では \`gh\` は使えない（CI の結果は読めない）。push だけはできる。"
  [[ $kind == comment ]] && sys_prompt+=$'\n\n'"$(sed "s|%%REPLIES_FILE%%|$replies_file|g" "$AGENT_DIR/prompts/command.md")"

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
    # 計画ファイルはリポジトリの外に置く。エージェントはリポジトリ直下で動くため
    # 相対パスだと書き先を間違えやすく、外したことに気づけないまま分解が失われる
    sys_prompt+=$'\n\n'"$(sed -e "s/%%MAX_SUB_ISSUES%%/$MAX_SUB_ISSUES/g" \
      -e "s|%%PLAN_FILE%%|$plan_file|g" "$AGENT_DIR/prompts/decompose.md")"
  fi

  local prompt pending_plan=""
  prompt=$(build_prompt "$kind" "$number" "$title" "$body" "${CURRENT_TASK_JSON:-}")
  [[ -n $prev_dir ]] && prompt+=$'\n\n'"$(build_retry_context "$prev_log" "$wt")"
  if [[ $kind == comment ]] && (( ! no_decompose )) && pending_plan=$(latest_plan_comment "$number"); then
    prompt+=$'\n\n'"$(build_pending_plan_context "$pending_plan")"
  fi

  local settings="$log_dir/settings.json"
  build_agent_settings "$task_dir" "$settings" || return 1

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
  invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "$branch" "$resume_id" || rc=$?

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
    invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "$branch" "" || rc=$?
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
      propose_plan "$task_id" "$number" "$plan_file" "$cost" "$pct_before" "$task_dir"
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
    set_labels "$number" "$( [[ -n $pending_plan ]] && printf '%s' "$LABEL_AWAITING" || printf '%s' "$LABEL_DONE" )"
    post_replies "${CURRENT_TASK_JSON:-}" "$replies_file" "${result:-（応答なし）}" ""
    record_spend "$task_id" "$cost" "$pct_before" ""
    remove_workspace "$task_dir"
    return 0
  fi

  log "[$task_id] push します: $branch"
  if ! push_workspace "$wt" "$branch"; then
    err "[$task_id] push に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_report "作業は完了しましたが push に失敗しました。worktree: \`$(agent_relpath "$wt")\`"
    record_spend "$task_id" "$cost" "$pct_before" ""
    return 1
  fi

  # 既存 PR があれば作り直さず、追加コミットをそのまま反映させる
  local pr_url pr_out pr_created=0
  pr_url=$(gh pr view "$branch" -R "$REPO" --json url --jq .url 2>/dev/null)
  if [[ -z $pr_url ]]; then
    if pr_out=$(gh pr create -R "$REPO" \
      --base "$BASE_BRANCH" --head "$branch" \
      --title "$title" \
      --body "$(printf 'Closes #%s\n\n%s\n\n---\n%s' "$number" "$result" "$COMMENT_MARKER")" 2>&1)
    then
      pr_url=$(grep -oE 'https://[^ ]+/pull/[0-9]+' <<<"$pr_out" | tail -1)
      pr_created=1
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
  # 新規作成なら変更内容の説明は PR 本文（$result）に載る。既存 PR への追加
  # コミットでは PR 本文が書き換わらないため、返信に含めないと応答が消える
  local summary fallback=""
  (( pr_created )) || fallback="${result:-（応答なし）}"
  summary=$(printf '%s: %s\n\n**コミット**:\n%s\n\n推定コスト: $%s' \
    "$( (( pr_created )) && printf 'PR を作成しました' || printf 'PR を更新しました' )" \
    "$pr_url" "$(commit_subjects "$wt" "$head_before")" "$cost")
  post_replies "${CURRENT_TASK_JSON:-}" "$replies_file" "$fallback" "$summary"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after"
  remove_workspace "$task_dir"
  log "[$task_id] 完了: $pr_url (推定 \$$cost, 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
  return 0
}
