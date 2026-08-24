#!/usr/bin/env bash

ensure_repo() {
  if [[ ! -d $REPO_DIR/.git ]]; then
    log "リポジトリを clone します: $REPO"
    gh repo clone "$REPO" "$REPO_DIR" -- --quiet || die "clone に失敗しました: $REPO"
    git -C "$REPO_DIR" remote set-url origin "https://github.com/$REPO.git"
  fi
  git -C "$REPO_DIR" fetch --quiet --prune origin || die "fetch に失敗しました"
}

# 使用中の worktree が残っていると同名ブランチを再作成できないため、
# 前回の失敗で残ったものは呼び出し側が明示的に削除する
create_worktree() {
  local branch="$1" wt="$2" base="origin/$BASE_BRANCH"
  # 同じ Issue への 2 回目以降の作業では、既存 PR のコミットを捨てないよう
  # リモートブランチがあればそちらをベースにする
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    base="origin/$branch"
    log "既存ブランチ $branch を引き継ぎます"
  fi
  git -C "$REPO_DIR" worktree add --quiet -B "$branch" "$wt" "$base" || return 1
  # サンドボックス内では HOME が差し替わり ~/.gitconfig を読めないため、
  # コミット時の identity を worktree のローカル設定として持たせる
  git -C "$wt" config user.name  "${GIT_AUTHOR_NAME:-gh-agent}"
  git -C "$wt" config user.email "${GIT_AUTHOR_EMAIL:-gh-agent@localhost}"
}

remove_worktree() {
  local wt="$1"
  [[ -d $wt ]] || return 0
  git -C "$REPO_DIR" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  git -C "$REPO_DIR" worktree prune
}

commit_subjects() {
  local wt="$1" since="$2"
  git -C "$wt" log --format='- %s' "$since..HEAD" 2>/dev/null
}
