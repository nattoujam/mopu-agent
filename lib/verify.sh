#!/usr/bin/env bash
# 検証フェーズのうち、コードが行う push・CI 待ち・critic。結果はタスクのログの verify.json に書く

CI_MAX_FIX_ROUNDS=5
CRITIC_MAX_ROUNDS=2
CI_START_WAIT=180
CI_POLL_SECONDS=20

# 使い方: verify_update <jq の式> [jq の引数 ...]
verify_update() {
  local f="$TASK_LOG/verify.json" expr="$1"
  shift
  [[ -s $f ]] || printf '{}\n' > "$f"
  jq "$@" "$expr" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# HEAD を push し、PR が無ければ draft PR を作る。PR を作ったときだけ、Issue にそのことを知らせる
push_task_branch() {
  if ! push_workspace "$TASK_WT" "$TASK_BRANCH"; then
    TASK_FAIL_REASON="push に失敗しました"
    return 1
  fi
  [[ -n $TASK_PR ]] && return 0

  local out reason notice
  if ! out=$(gh pr create -R "$REPO" --draft --base "$BASE_BRANCH" --head "$TASK_BRANCH" --title "$TASK_TITLE" \
      --body "$(pr_body_with_marker "エージェントが作業中です。作業が終わると、この本文を対応内容で置き換えます。")" 2>&1); then
    TASK_FAIL_REASON="draft PR を作れませんでした: $(tail -1 <<<"$out")"
    return 1
  fi
  load_task_pr
  [[ -n $TASK_PR ]] || { TASK_FAIL_REASON="作った draft PR を読めませんでした"; return 1; }
  # shellcheck disable=SC2034  # poll.sh の同時進行ゲートが参照
  LAST_TASK_OPENED_PR=1
  log "[$TASK_ID] draft PR を作りました: $(jq -r '.url' <<<"$TASK_PR")"

  reason=$(jq -r '.no_split_reason // ""' "$TASK_LOG/triage.json" 2>/dev/null)
  notice="PR #$(pr_number) を作りました。以降の報告は PR に書きます。"
  [[ -n $reason ]] && notice+=$'\n\n'"分解しない理由: $reason"
  post_comment "$TASK_NUMBER" "$notice"
}

ci_result() {
  verify_update '.ci = {verdict: $v, detail: $d, runs: $r}' --arg v "$1" --arg d "$2" --argjson r "${3:-[]}"
}

# HEAD のコミットの CI を、すべて終わるかタスクの時間制限まで待つ。
# verdict: passed / failed / skipped（変更にかかる CI が無い）/ unverified / timeout
wait_ci() {
  local head ref="origin/$BASE_BRANCH" inspect runs started now failed
  head=$(git -C "$TASK_WT" rev-parse HEAD)
  if git -C "$TASK_WT" log --format=%B "$ref..HEAD" 2>/dev/null \
      | grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|^skip-checks: *true'; then
    ci_result unverified "コミットメッセージで CI を飛ばしている"
    return
  fi
  if ! inspect=$(node "$AGENT_DIR/lib/ci-gate.ts" inspect "$TASK_WT" "$ref" "$BASE_BRANCH" 2>/dev/null); then
    ci_result unverified "CI が動くかを判定できなかった"
    return
  fi
  verify_update '.test_changes = $i.test_changes | .files = $i.files' --argjson i "$inspect"
  if [[ $(jq -r '.ci' <<<"$inspect") == skips ]]; then
    ci_result skipped "変更したファイルにかかる CI が無い"
    return
  fi

  started=$(date +%s)
  while :; do
    runs=$(gh api "repos/$REPO/actions/runs?head_sha=$head&per_page=100" \
      --jq '[.workflow_runs[] | select(.event == "pull_request" or .event == "pull_request_target" or .event == "push")
             | {id, name, status, conclusion, url: .html_url, head_sha}]' 2>/dev/null) || runs='[]'
    now=$(date +%s)
    if [[ $(jq 'length' <<<"$runs") != 0 ]]; then
      jq -e 'all(.[]; .status == "completed")' <<<"$runs" >/dev/null && break
    elif (( now - started >= CI_START_WAIT )); then
      ci_result unverified "push から $CI_START_WAIT 秒待っても CI が起動しなかった"
      return
    fi
    if (( now + CI_POLL_SECONDS >= TASK_DEADLINE )); then
      ci_result timeout "タスクの時間制限（$TASK_TIMEOUT）までに CI が終わらなかった" "$runs"
      return
    fi
    sleep "$CI_POLL_SECONDS"
  done

  failed=$(jq -c '[.[] | select(.conclusion as $c | ["success", "skipped", "neutral"] | index($c) | not)]' <<<"$runs")
  if [[ $failed == '[]' ]]; then
    ci_result passed "$(jq -r 'map(.name) | unique | join("、")' <<<"$runs")" "$runs"
  else
    ci_result failed "$(jq -r 'map("\(.name)（run \(.id)、\(.conclusion)）") | join("、")' <<<"$failed")" "$failed"
  fi
}

# 変更を書いた会話を共有しない critic に確かめさせる
run_critic() {
  local out
  out=$(MOPU_TASK_DIR="$TASK_DIR" MOPU_BASE_BRANCH="$BASE_BRANCH" MOPU_LOG_DIR="$TASK_LOG" "$AGENT_DIR/tools/critic")
  jq -e '.verdict' <<<"$out" >/dev/null 2>&1 || out='{"verdict":"error","reasons":["critic の出力を読めなかった"],"cost_usd":0}'
  verify_update '.critic = $o' --argjson o "$out"
  TASK_COST=$(jq -n --argjson a "$TASK_COST" --argjson c "$(jq '.cost_usd // 0' <<<"$out")" '$a + $c')
}
