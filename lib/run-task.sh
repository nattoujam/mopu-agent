#!/usr/bin/env bash
# タスク 1 件の state machine。遷移は run_task_body のループ、各 state の中身は state_<名前> にある。
# タスクの状態は TASK_ で始まるグローバル変数に持ち、run_task が 1 件ごとに初期化する

# 失敗した state を --retry でやり直すとき、その state より前の結果を前回のログから引き継ぐファイル
CARRY_FILES=(triage.json verify.json report.json)
# CI 待ちでタスクの時間制限を使い切っても、report を書けるようにする呼び出しごとの最低時間
MIN_CALL_SECONDS=300

post_comment() {
  local issue="$1" body="$2"
  printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body" \
    | gh issue comment "$issue" -R "$REPO" --body-file - >/dev/null
}

# 使い方: already_posted <issue|review> <番号> <マーカー>
already_posted() {
  local kind="$1" number="$2" marker="$3" path="issues/$2/comments"
  [[ $kind == review ]] && path="pulls/$number/comments"
  gh api --paginate "repos/$REPO/$path" --jq '.[].body' 2>/dev/null | grep -qF -- "$marker"
}

# 使い方: post_reply <issue|review> <番号> <コメント ID> <本文>
# 返信はコメントが来た場所に返す。PR のレビューコメントは専用のエンドポイントでないと同じスレッドに入らない
post_reply() {
  local kind="$1" number="$2" cid="$3" marker="<!-- mopu-agent:reply-to $3 -->" body
  body=$(printf '%s\n\n%s' "$4" "$marker")
  already_posted "$kind" "$number" "$marker" && return 0
  if [[ $kind == review ]]; then
    gh api -X POST "repos/$REPO/pulls/$number/comments/$cid/replies" \
      -f "body=$(printf '%s\n\n%s\n' "$COMMENT_MARKER" "$body")" >/dev/null 2>&1 && return 0
    warn "[$TASK_ID] レビューコメント $cid への返信に失敗しました。#$number にコメントします"
  fi
  post_comment "$number" "$body"
}

# 使い方: post_replies <出口の JSON> [各返信の末尾に足す文]
post_replies() {
  local outcome="$1" footer="${2:-}" row reply
  while IFS= read -r row; do
    reply=$(jq -r --arg id "$(jq -r '.id' <<<"$row")" '.replies[$id] // ""' <<<"$outcome")
    post_reply "$(jq -r '.reply_kind' <<<"$row")" "$(jq -r '.reply_number' <<<"$row")" "$(jq -r '.id' <<<"$row")" \
      "${reply}${footer:+$'\n\n---\n'$footer}"
  done < <(jq -c '(.comments // [])[]' <<<"$TASK_JSON")
}

# mopu-agent からの報告は、PR が無ければ Issue、あれば PR に書く
post_task_report() {
  if [[ -n $TASK_PR ]]; then
    post_comment "$(pr_number)" "$1"
  else
    post_comment "$TASK_NUMBER" "$1"
  fi
}

answer_footer() {
  printf '回答は、行頭に `%s` を付けてコメントしてください。' "$TRIGGER_COMMAND"
}

# 付いていないラベルの削除は gh がエラーにするため、追加と削除を分けて実行する
set_labels() {
  local issue="$1" add="$2" l
  if ! gh issue edit "$issue" -R "$REPO" --add-label "$add" >/dev/null 2>&1; then
    warn "ラベル '$add' を付けられませんでした（setup.sh でラベルを作成してください）。既存のラベルは変更しません"
    return 0
  fi
  for l in "${AGENT_LABELS[@]}"; do
    [[ $l == "$add" ]] && continue
    gh issue edit "$issue" -R "$REPO" --remove-label "$l" >/dev/null 2>&1 || true
  done
}

# 使い方: is_our_pr <gh pr view の JSON>
is_our_pr() {
  jq -e --arg m "$COMMENT_MARKER" '(.body // "") | contains($m)' <<<"$1" >/dev/null 2>&1
}

# タスクのブランチの、開いている PR を TASK_PR（JSON。無ければ空）と TASK_PR_OURS に読み込む。
# gh pr view にブランチ名を渡すと、フォークから出た同名ブランチの PR も当たるため isCrossRepository を見る
load_task_pr() {
  TASK_PR=$(gh pr view "$TASK_BRANCH" -R "$REPO" --json number,url,isDraft,body,state,isCrossRepository 2>/dev/null \
    | jq -c 'select(.state == "OPEN" and .isCrossRepository == false)' 2>/dev/null)
  TASK_PR_OURS=0
  if [[ -n $TASK_PR ]] && is_our_pr "$TASK_PR"; then TASK_PR_OURS=1; fi
  return 0
}

pr_number() { jq -r '.number' <<<"$TASK_PR"; }

pr_body_with_marker() {
  printf 'Closes #%s\n\n%s\n\n---\n%s' "$TASK_NUMBER" "$1" "$COMMENT_MARKER"
}

task_branch() {
  local b
  b=$(jq -r '.branch // empty' <<<"$1" 2>/dev/null)
  printf '%s' "${b:-${BRANCH_PREFIX}$2}"
}

task_phase() { record_phase "$TASK_LOG/$PHASE_FILE_NAME" "$@"; }

lead_quote() {
  [[ -n $1 ]] || return 0
  md_quote "${1%%$'\n\n'*}"
}

duration_seconds() {
  local v="$1"
  case $v in
    *d) echo $(( ${v%d} * 86400 )) ;;
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}

# --- チェックポイント（Issue ごとの最後の会話） ---

checkpoint_get() {
  [[ -f $SESSION_FILE ]] || return 0
  jq -c --arg n "$TASK_NUMBER" '.[$n] // empty' "$SESSION_FILE" 2>/dev/null
}

