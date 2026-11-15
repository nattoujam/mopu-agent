import std/[algorithm, json, options, os, strutils, tables, times, unicode]
import console_state

proc isId*(s: string): bool =
  s.len > 0 and s[0] in Letters + Digits and s.allCharsInSet(Letters + Digits + {'.', '_', '-'})

proc taskIds*(): seq[string] =
  if not dirExists(logsDir):
    return
  for repo in walkDir(logsDir):
    if repo.kind != pcDir or repo.path.extractFilename == "console":
      continue
    for d in walkDir(repo.path):
      if d.kind == pcDir:
        result.add d.path
  proc key(path: string): seq[string] =
    let parts = path.extractFilename.rsplit('-', 2)
    parts[max(0, parts.len - 2) .. ^1]
  proc cmpKeys(a, b: string): int =
    let (ka, kb) = (key(a), key(b))
    for i in 0 ..< min(ka.len, kb.len):
      let c = cmp(ka[i], kb[i])
      if c != 0:
        return c
    cmp(ka.len, kb.len)
  result.sort(cmpKeys, Descending)

proc taskDirOf*(name: string): Option[string] =
  let parts = name.split('/')
  if parts.len != 2 or not (isId(parts[0]) and isId(parts[1])) or parts[0] == "console":
    return none(string)
  let target = logsDir / parts[0] / parts[1]
  if dirExists(target): some(target) else: none(string)

proc taskId*(path: string): string =
  path.parentDir.extractFilename & "/" & path.extractFilename

proc truncateText*(text: string, limit = 800): string =
  if text.runeLen <= limit: text else: text.runeSubStr(0, limit) & " …"

proc textOf(n: JsonNode): string =
  if truthy(n): pyStr(n) else: ""

proc fileKey(path: string): string =
  try:
    let info = getFileInfo(path)
    $info.lastWriteTime.toUnix & "." & $info.lastWriteTime.nanosecond & ":" & $info.size
  except OSError:
    "-"

proc ownCost(path: string, total: JsonNode): JsonNode =
  if total.isNil or total.kind notin {JInt, JFloat}:
    return newJNull()
  let resume = readJsonFile(path / "resume.json")
  let base = if resume.kind == JObject and resume{"base_cost_usd"}.isKind({JInt, JFloat}):
               resume["base_cost_usd"].getFloat
             else: 0.0
  %max(total.getFloat - base, 0.0)

proc taskPhases*(path: string): JsonNode =
  result = newJArray()
  for line in pySplitLines(readText(path / "phases.jsonl")):
    let entry = try: parseJson(line) except CatchableError: nil
    if not entry.isNil and entry.kind == JObject and truthy(entry{"phase"}):
      result.add %*{"phase": entry.pyGet("phase"), "at": entry.pyGet("at"), "detail": entry.pyGet("detail")}

proc numberSum(rows: seq[JsonNode], key: string): JsonNode =
  var ints: BiggestInt = 0
  var floats = 0.0
  var isFloat = false
  for r in rows:
    let v = r{key}
    if v.isNil: continue
    case v.kind
    of JInt: ints += v.getBiggestInt
    of JFloat: (floats += v.getFloat; isFloat = true)
    else: discard
  if isFloat: %(ints.float + floats) else: %ints

proc parseTaskName(name: string): Option[(string, BiggestInt, float)] =
  let parts = name.split('-')
  if parts.len != 4 or parts[0] notin ["issue", "comment", "learn", "tidy"]:
    return
  let (n, date, clock) = (parts[1], parts[2], parts[3])
  if n.len == 0 or not n.allCharsInSet(Digits) or date.len != 8 or not date.allCharsInSet(Digits) or
      clock.len != 6 or not clock.allCharsInSet(Digits):
    return
  try:
    let started = parse(date & clock, "yyyyMMddHHmmss", local()).toTime.toUnixFloat
    some((parts[0], parseBiggestInt(n), started))
  except CatchableError:
    none((string, BiggestInt, float))

var summaryCache: Table[string, (string, JsonNode)]

