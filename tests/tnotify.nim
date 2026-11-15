import std/[asyncdispatch, asynchttpserver, json, os, strutils, tempfiles, unittest, uri]
import ../lib/notify

const
  Secret = "test-secret-0123456789"
  Room = "abc123"

var
  ports: Channel[int]
  received: Channel[string]
  replies: Channel[int]

proc onRequest(req: Request) {.async, gcsafe.} =
  var headers = newJObject()
  for key, value in req.headers:
    headers[key.toLowerAscii] = %value
  received.send $(%*{"url": $req.url, "headers": headers, "body": parseJson(req.body)})
  let (replied, code) = replies.tryRecv()
  await req.respond(if replied: HttpCode(code) else: Http201, "{}",
                    newHttpHeaders({"Content-Type": "application/json"}))

# send は同期の HTTP クライアントで応答を待つので、受け手は別のスレッドで動かす
proc serve() {.thread.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  ports.send server.getPort.int
  while true:
    waitFor server.acceptRequest(onRequest)

ports.open()
received.open()
replies.open()
var serverThread: Thread[void]
createThread(serverThread, serve)
let config = createTempDir("notify-test-", "") / "nextcloud.json"
writeFile(config, $(%*{"url": "http://127.0.0.1:" & $ports.recv() & "/", "room": Room, "secret": Secret}))

suite "sign":
  test "HMAC-SHA256 の hex（RFC 4231 の test case 2）":
    check sign("Jefe", "what do ya ", "want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

suite "send":
  test "random と message の HMAC を署名に付けて、会話の bot API に送る":
    send(readConfig(config), "テスト の本文", true)
    let req = parseJson(received.recv())
    check req["url"].getStr == "/ocs/v2.php/apps/spreed/api/v1/bot/" & Room & "/message"
    check req["headers"]["ocs-apirequest"].getStr == "true"
    check req["body"] == %*{"message": "テスト の本文", "silent": true}
    let random = req["headers"]["x-nextcloud-talk-bot-random"].getStr
    check req["headers"]["x-nextcloud-talk-bot-signature"].getStr == sign(Secret, random, "テスト の本文")

  test "送れなかったら、ステータスをメッセージに入れて IOError を投げる":
    replies.send 401
    expect IOError:
      try:
        send(readConfig(config), "届かない", false)
      except IOError as e:
        check "HTTP 401" in e.msg
        raise
    discard received.recv()