# 使い方: checkpoint_update <jq の式> [jq の引数 ...]
checkpoint_update() {
  local expr="$1" tmp="$SESSION_FILE.tmp"
  shift
  [[ -f $SESSION_FILE ]] || echo '{}' > "$SESSION_FILE"
  if jq "$@" "$expr" "$SESSION_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SESSION_FILE"
  else
    rm -f "$tmp"
    warn "チェックポイントを更新できませんでした: $expr"
  fi
}

checkpoint_set() {
  local sid="$1" cost="$2"
  checkpoint_update '.[$n] = {session_id: $s, head: $h, prompt_hash: $p, memory_hash: $mh, cost_usd: $c, updated: $t}' \
    --arg n "$TASK_NUMBER" --arg s "$sid" --arg h "$(git -C "$TASK_WT" rev-parse HEAD)" \
    --arg p "$TASK_SYS_HASH" --arg mh "$TASK_MEMORY_HASH" --argjson c "${cost:-0}" --arg t "$(date -Is)"
}

checkpoint_forget() { checkpoint_update 'del(.[$n])' --arg n "$1"; }

# PR がマージされた Issue の、ローカルブランチとチェックポイントを消す
cleanup_merged() {
  [[ -s $SESSION_FILE ]] || return 0
  local merged n head
  merged=$(gh pr list -R "$REPO" --state merged --limit 100 --json number,headRefName 2>/dev/null) || return 0
  for n in $(jq -r 'keys[]' "$SESSION_FILE"); do
    head=$(jq -r --arg n "$n" --arg b "$BRANCH_PREFIX$n" \
      'map(select(.headRefName == $b or (.number | tostring) == $n)) | .[0].headRefName // empty' <<<"$merged")
    [[ -n $head ]] || continue
    if (( ${DRY_RUN:-0} )); then
      log "PR がマージされたため、$head とチェックポイントを消します（dry-run）: #$n"
      continue
    fi
    [[ -d $REPO_DIR/.git ]] && git -C "$REPO_DIR" branch -D "$head" >/dev/null 2>&1
    checkpoint_forget "$n"
    log "PR がマージされたため、$head とチェックポイントを消しました: #$n"
  done
}

# 使い方: last_task_log <Issue 番号>
last_task_log() {
  find "$TASK_LOGS_DIR" -mindepth 1 -maxdepth 1 -type d \( -name "issue-$1-*" -o -name "comment-$1-*" \) 2>/dev/null \
    | sed -E 's/.*-([0-9]{8}-[0-9]{6})$/\1 &/' | sort | tail -1 | cut -d' ' -f2-
}

# 使い方: load_failed_task <Issue 番号>
# その Issue の最後のタスクが失敗していれば、そのタスク JSON を出す
load_failed_task() {
  local dir
  dir=$(last_task_log "$1")
  [[ -n $dir ]] && jq -e '.ok == false and (.failed_state // "") != ""' "$dir/outcome.json" >/dev/null 2>&1 || return 1
  jq -c 'del(.commit)' "$dir/$TASK_FILE_NAME" 2>/dev/null
}

# --- エージェントの呼び出し ---

# 使い方: build_agent_settings <タスクディレクトリ> <出力ファイル>
# パス制限は絶対パスでしか正しく効かないため、タスクごとに生成する
# （"//" が絶対パスのプレフィックス）。Write ルールは Claude Code が参照しない
# （書き込み系は Edit がカバーする）
build_agent_settings() {
  local task_dir="$1" out="$2"
  local wt="$task_dir/$REPO_SUBDIR"

  # permissions の Read は Read ツールに、sandbox の denyRead は Bash にしか効かない
  local -a secret_paths=("$AGENT_DIR/config.env" "$AGENT_DIR/state" "$APP_PRIVATE_KEY")
  local secrets_json
  secrets_json=$(printf '%s\n' "${secret_paths[@]}" | jq -R . | jq -sc .)
  local admin
  [[ $(<"$wt/.git") =~ ^gitdir:\ (.+)$ ]] || { err "worktree の .git を読めません: $wt"; return 1; }
  admin="${BASH_REMATCH[1]}"

  # worktree のコミットは共有の .git（repos/<slug>/.git）へ書くので、そこだけ
  # 書き込みを開ける。ただし hooks と config はホストが後で git push を実行する
  # ときに読まれる＝任意コード実行の経路なので閉じる。worktree 側の .git と、
  # 管理ディレクトリの commondir / gitdir は git が config と hooks を探す道筋で、
  # 書き換えると別の hooks を差し込めるため同様に閉じる。info/ は無視リストを持ち、
  # 書き換えると未コミットの変更を git status から隠せるため閉じる
  jq --arg wt "$wt" --arg repo_git "$REPO_DIR/.git" --arg admin "$admin" \
     --argjson secrets "$secrets_json" --arg mopu "$MOPU_BIN" \
    'def abs: sub("^/"; "//");
     ["\($mopu) run-container *"] as $host_cmds
     | .permissions.allow = (
        ["Read(\($wt | abs)/**)", "Edit(\($wt | abs)/**)"]
        + ($host_cmds | map("Bash(\(.))")) + .permissions.allow)
     | .sandbox.excludedCommands = $host_cmds
     | .hooks.PreToolUse = [
        {matcher: "Bash", hooks: [{type: "command", command: "\($mopu) hook guard-host-commands"}]},
        {matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: "\($mopu) hook phase-guard"}]}]
     | .hooks.Stop = [{hooks: [{type: "command", command: "\($mopu) hook phase-gate"}]}]
     | .permissions.deny = (
        ($secrets | map("Read(\(. | abs))", "Read(\(. | abs)/**)"))
        + ["Edit(\($wt | abs)/.git)", "Edit(\($wt | abs)/.git/**)"]
        + .permissions.deny)
     | .sandbox.filesystem = {
        allowWrite: [$wt, $repo_git],
        denyWrite: ["\($wt)/.git", "\($repo_git)/hooks", "\($repo_git)/config", "\($repo_git)/info",
                    "\($admin)/commondir", "\($admin)/gitdir"],
        denyRead: $secrets
       }' \
    "$AGENT_DIR/settings/agent-settings.json" > "$out"
}

