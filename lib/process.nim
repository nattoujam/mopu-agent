import std/[os, osproc, posix, streams, strtabs, strutils]

proc capture*(cmd: string, args: openArray[string], input = "",
              env: openArray[(string, string)] = [], mergeStderr = false): tuple[output: string, exitCode: int] =
  var table: StringTableRef = nil
  if env.len > 0:
    table = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      table[k] = v
    for (k, v) in env:
      table[k] = v
  let options = if mergeStderr: {poUsePath, poStdErrToStdOut} else: {poUsePath}
  let p = startProcess(cmd, args = args, env = table, options = options)
  defer: p.close()
  if input.len > 0:
    p.inputStream.write input
  p.inputStream.close()
  result.output = p.outputStream.readAll()
  if not mergeStderr:
    discard p.errorStream.readAll()
  result.exitCode = p.waitForExit()

var POSIX_SPAWN_SETSID {.importc, header: "<spawn.h>".}: cint
proc posix_spawn_file_actions_addchdir_np(fa: var Tposix_spawn_file_actions, path: cstring): cint {.
  importc, header: "<spawn.h>".}

proc gitRun*(dir: string, args: varargs[string]): tuple[output: string, exitCode: int] =
  capture("git", @["-C", dir] & @args)

proc gitOk*(dir: string, args: varargs[string]): bool =
  gitRun(dir, args).exitCode == 0

proc gitOut*(dir: string, args: varargs[string]): string =
  let r = gitRun(dir, args)
  if r.exitCode == 0: r.output.strip(leading = false) else: ""

proc ghRun*(args: openArray[string], input = ""): tuple[output: string, exitCode: int] =
  capture("gh", args, input)

proc ghOut*(args: openArray[string]): string =
  let r = ghRun(args)
  if r.exitCode == 0: r.output.strip(leading = false) else: ""

type
  Output* = object
    path*: string
    append*: bool

  SpawnOptions* = object
    stdinPath*: string
    stdout*, stderr*: Output
    stderrToStdout*: bool
    cwd*: string
    env*: seq[(string, string)]
    unsetEnv*: seq[string]
    newSession*: bool

proc environment(opts: SpawnOptions): seq[string] =
  var table = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    table[k] = v
  for k in opts.unsetEnv:
    table.del k
  for (k, v) in opts.env:
    table[k] = v
  for k, v in table:
    result.add k & "=" & v

# osproc の startProcess では、出力先のファイル・setsid・シグナルマスクを指定できない。
# console は addSignal のために SIGTERM を block しており、そのマスクが子に引き継がれるため、
# posix_spawn でマスクを空にして起動している。
proc spawn*(argv: seq[string], opts = SpawnOptions()): Pid =
  var fa: Tposix_spawn_file_actions
  var attr: Tposix_spawnattr
  discard posix_spawn_file_actions_init(fa)
  discard posix_spawnattr_init(attr)
  defer:
    discard posix_spawn_file_actions_destroy(fa)
    discard posix_spawnattr_destroy(attr)
  let stdinPath = if opts.stdinPath.len > 0: opts.stdinPath else: "/dev/null"
  discard posix_spawn_file_actions_addopen(fa, 0, stdinPath.cstring, O_RDONLY, 0)
  for (fd, o) in [(1.cint, opts.stdout), (2.cint, opts.stderr)]:
    if o.path.len > 0:
      let mode = O_WRONLY or O_CREAT or (if o.append: O_APPEND else: O_TRUNC)
      discard posix_spawn_file_actions_addopen(fa, fd, o.path.cstring, mode, 0o644)
  if opts.stderrToStdout:
    discard posix_spawn_file_actions_adddup2(fa, 1, 2)
  if opts.cwd.len > 0:
    discard posix_spawn_file_actions_addchdir_np(fa, opts.cwd.cstring)
  var mask: Sigset
  discard sigemptyset(mask)
  discard posix_spawnattr_setsigmask(attr, mask)
  var flags = POSIX_SPAWN_SETSIGMASK
  if opts.newSession:
    flags = flags or POSIX_SPAWN_SETSID
  discard posix_spawnattr_setflags(attr, flags)
  let args = allocCStringArray(argv)
  defer: deallocCStringArray(args)
  let env = allocCStringArray(environment(opts))
  defer: deallocCStringArray(env)
  let rc = posix_spawnp(result, argv[0].cstring, fa, attr, args, env)
  if rc != 0:
    raiseOSError(OSErrorCode(rc), argv[0])

proc exitStatus*(status: cint): int =
  if WIFEXITED(status): WEXITSTATUS(status).int
  elif WIFSIGNALED(status): 128 + WTERMSIG(status).int
  else: -1

proc waitExit*(pid: Pid): int =
  var status: cint
  while waitpid(pid, status, 0) < 0:
    if errno != EINTR:
      return -1
  exitStatus(status)

proc run*(argv: seq[string], opts = SpawnOptions()): int =
  waitExit(spawn(argv, opts))

proc ghShowingErrors*(args: openArray[string]): bool =
  run(@["gh"] & @args, SpawnOptions(stdout: Output(path: "/dev/null"))) == 0
