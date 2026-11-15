import std/[asyncdispatch, osproc, streams, times]

type RunResult* = object
  exitCode*: int
  output*, errors*: string
  timedOut*: bool

# 完了を優先し、出力をパイプに溜めたまま終了を待っているため、64 KiB を超えて書く
# コマンドはパイプが詰まってタイムアウトになる。
proc runAsync*(cmd: string, args: seq[string], timeoutMs: int): Future[RunResult] {.async.} =
  let p = startProcess(cmd, args = args, options = {poUsePath})
  defer: p.close()
  p.inputStream.close()
  let deadline = epochTime() + timeoutMs / 1000
  while p.peekExitCode == -1:
    if epochTime() > deadline:
      p.kill()
      discard p.waitForExit()
      result.timedOut = true
      return
    await sleepAsync(50)
  result.exitCode = p.peekExitCode
  result.output = p.outputStream.readAll()
  result.errors = p.errorStream.readAll()