# 使い方: invoke_agent <タスクディレクトリ> <ログディレクトリ> <本文> <システムプロンプト> <設定ファイル> <再開する会話 ID> <時間制限（秒）> <予算（USD）> [環境変数=値 ...]
# stream-json は <ログディレクトリ>/stream.jsonl に追記する
invoke_agent() {
  local task_dir="$1" log_dir="$2" prompt="$3" sys_prompt="$4" settings="$5" resume_id="$6" limit="$7" budget="$8"
  shift 8
  local -a resume_args=() schema_args=()
  [[ -n ${AGENT_JSON_SCHEMA:-} ]] && schema_args=(--json-schema "$AGENT_JSON_SCHEMA")
  # --fork-session で会話を分岐させる。元の会話をそのまま残せるので、再開した
  # 先で失敗しても同じ地点から何度でもやり直せる
  [[ -n $resume_id ]] && resume_args=(--resume "$resume_id" --fork-session)

  (
    cd "$task_dir/$REPO_SUBDIR" || exit 1
    # sandbox.credentials は Bash の子プロセスにしか効かない（WebFetch は本体側で動く）
    unset GH_TOKEN GITHUB_TOKEN
    [[ -n ${AGENT_GH_TOKEN:-} ]] && export GH_TOKEN="$AGENT_GH_TOKEN"
    export MOPU_TASK_DIR="$task_dir" MOPU_LOG_DIR="$log_dir"
    # shellcheck disable=SC2163  # 引数は 名前=値 の組
    (( $# )) && export "$@"
    # ~/.npm や ~/.cache は sandbox から書けないので、キャッシュを worktree に持たせる
    export npm_config_cache="$task_dir/$REPO_SUBDIR/.npm-cache" XDG_CACHE_HOME="$task_dir/$REPO_SUBDIR/.cache"
    # sandbox 内の Bash は prompt を経ずに自動承認されるので dontAsk に拒否されない
    timeout "$limit" "$CLAUDE_BIN" -p "$prompt" \
      "${resume_args[@]}" "${schema_args[@]}" \
      --settings "$settings" \
      --permission-mode dontAsk \
      --setting-sources '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --append-system-prompt "$sys_prompt" \
      --output-format stream-json --verbose \
      --model "$MODEL" \
      --max-budget-usd "$budget" </dev/null
  ) >> "$log_dir/stream.jsonl" 2>> "$log_dir/stderr.log"
}

# 使い方: call_agent <state> <本文>
# Issue のチェックポイントの会話を引き継いで LLM の state を 1 回実行する。終える条件を満たしたら
# TASK_OUTCOME に出口の JSON を入れ、チェックポイントを進めて 0 を返す。満たさなければ TASK_FAIL_REASON を入れて 1 を返す
call_agent() {
  local state="$1" body="$2" cp resume_id="" base_cost=0 head_start lines_before rc=0
  local -a env_args
  head_start=$(git -C "$TASK_WT" rev-parse HEAD)
  rm -f "$TASK_WT/$OUTCOME_FILE_NAME" "$TASK_LOG/phase-gate.count"

  cp=$(checkpoint_get)
  if [[ -n $cp && $(jq -r '.prompt_hash // ""' <<<"$cp") == "$TASK_SYS_HASH" ]]; then
    resume_id=$(jq -r '.session_id' <<<"$cp")
    base_cost=$(jq -r '.cost_usd // 0' <<<"$cp")
    if [[ $state == triage-* && -n $TASK_MEMORY && $(jq -r '.memory_hash // ""' <<<"$cp") != "$TASK_MEMORY_HASH" ]]; then
      body+=$'\n\n'"$TASK_MEMORY"
    fi
  fi

  if ! AGENT_GH_TOKEN=$(app_token_with "$AGENT_TOKEN_PERMISSIONS"); then
    TASK_FAIL_REASON="エージェント用のトークンを取得できませんでした。App に Actions: Read が付与されているか確認してください"
    return 1
  fi

  local now limit budget
  now=$(date +%s)
  limit=$(( TASK_DEADLINE - now ))
  (( limit >= MIN_CALL_SECONDS )) || limit=$MIN_CALL_SECONDS
  budget=$(jq -n --argjson m "$MAX_TASK_BUDGET_USD" --argjson c "$TASK_COST" '[$m - $c, 0.01] | max')
  env_args=(MOPU_PHASE="$state" MOPU_HEAD_START="$head_start" MOPU_HAS_PR="$([[ -n $TASK_PR ]] && echo 1 || echo 0)"
            MOPU_PR_OURS="$TASK_PR_OURS" MOPU_COMMENT_IDS="$TASK_COMMENT_IDS" MOPU_MAX_SUB_ISSUES="$MAX_SUB_ISSUES")

  printf '%s\n' "$body" > "$TASK_LOG/prompt-$(printf '%02d' "$TASK_CALLS")-$state.md"
  (( TASK_CALLS++ ))
  lines_before=0
  [[ -f $TASK_LOG/stream.jsonl ]] && lines_before=$(wc -l < "$TASK_LOG/stream.jsonl")
  jq -nc --arg s "$state" --arg r "$resume_id" '{type: "system", subtype: "mopu_state", state: $s, resume: $r}' >> "$TASK_LOG/stream.jsonl"
  [[ -n $resume_id ]] && log "[$TASK_ID] $state: 会話 $resume_id を再開します"
  invoke_agent "$TASK_DIR" "$TASK_LOG" "$body" "$TASK_SYS_PROMPT" "$TASK_SETTINGS" "$resume_id" "$limit" "$budget" "${env_args[@]}" || rc=$?

  # 保持期間を過ぎた会話は再開できない。この失敗は課金ゼロで即座に返るので、会話なしでやり直す
  if [[ -n $resume_id ]] && (( rc != 0 )) \
    && tail -n 5 "$TASK_LOG/stderr.log" 2>/dev/null | grep -q 'No conversation found with session ID'
  then
    warn "[$TASK_ID] 会話 $resume_id が見つかりません。新しい会話で実行します"
    checkpoint_forget "$TASK_NUMBER"
    resume_id="" base_cost=0 rc=0
    invoke_agent "$TASK_DIR" "$TASK_LOG" "$body"$'\n\n'"$TASK_MEMORY" "$TASK_SYS_PROMPT" "$TASK_SETTINGS" "" "$limit" "$budget" "${env_args[@]}" || rc=$?
  fi

  local result session_id total is_error subtype rl_status
  result=$(tail -n +"$(( lines_before + 1 ))" "$TASK_LOG/stream.jsonl" | jq -c 'select(.type == "result")' 2>/dev/null | tail -1)
  session_id=$(jq -r '.session_id // empty' <<<"$result" 2>/dev/null)
  total=$(jq -r '.total_cost_usd // 0' <<<"$result" 2>/dev/null)
  is_error=$(jq -r '.is_error // empty' <<<"$result" 2>/dev/null)
  subtype=$(jq -r '.subtype // empty' <<<"$result" 2>/dev/null)
  # 再開した会話の total_cost_usd は再開元の分を含む
  TASK_COST=$(jq -n --argjson a "$TASK_COST" --argjson t "${total:-0}" --argjson b "$base_cost" '$a + ([$t - $b, 0] | max)')

  rl_status=$(tail -n +"$(( lines_before + 1 ))" "$TASK_LOG/stream.jsonl" \
    | jq -r 'select(.type == "rate_limit_event") | .rate_limit_info.status' 2>/dev/null | tail -1)
  if [[ $rl_status == allowed_warning || $rl_status == rejected ]]; then
    warn "[$TASK_ID] レート上限イベント: $rl_status"
    # shellcheck disable=SC2034  # poll.sh のループが参照
    RATE_LIMIT_HIT=1
  fi

  if (( rc != 0 )) || [[ -z $result || $is_error == true ]]; then
    TASK_FAIL_REASON="エージェントの実行に失敗しました (exit=$rc${subtype:+, $subtype})"
    (( rc == 124 )) && TASK_FAIL_REASON="時間制限（残り ${limit} 秒）で打ち切りました"
    return 1
  fi
  if ! verify_workspace "$TASK_WT"; then
    TASK_FAIL_REASON="worktree の .git が書き換えられています"
    return 1
  fi
  local problem
  problem=$(export "${env_args[@]}"; "$MOPU_BIN" outcome-problem "$state" "$TASK_WT")
  if [[ -n $problem ]]; then
    TASK_FAIL_REASON="終える条件を満たしませんでした: $problem"
    return 1
  fi

  TASK_OUTCOME=$(jq -c . "$TASK_WT/$OUTCOME_FILE_NAME")
  rm -f "$TASK_WT/$OUTCOME_FILE_NAME"
  checkpoint_set "$session_id" "$total"
  return 0
}

# --- 本文の材料 ---

task_material() {
  {
    if [[ $TASK_KIND == comment ]]; then
      local n i
      n=$(jq '(.comments // []) | length' <<<"$TASK_JSON")
      echo "## 今回のコメント（$n 件）"
      echo
      for (( i = 0; i < n; i++ )); do
        printf '### コメント %s\n\n' "$(jq -r ".comments[$i].id" <<<"$TASK_JSON")"
        jq -r ".comments[$i].url // empty" <<<"$TASK_JSON" | sed '/^$/d;s/$/\n/'
        echo '```'
        jq -r ".comments[$i].instruction" <<<"$TASK_JSON"
        echo '```'
        echo
      done
      echo "## 背景: #$TASK_NUMBER「$TASK_TITLE」の本文"
    else
      echo "## Issue #$TASK_NUMBER「$TASK_TITLE」の本文"
    fi
    echo
    echo '```'
    printf '%s\n' "${TASK_BODY:-(本文なし)}"
    echo '```'
    if [[ $TASK_KIND == comment ]]; then
      local history
      history=$(render_history "$TASK_JSON")
      [[ -n $history ]] && printf '\n## 背景: その後のやり取り（古い順）\n\n%s\n' "$history"
    fi
  } | head -c 60000
}

pr_material() {
  [[ -n $TASK_PR ]] || return 0
  echo "## 作業先の PR #$(pr_number)"
  echo
  if (( TASK_PR_OURS )); then
    echo "mopu-agent が作った PR で、今の本文は次のとおり。"
  else
    echo "mopu-agent 以外が作った PR で、本文は次のとおり。"
  fi
  echo
  md_quote "$(jq -r '.body // ""' <<<"$TASK_PR")"
  echo
}

phase_header() {
  printf '# フェーズ: %s\n\nこのメッセージは mopu-agent からの、このフェーズの指示です。' "$1"
}

prompt_file() { cat "$AGENT_DIR/prompts/$1"; }

# --- state ---

# 作業ツリーを作る起点。チェックポイントのコミットに自分のコミットがあり、push 済みのコミットを
# 捨てずに済むならそこから、そうでなければ push 済みのブランチか、ベースから
workspace_start() {
  local cp_head remote="" base="origin/$BASE_BRANCH"
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$TASK_BRANCH" && remote="origin/$TASK_BRANCH"
  cp_head=$(jq -r '.head // empty' <<<"$(checkpoint_get)" 2>/dev/null)
  if [[ -n $cp_head ]] && git -C "$REPO_DIR" cat-file -e "$cp_head^{commit}" 2>/dev/null \
    && ! git -C "$REPO_DIR" merge-base --is-ancestor "$cp_head" "$base" \
    && { [[ -z $remote ]] || git -C "$REPO_DIR" merge-base --is-ancestor "$remote" "$cp_head"; }
  then
    printf '%s' "$cp_head"
  else
    printf '%s' "${remote:-$base}"
  fi
}

state_prepare() {
  local start
  start=$(workspace_start)
  if ! create_workspace "$TASK_BRANCH" "$TASK_DIR" "$start"; then
    TASK_FAIL_REASON="作業ツリーの準備に失敗しました。ブランチ \`$TASK_BRANCH\` が使用中でないか確認してください"
    return 1
  fi
  if [[ -n $SETUP_CMD ]]; then
    local setup_rc=0
    log "[$TASK_ID] 依存を準備します: $SETUP_CMD"
    run_setup "$TASK_WT" "$TASK_LOG/setup.log" || setup_rc=$?
    if (( setup_rc )); then
      TASK_FAIL_REASON="依存の準備コマンドが失敗しました (exit=$setup_rc$( (( setup_rc == 124 )) && printf ': %s で打ち切り' "$SETUP_TIMEOUT" ))"
      return 1
    fi
  fi
  TASK_SETTINGS="$TASK_LOG/settings.json"
  build_agent_settings "$TASK_DIR" "$TASK_SETTINGS" || { TASK_FAIL_REASON="エージェントの設定を作れませんでした"; return 1; }
  TASK_NEXT=$TASK_FIRST
}

# 入口は Issue の状態で決める。上から順に当てはめる
dispatch_entry() {
  if [[ $TASK_KIND == issue ]]; then
    printf 'triage-new'
    return
  fi
  local labels
  labels=$(gh issue view "$TASK_NUMBER" -R "$REPO" --json labels --jq '.labels[].name' 2>/dev/null)
  if grep -qxF -- "$LABEL_AWAITING" <<<"$labels"; then
    printf 'triage-plan'
  elif grep -qxF -- "$LABEL_AWAITING_INPUT" <<<"$labels"; then
    printf 'triage-reply'
  elif [[ -n $TASK_PR ]] && (( TASK_PR_OURS )); then
    printf 'triage-review'
  elif [[ -n $TASK_PR ]]; then
    printf 'triage-foreign'
  else
    printf 'triage-request'
  fi
}

state_triage() {
  local entry="${TASK_STATE#triage-}" body plan
  body=$(
    phase_header "1. 把握（$TASK_STATE）"
    printf '\n\n'
    prompt_file triage.md
    printf '\n'
    prompt_file "triage/$entry.md"
    if [[ -z $TASK_PR ]]; then
      printf '\n'
      sed "s/%%MAX_SUB_ISSUES%%/$MAX_SUB_ISSUES/g" "$AGENT_DIR/prompts/decompose.md"
    fi
    [[ $TASK_KIND == comment ]] && { printf '\n'; prompt_file replies.md; }
    printf '\n'
    task_material
    printf '\n'
    pr_material
    if [[ $entry == plan ]] && plan=$(latest_plan_comment "$TASK_NUMBER"); then
      printf '\n## 承認待ちの分解案\n\n```json\n%s\n```\n' "$(plan_from_comment "$plan")"
    fi
  )
  call_agent "$TASK_STATE" "$body" || return 1
  printf '%s\n' "$TASK_OUTCOME" > "$TASK_LOG/triage.json"

  case $(jq -r '.decision' <<<"$TASK_OUTCOME") in
    implement)
      withdraw_plan "$TASK_NUMBER"
      TASK_NEXT=implement
      ;;
    decompose)
      jq '.plan' <<<"$TASK_OUTCOME" > "$TASK_LOG/plan.json"
      withdraw_plan "$TASK_NUMBER"
      post_task_report "$(render_plan_comment "$TASK_LOG/plan.json")"
      post_replies "$TASK_OUTCOME"
      TASK_END=awaiting-approval
      TASK_END_DETAIL="分解案 $(jq '.sub_issues | length' "$TASK_LOG/plan.json") 件"
      ;;
    ask) end_with_question ;;
    answer)
      if [[ $TASK_KIND == comment ]]; then
        post_replies "$TASK_OUTCOME"
      else
        post_task_report "$(jq -r '.answer' <<<"$TASK_OUTCOME")"
      fi
      TASK_END=answered
      TASK_END_BODY=$(lead_quote "$(jq -r '.answer' <<<"$TASK_OUTCOME")")
      ;;
  esac
}