proc taskSummary*(path: string): JsonNode =
  let stream = path / "stream.jsonl"
  let outcomeFile = path / "outcome.json"
  let key = fileKey(stream) & "|" & fileKey(outcomeFile) & "|" & fileKey(path / "phases.jsonl")
  let id = taskId(path)
  if id in summaryCache and summaryCache[id][0] == key:
    return summaryCache[id][1]

  let slug = path.parentDir.extractFilename
  let sep = slug.find("__")
  let (owner, repo) = if sep < 0: (slug, "") else: (slug[0 ..< sep], slug[sep + 2 .. ^1])
  var summary = %*{"id": id, "repo": owner & "/" & repo, "state": "unknown"}
  let parsed = parseTaskName(path.extractFilename)
  if parsed.isSome:
    let (kind, number, started) = parsed.get
    summary["kind"] = %kind
    summary["number"] = %number
    summary["started_at"] = %started
  var results: seq[JsonNode]
  for line in pySplitLines(readText(stream, 4 * 1024 * 1024)):
    if "\"type\":\"result\"" notin line:
      continue
    let obj = try: parseJson(line) except CatchableError: nil
    if not obj.isNil and obj.kind == JObject and obj{"type"}.getStr == "result":
      results.add obj
  if results.len > 0:
    let last = results[^1]
    summary["state"] = %(if truthy(last{"is_error"}): "error" else: "success")
    summary["subtype"] = if last.hasKey("subtype"): last["subtype"] else: newJNull()
    summary["cost_usd"] = ownCost(path, last{"total_cost_usd"})
    summary["duration_ms"] = numberSum(results, "duration_ms")
    summary["turns"] = numberSum(results, "num_turns")
    summary["calls"] = %results.len
    let text = last{"result"}.getStr
    summary["result"] = %text.runeSubStr(0, min(400, text.runeLen))
  else:
    summary["state"] = %(if fileExists(stream): "incomplete" else: "aborted")
  var outcome = readJsonFile(outcomeFile)
  if outcome.kind != JObject:
    outcome = newJObject()
  if outcome{"cost_usd"}.isKind({JInt, JFloat}):
    summary["cost_usd"] = %outcome["cost_usd"].getFloat
  for k in ["entry", "end", "failed_state"]:
    if truthy(outcome{k}):
      summary[k] = outcome[k]
  if outcome{"ok"}.isKind({JBool}):
    if outcome["ok"].getBool:
      summary["state"] = %"success"
    else:
      summary["failure"] = %(if truthy(outcome{"reason"}): pyStr(outcome["reason"]) else: "失敗しました")
      if summary["state"].getStr != "aborted":
        summary["state"] = %"error"
  let phases = taskPhases(path)
  if phases.len > 0:
    summary["phase"] = phases[^1]["phase"]
    summary["phase_detail"] = phases[^1]["detail"]
  summaryCache[id] = (key, summary)
  summary

const toolPrimaryField = {
  "Bash": "command", "Read": "file_path", "Write": "file_path", "Edit": "file_path",
  "NotebookEdit": "notebook_path", "Glob": "pattern", "Grep": "pattern", "Task": "description",
  "WebFetch": "url", "WebSearch": "query",
}.toTable

proc toolFields(data: JsonNode, name: string): JsonNode =
  if data.isNil or data.kind != JObject:
    return %*[["input", truncateText(textOf(data), 600)]]
  var keys: seq[string]
  for k in data.keys: keys.add k
  let primary = toolPrimaryField.getOrDefault(name)
  let at = keys.find(primary)
  if primary.len > 0 and at >= 0:
    keys.delete(at)
    keys.insert(primary, 0)
  result = newJArray()
  for k in keys[0 ..< min(8, keys.len)]:
    let v = data[k]
    let text = if v.kind == JString: v.getStr else: pyDumps(v)
    result.add %*[k, truncateText(text, 600)]

