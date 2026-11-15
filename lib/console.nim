import std/[algorithm, asyncdispatch, asynchttpserver, json, math, nativesockets, options, os, posix, strutils,
            tables, times, uri]
import console_dump, console_scheduler, console_settings, console_state, console_tasks

let allowRemote = getEnv("CONSOLE_ALLOW_REMOTE") == "1"
var allowedHosts: seq[string]
let scheduler = newScheduler()

proc spendSummary(): JsonNode =
  var byRepo: Table[string, (float, int)]
  var last = newJObject()
  for line in pySplitLines(readText(spendFile)):
    let entry = try: parseJson(line) except CatchableError: nil
    if entry.isNil or entry.kind != JObject:
      continue
    let repo = if truthy(entry{"repo"}): pyStr(entry["repo"]) else: ""
    var slot = byRepo.getOrDefault(repo)
    slot[0] += (if entry{"cost_usd"}.isKind({JInt, JFloat}): entry["cost_usd"].getFloat else: 0.0)
    slot[1] += 1
    byRepo[repo] = slot
    last = entry
  var metrics = readJsonFile(loopMetricsFile)
  if metrics.kind != JObject:
    metrics = newJObject()
  var loopByRepo: Table[string, JsonNode]
  if metrics{"by_repo"}.isKind({JArray}):
    for m in metrics["by_repo"]:
      if m.kind == JObject:
        loopByRepo[pyStr(m{"repo"})] = m
  var names: seq[string]
  for name in byRepo.keys:
    names.add name
  var rows = newJArray()
  for name in names.sorted:
    let (total, tasks) = byRepo[name]
    rows.add %*{"repo": name, "total_usd": round(total, 4), "tasks": tasks,
                "loop": loopByRepo.getOrDefault(name, newJNull())}
  proc field(n: JsonNode, key: string): JsonNode =
    if n.hasKey(key): n[key] else: newJNull()
  %*{
    "by_repo": rows,
    "loop_total": metrics.field("total"),
    "loop_generated_at": metrics.field("generated_at"),
    "last_task": last.field("task"),
    "last_time": last.field("time"),
    "pct_5h": last.field("pct_5h_after"),
  }

proc lastPolls(names: seq[string]): JsonNode =
  result = newJObject()
  for name in names:
    let value = readText(stateDir / "repos" / name.replace("/", "__") / "last-poll").strip
    result[name] = if value.len > 0: %value else: newJNull()

proc status(): JsonNode =
  let repos = try: repoNames(loadSettings()) except SettingsBroken: @[]
  let polls = lastPolls(repos)
  var latest = newJNull()
  for _, v in polls:
    if v.kind == JString and (latest.kind == JNull or v.getStr > latest.getStr):
      latest = v
  %*{
    "now": epochTime(),
    "repos": repos,
    "configured": repos.len > 0,
    "scheduler": scheduler.snapshot,
    "poll": {"lock_held": pollLockHeld(), "last_poll_at": latest, "last_polls": polls},
    "spend": spendSummary(),
    "limits": {"min_interval": MinInterval, "max_interval": MaxInterval},
  }

proc header(req: Request, name: string): Option[string] =
  if req.headers.hasKey(name): some(req.headers[name, 0]) else: none(string)

proc queryValue(req: Request, key: string): Option[string] =
  for k, v in decodeQuery(req.url.query):
    if k == key and v.len > 0:
      return some(v)
  none(string)

proc netloc(url: string): string =
  let i = url.find("://")
  if i < 0:
    return ""
  result = url[i + 3 .. ^1]
  for j, c in result:
    if c in {'/', '?', '#'}:
      return result[0 ..< j]

proc send(req: Request, code: HttpCode, body: string, ctype = "application/json; charset=utf-8",
          extra: seq[(string, string)] = @[]) {.async.} =
  let headers = newHttpHeaders({"Content-Type": ctype, "Cache-Control": "no-store"})
  for (k, v) in extra:
    headers[k] = v
  await req.respond(code, body, headers)

proc sendJson(req: Request, obj: JsonNode, code = Http200) {.async.} =
  await req.send(code, $obj)