end_with_question() {
  if [[ $TASK_KIND == comment ]]; then
    post_replies "$TASK_OUTCOME" "$(answer_footer)"
  else
    post_task_report "$(jq -r '.question' <<<"$TASK_OUTCOME")"$'\n\n---\n'"$(answer_footer)"
  fi
  TASK_END=awaiting-input
  TASK_END_BODY=$(lead_quote "$(jq -r '.question' <<<"$TASK_OUTCOME")")
}

state_implement() {
  local note body
  note=$(jq -r '.note // ""' "$TASK_LOG/triage.json" 2>/dev/null)
  task_phase implement "" "${note:+$(md_quote "$note")}"
  body=$(
    phase_header "2. 実装"
    printf '\n\n'
    prompt_file implement.md
    if [[ -n $SETUP_CMD ]]; then
      local text
      text=$(prompt_file setup.md)
      printf '\n%s\n' "${text//"%%SETUP_CMD%%"/"$SETUP_CMD"}"
    fi
    if [[ $CONTAINER_CHECKS != '[]' ]]; then
      printf '\n'
      sed -e "s|%%RUN_CMD%%|$MOPU_BIN run-container|g" "$AGENT_DIR/prompts/container.md"
      jq -r '.[] | "- `\(.name)`: `\(.command)`（イメージ: `\(.image)`、作業ディレクトリ: `\(if .workdir == "" then "." else .workdir end)`、上限 \(.timeout)）"' <<<"$CONTAINER_CHECKS"
    fi
    [[ -n $note ]] && printf '\n## 把握で決めた方針\n\n%s\n' "$note"
  )
  call_agent implement "$body" || return 1
  if [[ $(jq -r '.decision' <<<"$TASK_OUTCOME") == ask ]]; then
    push_task_branch || return 1
    end_with_question
    return 0
  fi
  TASK_NEXT=verify
}

