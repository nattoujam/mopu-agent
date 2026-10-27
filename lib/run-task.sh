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
  for l in "${AGENT_LABELS[@]}"; do
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
# cost_usd は会話の累計の total_cost_usd。再開した実行の total_cost_usd は再開元の
# 会話の分も含むため、そのタスクの費用を出すときに差し引く
record_session() {
  local number="$1" sid="$2" cost="${3:-0}" tmp
  [[ -n $sid && $sid != null ]] || return 0
  [[ -f $SESSION_FILE ]] || echo '{}' > "$SESSION_FILE"
  tmp="$SESSION_FILE.tmp"
  if jq --arg n "$number" --arg s "$sid" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson c "${cost:-0}" \
      '.[$n] = {session_id: $s, updated: $t, cost_usd: $c}' "$SESSION_FILE" > "$tmp" 2>/dev/null
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

session_cost_of_issue() {
  [[ -f $SESSION_FILE ]] || { echo 0; return 0; }
  jq -r --arg n "$1" '.[$n].cost_usd // 0' "$SESSION_FILE" 2>/dev/null || echo 0
}

RESUME_FILE_NAME='resume.json'

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

QUESTION_FILE_NAME='.mopu-agent-question.md'

build_system_prompt() {
  local kind="$1" branch="$2" wt="$3" decompose_off="$4" p="$AGENT_DIR/prompts" text
  {
    cat "$p/agent.md"
    [[ $kind == comment ]] && printf '\n' && cat "$p/command.md"

    printf '\n'
    sed -e "s|%%QUESTION_FILE%%|$wt/$QUESTION_FILE_NAME|g" -e "s|%%NOTE_FILE%%|$wt/$NOTE_FILE_NAME|g" "$p/triage.md"
    printf '\n'
    if [[ -n $decompose_off ]]; then
      text=$(<"$p/decompose-off.md")
      printf '%s\n' "${text//"%%REASON%%"/"$decompose_off"}"
    else
      sed -e "s/%%MAX_SUB_ISSUES%%/$MAX_SUB_ISSUES/g" -e "s|%%PLAN_FILE%%|$wt/$PLAN_FILE_NAME|g" "$p/decompose.md"
    fi

    printf '\n'
    cat "$p/implement.md"
    # SETUP_CMD は & や | を含みうるので、sed ではなく bash の置換で埋め込む
    if [[ -n $SETUP_CMD ]]; then
      text=$(<"$p/setup.md")
      printf '\n%s\n' "${text//"%%SETUP_CMD%%"/"$SETUP_CMD"}"
    fi

    printf '\n'
    sed -e "s|%%PUSH_CMD%%|$AGENT_DIR/tools/push-branch|g" -e "s|%%BRANCH%%|$branch|g" "$p/verify.md"
    if [[ $CONTAINER_CHECKS != '[]' ]]; then
      printf '\n'
      sed -e "s|%%RUN_CMD%%|$AGENT_DIR/tools/run-container|g" "$p/container.md"
      jq -r '.[] | "- `\(.name)`: `\(.command)`（イメージ: `\(.image)`、作業ディレクトリ: `\(if .workdir == "" then "." else .workdir end)`、上限 \(.timeout)）"' <<<"$CONTAINER_CHECKS"
    fi
    [[ -n $AGENT_GH_TOKEN ]] || { printf '\n'; cat "$p/no-gh.md"; }

    printf '\n'
    cat "$p/report.md"
    printf '\n```markdown\n'
    cat "$p/pr-body.md"
    printf '```\n'
    [[ $kind == comment ]] && printf '\n' && sed "s|%%REPLIES_FILE%%|$wt/$REPLIES_FILE_NAME|g" "$p/replies.md"
    return 0
  }
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
  local tools="$AGENT_DIR/tools" admin
  [[ $(<"$wt/.git") =~ ^gitdir:\ (.+)$ ]] || { err "worktree の .git を読めません: $wt"; return 1; }
  admin="${BASH_REMATCH[1]}"

  # worktree のコミットは共有の .git（repos/<slug>/.git）へ書くので、そこだけ
  # 書き込みを開ける。ただし hooks と config はホストが後で git push を実行する
  # ときに読まれる＝任意コード実行の経路なので閉じる。worktree 側の .git と、
  # 管理ディレクトリの commondir / gitdir は git が config と hooks を探す道筋で、
  # 書き換えると別の hooks を差し込めるため同様に閉じる。info/ は無視リストを持ち、
  # 書き換えると未コミットの変更を git status から隠せるため閉じる
  jq --arg wt "$wt" --arg repo_git "$REPO_DIR/.git" --arg admin "$admin" \
     --argjson secrets "$secrets_json" --arg tools "$tools" \
    'def abs: sub("^/"; "//");
     ["\($tools)/push-branch", "\($tools)/run-container *"] as $host_cmds
     | .permissions.allow = (
        ["Read(\($wt | abs)/**)", "Edit(\($wt | abs)/**)"]
        + ($host_cmds | map("Bash(\(.))")) + .permissions.allow)
     | .sandbox.excludedCommands = $host_cmds
     | .hooks.PreToolUse = [
        {matcher: "Bash", hooks: [{type: "command", command: "\($tools)/guard-host-commands"}]},
        {matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: "\($tools)/track-phase"}]}]
     | .hooks.Stop = [{hooks: [{type: "command", command: "\($tools)/ci-gate", timeout: 600}]}]
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

