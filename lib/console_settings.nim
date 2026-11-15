import std/[algorithm, asyncdispatch, json, math, options, os, posix, sequtils, sets, strutils, unicode]
import async_process, console_state, process

type
  Reply* = object
    code*: int
    body*: JsonNode
  Invalid = object of ValueError
  SettingsError = object of ValueError
    field: string

let schema* = parseJson(readFile(schemaFile))

proc reply*(body: JsonNode, code = 200): Reply =
  Reply(code: code, body: body)

proc errorReply*(code: int, message: string, field = ""): Reply =
  result = Reply(code: code, body: %*{"error": message})
  if field.len > 0:
    result.body["field"] = %field

proc brokenSettings(): Reply =
  errorReply(500, "state/settings.json が壊れています")

proc hasControl*(s: string): bool =
  for c in s:
    if c.ord < 0x20 or c.ord == 0x7f:
      return true
  false

proc allIn(s: string, chars: set[char]): bool =
  s.len > 0 and s.allCharsInSet(chars)

proc isTimeout(s: string): bool =
  var i = 0
  while i < s.len and s[i] in Digits: inc i
  if i == 0: return false
  if i < s.len and s[i] == '.':
    let start = i + 1
    i = start
    while i < s.len and s[i] in Digits: inc i
    if i == start: return false
  if i < s.len and s[i] in {'s', 'm', 'h', 'd'}: inc i
  i == s.len

# std/re は保守の終わった PCRE1 を動的に読み込むため、schema の正規表現は
# 必須の依存にある jq の test() で照合している。
proc patternMatches(pattern, value: string): bool =
  capture("jq", ["-n", "-e", "--arg", "v", value, "--arg", "p", pattern, "$v | test($p)"]).exitCode == 0

proc containerCheckKey(row: JsonNode): string =
  var base = row["image"].getStr.rsplit('/', 1)[^1].split('@')[0].split(':')[0]
  var words = unicode.splitWhitespace(row["command"].getStr)
  if words.len > 0 and words[^1] == "--":
    words.setLen(words.len - 1)
  var joined = ""
  for c in (@[base] & words).join("-"):
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-'}:
      joined.add c
    elif joined.len == 0 or joined[^1] != '-':
      joined.add '-'
  var collapsed = ""
  for c in joined:
    if not (c == '-' and collapsed.len > 0 and collapsed[^1] == '-'):
      collapsed.add c
  collapsed.strip(chars = {'-'})

proc invalid(msg: string): ref Invalid = newException(Invalid, msg)

proc validateValue(d, value: JsonNode): JsonNode =
  let kind = d["type"].getStr
  case kind
  of "string", "duration":
    if value.kind != JString:
      raise invalid("文字列で指定してください")
    let v = unicode.strip(value.getStr)
    if hasControl(v):
      raise invalid("改行や制御文字は使えません")
    if kind == "duration" and not isTimeout(v):
      raise invalid("30m / 1h / 90s の形で指定してください")
    if truthy(d{"required"}) and v.len == 0:
      raise invalid("入力してください")
    if truthy(d{"pattern"}) and not patternMatches(d["pattern"].getStr, v):
      raise invalid("形式が正しくありません")
    %v
  of "boolean":
    if value.kind != JBool:
      raise invalid("true か false で指定してください")
    value
  of "integer", "number":
    if value.kind notin {JInt, JFloat}:
      raise invalid("数値で指定してください")
    var v = value
    if kind == "integer" and value.kind == JFloat:
      if value.getFloat != value.getFloat.trunc:
        raise invalid("整数で指定してください")
      v = %int(value.getFloat)
    if d.hasKey("min") and v.getFloat < d["min"].getFloat:
      raise invalid($d["min"] & " 以上にしてください")
    if d.hasKey("max") and v.getFloat > d["max"].getFloat:
      raise invalid($d["max"] & " 以下にしてください")
    v
  of "list":
    if value.kind != JArray or not value.getElems.allIt(it.kind == JString):
      raise invalid("文字列の配列で指定してください")
    var items: seq[string]
    for raw in value.getElems:
      let v = unicode.strip(raw.getStr)
      if v.len == 0 or v in items:
        continue
      if truthy(d{"item_pattern"}) and not patternMatches(d["item_pattern"].getStr, v):
        raise invalid("形式が正しくありません: " & v)
      items.add v
    if truthy(d{"required"}) and items.len == 0:
      raise invalid("1 つ以上指定してください")
    %items
  of "records":
    if value.kind != JArray or not value.getElems.allIt(it.kind == JObject):
      raise invalid("オブジェクトの配列で指定してください")
    let fields = d["fields"]
    let keyName = d["key"].getStr
    var rows = newJArray()
    var keys: HashSet[string]
    for i, row in value.getElems:
      var unknown: seq[string]
      for k in row.keys:
        if not fields.hasKey(k) and k != keyName:
          unknown.add k
      if unknown.len > 0:
        raise invalid($(i + 1) & " 行目: 未知の項目です: " & unknown.sorted[0])
      var clean = newJObject()
      for k, f in fields:
        try:
          clean[k] = validateValue(f, if row.hasKey(k): row[k] else: f["default"])
        except Invalid as e:
          raise invalid($(i + 1) & " 行目の" & f["label"].getStr & ": " & e.msg)
      let key = containerCheckKey(clean)
      if key in keys:
        raise invalid($(i + 1) & " 行目: " & d["key_conflict"].getStr)
      keys.incl key
      var entry = %*{keyName: key}
      for k, v in clean:
        entry[k] = v
      rows.add entry
    rows
  else:
    raise invalid("未知の型です: " & kind)