# 使い方: run_fix <本文の材料>
# 戻り値 0 で TASK_FIX に done / ask / give_up が入る
run_fix() {
  local body
  task_phase verify fix
  body=$(
    phase_header "3. 検証の修正"
    printf '\n\n'
    prompt_file fix.md
    printf '\n%s\n' "$1"
  )
  call_agent fix "$body" || return 1
  TASK_FIX=$(jq -r '.decision' <<<"$TASK_OUTCOME")
}

state_verify() {
  local ci_rounds=0 critic_rounds=0 ci review material
  printf '{}\n' > "$TASK_LOG/verify.json"
  while :; do
    refresh_app_token
    task_phase verify push
    push_task_branch || return 1
    task_phase verify ci
    wait_ci
    ci=$(jq -r '.ci.verdict' "$TASK_LOG/verify.json")

    if [[ $ci == failed ]]; then
      (( ++ci_rounds ))
      verify_update '.ci_rounds = $n' --argjson n "$ci_rounds"
      if (( ci_rounds > CI_MAX_FIX_ROUNDS )); then
        verify_end "CI が ${CI_MAX_FIX_ROUNDS} 回直しても落ちたまま: $(jq -r '.ci.detail' "$TASK_LOG/verify.json")"
        return 0
      fi
      notify_task "$TASK_LOG" "CI が落ちました（${ci_rounds}/${CI_MAX_FIX_ROUNDS} 回目）: $(jq -r '.ci.detail' "$TASK_LOG/verify.json")"
      material=$(
        echo "## CI が落ちた（${ci_rounds}/${CI_MAX_FIX_ROUNDS} 回目）"
        echo
        jq -r '.ci.runs[] | "- run \(.id)「\(.name)」: \(.conclusion)（\(.url)、コミット \(.head_sha[0:7])）"' "$TASK_LOG/verify.json"
      )
      run_fix "$material" || return 1
    elif [[ $ci == timeout ]]; then
      verify_end "$(jq -r '.ci.detail' "$TASK_LOG/verify.json")"
      return 0
    else
      task_phase verify critic
      run_critic
      review=$(jq -r '.critic.verdict' "$TASK_LOG/verify.json")
      case $review in
        approve)
          if [[ $ci == passed || $ci == skipped ]]; then
            verify_end ""
          else
            verify_end "CI 未検証: $(jq -r '.ci.detail' "$TASK_LOG/verify.json")"
          fi
          return 0
          ;;
        revise)
          (( ++critic_rounds ))
          verify_update '.critic_rounds = $n' --argjson n "$critic_rounds"
          if (( critic_rounds > CRITIC_MAX_ROUNDS )); then
            verify_end "レビュアー（critic）の指摘が ${CRITIC_MAX_ROUNDS} 回直しても残った"$'\n'"$(jq -r '.critic.reasons | map("- \(.)") | join("\n")' "$TASK_LOG/verify.json")"
            return 0
          fi
          notify_task "$TASK_LOG" "レビュアーが差し戻しました（${critic_rounds}/${CRITIC_MAX_ROUNDS} 回目）"
          material=$(
            echo "## レビュアー（critic）の差し戻し（${critic_rounds}/${CRITIC_MAX_ROUNDS} 回目）"
            echo
            echo "この会話を共有しない別のレビュアーが diff を確かめ、次の点を指摘した。"
            echo
            jq -r '.critic.reasons | map("- \(.)") | join("\n")' "$TASK_LOG/verify.json"
          )
          run_fix "$material" || return 1
          ;;
        *)
          verify_end "レビュアー（critic）が判定できなかった: $(jq -r '.critic.reasons[0] // ""' "$TASK_LOG/verify.json")"
          return 0
          ;;
      esac
    fi

    case $TASK_FIX in
      ask)
        push_task_branch || return 1
        end_with_question
        return 0
        ;;
      give_up)
        verify_end "エージェントが修正を諦めた: $(jq -r '.reason' <<<"$TASK_OUTCOME")"
        return 0
        ;;
    esac
  done
}