proc sendError(req: Request, code: HttpCode, message: string) {.async.} =
  await req.sendJson(%*{"error": message}, code)

proc sendReply(req: Request, r: Reply) {.async.} =
  await req.sendJson(r.body, HttpCode(r.code))

proc sendDump(req: Request, dump: (string, string)) {.async.} =
  await req.send(Http200, dump[1], "application/gzip",
                 @[("Content-Disposition", "attachment; filename=\"" & dump[0] & "\"")])

proc hostAllowed(req: Request): bool =
  allowRemote or req.header("host").get("").toLowerAscii in allowedHosts

proc writeRejection(req: Request): Option[(HttpCode, string)] =
  let ctype = req.header("content-type").get("").split(';')[0].strip.toLowerAscii
  if ctype != "application/json":
    return some((Http415, "Content-Type は application/json にしてください"))
  let origin = req.header("origin")
  if origin.isSome and netloc(origin.get).toLowerAscii != req.header("host").get("").toLowerAscii:
    return some((Http403, "別のオリジンからの操作は受け付けません"))
  none((HttpCode, string))

proc handleTaskRaw(req: Request, target: string) {.async.} =
  let wanted = req.queryValue("line")
  if wanted.isNone:
    await req.sendJson(%*{
      "stream": readText(target / "stream.jsonl", 2 * 1024 * 1024),
      "stderr": readText(target / "stderr.log", 256 * 1024),
      "setup": readText(target / "setup.log", 256 * 1024),
    })
    return
  var lineno: int
  try:
    lineno = parseInt(wanted.get.strip)
  except ValueError:
    await req.sendError(Http400, "line は整数で指定してください")
    return
  let lines = pySplitLines(readText(target / "stream.jsonl", 4 * 1024 * 1024))
  if lineno < 1 or lineno > lines.len:
    await req.sendError(Http404, $lineno & " 行目はありません（全 " & $lines.len & " 行）")
    return
  await req.sendJson(%*{"line": lineno, "text": lines[lineno - 1]})

proc taskTarget(path, prefix, suffix: string): Option[string] =
  taskDirOf(path[prefix.len ..< path.len - suffix.len])

proc handleGet(req: Request, path: string) {.async.} =
  const tasksPrefix = "/api/tasks/"
  case path
  of "/", "/index.html":
    let page = webDir / "index.html"
    if not fileExists(page):
      await req.sendError(Http500, "web/index.html がありません")
    else:
      await req.send(Http200, readFile(page), "text/html; charset=utf-8")
  of "/api/status": await req.sendJson(status())
  of "/api/settings": await req.sendReply(settingsReply())
  of "/api/github-app": await req.sendReply(appReply())
  of "/api/notify": await req.sendReply(notifyReply())
  of "/api/states":
    await req.send(Http200, readFile(agentDir / "lib" / "states.json"))
  of "/api/tasks":
    let q = req.queryValue("q").get("").strip
    var rows = newJArray()
    for d in taskIds():
      if q in taskId(d):
        rows.add taskSummary(d)
        if rows.len == 100:
          break
    await req.sendJson(%*{"tasks": rows})
  of "/api/dump":
    let days = req.queryValue("days").get("0")
    if not days.allCharsInSet(Digits):
      await req.sendError(Http400, "days は 0 以上の整数で指定してください")
      return
    let label = "dump-" & now().format("yyyyMMdd-HHmmss")
    await req.sendDump(await buildDump(label, dumpFiles(parseInt(days)), %*{"days": parseInt(days)}))
  else:
    if path.startsWith("/api/runs/"):
      let name = path["/api/runs/".len .. ^1]
      if not isId(name) or not name.endsWith(".log"):
        await req.sendError(Http400, "不正なログ名です")
      elif not fileExists(runLogDir / name):
        await req.sendError(Http404, "ログがありません")
      else:
        await req.sendJson(%*{"log": name, "lines": stripAnsiLines(readText(runLogDir / name, 512 * 1024))})
    elif path.startsWith(tasksPrefix) and path.endsWith("/raw"):
      let target = taskTarget(path, tasksPrefix, "/raw")
      if target.isNone:
        await req.sendError(Http404, "タスクログがありません")
      else:
        await req.handleTaskRaw(target.get)
    elif path.startsWith(tasksPrefix) and path.endsWith("/dump"):
      let target = taskTarget(path, tasksPrefix, "/dump")
      if target.isNone:
        await req.sendError(Http404, "タスクログがありません")
      else:
        let t = target.get
        let label = "task-" & t.parentDir.extractFilename & "-" & t.extractFilename
        await req.sendDump(await buildDump(label, taskFiles(t), %*{"task": taskId(t)}))
    elif path.startsWith(tasksPrefix):
      let target = taskTarget(path, tasksPrefix, "")
      if target.isNone:
        await req.sendError(Http404, "タスクログがありません")
      else:
        await req.sendJson(taskDetail(target.get))
    else:
      await req.sendError(Http404, "not found")