proc settingsError(field, message: string): ref SettingsError =
  result = newException(SettingsError, message)
  result.field = field

proc validateSection(scope: string, defs, values: JsonNode): JsonNode =
  if values.kind != JObject:
    raise settingsError(scope, "オブジェクトで指定してください")
  var unknown: seq[string]
  for k in values.keys:
    if not defs.hasKey(k):
      unknown.add k
  if unknown.len > 0:
    let u = unknown.sorted[0]
    raise settingsError(scope & "." & u, "未知の項目です: " & u)
  result = newJObject()
  for key, d in defs:
    try:
      result[key] = validateValue(d, if values.hasKey(key): values[key] else: d["default"])
    except Invalid as e:
      raise settingsError(scope & "." & key, d["label"].getStr & ": " & e.msg)

proc effectiveValues(defs, saved: JsonNode): JsonNode =
  result = newJObject()
  let s = if truthy(saved): saved else: newJObject()
  for key, d in defs:
    result[key] = if s.hasKey(key): s[key] else: d["default"]

proc orEmpty(n: JsonNode): JsonNode =
  if truthy(n): n else: newJObject()

proc settingsView(settings: JsonNode): JsonNode =
  let s = orEmpty(settings)
  let repos = orEmpty(s{"repos"})
  var rows = newJArray()
  var names: seq[string]
  for name in repos.keys:
    names.add name
  for name in names.sorted:
    rows.add %*{"name": name, "values": effectiveValues(schema["repo"], repos[name])}
  %*{
    "schema": schema,
    "configured": repos.len > 0,
    "global": effectiveValues(schema["global"], s{"global"}),
    "repos": rows,
  }

proc settingsReply*(): Reply =
  try: reply(settingsView(loadSettings())) except SettingsBroken: brokenSettings()

proc saveGlobal*(body: JsonNode): Reply =
  var values: JsonNode
  try:
    values = validateSection("global", schema["global"], orEmpty(body{"values"}))
  except SettingsError as e:
    return errorReply(400, e.msg, e.field)
  try:
    reply(settingsView(updateSettings(proc (data: JsonNode) =
      data["version"] = %1
      data["global"] = values)))
  except SettingsBroken:
    brokenSettings()

proc isRepoName(name: string): bool =
  let parts = name.split('/')
  if parts.len != 2: return false
  let (owner, repo) = (parts[0], parts[1])
  owner.allIn(Letters + Digits + {'-'}) and owner[0] != '-' and owner[^1] != '-' and
    repo.allIn(Letters + Digits + {'.', '_', '-'})