# 使い方: verify_end <未完了の理由（完了なら空）>
verify_end() {
  verify_update '.complete = ($r == "") | .reason = $r' --arg r "$1"
  TASK_NEXT=report
}

state_report() {
  local body verify_reason
  verify_reason=$(jq -r '.reason // ""' "$TASK_LOG/verify.json" 2>/dev/null)
  body=$(
    phase_header "4. 公開（report）"
    printf '\n\n'
    sed "s|%%BASE_BRANCH%%|$BASE_BRANCH|g" "$AGENT_DIR/prompts/report.md"
    if (( TASK_PR_OURS )); then
      printf '\n### PR テンプレート\n\n```markdown\n'
      prompt_file pr-body.md
      printf '```\n'
    else
      printf '\n作業先の PR は mopu-agent 以外が作ったものなので、PR 本文（pr_body）は書かない。\n'
    fi
    [[ $TASK_KIND == comment ]] && { printf '\n'; prompt_file replies.md; printf '\n返信が要るコメント ID: %s\n' "$TASK_COMMENT_IDS"; }
    printf '\n## 検証の結果\n\n'
    if [[ -z $verify_reason ]]; then
      echo "CI とレビュアーの確認を通った。"
    else
      echo "検証を終えられなかった。PR は draft のまま公開される。理由:"
      echo
      md_quote "$verify_reason"
      echo
    fi
    printf '\n'
    pr_material
  )
  call_agent report "$body" || return 1
  printf '%s\n' "$TASK_OUTCOME" > "$TASK_LOG/report.json"
  TASK_NEXT=publish
}

