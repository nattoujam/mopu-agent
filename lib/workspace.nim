import std/[os, strutils]
import config, github_app, log, outcome, paths, process

# Claude Code の sandbox が、まだないファイルへの書き込みを禁じるために置くもの。
# sandbox の中では /dev/null に見え、未追跡のまま残すと git add -A が丸ごと失敗する。
# セッションが殺されると 0 バイトのファイルとしてホストに残り、git status にも出る
const SandboxPlaceholders* = [
  "/.bash_profile", "/.bashrc", "/.profile", "/.zprofile", "/.zshrc",
  "/.gitconfig", "/.gitmodules", "/.ripgreprc", "/.mcp.json", "/.idea", "/.vscode",
  "/.claude/agents", "/.claude/commands", "/.claude/hooks", "/.claude/launch.json", "/.claude/loop.md",
  "/.claude/output-styles", "/.claude/routines", "/.claude/scheduled_tasks.json",
  "/.claude/settings.json", "/.claude/settings.local.json", "/.claude/skills", "/.claude/workflows",
]

proc readTrimmed(path: string): string =
  readFile(path).strip(leading = false, chars = {'\n'})

proc realPath(path: string): string =
  try: expandFilename(path) except OSError: ""

# worktree の .git と、それが指す管理ディレクトリが git の作ったままかを確かめる。
# コンテナからは worktree を rename して偽の .git を置けるうえ、管理ディレクトリの
# commondir は sandbox から書けるため、ホストが git を実行する前に通すこと
proc verifyWorkspace*(wt, repoDir: string): bool =
  let dotGit = wt / ".git"
  if not dirExists(wt) or symlinkExists(wt) or not fileExists(dotGit) or symlinkExists(dotGit):
    return false
  let real = realPath(wt)
  let repoReal = realPath(repoDir)
  if real.len == 0 or repoReal.len == 0:
    return false
  let link = readTrimmed(dotGit)
  if not link.startsWith("gitdir: ") or link.len == "gitdir: ".len:
    return false
  let admin = link["gitdir: ".len .. ^1]
  let prefix = repoReal & "/.git/worktrees/"
  if not admin.startsWith(prefix) or '/' in admin[prefix.len .. ^1]:
    return false
  let gitdir = admin / "gitdir"
  let commondir = admin / "commondir"
  fileExists(gitdir) and not symlinkExists(gitdir) and readTrimmed(gitdir) == real & "/.git" and
    fileExists(commondir) and not symlinkExists(commondir) and readTrimmed(commondir) == "../.."

# 出口ファイルとキャッシュは worktree の中に置くが、git status を
# 「エージェントが変更を残したか」の判定に使うため、git からは見えなくする
proc ensureExcludes(cfg: Config) =
  let f = cfg.repoDir / ".git" / "info" / "exclude"
  createDir(f.parentDir)
  var lines = (if fileExists(f): readFile(f) else: "").splitLines
  var add = ""
  for p in @["/" & outcomeFileName, "/.npm-cache/", "/.cache/"] & @SandboxPlaceholders:
    if p notin lines:
      add.add p & "\n"
      lines.add p
  if add.len > 0:
    let h = open(f, fmAppend)
    h.write add
    h.close()

proc ensureRepo*(cfg: Config) =
  if not dirExists(cfg.repoDir / ".git"):
    log "リポジトリを clone します: " & cfg.repo
    if run(@["gh", "repo", "clone", cfg.repo, cfg.repoDir, "--", "--quiet"]) != 0:
      die "clone に失敗しました: " & cfg.repo
    discard gitRun(cfg.repoDir, "remote", "set-url", "origin", "https://github.com/" & cfg.repo & ".git")
  if run(@["git", "-C", cfg.repoDir, "fetch", "--quiet", "--prune", "origin"]) != 0:
    die "fetch に失敗しました"
  ensureExcludes(cfg)

proc runSetup*(cfg: Config, wt, output: string): int =
  if cfg.setupCmd.len == 0:
    return 0
  run(@["timeout", cfg.setupTimeout, "bash", "-c", cfg.setupCmd],
      SpawnOptions(stdout: Output(path: output), stderrToStdout: true, cwd: wt))

# worktree はタスクディレクトリの直下の repo/ に置く。sandbox からはタスクディレクトリに
# 書けないので、repo/ を rename して別の .git を持つディレクトリに差し替えられないため
proc workspaceRepo*(taskDir: string): string = taskDir / repoSubdir

proc removeWorkspace*(cfg: Config, taskDir: string): bool =
  if not dirExists(taskDir):
    return true
  # removeDir に渡すため、worktrees 配下であることを必ず確かめる
  if not taskDir.startsWith(cfg.worktreesDir & "/") or taskDir.len <= cfg.worktreesDir.len + 1:
    err "想定外のパスは削除しません: " & taskDir
    return false
  discard gitRun(cfg.repoDir, "worktree", "remove", "--force", workspaceRepo(taskDir))
  discard gitRun(cfg.repoDir, "worktree", "prune")
  removeDir(taskDir)
  true

# 異常終了したタスクの worktree が残っていると、同じ Issue を再実行したときに
# ブランチが使用中で worktree を作れない。残骸からブランチだけ取り上げる。
# 未コミットの変更がある場合は消さずに HEAD を切り離すだけにする
proc releaseBranch(cfg: Config, branch: string): bool =
  var holder, current = ""
  for line in gitRun(cfg.repoDir, "worktree", "list", "--porcelain").output.splitLines:
    if line.startsWith("worktree "):
      current = line["worktree ".len .. ^1]
    elif line == "branch refs/heads/" & branch:
      holder = current
  if holder.len == 0:
    return true
  if not verifyWorkspace(holder, cfg.repoDir):
    err "worktree の .git が書き換えられています: " & holder
    return false
  if gitRun(holder, "status", "--porcelain").output.len == 0:
    log "前回の worktree を片付けます: " & holder
    let suffix = "/" & repoSubdir
    if not removeWorkspace(cfg, if holder.endsWith(suffix): holder[0 ..< ^suffix.len] else: holder):
      return false
  else:
    warn "未コミットの変更が残るため worktree は消さず、ブランチ " & branch & " だけ切り離します: " & holder
    if not gitOk(holder, "checkout", "--quiet", "--detach"):
      return false
  discard gitRun(cfg.repoDir, "worktree", "prune")
  true

proc createWorkspace*(cfg: Config, branch, taskDir, start: string): bool =
  let wt = workspaceRepo(taskDir)
  if not releaseBranch(cfg, branch):
    return false
  createDir(taskDir)
  if run(@["git", "-C", cfg.repoDir, "worktree", "add", "--quiet", "-B", branch, wt, start]) != 0:
    return false
  # コミットの identity を worktree のローカル設定に固定する。環境変数が引き継がれ
  # なかった場合にホストの ~/.gitconfig が使われるのを防ぐ
  discard gitRun(wt, "config", "user.name", getEnv("GIT_AUTHOR_NAME", "mopu-agent"))
  discard gitRun(wt, "config", "user.email", getEnv("GIT_AUTHOR_EMAIL", "mopu-agent@localhost"))
  true

proc pushWorkspace*(cfg: Config, wt, branch: string): bool =
  if not verifyWorkspace(wt, cfg.repoDir):
    err "worktree の .git が書き換えられています: " & wt
    return false
  run(@["git", "-C", wt, "push", "--quiet", "-u", "origin", branch, "--force-with-lease"],
      SpawnOptions(env: askpassEnv())) == 0
