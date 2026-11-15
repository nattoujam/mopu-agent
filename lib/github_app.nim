import std/[base64, json, openssl, os, strutils, times]
import config, crypto, log, paths, process

proc RSA_check_key(rsa: PRSA): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc i2d_PUBKEY(pkey: EVP_PKEY, pp: ptr ptr uint8): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_DigestSign(ctx: EVP_MD_CTX, sig: pointer, siglen: ptr csize_t, tbs: pointer,
                    tbslen: csize_t): cint {.cdecl, dynlib: DLLUtilName, importc.}

type AppKeyError* = object of CatchableError

proc b64url(s: string): string =
  base64.encode(s, safe = true).strip(leading = false, chars = {'='})

proc withBio[T](pem: string, f: proc (bio: BIO): T): T =
  let bio = BIO_new_mem_buf(pem.cstring, pem.len.cint)
  if bio == nil:
    raise newException(AppKeyError, "秘密鍵を読めません")
  defer: discard BIO_free(bio)
  f(bio)

proc readKey(pem: string): EVP_PKEY =
  result = withBio(pem, proc (bio: BIO): EVP_PKEY = PEM_read_bio_PrivateKey(bio, nil, nil, nil))
  if result == nil:
    raise newException(AppKeyError, "秘密鍵を読めません")

proc isRsaKey*(pem: string): bool =
  let rsa = withBio(pem, proc (bio: BIO): PRSA = PEM_read_bio_RSAPrivateKey(bio, nil, nil, nil))
  if rsa == nil:
    return false
  defer: RSA_free(rsa)
  RSA_check_key(rsa) == 1

proc signRs256(pem, data: string): string =
  let key = readKey(pem)
  defer: EVP_PKEY_free(key)
  let ctx = EVP_MD_CTX_create()
  defer: EVP_MD_CTX_destroy(ctx)
  var length: csize_t
  if EVP_DigestSignInit(ctx, nil, EVP_sha256(), nil, key) != 1 or
      EVP_DigestSign(ctx, nil, length.addr, data.cstring, data.len.csize_t) != 1:
    raise newException(AppKeyError, "署名できません")
  result = newString(length)
  if EVP_DigestSign(ctx, result[0].addr, length.addr, data.cstring, data.len.csize_t) != 1:
    raise newException(AppKeyError, "署名できません")
  result.setLen(length)

# GitHub App の JWT は RS256 固定。iat は時計ずれ対策で 60 秒過去に置き、
# exp は仕様上の上限が 10 分先
proc appJwt*(appId, pem: string, now = getTime().toUnix): string =
  let header = b64url("""{"alg":"RS256","typ":"JWT"}""")
  let payload = b64url("{\"iat\":" & $(now - 60) & ",\"exp\":" & $(now + 540) & ",\"iss\":" & $(%appId) & "}")
  let signing = header & "." & payload
  signing & "." & b64url(signRs256(pem, signing))

# GitHub の App 設定画面に表示されるフィンガープリントと同じ計算
proc fingerprint*(pem: string): string =
  let key = readKey(pem)
  defer: EVP_PKEY_free(key)
  let n = i2d_PUBKEY(key, nil)
  if n <= 0:
    raise newException(AppKeyError, "公開鍵を取り出せません")
  var der = newString(n)
  var p = cast[ptr uint8](der[0].addr)
  discard i2d_PUBKEY(key, p.addr)
  "SHA256:" & base64.encode(sha256(der))

type AppAuth* = ref object
  appId, pem, repo: string
  token: string
  expires: int64
  botName*, botEmail*: string

proc newAppAuth*(appId, keyFile, repo: string): AppAuth =
  AppAuth(appId: appId, pem: readFile(keyFile), repo: repo)

proc jwtApi(a: AppAuth, jwt: string, args: openArray[string], input = ""): tuple[output: string, exitCode: int] =
  capture("gh", @["api", "-H", "Authorization: Bearer " & jwt] & @args, input, env = [("GH_TOKEN", "")])

proc installationId(a: AppAuth, jwt: string): string =
  let r = a.jwtApi(jwt, ["repos/" & a.repo & "/installation", "--jq", ".id"])
  # 404 でも gh は本文を出すので、--jq '.id' は空ではなく "null" になる
  result = r.output.strip
  if r.exitCode != 0 or result.len == 0 or not result.allCharsInSet(Digits):
    result = ""