# 使い方: invoke_agent <タスクディレクトリ> <ログディレクトリ> <プロンプト> <システムプロンプト> <設定ファイル> <ブランチ> [再開する会話 ID]
invoke_agent() {
  local task_dir="$1" log_dir="$2" prompt="$3" sys_prompt="$4" settings="$5" branch="$6" resume_id="${7:-}"
  local -a resume_args=() schema_args=()
  [[ -n ${AGENT_JSON_SCHEMA:-} ]] && schema_args=(--json-schema "$AGENT_JSON_SCHEMA")

  # --fork-session で会話を分岐させる。元の会話をそのまま残せるので、再開した
  # 先で失敗しても同じ地点から何度でもやり直せる
  if [[ -n $resume_id ]]; then
    resume_args=(--resume "$resume_id" --fork-session)
    # 同じタスク説明が会話の中で二度目になるため、新しい依頼ではないと断っておく
    sys_prompt+=$'\n\n'"$(cat "$AGENT_DIR/prompts/resume.md")"
  fi

  (
    cd "$task_dir/$REPO_SUBDIR" || exit 1
    # sandbox.credentials は Bash の子プロセスにしか効かない（WebFetch は本体側で動く）
    unset GH_TOKEN GITHUB_TOKEN
    [[ -n ${AGENT_GH_TOKEN:-} ]] && export GH_TOKEN="$AGENT_GH_TOKEN"
    export MOPU_TASK_DIR="$task_dir" MOPU_BRANCH="$branch"
    # tools/ci-gate（Stop hook）が読む。hook は Claude Code の環境を引き継ぐ
    export MOPU_REPO="$REPO" MOPU_BASE_BRANCH="$BASE_BRANCH" MOPU_LOG_DIR="$log_dir" MOPU_HEAD_BEFORE="${GATE_HEAD_BEFORE:-}"
    # ~/.npm や ~/.cache は sandbox から書けないので、キャッシュを worktree に持たせる
    export npm_config_cache="$task_dir/$REPO_SUBDIR/.npm-cache" XDG_CACHE_HOME="$task_dir/$REPO_SUBDIR/.cache"
    # sandbox 内の Bash は prompt を経ずに自動承認されるので dontAsk に拒否されない
    timeout "$TASK_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" \
      "${resume_args[@]}" "${schema_args[@]}" \
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

ci_gate_report() {
  local f="$1/ci-gate.json" verdict detail files tests
  [[ -s $f ]] || return 0
  verdict=$(jq -r '.verdict // empty' "$f")
  detail=$(jq -r '.detail // ""' "$f")
  case $verdict in
    passed)     printf '**CI**: 通過' ;;
    failed)     printf '**CI**: 検証未通過。直しても落ちたままで、上限に達した: %s' "$detail" ;;
    unverified) printf '**CI**: 未検証（%s）' "$detail" ;;
    skipped)
      files=$(jq -r '(.files // [])[:20] | map("`\(.)`") | join(", ")' "$f")
      printf '**CI**: 対象外（%s）: %s' "$detail" "$files"
      ;;
    *) return 0 ;;
  esac
  local critic reasons
  critic=$(jq -r '.critic_verdict // empty' "$f")
  reasons=$(jq -r '(.critic_reasons // []) | map("- \(.)") | join("\n")' "$f")
  case $critic in
    approve)    printf '\n\n**レビュー（critic）**: 承認' ;;
    unresolved) printf '\n\n**レビュー（critic）**: 指摘が残ったまま上限に達した:\n%s' "$reasons" ;;
    revise)     printf '\n\n**レビュー（critic）**: 指摘に対応している途中で作業が終わった:\n%s' "$reasons" ;;
    error)      printf '\n\n**レビュー（critic）**: 確かめられなかった（%s）' "$(jq -r '(.critic_reasons // [])[0] // ""' "$f")" ;;
  esac
  tests=$(jq -r '(.test_changes // [])[] | "- `\(.)`"' "$f")
  [[ -n $tests ]] && printf '\n\n**テストに関わる変更**（テストを弱めていないか確かめてください）:\n%s' "$tests"
  return 0
}

