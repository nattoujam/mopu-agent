import std/[json, os, strutils, unicode]
import outcome, paths

proc readInput(): JsonNode =
  try:
    result = parseJson(stdin.readAll())
  except CatchableError:
    result = newJObject()
  if result.kind != JObject:
    result = newJObject()

proc str(node: JsonNode, keys: varargs[string]): string =
  var n = node
  for k in keys:
    if n == nil or n.kind != JObject:
      return ""
    n = n{k}
  if n != nil and n.kind == JString: n.getStr else: ""

proc deny(reason: string) =
  stdout.writeLine $(%*{"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
  }})

# シェルが単語の区切りとクォート以外に解釈する文字を含まないか。展開はホストの
# 権限で走るので、クォートの外では区切りの空白と決まった記号だけを通す
proc plainWords*(s: string): bool =
  var quote = Rune(0)
  for c in s.runes:
    if quote == Rune('\''):
      if c == Rune('\''): quote = Rune(0)
    elif quote == Rune('"'):
      if c == Rune('"'): quote = Rune(0)
      elif c.int < 128 and char(c.int) in {'$', '`', '\\', '!'}: return false
    elif c == Rune('\'') or c == Rune('"'):
      quote = c
    elif c.int < 128:
      if char(c.int) notin {'a'..'z', 'A'..'Z', '0'..'9', ' ', '_', '.', ',', ':', '=', '/', '@', '%', '+', '-'}:
        return false
    elif not c.isAlpha:
      return false
  quote == Rune(0)

proc runContainerCommand*(): string =
  mopuBin & " run-container"

proc allowedHostCommand*(command: string): bool =
  let prefix = runContainerCommand() & " "
  if not command.startsWith(prefix):
    return false
  let rest = command[prefix.len .. ^1]
  var i = 0
  while i < rest.len and rest[i] in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-'}:
    inc i
  i > 0 and (i == rest.len or rest[i] == ' ') and plainWords(rest)

# PreToolUse hook。run-container は excludedCommands なので、
# `&&` で繋いだ後半や $(...) まで sandbox の外で走る。単独の素直な呼び出し以外を弾く
proc guardHostCommands*() =
  let command = readInput().str("tool_input", "command")
  if "run-container" in command and not allowedHostCommand(command):
    deny "run-container は単独で呼ぶこと。パイプ・リダイレクト・変数やコマンドの展開・ワイルドカードは使えない（引数に含めるならクォートで囲む）: " &
      runContainerCommand() & " <キー> [引数 ...]"

proc isGitCommit*(command: string): bool =
  const word = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}
  var i = command.find("git")
  while i >= 0:
    if i == 0 or command[i - 1] notin word:
      var j = i + 3
      while j < command.len and command[j] in Whitespace: inc j
      if j > i + 3 and command.continuesWith("commit", j) and
          (j + 6 == command.len or command[j + 6] in Whitespace):
        return true
    i = command.find("git", i + 1)
  false

# PreToolUse hook。把握と報告の state では、出口ファイル以外の書き込みとコミットを拒む
proc phaseGuard*() =
  let phase = getEnv("MOPU_PHASE")
  if not (phase.startsWith("triage-") or phase == "report"):
    return
  let input = readInput()
  case input.str("tool_name")
  of "Edit", "Write", "NotebookEdit":
    var path = input.str("tool_input", "file_path")
    if path.len == 0:
      path = input.str("tool_input", "notebook_path")
    if path.rsplit('/', 1)[^1] != outcomeFileName:
      deny "このフェーズで書けるのは出口ファイル " & outcomeFileName & " だけ"
  of "Bash":
    if isGitCommit(input.str("tool_input", "command")):
      deny "このフェーズではコミットしない"
  else: discard

# Stop hook。MOPU_PHASE の state を終える条件を満たすまで、2 回まで終えるのを拒む。
# 3 回目は終えるのを許し、run-task が同じ検査でその state を失敗として記録する
proc phaseGate*(): int =
  let phase = getEnv("MOPU_PHASE")
  let taskDir = getEnv("MOPU_TASK_DIR")
  let logDir = getEnv("MOPU_LOG_DIR")
  if phase.len == 0 or taskDir.len == 0 or logDir.len == 0:
    return 0
  discard stdin.readAll()
  let problem = outcomeProblem(phase, taskDir / repoSubdir, conditionsFromEnv())
  if problem.len == 0:
    return 0
  let countFile = logDir / "phase-gate.count"
  let count = (try: parseInt(readFile(countFile).strip) except CatchableError: 0)
  if count >= 2:
    return 0
  writeFile(countFile, $(count + 1) & "\n")
  stderr.writeLine "まだ終えられない: " & problem & "。直してから終えること。"
  2
