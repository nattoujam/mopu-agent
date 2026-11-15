import std/[httpclient, json, openssl, os, sequtils, strutils, sysrand, uri]
import log, paths

type Config = object
  url, room, secret: string

proc readConfig(path: string): Config =
  let data = parseJson(readFile(path))
  if data.kind != JObject:
    raise newException(ValueError, path & " が JSON オブジェクトではありません")
  for key in ["url", "room", "secret"]:
    if data{key}.isNil or data[key].kind != JString:
      raise newException(ValueError, path & " に url / room / secret がありません")
  Config(url: data["url"].getStr.strip(leading = false, chars = {'/'}), room: data["room"].getStr,
         secret: data["secret"].getStr)

proc toHexLower(bytes: openArray[byte]): string =
  for b in bytes:
    result.add b.toHex(2).toLowerAscii

proc sign*(secret, random, message: string): string =
  let data = random & message
  var digest: array[32, byte]
  var length: cuint
  if HMAC(EVP_sha256(), secret.cstring, secret.len.cint, data.cstring, data.len.csize_t,
          cast[cstring](digest[0].addr), length.addr).isNil:
    raise newException(ValueError, "HMAC を計算できませんでした")
  toHexLower(digest)

proc send(config: Config, message: string, silent: bool) =
  let random = toHexLower(urandom(32))
  let client = newHttpClient(timeout = 10_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json",
    "OCS-APIRequest": "true",
    "X-Nextcloud-Talk-Bot-Random": random,
    "X-Nextcloud-Talk-Bot-Signature": sign(config.secret, random, message),
  })
  let url = config.url & "/ocs/v2.php/apps/spreed/api/v1/bot/" & encodeUrl(config.room, usePlus = false) & "/message"
  let res = client.post(url, body = $(%*{"message": message, "silent": silent}))
  if not res.code.is2xx:
    raise newException(IOError, "HTTP " & $res.code.int & ": " & res.body[0 ..< min(300, res.body.len)])

proc notify*(message: string, silent = false) =
  if not fileExists(notifyFile):
    return
  try:
    send(readConfig(notifyFile), message, silent)
  except CatchableError as e:
    warn "Nextcloud Talk に通知できませんでした: " & e.msg

proc notifyOnChange*(key, value, message: string, silent = false) =
  var state = (try: parseFile(notifyStateFile) except CatchableError: newJObject())
  if state.kind != JObject:
    state = newJObject()
  let prev = state{key}
  if (if prev == nil or prev.kind != JString: "" else: prev.getStr) == value:
    return
  state[key] = %value
  try:
    writeFile(notifyStateFile & ".tmp", $state & "\n")
    moveFile(notifyStateFile & ".tmp", notifyStateFile)
  except CatchableError:
    discard
  notify(message, silent)

proc notifyMain*(args: seq[string]): int =
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  let silent = "--silent" in rest
  let message = rest.filterIt(it != "--silent").join(" ")
  if args.len == 0 or message.len == 0:
    stderr.writeLine "使い方: notify <設定ファイル> [--silent] <本文>"
    return 1
  try:
    send(readConfig(args[0]), message, silent)
  except CatchableError as e:
    stderr.writeLine e.msg
    return 1
