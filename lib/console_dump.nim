import std/[algorithm, asyncdispatch, json, options, os, strutils, tempfiles, times]
import async_process, console_state, console_tasks, process

const dumpStateFiles = ["settings.json", "spend.jsonl", "console-runs.jsonl", "loop-metrics.json",
                        "followup-categories.jsonl"]

proc agentCommit(): string =
  let sha = capture("git", ["-C", agentDir, "rev-parse", "--short", "HEAD"])
  let status = capture("git", ["-C", agentDir, "status", "--porcelain"])
  if sha.exitCode != 0 or status.exitCode != 0:
    return "unknown"
  sha.output.strip & (if status.output.strip.len > 0: "-dirty" else: "")

proc stampedSince(name: string, cutoff: Option[Time]): bool =
  if cutoff.isNone:
    return true
  let base = if name.endsWith(".log"): name[0 ..< ^4] else: name
  if base.len < 15 or base[^7] != '-' or not base[^15 ..< ^7].allCharsInSet(Digits) or
      not base[^6 .. ^1].allCharsInSet(Digits):
    return true
  try:
    parse(base[^15 ..< ^7] & base[^6 .. ^1], "yyyyMMddHHmmss", local()).toTime >= cutoff.get
  except CatchableError:
    true

proc regularFiles(dir: string): seq[string] =
  for f in walkDirRec(dir, yieldFilter = {pcFile}):
    result.add f
  result.sort()

proc taskFiles*(task: string): seq[string] =
  regularFiles(task)

proc dumpFiles*(days: int): seq[string] =
  let cutoff = if days > 0: some(getTime() - initDuration(days = days)) else: none(Time)
  var files: seq[string]
  for name in dumpStateFiles:
    files.add stateDir / name
  if dirExists(stateDir / "repos"):
    files.add regularFiles(stateDir / "repos")
  var logs: seq[string]
  for kind, path in walkDir(runLogDir):
    if path.endsWith(".log"):
      logs.add path
  for log in logs.sorted:
    if stampedSince(log.extractFilename, cutoff):
      files.add log
  for f in files:
    if fileExists(f) and not symlinkExists(f):
      result.add f
  for task in taskIds():
    if stampedSince(task.extractFilename, cutoff):
      result.add taskFiles(task)

const wordChars = Letters + Digits + {'_'}

proc tokenEnd(data: string, i: int): int =
  proc run(start: int, chars: set[char], min: int): int =
    var j = start
    while j < data.len and data[j] in chars: inc j
    if j - start >= min: j else: -1
  if i > 0 and data[i - 1] in wordChars:
    return -1
  for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]:
    if data.continuesWith(prefix, i):
      return run(i + prefix.len, Letters + Digits, 36)
  if data.continuesWith("github_pat_", i):
    return run(i + 11, Letters + Digits + {'_'}, 22)
  if data.continuesWith("sk-ant-", i):
    return run(i + 7, Letters + Digits + {'_', '-'}, 20)
  -1

proc keyMarkerEnd(data: string, i: int, head: string): int =
  if not data.continuesWith(head, i):
    return -1
  var j = i + head.len
  while j < data.len and data[j] in {'A'..'Z', ' '}: inc j
  const tail = "PRIVATE KEY"
  if j - tail.len >= i + head.len and data.continuesWith(tail, j - tail.len) and data.continuesWith("-----", j):
    j + 5
  else:
    -1

proc privateKeyEnd(data: string, i: int): int =
  let bodyStart = keyMarkerEnd(data, i, "-----BEGIN ")
  if bodyStart < 0:
    return -1
  var q = data.find("-----END ", bodyStart)
  while q >= 0:
    let stop = keyMarkerEnd(data, q, "-----END ")
    if stop >= 0:
      return stop
    q = data.find("-----END ", q + 1)
  -1

proc redact*(data: string): (string, int) =
  var output = newStringOfCap(data.len)
  var count = 0
  var i = 0
  while i < data.len:
    var stop = -1
    if data[i] in {'g', 's'}:
      stop = tokenEnd(data, i)
    if stop < 0 and data[i] == '-':
      stop = privateKeyEnd(data, i)
    if stop >= 0:
      output.add "***"
      inc count
      i = stop
    else:
      output.add data[i]
      inc i
  (output, count)

# 標準ライブラリに tar と gzip が無いため、伏せたコピーを一時ディレクトリに書いて tar で固めている。
proc buildDump*(label: string, files: seq[string], scope: JsonNode): Future[(string, string)] {.async.} =
  let commit = agentCommit()
  let root = "mopu-" & label & "-" & commit
  let work = createTempDir("mopu-dump-", "")
  defer: removeDir(work)
  var list: seq[string]
  var count, redacted = 0
  for path in files:
    var data: string
    try:
      data = readFile(path)
    except IOError:
      continue
    let (clean, n) = redact(data)
    redacted += n
    inc count
    let rel = root / path.relativePath(agentDir)
    createDir(work / rel.parentDir)
    writeFile(work / rel, clean)
    list.add rel
  var manifest = %*{"created_at": localStamp(), "commit": commit}
  for k, v in scope:
    manifest[k] = v
  manifest["files"] = %count
  manifest["redacted"] = %redacted
  writeFile(work / root / "dump.json", manifest.pretty(2))
  list.add root / "dump.json"
  writeFile(work / "files.txt", list.join("\n") & "\n")
  let archive = work / "dump.tar.gz"
  let r = await runAsync("tar", @["-czf", archive, "-C", work, "--no-recursion", "-T", work / "files.txt"], 300_000)
  if r.timedOut or r.exitCode != 0:
    raise newException(IOError, "tar で固められませんでした: " & r.errors.strip)
  (root & ".tar.gz", readFile(archive))