state_publish() {
  local report complete reason marker pr
  report=$(<"$TASK_LOG/report.json")
  complete=$(jq -r '.complete // false' "$TASK_LOG/verify.json")
  reason=$(jq -r '.reason // ""' "$TASK_LOG/verify.json")
  load_task_pr
  [[ -n $TASK_PR ]] || { TASK_FAIL_REASON="公開する PR が見つかりません"; return 1; }
  pr=$(pr_number)
  task_phase publish "$([[ $complete == true ]] && printf '検証済み' || printf 'draft')"

  if (( TASK_PR_OURS )); then
    gh pr edit "$pr" -R "$REPO" --body "$(pr_body_with_marker "$(jq -r '.pr_body' <<<"$report")")" >/dev/null \
      || { TASK_FAIL_REASON="PR の本文を書き換えられませんでした"; return 1; }
  fi
  if [[ $complete == true ]]; then
    if [[ $(jq -r '.isDraft' <<<"$TASK_PR") == true ]]; then
      gh pr ready "$pr" -R "$REPO" >/dev/null || { TASK_FAIL_REASON="PR を ready にできませんでした"; return 1; }
    fi
    local out
    out=$(gh pr edit "$pr" -R "$REPO" --add-reviewer "${REPO%%/*}" 2>&1) \
      || warn "[$TASK_ID] レビュアー '${REPO%%/*}' を指定できませんでした: $out"
  else
    if [[ $(jq -r '.isDraft' <<<"$TASK_PR") != true ]]; then
      gh pr ready --undo "$pr" -R "$REPO" >/dev/null 2>&1 || { TASK_FAIL_REASON="PR を draft に戻せませんでした"; return 1; }
    fi
    marker="<!-- mopu-agent:verify $(git -C "$TASK_WT" rev-parse HEAD) -->"
    if ! already_posted issue "$pr" "$marker"; then
      post_comment "$pr" "$(verify_comment "$reason")"$'\n\n'"$marker"
    fi
  fi
  post_replies "$report"

  if [[ $complete == true ]]; then
    TASK_END=review
    TASK_END_DETAIL="PR #$pr"
    TASK_END_BODY="推定 \$$(printf '%.2f' "$TASK_COST")"
  else
    TASK_FAILED_STATE=verify
    TASK_FAIL_REASON="検証を終えられなかったため、PR を draft のまま公開しました: ${reason%%$'\n'*}"
  fi
}

verify_comment() {
  printf '検証を終えられなかったため、この PR は draft のままにしています（レビューは依頼していません）。\n\n'
  md_quote "$1"
  local tests
  tests=$(jq -r '(.test_changes // [])[] | "- `\(.)`"' "$TASK_LOG/verify.json" 2>/dev/null)
  [[ -n $tests ]] && printf '\n\n**テストに関わる変更**（テストを弱めていないか確かめてください）:\n%s' "$tests"
  return 0
}

# --- タスクの始まりと終わり ---