TASK_OUTCOME_FILE=""
TASK_PHASE_FILE=""

task_phase() {
  [[ -n $TASK_PHASE_FILE ]] || return 0
  record_phase "$TASK_PHASE_FILE" "$@"
}

lead_quote() {
  [[ -n $1 ]] || return 0
  md_quote "${1%%$'\n\n'*}"
}

record_outcome() {
  [[ -n $TASK_OUTCOME_FILE ]] || return 0
  jq -nc --argjson ok "$1" --arg reason "${2:-}" \
    '{ok: $ok} + (if $reason == "" then {} else {reason: $reason} end)' > "$TASK_OUTCOME_FILE"
}

fail_task() {
  err "[$1] $2"
  record_outcome false "$2"
  task_phase failed "$2"
}

# 使い方: run_task <kind:issue|comment> <issue番号> <タイトル> <本文>
# コメントの内容と返信先は CURRENT_TASK_JSON の comments から読む
run_task() {
  local rc=0
  TASK_OUTCOME_FILE=""
  TASK_PHASE_FILE=""
  run_task_body "$@" || rc=$?
  if [[ -n $TASK_OUTCOME_FILE && ! -f $TASK_OUTCOME_FILE ]]; then
    if (( rc == 0 )); then record_outcome true; else record_outcome false "終了コード $rc で中断しました"; fi
  fi
  TASK_OUTCOME_FILE=""
  TASK_PHASE_FILE=""
  return "$rc"
}

