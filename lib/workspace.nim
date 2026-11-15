import std/[os, strutils]

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
