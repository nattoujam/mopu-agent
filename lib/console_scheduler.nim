import std/[asyncdispatch, json, math, options, os, posix, strutils, times]
import console_state

const
  MinInterval* = 60
  MaxInterval* = 86400
  RunsKeep = 200

var POSIX_SPAWN_SETSID {.importc, header: "<spawn.h>".}: cint
var environ {.importc.}: cstringArray
proc posix_spawn_file_actions_addchdir_np(fa: var Tposix_spawn_file_actions, path: cstring): cint {.
  importc, header: "<spawn.h>".}

type AnsiCode = tuple[start, stop: int, params: seq[string]]

proc ansiCodes(text: string): seq[AnsiCode] =
  var i = 0
  while i + 1 < text.len:
    if text[i] == '\x1b' and text[i + 1] == '[':
      var j = i + 2
      while j < text.len and text[j] in Digits + {';'}: inc j
      if j < text.len and text[j] == 'm':
        result.add (i, j + 1, text[i + 2 ..< j].split(';'))
        i = j + 1
        continue
    inc i

proc stripAnsi(text: string): string =
  var last = 0
  for c in ansiCodes(text):
    result.add text[last ..< c.start]
    last = c.stop
  result.add text[last .. ^1]

proc stripAnsiLines*(text: string): JsonNode =
  result = newJArray()
  for raw in pySplitLines(text):
    var level = "info"
    for c in ansiCodes(raw):
      if "33" in c.params: level = "warn"
      elif "31" in c.params: level = "error"
    result.add %*{"text": stripAnsi(raw), "level": level}

proc numbersBefore(text, marker: string): seq[int] =
  var at = text.find(marker)
  while at >= 0:
    var j = at
    while j > 0 and text[j - 1] in Whitespace: dec j
    var k = j
    while k > 0 and text[k - 1] in Digits: dec k
    if k < j:
      result.add parseInt(text[k ..< j])
    at = text.find(marker, at + marker.len)

proc numbersAfter(text, marker, tail: string): seq[int] =
  var at = text.find(marker)
  while at >= 0:
    var j = at + marker.len
    while j < text.len and text[j] in Whitespace: inc j
    let digitsStart = j
    while j < text.len and text[j] in Digits: inc j
    let digitsEnd = j
    while j < text.len and text[j] in Whitespace: inc j
    if digitsEnd > digitsStart and text.continuesWith(tail, j):
      result.add parseInt(text[digitsStart ..< digitsEnd])
      at = text.find(marker, j + tail.len)
    else:
      at = text.find(marker, at + marker.len)

proc summarizeRunLog(path: string): JsonNode =
  let text = readText(path, 256 * 1024)
  let plain = stripAnsi(text)
  var commit = newJNull()
  var at = plain.find("mopu-agent ")
  while at >= 0:
    var j = at + "mopu-agent ".len
    let start = j
    while j < plain.len and plain[j] notin Whitespace: inc j
    if j > start:
      commit = %plain[start ..< j]
      break
    at = plain.find("mopu-agent ", at + 1)
  let found = numbersBefore(plain, "件のタスクを検出")
  let done = numbersAfter(plain, "完了:", "件")
  var warnings, errors = 0
  for c in ansiCodes(text):
    if "33" in c.params: inc warnings
    if "31" in c.params: inc errors
  %*{
    "commit": commit,
    "detected": (if found.len > 0: %sum(found) elif "処理するタスクはありません" in plain: %0 else: newJNull()),
    "processed": (if done.len > 0: %sum(done) else: newJNull()),
    "warnings": warnings,
    "errors": errors,
  }

proc clampInterval*(seconds: int): int =
  max(MinInterval, min(MaxInterval, seconds))

type
  Retry* = object
    repo*: string
    number*: int

  Scheduler* = ref object
    interval*: int
    enabled*: bool
    nextRunAt: Option[float]
    current*: JsonNode
    manualRequested: bool
    manualRetry: Option[Retry]
    runs: seq[JsonNode]
    stopping*: bool
    wake: Future[void]

proc newScheduler*(): Scheduler =
  result = Scheduler(interval: 300, wake: newFuture[void]("wake"))
  try:
    let settings = loadSettings()
    let saved = if settings.isNil or settings.kind != JObject: nil else: settings{"scheduler"}
    if not saved.isNil and saved.kind == JObject:
      if saved{"interval_seconds"}.isKind({JInt, JFloat}):
        result.interval = clampInterval(int(saved["interval_seconds"].getFloat))
      if saved{"enabled"}.isKind({JBool}):
        result.enabled = saved["enabled"].getBool
  except SettingsBroken:
    discard
  var runs: seq[JsonNode]
  for line in pySplitLines(readText(runsFile)):
    try:
      runs.add parseJson(line)
    except JsonParsingError:
      discard
  for i in countdown(runs.high, max(0, runs.len - RunsKeep)):
    result.runs.add runs[i]
  if result.enabled:
    result.nextRunAt = some(epochTime() + result.interval.float)

proc snapshot*(s: Scheduler): JsonNode =
  %*{
    "enabled": s.enabled,
    "interval_seconds": s.interval,
    "next_run_at": (if s.nextRunAt.isSome: %s.nextRunAt.get else: newJNull()),
    "current": (if s.current.isNil: newJNull() else: s.current.copy),
    "runs": s.runs,
  }

