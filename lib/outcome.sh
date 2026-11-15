#!/usr/bin/env bash

OUTCOME_FILE_NAME='.mopu-agent-outcome.json'

# 使い方: outcome_problem <state> <worktree>
# 出口ファイルと作業ツリーが、その state を終える条件を満たしていなければ、足りないものを 1 行で出す。
# 呼び出しの条件は環境変数で受け取る: MOPU_HEAD_START（呼び出し開始時の HEAD）、MOPU_HAS_PR / MOPU_PR_OURS（0 か 1）、
# MOPU_COMMENT_IDS（返信が要るコメント ID を空白区切り）、MOPU_MAX_SUB_ISSUES
outcome_problem() {
  local state="$1" wt="$2" f="$2/$OUTCOME_FILE_NAME" allowed decision head ending=0
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  case $state in
    triage-*) allowed="implement decompose ask answer" ;;
    implement) allowed="done ask" ;;
    fix) allowed="done ask give_up" ;;
    report) allowed="done" ;;
    *) printf '出口ファイルを持たない state: %s' "$state"; return ;;
  esac

  if [[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]]; then
    case $state in
      implement | fix) printf 'コミットしていない変更が残っている。git add でファイルを指定してコミットするか、不要なら元に戻す' ;;
      *) printf 'このフェーズでは作業ツリーを変更しない。変更を元に戻す' ;;
    esac
    return
  fi
  if [[ $state == triage-* || $state == report ]] && [[ $head != "${MOPU_HEAD_START:-}" ]]; then
    printf 'このフェーズではコミットしない。git reset --hard %s で戻す' "${MOPU_HEAD_START:-}"
    return
  fi

  [[ -s $f ]] || { printf '出口ファイル %s が無い' "$OUTCOME_FILE_NAME"; return; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { printf '%s が JSON のオブジェクトではない' "$OUTCOME_FILE_NAME"; return; }
  decision=$(jq -r '.decision // "" | tostring' "$f")
  [[ " $allowed " == *" $decision "* ]] \
    || { printf 'decision は %s のどれか（今は "%s"）' "${allowed// /・}" "$decision"; return; }

  local -a need=()
  case $state/$decision in
    triage-*/implement)
      need=(note)
      (( ${MOPU_HAS_PR:-0} )) || need+=(no_split_reason) ;;
    triage-*/decompose)
      (( ${MOPU_HAS_PR:-0} )) && { printf 'PR がある Issue は分解できない。implement・ask・answer から選ぶ'; return; }
      jq -e --argjson max "${MOPU_MAX_SUB_ISSUES:-5}" '
        (.plan.sub_issues | type) == "array"
        and (.plan.sub_issues | length) >= 1 and (.plan.sub_issues | length) <= $max
        and all(.plan.sub_issues[]; (.title | type) == "string" and (.title | length) > 0)' "$f" >/dev/null 2>&1 \
        || { printf 'plan.sub_issues は 1〜%s 件の配列で、各要素に空でない title が要る' "${MOPU_MAX_SUB_ISSUES:-5}"; return; }
      ending=1 ;;
    */ask) need=(question); ending=1 ;;
    */answer) need=(answer); ending=1 ;;
    */give_up) need=(reason) ;;
    implement/done | fix/done)
      [[ $head != "${MOPU_HEAD_START:-}" ]] || { printf 'コミットが無い。変更をコミットしてから done にする'; return; } ;;
    report/done)
      (( ${MOPU_PR_OURS:-0} )) && need=(pr_body)
      ending=1 ;;
  esac

  local k
  for k in "${need[@]}"; do
    jq -e --arg k "$k" '.[$k] | type == "string" and (gsub("\\s"; "") | length) > 0' "$f" >/dev/null 2>&1 \
      || { printf '%s が空' "$k"; return; }
  done

  if (( ending )) && [[ -n ${MOPU_COMMENT_IDS:-} ]]; then
    local missing
    missing=$(jq -r --arg ids "$MOPU_COMMENT_IDS" \
      '($ids | split(" ")) - ((.replies // {}) | to_entries | map(select(.value | type == "string" and length > 0) | .key)) | join(" ")' "$f" 2>/dev/null)
    [[ -z $missing ]] || { printf 'replies に次のコメントへの返信が無い: %s' "$missing"; return; }
  fi
}