proc blocksOf(message: JsonNode): seq[JsonNode] =
  if message.isNil or message.kind != JObject:
    return
  let content = message{"content"}
  if content.isNil:
    return
  if content.kind == JString:
    return @[%*{"kind": "text", "text": content.getStr}]
  if content.kind != JArray:
    return
  for b in content:
    if b.kind != JObject:
      continue
    case b{"type"}.getStr
    of "text":
      result.add %*{"kind": "text", "text": textOf(b{"text"})}
    of "thinking":
      result.add %*{"kind": "thinking", "text": textOf(b{"thinking"})}
    of "tool_use":
      let name = if b.hasKey("name"): b["name"] else: %"?"
      result.add %*{"kind": "tool_use", "name": name, "text": "",
                    "fields": toolFields(b{"input"}, name.getStr)}
    of "tool_result":
      var body = b{"content"}
      var text = ""
      if not body.isNil and body.kind == JArray:
        for part in body:
          if part.kind == JObject:
            text.add textOf(part{"text"})
      else:
        text = textOf(body)
      result.add %*{"kind": "tool_result", "text": text, "is_error": truthy(b{"is_error"})}
    else: discard

proc systemText(subtype: string, obj: JsonNode): string =
  proc pairs(keys: openArray[string]): string =
    var parts: seq[string]
    for k in keys:
      if truthy(obj{k}):
        parts.add k & "=" & pyStr(obj[k])
    parts.join(" ")
  case subtype
  of "init": pairs(["model", "permissionMode", "cwd"])
  of "permission_denied":
    let tool = if obj.hasKey("tool_name"): pyStr(obj["tool_name"]) else: "?"
    let reason = if truthy(obj{"message"}): pyStr(obj["message"])
                 elif truthy(obj{"decision_reason"}): pyStr(obj["decision_reason"])
                 else: ""
    unicode.strip(tool & ": " & reason)
  of "mopu_state":
    let state = if obj.hasKey("state"): pyStr(obj["state"]) else: "?"
    state & (if truthy(obj{"resume"}): "（会話 " & pyStr(obj["resume"]) & " を再開）" else: "（新しい会話）")
  of "vcs_state_changed": pairs(["kind", "branch"])
  else:
    var rest = newJObject()
    for k, v in obj:
      if k notin ["type", "subtype", "uuid", "session_id"]:
        rest[k] = v
    truncateText(pyDumps(rest), 300)

proc taskDetail*(path: string): JsonNode =
  var events: seq[JsonNode]
  for i, line in pySplitLines(readText(path / "stream.jsonl")):
    let obj = try: parseJson(line) except CatchableError: nil
    if obj.isNil or obj.kind != JObject:
      continue
    let lineno = i + 1
    let etype = obj{"type"}.getStr
    case etype
    of "assistant", "user":
      for b in blocksOf(obj{"message"}):
        let text = unicode.strip(textOf(b{"text"}))
        let kind = b["kind"].getStr
        if text.len == 0 and kind != "tool_use":
          continue
        events.add %*{
          "line": lineno, "role": etype, "kind": kind,
          "name": (if b.hasKey("name"): b["name"] else: newJNull()),
          "text": truncateText(text),
          "fields": (if b.hasKey("fields"): b["fields"] else: newJNull()),
          "is_error": (if b.hasKey("is_error"): b["is_error"] else: %false),
        }
    of "system":
      let subtype = if truthy(obj{"subtype"}): pyStr(obj["subtype"]) else: "system"
      if subtype == "thinking_tokens":
        continue
      events.add %*{"line": lineno, "role": "system", "kind": subtype, "text": systemText(subtype, obj)}
    of "result":
      events.add %*{
        "line": lineno, "role": "result",
        "kind": (if truthy(obj{"subtype"}): pyStr(obj["subtype"]) else: "result"),
        "text": truncateText(textOf(obj{"result"})),
        "is_error": truthy(obj{"is_error"}),
      }
    else: discard
  %*{
    "summary": taskSummary(path),
    "phases": taskPhases(path),
    "verify": readJsonFile(path / "verify.json"),
    "events": events[max(0, events.len - 300) .. ^1],
    "stderr": readText(path / "stderr.log", 64 * 1024),
    "setup": readText(path / "setup.log", 64 * 1024),
  }