# installation access token は 1 時間で失効する。ポーリング 1 回のあいだは使い回せるので、プロセス内でキャッシュする
proc appToken*(a: AppAuth): string =
  let now = getTime().toUnix
  if a.token.len > 0 and now < a.expires - 300:
    return a.token
  var jwt: string
  try:
    jwt = appJwt(a.appId, a.pem)
  except AppKeyError:
    err "JWT の生成に失敗しました（秘密鍵を確認してください）"
    return ""
  let id = a.installationId(jwt)
  if id.len == 0:
    err "App が " & a.repo & " にインストールされていません（またはApp ID/秘密鍵が不正です）"
    return ""
  let r = a.jwtApi(jwt, ["-X", "POST", "app/installations/" & id & "/access_tokens"])
  if r.exitCode != 0:
    return ""
  let resp = (try: parseJson(r.output) except CatchableError: newJObject())
  let token = resp{"token"}
  if token == nil or token.kind != JString or token.getStr.len == 0:
    err "installation access token を取得できませんでした"
    return ""
  a.token = token.getStr
  try:
    a.expires = parseTime(resp{"expires_at"}.getStr, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toUnix
  except CatchableError:
    a.expires = now + 3600
  a.token

proc jwtOrEmpty(a: AppAuth): string =
  try: appJwt(a.appId, a.pem) except AppKeyError: ""

# エージェントに渡す用。App に付与されていない権限を要求すると 422 で失敗する
proc appTokenWith*(a: AppAuth, permissions: JsonNode): string =
  let jwt = a.jwtOrEmpty()
  if jwt.len == 0:
    return ""
  let id = a.installationId(jwt)
  if id.len == 0:
    return ""
  let r = a.jwtApi(jwt, ["-X", "POST", "app/installations/" & id & "/access_tokens", "--input", "-",
                         "--jq", ".token"], $(%*{"permissions": permissions}))
  if r.exitCode == 0: r.output.strip else: ""

proc refreshAppToken*(a: AppAuth) =
  let tok = a.appToken()
  if tok.len > 0:
    putEnv("GH_TOKEN", tok)

# bot のコミット author 名義。App の bot ユーザー ID は変わらないので一度だけ引く
proc botIdentity*(a: AppAuth): bool =
  if a.botEmail.len > 0:
    return true
  # GET /app は JWT 専用で、installation access token では 401 になる
  let jwt = a.jwtOrEmpty()
  if jwt.len == 0:
    return false
  let slug = a.jwtApi(jwt, ["app", "--jq", ".slug"]).output.strip
  if slug.len == 0:
    return false
  let uid = capture("gh", ["api", "users/" & slug & "[bot]", "--jq", ".id"]).output.strip
  if uid.len == 0:
    return false
  a.botName = slug & "[bot]"
  a.botEmail = uid & "+" & slug & "[bot]@users.noreply.github.com"
  true

proc setupAppAuth*(cfg: Config): AppAuth =
  result = newAppAuth(cfg.appId, appKeyFile, cfg.repo)
  let tok = result.appToken()
  if tok.len == 0:
    die "GitHub App の認証に失敗しました"
  putEnv("GH_TOKEN", tok)
  if result.botIdentity():
    for k in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"]: putEnv(k, result.botName)
    for k in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]: putEnv(k, result.botEmail)
    # 分解で作られた sub issue の author は bot 自身になるため、許可アクターに
    # 加えないと次のポーリングで弾かれる。bot 名義で Issue を作れるのは秘密鍵の
    # 持ち主だけなので、第三者の迂回には使えない。
    # 3 つとも必要。GraphQL は "<slug>"、gh は "app/<slug>"、REST は "<slug>[bot]" を返す
    let slug = result.botName[0 ..< ^"[bot]".len]
    cfg.allowedActors.add [slug, "app/" & slug, result.botName]
    log "GitHub App として動作します: " & result.botName
  else:
    warn "App の bot 情報を取得できませんでした。コミット author は既定値になります"

# push は認証情報を URL に埋めず、GIT_ASKPASS で渡す。git は GIT_ASKPASS をシェルを通さずに
# 実行するので、サブコマンドを付けられない。MOPU_ASKPASS で mopu 自身を askpass として動かす
proc askpassEnv*(): seq[(string, string)] =
  @[("GIT_ASKPASS", mopuBin), ("MOPU_ASKPASS", "1")]

proc askpassMain*(prompt: string) =
  stdout.writeLine(if "Username" in prompt: "x-access-token" else: getEnv("GH_TOKEN"))

proc appCheckMain*(args: seq[string]): int =
  if args.len != 2:
    stderr.writeLine "使い方: app-check <App ID> <秘密鍵のパス>"
    return 2
  let appId = args[0]
  if appId.len == 0 or not appId.allCharsInSet(Digits):
    stderr.writeLine "App ID は数字で指定してください"
    return 2
  let pem = (try: readFile(args[1]) except IOError: "")
  if not isRsaKey(pem):
    stderr.writeLine "RSA 秘密鍵として読めません"
    return 3
  var jwt, fp: string
  try:
    jwt = appJwt(appId, pem)
    fp = fingerprint(pem)
  except AppKeyError:
    stderr.writeLine "JWT を生成できません"
    return 3
  let r = capture("gh", ["api", "-H", "Authorization: Bearer " & jwt, "app", "--jq", ".slug"],
                  env = [("GH_TOKEN", "")])
  if r.exitCode != 0:
    stderr.writeLine "GitHub が App ID " & appId & " とこの鍵の組を受け付けませんでした"
    return 4
  let slug = r.output.strip
  if slug.len == 0:
    stderr.writeLine "GitHub から App の情報を取得できませんでした"
    return 4
  stdout.writeLine $(%*{"slug": slug, "fingerprint": fp})
  0
