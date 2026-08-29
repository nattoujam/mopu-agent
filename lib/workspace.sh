#!/usr/bin/env bash

ensure_repo() {
  if [[ ! -d $REPO_DIR/.git ]]; then
    log "リポジトリを clone します: $REPO"
    gh repo clone "$REPO" "$REPO_DIR" -- --quiet || die "clone に失敗しました: $REPO"
    git -C "$REPO_DIR" remote set-url origin "https://github.com/$REPO.git"
  fi
  git -C "$REPO_DIR" fetch --quiet --prune origin || die "fetch に失敗しました"
}

# エージェントの cwd はタスクディレクトリで、その直下の repo/ が worktree。
# .mopu-agent-plan.json をリポジトリの外に置き、git status の結果をそのまま
# 「エージェントが変更を残したか」の判定に使えるようにする
workspace_repo() { printf '%s/%s' "$1" "$REPO_SUBDIR"; }

# 失敗したタスクの worktree は調査用に残すので、同じ Issue を再実行すると
# ブランチが使用中で worktree を作れない。残骸からブランチだけ取り上げる。
# 未コミットの変更がある場合は消さずに HEAD を切り離すだけにする
release_branch() {
  local branch="$1" holder
  holder=$(git -C "$REPO_DIR" worktree list --porcelain \
    | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} /^branch /{if ($2 == b) print w}')
  [[ -n $holder ]] || return 0

  if [[ -z $(git -C "$holder" status --porcelain 2>/dev/null) ]]; then
    log "前回の worktree を片付けます: $holder"
    remove_workspace "${holder%"/$REPO_SUBDIR"}" || return 1
  else
    warn "未コミットの変更が残るため worktree は消さず、ブランチ $branch だけ切り離します: $holder"
    git -C "$holder" checkout --quiet --detach || return 1
  fi
  git -C "$REPO_DIR" worktree prune
}

# 使い方: workspace_identity <worktree>
# コミットの identity を worktree のローカル設定に固定する。環境変数が引き継がれ
# なかった場合にホストの ~/.gitconfig が使われるのを防ぐ
workspace_identity() {
  git -C "$1" config user.name  "${GIT_AUTHOR_NAME:-mopu-agent}"
  git -C "$1" config user.email "${GIT_AUTHOR_EMAIL:-mopu-agent@localhost}"
}

# --retry 用。残っている worktree を作り直さずにそのまま使う。未コミットの
# 変更も untracked ファイルも失わずに続きから作業させるのが目的。
# release_branch で切り離されているので、ブランチを付け直す
resume_workspace() {
  local branch="$1" task_dir="$2" wt
  wt=$(workspace_repo "$task_dir")
  [[ -e $wt/.git ]] || { err "引き継げる worktree がありません: $wt"; return 1; }
  git -C "$wt" checkout --quiet -B "$branch" || return 1
  workspace_identity "$wt"
}

create_workspace() {
  local branch="$1" task_dir="$2" base="origin/$BASE_BRANCH" wt
  wt=$(workspace_repo "$task_dir")
  release_branch "$branch" || return 1
  # 同じ Issue への 2 回目以降の作業では、既存 PR のコミットを捨てないよう
  # リモートブランチがあればそちらをベースにする
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    base="origin/$branch"
    log "既存ブランチ $branch を引き継ぎます"
  fi
  mkdir -p "$task_dir" || return 1
  git -C "$REPO_DIR" worktree add --quiet -B "$branch" "$wt" "$base" || return 1
  workspace_identity "$wt"
}

remove_workspace() {
  local task_dir="$1" wt
  [[ -d $task_dir ]] || return 0
  # rm -rf に渡すため、worktrees 配下であることを必ず確かめる
  [[ $task_dir == "$AGENT_DIR/worktrees/"?* ]] || { err "想定外のパスは削除しません: $task_dir"; return 1; }
  wt=$(workspace_repo "$task_dir")
  git -C "$REPO_DIR" worktree remove --force "$wt" 2>/dev/null
  git -C "$REPO_DIR" worktree prune
  rm -rf "$task_dir"
}

commit_subjects() {
  local wt="$1" since="$2"
  git -C "$wt" log --format='- %s' "$since..HEAD" 2>/dev/null
}
