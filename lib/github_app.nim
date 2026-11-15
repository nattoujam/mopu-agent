import std/[base64, json, openssl, strutils, times]
import process

proc RSA_check_key(rsa: PRSA): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc i2d_PUBKEY(pkey: EVP_PKEY, pp: ptr ptr uint8): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_DigestSign(ctx: EVP_MD_CTX, sig: pointer, siglen: ptr csize_t, tbs: pointer,
                    tbslen: csize_t): cint {.cdecl, dynlib: DLLUtilName, importc.}

type KeyError* = object of CatchableError

proc b64url(s: string): string =
  base64.encode(s, safe = true).strip(leading = false, chars = {'='})

proc withBio[T](pem: string, f: proc (bio: BIO): T): T =
  let bio = BIO_new_mem_buf(pem.cstring, pem.len.cint)
  if bio == nil:
    raise newException(KeyError, "秘密鍵を読めません")
  defer: discard BIO_free(bio)
  f(bio)

proc readKey(pem: string): EVP_PKEY =
  result = withBio(pem, proc (bio: BIO): EVP_PKEY = PEM_read_bio_PrivateKey(bio, nil, nil, nil))
  if result == nil:
    raise newException(KeyError, "秘密鍵を読めません")

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
    raise newException(KeyError, "署名できません")
  result = newString(length)
  if EVP_DigestSign(ctx, result[0].addr, length.addr, data.cstring, data.len.csize_t) != 1:
    raise newException(KeyError, "署名できません")
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
    raise newException(KeyError, "公開鍵を取り出せません")
  var der = newString(n)
  var p = cast[ptr uint8](der[0].addr)
  discard i2d_PUBKEY(key, p.addr)
  let ctx = EVP_MD_CTX_create()
  defer: EVP_MD_CTX_destroy(ctx)
  var digest = newString(32)
  var length: cuint
  if EVP_DigestInit_ex(ctx, EVP_sha256()) != 1 or
      EVP_DigestUpdate(ctx, der.cstring, der.len.cuint) != 1 or
      EVP_DigestFinal_ex(ctx, digest[0].addr, length.addr) != 1:
    raise newException(KeyError, "フィンガープリントを計算できません")
  "SHA256:" & base64.encode(digest)

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
  except KeyError:
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
