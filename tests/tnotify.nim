import std/[asyncdispatch, asynchttpserver, json, os, osproc, streams, strutils, tables, tempfiles, unittest, uri]
import ../lib/notify

const
  Root = currentSourcePath().parentDir.parentDir
  Secret = "test-secret-0123456789"
  Room = "abc123"

type Received = object
  url: string
  headers: Table[string, string]
  body: JsonNode

var
  received: seq[Received]
  replies: seq[(HttpCode, string)]

proc handler(req: Request) {.async.} =
  var headers: Table[string, string]
  for key, value in req.headers:
    headers[key.toLowerAscii] = value
  received.add Received(url: $req.url, headers: headers, body: parseJson(req.body))
  let (code, body) = if replies.len > 0: replies.pop() else: (Http201, "{}")
  await req.respond(code, body, newHttpHeaders({"Content-Type": "application/json"}))

let server = newAsyncHttpServer()
server.listen(Port(0), "127.0.0.1")
let baseUrl = "http://127.0.0.1:" & $server.getPort.int

# テストのために 1 スレッドで動かしており、グローバルを読むハンドラを
# acceptRequest が求める gcsafe として渡すため。
proc acceptLoop() {.async.} =
  while true:
    await server.acceptRequest(proc (req: Request): Future[void] {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        result = handler(req))

asyncCheck acceptLoop()

proc notify(args: varargs[string]): tuple[code: int, stderr: string] =
  let config = createTempDir("notify-test-", "") / "nextcloud.json"
  writeFile(config, $(%*{"url": baseUrl & "/", "room": Room, "secret": Secret}))
  let p = startProcess(Root / "bin" / "mopu", args = @["notify", config] & @args)
  defer: p.close()
  while p.running:
    poll(20)
  result.stderr = p.errorStream.readAll()
  result.code = p.waitForExit()

suite "sign":
  test "HMAC-SHA256 の hex（RFC 4231 の test case 2）":
    check sign("Jefe", "what do ya ", "want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

suite "notify":
  setup:
    received.setLen(0)
    replies.setLen(0)

  test "random と message の HMAC を署名に付けて、会話の bot API に送る":
    check notify("--silent", "テスト", "の本文").code == 0
    check received.len == 1
    let req = received[0]
    check req.url == "/ocs/v2.php/apps/spreed/api/v1/bot/" & Room & "/message"
    check req.headers["ocs-apirequest"] == "true"
    check req.body == %*{"message": "テスト の本文", "silent": true}
    let random = req.headers["x-nextcloud-talk-bot-random"]
    check req.headers["x-nextcloud-talk-bot-signature"] == sign(Secret, random, "テスト の本文")

  test "送れなかったら、ステータスを stderr に出して 1 で終わる":
    replies = @[(Http401, "unauthorized")]
    let (code, stderr) = notify("届かない")
    check code == 1
    check "HTTP 401" in stderr
