#!/usr/bin/env bash

# エージェントは --setting-sources '' で起動するので、Claude Code 自身は対象リポジトリの
# CLAUDE.md も .claude/rules/ も読まない。ここで origin の版を読んでシステムプロンプトに足す。
# worktree の版を読まないのは、エージェントが PR の中で書き換えた基準を次の周回に効かせないため

PROJECT_MEMORY_MAX_CHARS=60000
# Claude Code の @ の取り込みと同じ深さ
PROJECT_MEMORY_MAX_DEPTH=4

pm_normalize() {
  local -a parts out=()
  local part
  IFS=/ read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    case $part in
      ''|.) ;;
      ..) (( ${#out[@]} )) || return 1; unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  (( ${#out[@]} )) || return 1
  local IFS=/
  printf '%s' "${out[*]}"
}

# Claude Code はコードブロックとインラインコードの中の @ を取り込みとして扱わないため、そこは除く
pm_imports() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /(^|[[:space:]])@[^[:space:]]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^[[:space:]]*@/, "", tok)
        print tok
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

pm_rule_paths() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    /^paths:[[:space:]]*$/ { inlist = 1; next }
    /^paths:/ { v = $0; sub(/^paths:[[:space:]]*/, "", v); gsub(/[][]/, "", v); print v; exit }
    inlist && /^[[:space:]]*-[[:space:]]*/ { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); out = out (out == "" ? "" : ", ") v; next }
    inlist { inlist = 0 }
    END { if (out != "") print out }' | tr -d "\"'"
}

# Claude Code はブロック単位の HTML コメントを人間向けのメモとして読み込まないため、同じく除く
pm_strip_comments() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence }
    !fence && !incomment && /^[[:space:]]*<!--/ { incomment = 1 }
    incomment { if ($0 ~ /-->[[:space:]]*$/) incomment = 0; next }
    { print }'
}

pm_strip_frontmatter() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm'
}

# project_memory_prompt の local の pm_out / pm_seen / pm_skipped を書き換えるため、その中からしか呼べない
pm_add_section() {
  local header="$1" body="$2" section
  section=$(printf '### %s\n\n%s\n' "$header" "$body")
  if (( ${#pm_out} + ${#section} > PROJECT_MEMORY_MAX_CHARS )); then
    pm_skipped+=("${header%%（*}")
    return 0
  fi
  pm_out+=$'\n\n'"$section"
}

pm_load() {
  local gitdir="$1" ref="$2" path="$3" header="$4" depth="$5" body tok target dir
  [[ -n ${pm_seen[$path]:-} ]] && return 0
  pm_seen[$path]=1
  body=$(git -C "$gitdir" show "$ref:$path" 2>/dev/null | pm_strip_comments) || return 0
  pm_add_section "$header" "$body"
  (( depth < PROJECT_MEMORY_MAX_DEPTH )) || return 0
  dir=$(dirname -- "$path")
  [[ $dir == . ]] && dir=""
  while IFS= read -r tok; do
    # ホストのファイルをプロンプトに載せないよう、リポジトリの中を指す相対パスだけを展開する
    [[ $tok == /* || $tok == '~'* || $tok == *://* ]] && continue
    while [[ $tok == *[\)\]\}.,\;:!?。、」』）] ]]; do tok="${tok%?}"; done
    target=$(pm_normalize "${dir:+$dir/}$tok") || continue
    git -C "$gitdir" cat-file -e "$ref:$target" 2>/dev/null || continue
    pm_load "$gitdir" "$ref" "$target" "$target（$path から取り込み）" $(( depth + 1 ))
  done < <(pm_imports <<<"$body")
}

project_memory_prompt() {
  local gitdir="$1" ref="$2" pm_out="" path scope root_found=0
  local -A pm_seen=()
  local -a pm_skipped=() files

  for path in CLAUDE.md .claude/CLAUDE.md; do
    git -C "$gitdir" cat-file -e "$ref:$path" 2>/dev/null || continue
    root_found=1
    pm_load "$gitdir" "$ref" "$path" "$path" 0
  done
  # Claude Code は CLAUDE.md が無いときだけ AGENTS.md を読む
  if (( ! root_found )) && git -C "$gitdir" cat-file -e "$ref:AGENTS.md" 2>/dev/null; then
    pm_load "$gitdir" "$ref" AGENTS.md AGENTS.md 0
  fi

  mapfile -t files < <(git -C "$gitdir" ls-tree -r --name-only "$ref" -- .claude/rules 2>/dev/null | grep '\.md$')
  for path in "${files[@]}"; do
    [[ -n ${pm_seen[$path]:-} ]] && continue
    pm_seen[$path]=1
    scope=$(git -C "$gitdir" show "$ref:$path" | pm_rule_paths)
    pm_add_section "$path${scope:+（適用範囲: $scope）}" "$(git -C "$gitdir" show "$ref:$path" | pm_strip_frontmatter | pm_strip_comments)"
  done

  mapfile -t files < <(git -C "$gitdir" ls-tree -r --name-only "$ref" | grep -E '(^|/)CLAUDE\.md$' | grep -vxE 'CLAUDE\.md|\.claude/CLAUDE\.md')
  for path in "${files[@]}"; do
    pm_load "$gitdir" "$ref" "$path" "$path（適用範囲: $(dirname -- "$path")/**）" 0
  done

  [[ -n $pm_out ]] || return 0
  sed -e "s|%%REF%%|$ref|g" "$AGENT_DIR/prompts/project-memory.md"
  printf '%s\n' "$pm_out"
  (( ${#pm_skipped[@]} )) && printf '\n（%s 文字の上限を超えたため、次は載せていない。必要なら作業ツリーで読むこと: %s）\n' \
    "$PROJECT_MEMORY_MAX_CHARS" "${pm_skipped[*]}"
  return 0
}