proc parseDuration(value: JsonNode): int =
  case value.kind
  of JBool: raise newException(ValueError, "間隔が数値ではありません")
  of JInt: return value.getInt
  of JFloat: return int(value.getFloat)
  of JString:
    let s = value.getStr.strip.toLowerAscii
    var digits = 0
    while digits < s.len and s[digits] in Digits:
      inc digits
    let unit = s[digits .. ^1].strip
    if digits > 0 and unit in ["", "s", "m", "h"]:
      return parseInt(s[0 ..< digits]) * (case unit
        of "m": 60
        of "h": 3600
        else: 1)
    raise newException(ValueError, "間隔を解釈できません: " & value.getStr)
  else: raise newException(ValueError, "間隔を解釈できません: " & pyStr(value))

proc handleScheduler(req: Request, body: JsonNode) {.async.} =
  var interval = none(int)
  if body.hasKey("interval"):
    try:
      interval = some(parseDuration(body["interval"]))
    except ValueError as e:
      await req.sendError(Http400, e.msg)
      return
    if interval.get notin MinInterval .. MaxInterval:
      await req.sendError(Http400, "間隔は " & $MinInterval & "〜" & $MaxInterval & " 秒の範囲で指定してください")
      return
  var enabled = none(bool)
  let e = body{"enabled"}
  if not e.isNil and e.kind != JNull:
    if e.kind != JBool:
      await req.sendError(Http400, "enabled は真偽値で指定してください")
      return
    enabled = some(e.getBool)
  try:
    scheduler.update(interval, enabled)
  except SettingsBroken:
    await req.sendError(Http500, "state/settings.json が壊れています")
    return
  await req.sendJson(status())

proc parseRetry(v: JsonNode): Option[int] =
  case v.kind
  of JInt: some(v.getInt)
  of JFloat: some(int(v.getFloat))
  of JBool: some(ord(v.getBool))
  of JString:
    try: some(parseInt(v.getStr.strip)) except ValueError: none(int)
  else: none(int)

proc handleRun(req: Request, body: JsonNode) {.async.} =
  var retry = none(Retry)
  let r = body{"retry"}
  if not r.isNil and r.kind != JNull:
    let number = parseRetry(r)
    if number.isNone:
      await req.sendError(Http400, "retry は Issue 番号（整数）で指定してください")
      return
    if number.get < 1:
      await req.sendError(Http400, "retry は 1 以上の整数で指定してください")
      return
    var known: seq[string]
    try:
      known = repoNames(loadSettings())
    except SettingsBroken:
      await req.sendError(Http500, "state/settings.json が壊れています")
      return
    let repo = body{"repo"}
    if repo.isNil or repo.kind != JString or repo.getStr notin known:
      await req.sendError(Http400, "再実行するリポジトリが設定にありません")
      return
    retry = some(Retry(repo: repo.getStr, number: number.get))
  if not scheduler.requestRun(retry):
    await req.sendError(Http409, "すでにポーリングが実行中です")
    return
  await req.sendJson(status())

proc writeBody(req: Request): Option[JsonNode] =
  if req.body.len == 0:
    return some(newJObject())
  try:
    some(parseJson(req.body))
  except JsonParsingError:
    none(JsonNode)

