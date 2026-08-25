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
# サンドボックスは認証情報の読み取りを塞ぐため cwd に .env や package.json の
# 0 バイトのファイルを作るので、cwd をリポジトリの外に置いて巻き込まれないようにする
workspace_repo() { printf '%s/%s' "$1" "$REPO_SUBDIR"; }

# 使用中の worktree が残っていると同名ブランチを再作成できないため、
# 前回の失敗で残ったものは呼び出し側が明示的に削除する
create_workspace() {
  local branch="$1" task_dir="$2" base="origin/$BASE_BRANCH" wt
  wt=$(workspace_repo "$task_dir")
  # 同じ Issue への 2 回目以降の作業では、既存 PR のコミットを捨てないよう
  # リモートブランチがあればそちらをベースにする
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    base="origin/$branch"
    log "既存ブランチ $branch を引き継ぎます"
  fi
  mkdir -p "$task_dir" || return 1
  git -C "$REPO_DIR" worktree add --quiet -B "$branch" "$wt" "$base" || return 1
  # サンドボックス内では HOME が差し替わり ~/.gitconfig を読めないため、
  # コミット時の identity を worktree のローカル設定として持たせる
  git -C "$wt" config user.name  "${GIT_AUTHOR_NAME:-gh-agent}"
  git -C "$wt" config user.email "${GIT_AUTHOR_EMAIL:-gh-agent@localhost}"
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