# CI の関門と critic を抜けたか。critic が動かなかった（error）ときは、変更の問題ではないので止めない
gate_passed() {
  jq -e '(.verdict == "passed" or .verdict == "skipped")
         and ((.critic_verdict // "") | IN("revise", "unresolved") | not)' "$1/ci-gate.json" >/dev/null 2>&1
}

run_task_body() {
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
  local plan_file="$wt/$PLAN_FILE_NAME"
  local replies_file="$wt/$REPLIES_FILE_NAME"
  local question_file="$wt/$QUESTION_FILE_NAME"
  # --retry で引き継いだ作業ツリーには前回の返信と質問と方針が残っている
  rm -f "$replies_file" "$question_file" "$wt/$NOTE_FILE_NAME"
  local log_dir="$TASK_LOGS_DIR/$task_id"
  mkdir -p "$log_dir"
  TASK_OUTCOME_FILE="$log_dir/outcome.json"
  TASK_PHASE_FILE="$log_dir/$PHASE_FILE_NAME"
  [[ -n ${CURRENT_TASK_JSON:-} ]] \
    && jq -c --arg c "$AGENT_COMMIT" '. + {commit: $c}' <<<"$CURRENT_TASK_JSON" \
      > "$log_dir/$TASK_FILE_NAME"
  task_phase prepare

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
    fail_task "$task_id" "worktree の準備に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_report "エージェントの作業ツリー準備に失敗しました。ブランチ \`$branch\` が使用中でないか確認してください。"
    return 1
  fi

  if [[ -n $SETUP_CMD ]]; then
    local setup_log="$log_dir/setup.log" setup_rc=0
    log "[$task_id] 依存を準備します: $SETUP_CMD"
    run_setup "$wt" "$setup_log" || setup_rc=$?
    if (( setup_rc )); then
      fail_task "$task_id" "依存の準備に失敗しました (exit=$setup_rc)"
      [[ -s $setup_log ]] && warn "$(tail -20 "$setup_log")"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf '依存の準備コマンドが失敗しました (exit=%s%s)。\n\n```\n%s\n```\n\n```\n%s\n```\n\nログ: `%s`' \
        "$setup_rc" "$( (( setup_rc == 124 )) && printf ': %s で打ち切り' "$SETUP_TIMEOUT" )" \
        "$SETUP_CMD" "$(tail -20 "$setup_log")" "$(agent_relpath "$setup_log")")"
      log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
      return 1
    fi
  fi

  AGENT_GH_TOKEN=""
  if use_github_app; then
    AGENT_GH_TOKEN=$(app_token_with "$AGENT_TOKEN_PERMISSIONS") \
      || warn "[$task_id] エージェント用トークンを取得できません。App に Actions: Read を付与すると CI の結果を読めます"
  fi

  # 再開時にタスク分解へ逸れると、やりかけの変更が宙に浮く
  local no_decompose=0 decompose_off=""
  if [[ -n $prev_dir ]]; then
    no_decompose=1
    decompose_off="これは中断したタスクの再開なので、残っている作業を仕上げる。"
  elif is_sub_issue "$number" "$body"; then
    no_decompose=1
    decompose_off="この Issue は既に分解されたタスクの一部なので、"
  fi

  local sys_prompt memory
  sys_prompt=$(build_system_prompt "$kind" "$branch" "$wt" "$decompose_off")
  memory=$(project_memory_prompt "$REPO_DIR" "origin/$BASE_BRANCH")
  if [[ -n $memory ]]; then
    sys_prompt+=$'\n\n'"$memory"
    printf '%s\n' "$memory" > "$log_dir/project-memory.md"
    log "[$task_id] 対象リポジトリの指示を ${#memory} 文字足します: $(agent_relpath "$log_dir/project-memory.md")"
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
  GATE_HEAD_BEFORE="$head_before"

  # 前回の会話を引き継ぐ条件。--retry は中断したタスクの再開、コメントは自分が
  # 出した PR へのレビュー対応で、どちらも前回の続きになる
  local resume_id="" resume_file="$log_dir/$RESUME_FILE_NAME"
  if (( ${RETRY:-0} )) || [[ $kind == comment ]]; then
    resume_id=$(session_of_issue "$number")
    if [[ -n $resume_id ]]; then
      log "[$task_id] 前回の会話を再開します: $resume_id"
      jq -nc --arg s "$resume_id" --argjson c "$(session_cost_of_issue "$number")" \
        '{session_id: $s, base_cost_usd: $c}' > "$resume_file"
    fi
  fi

  local rc=0
  task_phase triage
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
    rm -f "$resume_file"
    rc=0
    invoke_agent "$task_dir" "$log_dir" "$prompt" "$sys_prompt" "$settings" "$branch" "" || rc=$?
  fi

  local result is_error session_cost cost
  result=$(last_result "$log_dir/stream.jsonl")
  is_error=$(jq -r 'select(.type=="result") | .is_error' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  session_cost=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  cost=$(jq -rn --argjson c "${session_cost:-0}" --argjson b "$(jq '.base_cost_usd // 0' "$resume_file" 2>/dev/null || echo 0)" \
    '[$c - $b, 0] | max')
  # critic は別の claude -p なので、エージェントの total_cost_usd にも --max-budget-usd にも入らない
  [[ -s $log_dir/ci-gate.json ]] \
    && cost=$(jq -r --argjson c "${cost:-0}" '$c + (.critic_cost_usd // 0)' "$log_dir/ci-gate.json")

  local subtype session_id
  subtype=$(jq -r 'select(.type=="result") | .subtype' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)
  session_id=$(jq -r 'select(.type=="result") | .session_id // empty' "$log_dir/stream.jsonl" 2>/dev/null | tail -1)

  # 打ち切りで終わった会話を引き継ぐと、膨らんだ context のまま再開して同じ壁に
  # ぶつかる。timeout(1) の 124 と --max-budget-usd による打ち切りがこれにあたる
  if (( rc == 124 )) || [[ $subtype == error_max_budget_usd ]]; then
    warn "[$task_id] 打ち切りで終わったため、この会話は引き継ぎません (${subtype:-timeout})"
    forget_session "$number"
  else
    record_session "$number" "$session_id" "$session_cost"
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
    fail_task "$task_id" "エージェントの実行に失敗しました (exit=$rc, is_error=$is_error)"
    local detail
    detail=$(tail -20 "$log_dir/stderr.log")
    set_labels "$number" "$LABEL_FAILED"
    post_report "$(printf 'エージェントの実行に失敗しました (exit=%s)。\n\n%s\n\n```\n%s\n```\n\nログ: `%s`' \
      "$rc" "${result:-}" "${detail:-（stderr なし）}" "$(agent_relpath "$log_dir")")"
    record_spend "$task_id" "$cost" "$pct_before" "" failed
    log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
    return 1
  fi

  if ! verify_workspace "$wt"; then
    fail_task "$task_id" "worktree の .git が書き換えられています"
    set_labels "$number" "$LABEL_FAILED"
    post_report "$(printf 'worktree の `.git` が書き換えられていたため、push せずに止めました。\n\nworktree: `%s`' "$(agent_relpath "$wt")")"
    record_spend "$task_id" "$cost" "$pct_before" "" failed
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

  if [[ -s $question_file ]]; then
    ask_user "$task_id" "$number" "$question_file" "$wt" "$branch" "$head_before" "$cost" "$pct_before" "$task_dir"
    return $?
  fi

  if [[ $(git -C "$wt" rev-parse HEAD) == "$head_before" ]]; then
    if [[ -n $(git -C "$wt" status --porcelain) ]]; then
      fail_task "$task_id" "コミットされていない変更が残っています"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf '%s\n\nコミットに失敗した可能性があります。作業ツリーに未コミットの変更が残っているため保全しました。\n\nworktree: `%s`' \
        "${result:-（応答なし）}" "$(agent_relpath "$wt")")"
      record_spend "$task_id" "$cost" "$pct_before" "" failed
      log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
      return 1
    fi

    log "[$task_id] コード変更なし。結果のみコメントします"
    if [[ -n $pending_plan ]]; then
      task_phase awaiting-approval
      set_labels "$number" "$LABEL_AWAITING"
    else
      task_phase answered "" "$(lead_quote "$result")"
      set_labels "$number" "$LABEL_DONE"
    fi
    post_replies "${CURRENT_TASK_JSON:-}" "$replies_file" "${result:-（応答なし）}" ""
    record_spend "$task_id" "$cost" "$pct_before" "" no-change
    remove_workspace "$task_dir"
    return 0
  fi

  log "[$task_id] push します: $branch"
  if ! push_workspace "$wt" "$branch"; then
    fail_task "$task_id" "push に失敗しました"
    set_labels "$number" "$LABEL_FAILED"
    post_report "作業は完了しましたが push に失敗しました。worktree: \`$(agent_relpath "$wt")\`"
    record_spend "$task_id" "$cost" "$pct_before" "" failed
    return 1
  fi

  # PR は検証を通るまで draft にしておき、通ったときだけ ready にしてレビューを依頼する。
  # draft は tools/push-branch が最初の push で作った仮の PR なので、本文を結果で書き換える。
  # 既に ready の PR（コメントからの追加コミット）は本文を変えず、検証を通らなければ draft に戻す
  local reviewed=""
  [[ $(jq -r '.critic_verdict // empty' "$log_dir/ci-gate.json" 2>/dev/null) == approve ]] && reviewed="レビュアー承認"
  task_phase publish "$reviewed"
  local pr_url pr_out pr_created=0 pr_draft gate pr_body passed=0 ok=1
  gate_passed "$log_dir" && passed=1
  gate=$(ci_gate_report "$log_dir")
  pr_body=$(printf 'Closes #%s\n\n%s\n\n%s---\n%s' "$number" "$result" "${gate:+$gate$'\n\n'}" "$COMMENT_MARKER")
  pr_url=$(gh pr view "$branch" -R "$REPO" --json url --jq .url 2>/dev/null)
  pr_draft=$(gh pr view "$branch" -R "$REPO" --json isDraft --jq .isDraft 2>/dev/null)
  if [[ -n $pr_url && $pr_draft == true ]]; then
    if gh pr edit "$branch" -R "$REPO" --body "$pr_body" >/dev/null; then
      pr_created=1
    else
      warn "[$task_id] draft PR の本文を書き換えられませんでした: $pr_url"
    fi
    if (( passed )); then
      if gh pr ready "$branch" -R "$REPO" >/dev/null; then
        request_review "$task_id" "$branch"
      else
        warn "[$task_id] draft PR を出せませんでした: $pr_url"
        ok=0
      fi
    fi
  elif [[ -n $pr_url ]]; then
    if (( ! passed )) && ! gh pr ready --undo "$branch" -R "$REPO" >/dev/null 2>&1; then
      warn "[$task_id] 検証を通らなかった PR を draft に戻せませんでした: $pr_url"
    fi
  else
    local -a draft_args=()
    (( passed )) || draft_args=(--draft)
    if pr_out=$(gh pr create -R "$REPO" "${draft_args[@]}" \
      --base "$BASE_BRANCH" --head "$branch" \
      --title "$title" \
      --body "$pr_body" 2>&1)
    then
      pr_url=$(grep -oE 'https://[^ ]+/pull/[0-9]+' <<<"$pr_out" | tail -1)
      pr_created=1
      (( passed )) && request_review "$task_id" "$branch"
    else
      fail_task "$task_id" "PR の作成に失敗しました: $pr_out"
      set_labels "$number" "$LABEL_FAILED"
      post_report "$(printf 'ブランチ `%s` は push 済みですが、PR の作成に失敗しました。\n\n```\n%s\n```' "$branch" "$pr_out")"
      record_spend "$task_id" "$cost" "$pct_before" "" failed
      return 1
    fi
  fi

  # shellcheck disable=SC2034  # poll.sh の同時進行ゲートが参照
  LAST_TASK_OPENED_PR=1

  local headline brief
  if (( passed && ok )); then
    brief=$(lead_quote "$result")
    task_phase review "PR #${pr_url##*/}" "推定 \$$(printf '%.2f' "$cost")${brief:+$'\n'$brief}"
    set_labels "$number" "$LABEL_DONE"
    headline=$( (( pr_created )) && printf 'PR を作成しました' || printf 'PR を更新しました' )
  else
    fail_task "$task_id" "検証を通らなかったため、PR を draft のまま止めました"
    set_labels "$number" "$LABEL_FAILED"
    headline='検証を通らなかったため、PR を draft のまま止めました（レビューは依頼していません）'
  fi
  # 新規作成なら変更内容の説明は PR 本文（$result）に載る。既存 PR への追加
  # コミットでは PR 本文が書き換わらないため、返信に含めないと応答が消える
  local summary fallback=""
  (( pr_created )) || fallback="${result:-（応答なし）}"
  local gate_block=""
  [[ -n $gate ]] && gate_block="$gate"$'\n\n'
  summary=$(printf '%s: %s\n\n**コミット**:\n%s\n\n%s推定コスト: $%s' \
    "$headline" "$pr_url" "$(commit_subjects "$wt" "$head_before")" "$gate_block" "$(printf '%.2f' "$cost")")
  post_replies "${CURRENT_TASK_JSON:-}" "$replies_file" "$fallback" "$summary"

  local pct_after=""
  parse_usage "$(fetch_usage)" && pct_after="$USAGE_5H"
  if (( passed && ok )); then
    record_spend "$task_id" "$cost" "$pct_before" "$pct_after" pr
    remove_workspace "$task_dir"
    log "[$task_id] 完了: $pr_url (推定 \$$(printf '%.2f' "$cost"), 5h枠 ${pct_before:-?}%→${pct_after:-?}%)"
    return 0
  fi
  record_spend "$task_id" "$cost" "$pct_before" "$pct_after" draft
  log "[$task_id] 作業ディレクトリを調査用に残します: $task_dir"
  return 1
}

# 実装の途中で聞いた場合のコミットは、回答を受けた次の実行が引き継げるよう push しておく
ask_user() {
  local task_id="$1" number="$2" question="$3" wt="$4" branch="$5" head_before="$6" cost="$7" pct_before="$8" task_dir="$9"
  local keep=0
  if [[ $(git -C "$wt" rev-parse HEAD) != "$head_before" ]] && ! push_workspace "$wt" "$branch"; then
    warn "[$task_id] 質問の前のコミットを push できませんでした"
    keep=1
  fi
  [[ -n $(git -C "$wt" status --porcelain) ]] && keep=1

  log "[$task_id] ユーザーに質問し、回答を待ちます"
  task_phase awaiting-input "" "$(lead_quote "$(<"$question")")"
  set_labels "$number" "$LABEL_AWAITING_INPUT"
  post_report "$(printf '%s\n\n---\n回答は、行頭に `%s` を付けてコメントしてください。' "$(<"$question")" "$TRIGGER_COMMAND")"
  record_spend "$task_id" "$cost" "$pct_before" "" question
  if (( keep )); then
    log "[$task_id] push していない変更があるため、作業ディレクトリを残します: $task_dir"
  else
    remove_workspace "$task_dir"
  fi
  return 0
}
