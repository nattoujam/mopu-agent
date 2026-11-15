import std/[json, os, posix, strutils, tempfiles]
import log, paths, process, workspace

var interrupted {.global.}: bool

proc onSignal(sig: cint) {.noconv.} =
  interrupted = true

proc realPath(path: string): string =
  try: expandFilename(path) except OSError: ""

# owner には _ が使えないので、最初の __ で分ければ repo 名に __ が入っていても取り違えない
proc repoOfTaskDir*(taskDir: string): string =
  let dir = (let r = realPath(taskDir); if r.len > 0: r else: absolutePath(taskDir).normalizedPath)
  let root = realPath(worktreesRoot)
  if root.len == 0 or not dir.startsWith(root & "/"):
    return ""
  let parts = dir[root.len + 1 .. ^1].split('/')
  if parts.len != 2 or parts[1].len == 0:
    return ""
  let slug = parts[0]
  let sep = slug.find("__")
  if sep <= 0 or sep + 2 >= slug.len:
    return ""
  slug[0 ..< sep] & "/" & slug[sep + 2 .. ^1]

proc containerChecks(repo: string): JsonNode =
  let settings = (try: parseFile(settingsFile) except CatchableError: die "state/settings.json を読めません")
  let r = settings{"repos", repo}
  if r == nil:
    die "設定にないリポジトリです: " & repo
  result = r{"container_checks"}
  if result == nil or result.kind != JArray:
    result = newJArray()

proc waitInterruptible(pid: Pid): int =
  var status: cint
  var forwarded = false
  while waitpid(pid, status, 0) < 0:
    if errno != EINTR:
      return -1
    if interrupted and not forwarded:
      discard kill(pid, SIGTERM)
      forwarded = true
  exitStatus(status)

# エージェントがコンテナで検証を回すための唯一の入口。sandbox の外
# （excludedCommands）で動き、コンテナの中ではエージェントが書き換えたコードが走る。
# イメージとコマンドは設定から引き、エージェントが選べるのは検証のキーと追加の引数だけ
proc runContainerMain*(args: seq[string]): int =
  if args.len < 1:
    stderr.writeLine "使い方: run-container <検証のキー> [引数 ...]"
    return 2
  let key = args[0]
  let extra = args[1 .. ^1]
  let taskDirArg = getEnv("MOPU_TASK_DIR")
  if taskDirArg.len == 0:
    die "MOPU_TASK_DIR が渡されていません"
  let repo = repoOfTaskDir(taskDirArg)
  if repo.len == 0:
    die "想定外のタスクディレクトリです"

  var check: JsonNode = nil
  var names: seq[string]
  for c in containerChecks(repo):
    let name = c{"name"}.getStr
    names.add name
    if check == nil and name == key:
      check = c
  if check == nil:
    die "この検証は登録されていません: " & key & "（登録済み: " &
      (if names.len > 0: names.join(" ") else: "なし") & "）"
  if findExe("docker").len == 0:
    die "docker が見つかりません"

  # worktree をマウント元にできるのは、sandbox から worktrees/<slug> にも task_dir にも
  # 書けず、repo/ をシンボリックリンクに差し替えられないため。差し替えられると、
  # ホストの任意のディレクトリをコンテナに渡してしまう
  let taskDir = realPath(taskDirArg)
  if taskDir.len == 0:
    die "タスクディレクトリがありません"
  if taskDir.parentDir != realPath(worktreesRoot / repoSlug(repo)) or symlinkExists(taskDirArg):
    die "想定外のタスクディレクトリです"
  if ',' in taskDir or '"' in taskDir:
    die "タスクディレクトリのパスに , や \" を含められません"
  let wt = taskDir / repoSubdir
  let repoDir = reposRoot / repoSlug(repo)
  if not verifyWorkspace(wt, repoDir):
    die "worktree の .git が書き換えられています"
  let gitfile = readFile(wt / ".git").strip(leading = false, chars = {'\n'})

  let image = check{"image"}.getStr
  let workdir = check{"workdir"}.getStr
  let limit = check{"timeout"}.getStr

  # .git にはホスト側で作ったコピーを読み取り専用で bind mount する。コンテナから worktree の .git を書き換えられると、
  # ホストが後で実行する git に別の hooks や config を読ませられるため
  let (snapFile, snap) = createTempFile("mopu-gitfile-", "")
  snapFile.writeLine gitfile
  snapFile.close()
  # コンテナ名には : が使えないため
  var safeKey = ""
  for c in key:
    safeKey.add(if c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-'}: c else: '-')
  let cname = "mopu-" & taskDir.extractFilename & "-" & safeKey & "-" & $getCurrentProcessId()
  defer:
    discard capture("docker", ["rm", "-f", cname])
    removeFile(snap)

  var action: Sigaction
  action.sa_handler = onSignal
  discard sigemptyset(action.sa_mask)
  discard sigaction(SIGINT, action)
  discard sigaction(SIGTERM, action)

  # --user の uid はイメージの passwd にないことが多く、HOME が書けない / になる。
  # そのままだと npm などがキャッシュを作れずに落ちるため HOME=/tmp を渡す
  stderr.writeLine "[run-container] " & key & ": " & image
  let rc = waitInterruptible(spawn(@[
    "timeout", limit, "docker", "run", "--rm", "--name", cname, "--init",
    "--network", "none",
    "--user", $getuid() & ":" & $getgid(),
    "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
    "--pids-limit", "4096", "--shm-size", "1g",
    "-e", "HOME=/tmp",
    "--mount", "type=bind,src=" & wt & ",dst=" & wt,
    "--mount", "type=bind,src=" & snap & ",dst=" & wt & "/.git,readonly",
    "-w", wt & (if workdir.len > 0: "/" & workdir else: ""),
    image, "sh", "-c", check{"command"}.getStr & " \"$@\"", "sh"] & extra))
  if interrupted:
    return 130

  if not verifyWorkspace(wt, repoDir) or
      readFile(wt / ".git").strip(leading = false, chars = {'\n'}) != gitfile:
    die "検証の実行中に worktree の .git が書き換えられました。このタスクの push はできません"
  if rc == 124:
    err "[run-container] " & limit & " で打ち切りました"
  rc