proc wakeUp*(s: Scheduler) =
  if not s.wake.finished:
    s.wake.complete()

proc update*(s: Scheduler, interval: Option[int], enabled: Option[bool]) =
  if interval.isSome:
    s.interval = clampInterval(interval.get)
  if enabled.isSome:
    s.enabled = enabled.get
  s.nextRunAt = if s.enabled: some(epochTime() + s.interval.float) else: none(float)
  let state = %*{"interval_seconds": s.interval, "enabled": s.enabled}
  discard updateSettings(proc (data: JsonNode) = data["scheduler"] = state)
  s.wakeUp()

proc requestRun*(s: Scheduler, retry: Option[Retry]): bool =
  if not s.current.isNil:
    return false
  s.manualRequested = true
  s.manualRetry = retry
  s.wakeUp()
  true

# osproc の startProcess では、setsid と出力先のファイルを指定できず、addSignal が
# block した SIGTERM のマスクも子に引き継がれるため、posix_spawn で起動している。
proc spawnPoll(argv: seq[string], logPath: string): Pid =
  var fa: Tposix_spawn_file_actions
  var attr: Tposix_spawnattr
  discard posix_spawn_file_actions_init(fa)
  discard posix_spawnattr_init(attr)
  defer:
    discard posix_spawn_file_actions_destroy(fa)
    discard posix_spawnattr_destroy(attr)
  discard posix_spawn_file_actions_addopen(fa, 0, "/dev/null", O_RDONLY, 0)
  discard posix_spawn_file_actions_addopen(fa, 1, logPath.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
  discard posix_spawn_file_actions_adddup2(fa, 1, 2)
  discard posix_spawn_file_actions_addchdir_np(fa, agentDir.cstring)
  var mask: Sigset
  discard sigemptyset(mask)
  discard posix_spawnattr_setsigmask(attr, mask)
  discard posix_spawnattr_setflags(attr, POSIX_SPAWN_SETSID or POSIX_SPAWN_SETSIGMASK)
  let args = allocCStringArray(argv)
  defer: deallocCStringArray(args)
  let rc = posix_spawn(result, argv[0].cstring, fa, attr, args, environ)
  if rc != 0:
    raiseOSError(OSErrorCode(rc))

proc waitExit(pid: Pid): Future[int] {.async.} =
  var status: cint
  while true:
    let r = waitpid(pid, status, WNOHANG)
    if r == pid:
      break
    if r < 0:
      return -1
    await sleepAsync(500)
  if WIFEXITED(status): WEXITSTATUS(status).int
  elif WIFSIGNALED(status): -WTERMSIG(status).int
  else: -1

proc execute(s: Scheduler, trigger: string, retry: Option[Retry]) {.async.} =
  var argv = @[agentDir / "poll.sh"]
  let retryNumber = if retry.isSome: %retry.get.number else: newJNull()
  let retryRepo = if retry.isSome: %retry.get.repo else: newJNull()
  if retry.isSome:
    argv.add ["--repo", retry.get.repo, "--retry", $retry.get.number]
  createDir(runLogDir)
  let name = "poll-" & now().format("yyyyMMdd-HHmmss") & ".log"
  let path = runLogDir / name
  let started = epochTime()
  s.current = %*{"log": name, "trigger": trigger, "started_at": started,
                 "retry_number": retryNumber, "retry_repo": retryRepo}
  var exitCode: int
  try:
    exitCode = await waitExit(spawnPoll(argv, path))
  except OSError as e:
    let f = open(path, fmAppend)
    f.writeLine "poll.sh を起動できませんでした: " & e.msg
    f.close()
    exitCode = -1
  let finished = epochTime()
  let duration = round(finished - started, 1)
  var record = %*{
    "log": name, "trigger": trigger, "retry_number": retryNumber, "retry_repo": retryRepo,
    "started_at": started, "finished_at": finished, "duration_s": duration, "exit_code": exitCode,
  }
  for k, v in summarizeRunLog(path):
    record[k] = v
  try:
    let f = open(runsFile, fmAppend)
    defer: f.close()
    f.writeLine $record
  except IOError as e:
    log "実行履歴を書けませんでした: " & e.msg
  s.current = nil
  s.runs.insert(record, 0)
  if s.runs.len > RunsKeep:
    s.runs.setLen(RunsKeep)
  log "ポーリング終了 (" & trigger & ") exit=" & $exitCode & " " & formatFloat(duration, ffDecimal, 1) & "s"

proc loop*(s: Scheduler) {.async.} =
  while not s.stopping:
    var trigger = ""
    var retry = none(Retry)
    if s.manualRequested:
      s.manualRequested = false
      retry = s.manualRetry
      s.manualRetry = none(Retry)
      trigger = if retry.isSome: "retry" else: "manual"
    elif s.enabled and s.nextRunAt.isSome and epochTime() >= s.nextRunAt.get:
      trigger = "schedule"
    if trigger.len > 0:
      await s.execute(trigger, retry)
      s.nextRunAt = if s.enabled: some(epochTime() + s.interval.float) else: none(float)
      continue
    await s.wake or sleepAsync(1000)
    if s.wake.finished:
      s.wake = newFuture[void]("wake")

proc waitForCurrent*(s: Scheduler, timeout: float): Future[bool] {.async.} =
  let deadline = epochTime() + timeout
  while epochTime() < deadline:
    if s.current.isNil:
      return true
    await sleepAsync(500)
  false
