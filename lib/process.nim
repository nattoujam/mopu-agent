import std/[osproc, streams]

proc capture*(cmd: string, args: openArray[string]): tuple[output: string, exitCode: int] =
  let p = startProcess(cmd, args = args, options = {poUsePath})
  defer: p.close()
  result.output = p.outputStream.readAll()
  discard p.errorStream.readAll()
  result.exitCode = p.waitForExit()
