import std/[json, os, strutils]
import config, log, paths, process, resources

type Usage* = object
  pct5h*, pct7d*, reset5h*, reset7d*: string

# /usage はローカルコマンドとして処理され API 呼び出しを伴わない（実測: num_turns=0,
# total_cost_usd=0, 約1.8秒）。そのためタスクごとに呼び直しても枠を消費しない。
proc fetchUsage*(cfg: Config): string =
  let r = capture("timeout", ["60", cfg.claudeBin, "-p", "/usage", "--output-format", "json",
                              "--setting-sources", "", "--strict-mcp-config", "--mcp-config", """{"mcpServers":{}}""",
                              "--permission-mode", "dontAsk"])
  try:
    let res = parseJson(r.output){"result"}
    if res != nil and res.kind == JString: res.getStr else: ""
  except CatchableError:
    ""

proc parseUsage*(text: string): Usage =
  proc field(prefix: string): tuple[pct, reset: string] =
    for line in text.splitLines:
      if not line.startsWith(prefix):
        continue
      var i = prefix.len
      while i < line.len and line[i] in Digits: inc i
      if i == prefix.len or not line.continuesWith("% used", i):
        continue
      result.pct = line[prefix.len ..< i]
      const resets = "% used · resets "
      if line.continuesWith(resets, i):
        result.reset = line[i + resets.len .. ^1]
      return
  (result.pct5h, result.reset5h) = field("Current session: ")
  (result.pct7d, result.reset7d) = field("Current week (all models): ")

proc known*(u: Usage): bool = u.pct5h.len > 0 and u.pct7d.len > 0

type Budget* = enum
  bOk, bOver, bUnknown

proc checkBudget*(cfg: Config, usage: var Usage): Budget =
  let text = fetchUsage(cfg)
  usage = parseUsage(text)
  if text.len == 0 or not usage.known:
    warn "/usage の出力を解釈できませんでした。安全側に倒して起動しません（--ignore-budget で上書き可）"
    if text.len > 0:
      let lines = text.splitLines
      stderr.writeLine lines[0 ..< min(5, lines.len)].join("\n")
    return bUnknown
  log "利用枠: 5h=" & usage.pct5h & "% (閾値 " & $cfg.max5hPercent & "%) / 7d=" & usage.pct7d &
    "% (閾値 " & $cfg.max7dPercent & "%)"
  if parseInt(usage.pct5h) >= cfg.max5hPercent:
    warn "5時間枠が " & usage.pct5h & "% に達しています。resets " &
      (if usage.reset5h.len > 0: usage.reset5h else: "不明") & " 以降に再実行してください"
    return bOver
  if parseInt(usage.pct7d) >= cfg.max7dPercent:
    warn "週次枠が " & usage.pct7d & "% に達しています。resets " &
      (if usage.reset7d.len > 0: usage.reset7d else: "不明") & " 以降に再実行してください"
    return bOver
  bOk

proc resultEvents*(stream: string): seq[JsonNode] =
  if not fileExists(stream):
    return
  for line in readFile(stream).splitLines:
    let ev = (try: parseJson(line) except CatchableError: nil)
    if ev != nil and ev.kind == JObject and ev{"type"}.getStr == "result":
      result.add ev

proc recordSpend*(cfg: Config, taskId: string, cost: float, before, after, outcome: string, task: JsonNode) =
  var denials = 0
  for ev in resultEvents(cfg.taskLogsDir / taskId / "stream.jsonl"):
    let d = ev{"permission_denials"}
    if d != nil and d.kind == JArray:
      denials += d.len
  let t = if task == nil: newJNull() else: task
  let row = %*{
    "time": localStamp(), "repo": cfg.repo, "task": taskId, "cost_usd": cost,
    "pct_5h_before": before, "pct_5h_after": after,
    "issue": (if t.kind == JObject and t{"number"} != nil: t["number"] else: newJNull()),
    "kind": (if t.kind == JObject and t{"kind"} != nil: t["kind"] else: newJNull()),
    "outcome": (if outcome.len == 0: newJNull() else: %outcome),
    "denials": denials, "commit": Commit,
  }
  let f = open(spendFile, fmAppend)
  f.writeLine $row
  f.close()