# 使い方: run_task <kind:issue|comment> <issue番号> <タイトル> <本文>
# タスク JSON は CURRENT_TASK_JSON から読む
run_task() {
  TASK_KIND="$1" TASK_NUMBER="$2" TASK_TITLE="$3" TASK_BODY="$4" TASK_JSON="${CURRENT_TASK_JSON:-}"
  TASK_ID="${TASK_KIND}-${TASK_NUMBER}-$(date +%Y%m%d-%H%M%S)"
  TASK_BRANCH=$(task_branch "$TASK_JSON" "$TASK_NUMBER")
  TASK_DIR="$WORKTREES_DIR/$TASK_ID"
  TASK_WT=$(workspace_repo "$TASK_DIR")
  TASK_LOG="$TASK_LOGS_DIR/$TASK_ID"
  TASK_COMMENT_IDS=$(jq -r '(.comments // []) | map(.id) | join(" ")' <<<"$TASK_JSON" 2>/dev/null)
  TASK_COST=0 TASK_CALLS=0 TASK_FIX=""
  TASK_STATE="" TASK_NEXT="" TASK_OUTCOME="" TASK_FAIL_REASON="" TASK_FAILED_STATE=""
  TASK_END="" TASK_END_DETAIL="" TASK_END_BODY=""
  TASK_DEADLINE=$(( $(date +%s) + $(duration_seconds "$TASK_TIMEOUT") ))
  # shellcheck disable=SC2034  # poll.sh の同時進行ゲートが参照
  LAST_TASK_OPENED_PR=0

  load_task_pr
  TASK_ENTRY=$(dispatch_entry)
  TASK_FIRST=$TASK_ENTRY
  if (( ${RETRY:-0} )); then
    local prev failed f
    prev=$(last_task_log "$TASK_NUMBER")
    if [[ -n $prev ]] && failed=$(jq -er '.failed_state // empty' "$prev/outcome.json" 2>/dev/null); then
      TASK_ENTRY=$(jq -r --arg e "$TASK_ENTRY" '.entry // $e' "$prev/outcome.json")
      TASK_FIRST=$TASK_ENTRY
      [[ $failed == prepare ]] || TASK_FIRST=$failed
      mkdir -p "$TASK_LOG"
      for f in "${CARRY_FILES[@]}"; do
        [[ -f $prev/$f ]] && cp "$prev/$f" "$TASK_LOG/$f"
      done
      log "[$TASK_ID] 前回のタスク ${prev##*/} の $TASK_FIRST からやり直します"
    else
      warn "[$TASK_ID] やり直せる失敗が無いため、通常どおり始めます"
    fi
  fi

  mkdir -p "$TASK_LOG"
  [[ -n $TASK_JSON ]] && jq -c --arg c "$AGENT_COMMIT" '. + {commit: $c}' <<<"$TASK_JSON" > "$TASK_LOG/$TASK_FILE_NAME"

  TASK_SYS_PROMPT=$(prompt_file agent.md)
  TASK_SYS_HASH=$(sha256sum <<<"$TASK_SYS_PROMPT" | cut -c1-16)
  TASK_MEMORY=$(project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH")
  TASK_MEMORY_HASH=$(sha256sum <<<"$TASK_MEMORY" | cut -c1-16)
  if [[ -n $TASK_MEMORY ]]; then
    printf '%s\n' "$TASK_MEMORY" > "$TASK_LOG/project-memory.md"
    TASK_SYS_PROMPT+=$'\n\n'"$TASK_MEMORY"
  fi

  TASK_PCT_BEFORE="$USAGE_5H"
  [[ -z $TASK_PCT_BEFORE ]] && parse_usage "$(fetch_usage)" && TASK_PCT_BEFORE="$USAGE_5H"

  log "[$TASK_ID] 開始: #$TASK_NUMBER $TASK_TITLE（$TASK_ENTRY）"
  set_labels "$TASK_NUMBER" "$LABEL_RUNNING"

  # implement・verify・publish は、記録に添える情報を持つので state の中で記録する
  TASK_NEXT=prepare
  while [[ -n $TASK_NEXT && -z $TASK_FAILED_STATE ]]; do
    TASK_STATE=$TASK_NEXT
    TASK_NEXT=""
    case $TASK_STATE in
      implement | verify | publish) ;;
      *) task_phase "$TASK_STATE" ;;
    esac
    refresh_app_token
    "state_${TASK_STATE%%-*}" || task_failed
  done
  if [[ -z $TASK_FAILED_STATE && -z $TASK_END ]]; then
    TASK_FAIL_REASON="$TASK_STATE の後に進む state がありません"
    task_failed
  fi
  finish_task
}

# 失敗した state を記録し、その state の途中の差分をログに残して報告する
task_failed() {
  TASK_FAILED_STATE=$TASK_STATE
  err "[$TASK_ID] $TASK_STATE: $TASK_FAIL_REASON"
  if [[ -d $TASK_WT ]] && verify_workspace "$TASK_WT"; then
    {
      git -C "$TASK_WT" log --format='commit %H %s' "$(jq -r '.head // empty' <<<"$(checkpoint_get)" 2>/dev/null || true)..HEAD" 2>/dev/null
      git -C "$TASK_WT" status --short
      git -C "$TASK_WT" diff HEAD
    } > "$TASK_LOG/failed.diff" 2>/dev/null
  fi
  local body
  body=$(printf 'エージェントの作業が `%s` で止まりました。\n\n%s\n\nログ: `%s`' \
    "$TASK_STATE" "$(md_quote "$TASK_FAIL_REASON")" "$(agent_relpath "$TASK_LOG")")
  [[ -s $TASK_LOG/setup.log && $TASK_STATE == prepare ]] && body+=$'\n\n```\n'"$(tail -20 "$TASK_LOG/setup.log")"$'\n```'
  post_task_report "$body"
}

# ラベルは、タスクの終わりに待っているもので決める
finish_task() {
  local label=$LABEL_DONE spend
  if latest_plan_comment "$TASK_NUMBER" >/dev/null; then
    label=$LABEL_AWAITING
  elif [[ $TASK_END == awaiting-input ]]; then
    label=$LABEL_AWAITING_INPUT
  elif [[ -n $TASK_FAILED_STATE ]]; then
    label=$LABEL_FAILED
  fi
  set_labels "$TASK_NUMBER" "$label"

  if [[ -n $TASK_FAILED_STATE ]]; then
    task_phase failed "$TASK_FAIL_REASON"
    spend=failed
    [[ $TASK_FAILED_STATE == verify ]] && spend=draft
  else
    task_phase "$TASK_END" "$TASK_END_DETAIL" "$TASK_END_BODY"
    case $TASK_END in
      review) spend="pr" ;;
      answered) spend=no-change ;;
      awaiting-input) spend=question ;;
      awaiting-approval) spend=plan ;;
    esac
  fi
  jq -nc --argjson ok "$([[ -z $TASK_FAILED_STATE ]] && echo true || echo false)" \
    --arg reason "$TASK_FAIL_REASON" --arg failed "$TASK_FAILED_STATE" --arg entry "$TASK_ENTRY" \
    --arg end "$TASK_END" --argjson cost "$TASK_COST" \
    '{ok: $ok, entry: $entry, cost_usd: $cost}
     + (if $failed == "" then {end: $end} else {failed_state: $failed, reason: $reason} end)' > "$TASK_LOG/outcome.json"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  record_spend "$TASK_ID" "$TASK_COST" "$TASK_PCT_BEFORE" "$pct_after" "$spend"
  remove_workspace "$TASK_DIR"
  log "[$TASK_ID] 終了: ${TASK_FAILED_STATE:+失敗（$TASK_FAILED_STATE）}${TASK_END} (推定 \$$(printf '%.2f' "$TASK_COST"), 5h枠 ${TASK_PCT_BEFORE:-?}%→${pct_after:-?}%)"
  [[ -z $TASK_FAILED_STATE ]]
}
