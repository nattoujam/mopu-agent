import std/[openssl, strutils]

proc sha256*(data: string): string =
  let ctx = EVP_MD_CTX_create()
  defer: EVP_MD_CTX_destroy(ctx)
  result = newString(32)
  var length: cuint
  if EVP_DigestInit_ex(ctx, EVP_sha256()) != 1 or
      EVP_DigestUpdate(ctx, data.cstring, data.len.cuint) != 1 or
      EVP_DigestFinal_ex(ctx, result[0].addr, length.addr) != 1:
    raise newException(ValueError, "SHA-256 を計算できません")

proc sha256Hex*(data: string): string =
  for c in sha256(data):
    result.add c.ord.toHex(2).toLowerAscii
