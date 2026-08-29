#!/usr/bin/env bash

# /usage はローカルコマンドとして処理され API 呼び出しを伴わない（実測: num_turns=0,
# total_cost_usd=0, 約1.8秒）。そのためタスクごとに呼び直しても枠を消費しない。
fetch_usage() {
  timeout 60 "$CLAUDE_BIN" -p "/usage" \
    --output-format json \
    --setting-sources '' \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --permission-mode dontAsk 2>/dev/null \
    | jq -r '.result // empty' 2>/dev/null
}

USAGE_5H="" USAGE_7D="" USAGE_5H_RESET="" USAGE_7D_RESET=""

parse_usage() {
  local text="$1"
  USAGE_5H=$(sed -n 's/^Current session: \([0-9]\+\)% used.*/\1/p' <<<"$text" | head -1)
  USAGE_7D=$(sed -n 's/^Current week (all models): \([0-9]\+\)% used.*/\1/p' <<<"$text" | head -1)
  USAGE_5H_RESET=$(sed -n 's/^Current session: [0-9]\+% used · resets \(.*\)$/\1/p' <<<"$text" | head -1)
  USAGE_7D_RESET=$(sed -n 's/^Current week (all models): [0-9]\+% used · resets \(.*\)$/\1/p' <<<"$text" | head -1)
  [[ -n $USAGE_5H && -n $USAGE_7D ]]
}

# 0: 実行してよい / 1: 枠が閾値を超えている / 2: 使用率を取得できなかった
check_budget() {
  local text
  text=$(fetch_usage)

  if [[ -z $text ]] || ! parse_usage "$text"; then
    warn "/usage の出力を解釈できませんでした。安全側に倒して起動しません（--ignore-budget で上書き可）"
    [[ -n $text ]] && printf '%s\n' "$text" | head -5 >&2
    return 2
  fi

  log "利用枠: 5h=${USAGE_5H}% (閾値 ${MAX_5H_PERCENT}%) / 7d=${USAGE_7D}% (閾値 ${MAX_7D_PERCENT}%)"

  if (( USAGE_5H >= MAX_5H_PERCENT )); then
    warn "5時間枠が ${USAGE_5H}% に達しています。resets ${USAGE_5H_RESET:-不明} 以降に再実行してください"
    return 1
  fi
  if (( USAGE_7D >= MAX_7D_PERCENT )); then
    warn "週次枠が ${USAGE_7D}% に達しています。resets ${USAGE_7D_RESET:-不明} 以降に再実行してください"
    return 1
  fi
  return 0
}

record_spend() {
  local task_id="$1" cost="$2" before="$3" after="$4"
  jq -nc --arg t "$(date -Is)" --arg id "$task_id" \
     --argjson cost "${cost:-0}" \
     --arg before "$before" --arg after "$after" \
     '{time:$t, task:$id, cost_usd:$cost, pct_5h_before:$before, pct_5h_after:$after}' \
     >> "$SPEND_FILE"
}