proc saveRepo*(body: JsonNode): Reply =
  let name = unicode.strip(if truthy(body{"name"}): pyStr(body["name"]) else: "")
  if not isRepoName(name):
    return errorReply(400, "リポジトリは owner/repo の形で指定してください", "repo.name")
  var values: JsonNode
  try:
    values = validateSection("repo", schema["repo"], orEmpty(body{"values"}))
  except SettingsError as e:
    return errorReply(400, e.msg, e.field)
  let create = body{"create"}.isKind({JBool}) and body["create"].getBool
  var conflict = false
  var saved: JsonNode
  try:
    saved = updateSettings(proc (data: JsonNode) =
      if not data.hasKey("repos"):
        data["repos"] = newJObject()
      let repos = data["repos"]
      if create == repos.hasKey(name):
        conflict = true
        return
      data["version"] = %1
      repos[name] = values)
  except SettingsBroken:
    return brokenSettings()
  if conflict:
    let message = if create: "すでに登録されています" else: "登録されていないリポジトリです"
    return errorReply(409, message & ": " & name, "repo.name")
  reply(settingsView(saved))

proc deleteRepo*(body: JsonNode): Reply =
  let name = body{"name"}
  var missing = false
  var saved: JsonNode
  try:
    saved = updateSettings(proc (data: JsonNode) =
      let repos = data{"repos"}
      if not truthy(repos) or name.isNil or name.kind != JString or not repos.hasKey(name.getStr):
        missing = true
        return
      repos.delete(name.getStr))
  except SettingsBroken:
    return brokenSettings()
  if missing:
    return errorReply(404, "登録されていないリポジトリです: " & pyStr(name))
  reply(settingsView(saved))

proc appView(settings: JsonNode): JsonNode =
  let app = orEmpty(settings){"github_app"}
  let keyExists = fileExists(appKeyFile)
  if not truthy(app) or not keyExists:
    return %*{"registered": false, "key_without_app": keyExists and not truthy(app)}
  %*{
    "registered": true,
    "app_id": app.pyGet("app_id"),
    "bot": pyStr(app.pyGet("slug")) & "[bot]",
    "fingerprint": app.pyGet("fingerprint"),
    "registered_at": app.pyGet("registered_at"),
  }

proc appReply*(): Reply =
  try: reply(appView(loadSettings())) except SettingsBroken: brokenSettings()

proc prepareSecretsDir() =
  createDir(secretsDir)
  setFilePermissions(secretsDir, {fpUserRead, fpUserWrite, fpUserExec})

var tmpSeq = 0

proc writeSecretTmp(prefix, content: string): string =
  inc tmpSeq
  result = secretsDir / prefix & "." & $getCurrentProcessId() & "." & $tmpSeq
  let fd = posix.open(result.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o600)
  if fd < 0:
    raiseOSError(osLastError())
  defer: discard posix.close(fd)
  if content.len > 0 and posix.write(fd, content[0].unsafeAddr, content.len) != content.len:
    raiseOSError(osLastError())

proc lastLine(text, fallback: string): string =
  let lines = pySplitLines(unicode.strip(text))
  if lines.len > 0: lines[^1] else: fallback

proc registerApp(appId: BiggestInt, pem: string): Future[Reply] {.async.} =
  const field = "app.private_key"
  const taken = "秘密鍵が登録済みです。差し替えるには先に削除してください"
  prepareSecretsDir()
  if fileExists(appKeyFile):
    return errorReply(409, taken, field)
  let tmp = writeSecretTmp(".github-app.pem", if pem.endsWith("\n"): pem else: pem & "\n")
  var info: JsonNode
  try:
    let r = await runAsync(mopuBin, @["app-check", $appId, tmp], 60_000)
    if r.timedOut:
      return errorReply(504, "GitHub への確認がタイムアウトしました", field)
    if r.exitCode != 0:
      return errorReply(400, lastLine(r.errors, "鍵を検証できませんでした"), field)
    info = parseJson(r.output)
    if posix.link(tmp.cstring, appKeyFile.cstring) != 0:
      if errno == EEXIST:
        return errorReply(409, taken, field)
      raiseOSError(osLastError())
  finally:
    discard tryRemoveFile(tmp)
  let app = %*{"app_id": appId, "slug": info["slug"], "fingerprint": info["fingerprint"],
               "registered_at": localStamp()}
  try:
    return reply(appView(updateSettings(proc (data: JsonNode) = data["github_app"] = app)))
  except SettingsBroken:
    return brokenSettings()