proc handleWrite(req: Request, path: string) {.async.} =
  let rejection = req.writeRejection
  if rejection.isSome:
    await req.sendError(rejection.get[0], rejection.get[1])
    return
  let parsed = req.writeBody
  if parsed.isNone:
    await req.sendError(Http400, "JSON を解釈できません")
    return
  let body = parsed.get
  if body.kind != JObject:
    await req.sendError(Http400, "JSON オブジェクトで指定してください")
    return
  if req.reqMethod == HttpPost:
    case path
    of "/api/settings/global": await req.sendReply(saveGlobal(body))
    of "/api/settings/repo": await req.sendReply(saveRepo(body))
    of "/api/github-app": await req.sendReply(await registerAppReq(body))
    of "/api/notify": await req.sendReply(await registerNotifyReq(body))
    of "/api/scheduler": await req.handleScheduler(body)
    of "/api/run": await req.handleRun(body)
    else: await req.sendError(Http404, "not found")
  else:
    case path
    of "/api/settings/repo": await req.sendReply(deleteRepo(body))
    of "/api/notify": await req.sendReply(deleteNotify())
    of "/api/github-app": await req.sendReply(deleteAppReq())
    else: await req.sendError(Http404, "not found")

proc route(req: Request) {.async.} =
  if not req.hostAllowed:
    await req.sendError(Http403, "Host が不正です")
    return
  let path = decodeUrl(req.url.path, decodePlus = false)
  try:
    case req.reqMethod
    of HttpGet: await req.handleGet(path)
    of HttpPost, HttpDelete: await req.handleWrite(path)
    else: await req.sendError(Http501, "未対応のメソッドです")
  except CatchableError as e:
    log req.reqMethod.`$` & " " & path & " で失敗しました: " & e.msg
    await req.sendError(Http500, "処理に失敗しました: " & e.msg)

proc acceptLoop(server: AsyncHttpServer) {.async.} =
  # スレッドを使わずイベントループ 1 本で動かしており、グローバルを読むハンドラを
  # acceptRequest が求める gcsafe として渡すため。
  let callback = proc (req: Request): Future[void] {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      result = route(req)
  while not scheduler.stopping:
    try:
      if server.shouldAcceptRequest():
        await server.acceptRequest(callback)
      else:
        await sleepAsync(500)
    except OSError:
      if not scheduler.stopping:
        raise

proc main(): Future[int] {.async.} =
  let host = (let h = getEnv("CONSOLE_HOST"); if h.len > 0: h else: "127.0.0.1")
  let port = (let p = getEnv("CONSOLE_PORT"); if p.len > 0: parseInt(p) else: 8787)
  if host notin ["127.0.0.1", "::1", "localhost"] and not allowRemote:
    log host & " での待受は拒否します。認証がないため loopback 以外に晒すのは危険です"
    log "それでも公開する場合は CONSOLE_ALLOW_REMOTE=1 を設定し、前段で認証をかけてください"
    return 1
  if not fileExists(agentDir / "poll.sh"):
    log "poll.sh が見つかりません: " & agentDir
    return 1
  for h in ["127.0.0.1", "localhost", "[::1]"]:
    allowedHosts.add h & ":" & $port
  createDir(runLogDir)

  let stop = newFuture[void]("stop")
  for sig in [SIGINT, SIGTERM]:
    addSignal(sig.int, proc (fd: AsyncFD): bool =
      if not stop.finished:
        stop.complete()
      true)

  let server = newAsyncHttpServer(maxBody = 1024 * 1024)
  server.listen(Port(port), host, if ':' in host: Domain.AF_INET6 else: Domain.AF_INET)
  asyncCheck scheduler.loop()
  asyncCheck acceptLoop(server)
  log "http://" & host & ":" & $port & " で待受"
  if scheduler.enabled:
    log "次回ポーリング: " & $scheduler.interval & " 秒後"
  else:
    log "スケジューラは停止中です（コンソールから再開できます）"

  await stop
  scheduler.stopping = true
  scheduler.wakeUp()
  server.close()
  if not scheduler.current.isNil:
    log "実行中のポーリングが終わるのを待っています (最大 5 分)"
    if not await scheduler.waitForCurrent(300):
      log "待機を打ち切りました。poll.sh はバックグラウンドで継続します"
  0

when isMainModule:
  quit waitFor main()