proc registerAppReq*(body: JsonNode): Future[Reply] {.async.} =
  var id = body{"app_id"}
  if not id.isNil and id.kind == JString and id.getStr.strip.allIn(Digits):
    id = %parseBiggestInt(id.getStr.strip)
  if id.isNil or id.kind != JInt or id.getBiggestInt <= 0:
    return errorReply(400, "App ID は正の整数で指定してください", "app.app_id")
  let pem = body{"private_key"}
  if pem.isNil or pem.kind != JString or "-----BEGIN" notin pem.getStr or pem.getStr.runeLen > 32 * 1024:
    return errorReply(400, "秘密鍵は .pem ファイルの中身を貼り付けてください", "app.private_key")
  return await registerApp(id.getBiggestInt, pem.getStr.replace("\r\n", "\n"))

proc deleteAppReq*(): Reply =
  let fd = tryLockPoll()
  if fd.isNone:
    return errorReply(409, "ポーリングの実行中は削除できません。終わってから操作してください")
  defer: unlockPoll(fd.get)
  discard tryRemoveFile(appKeyFile)
  try:
    reply(appView(updateSettings(proc (data: JsonNode) =
      if data.hasKey("github_app"):
        data.delete("github_app"))))
  except SettingsBroken:
    brokenSettings()

proc notifyView(): JsonNode =
  if not fileExists(notifyFile):
    return %*{"registered": false}
  let saved = try: parseJson(readFile(notifyFile)) except CatchableError: nil
  if saved.isNil:
    return %*{"registered": false, "broken": true}
  %*{"registered": true, "url": saved.pyGet("url"), "room": saved.pyGet("room"),
     "registered_at": saved.pyGet("registered_at")}

proc notifyReply*(): Reply =
  reply(notifyView())

proc deleteNotify*(): Reply =
  discard tryRemoveFile(notifyFile)
  reply(notifyView())

proc isNotifyUrl(url: string): bool =
  const prefix = "https://"
  if not url.startsWith(prefix): return false
  var i = prefix.len
  let hostStart = i
  while i < url.len and url[i] in Letters + Digits + {'.', '-'}: inc i
  if i == hostStart: return false
  if i < url.len and url[i] == ':':
    inc i
    let portStart = i
    while i < url.len and url[i] in Digits: inc i
    if i == portStart: return false
  if i < url.len and url[i] == '/':
    inc i
    while i < url.len and url[i] in Letters + Digits + {'.', '_', '~', '/', '-'}: inc i
  i == url.len

proc registerNotify(url, room, secret: string): Future[Reply] {.async.} =
  prepareSecretsDir()
  let config = %*{"url": url, "room": room, "secret": secret, "registered_at": localStamp()}
  let tmp = writeSecretTmp(".nextcloud.json", $config)
  try:
    var r: RunResult
    try:
      r = await runAsync(mopuBin, @["notify", tmp, "mopu-agent の通知を登録しました"], 30_000)
    except OSError as e:
      return errorReply(500, "mopu notify を起動できません: " & e.msg)
    if r.timedOut:
      return errorReply(504, "Nextcloud への送信がタイムアウトしました")
    if r.exitCode != 0:
      return errorReply(400, "テストメッセージを送れませんでした: " & lastLine(r.errors, "送信できませんでした"))
    moveFile(tmp, notifyFile)
  finally:
    discard tryRemoveFile(tmp)
  return reply(notifyView())

proc registerNotifyReq*(body: JsonNode): Future[Reply] {.async.} =
  proc field(key: string): string =
    unicode.strip(if truthy(body{key}): pyStr(body[key]) else: "")
  let url = field("url").strip(leading = false, chars = {'/'})
  if not isNotifyUrl(url):
    return errorReply(400, "https:// で始まる Nextcloud の URL を指定してください", "notify.url")
  let room = field("room")
  if not room.allIn(Letters + Digits):
    return errorReply(400, "会話の URL の /call/ に続く英数字を指定してください", "notify.room")
  let secret = field("secret")
  if secret.len == 0 or hasControl(secret):
    return errorReply(400, "bot を登録したときの secret を指定してください", "notify.secret")
  return await registerNotify(url, room, secret)
