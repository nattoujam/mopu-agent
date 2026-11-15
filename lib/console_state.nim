import std/[algorithm, json, os, strutils, times]
import paths, run_lock
from log import localStamp
export paths, run_lock, localStamp

type SettingsBroken* = object of CatchableError

proc log*(msg: string) =
  stderr.writeLine now().format("HH:mm:ss") & " [console] " & msg


proc sanitizeUtf8*(s: string): string =
  var i = 0
  while i < s.len:
    let b = s[i].uint8
    var need = 0
    var (lo, hi) = (0x80'u8, 0xBF'u8)
    if b < 0x80:
      result.add s[i]
      inc i
      continue
    elif b in 0xC2'u8 .. 0xDF'u8: need = 1
    elif b == 0xE0: (need, lo) = (2, 0xA0'u8)
    elif b == 0xED: (need, hi) = (2, 0x9F'u8)
    elif b in 0xE1'u8 .. 0xEF'u8: need = 2
    elif b == 0xF0: (need, lo) = (3, 0x90'u8)
    elif b == 0xF4: (need, hi) = (3, 0x8F'u8)
    elif b in 0xF1'u8 .. 0xF3'u8: need = 3
    else:
      result.add "�"
      inc i
      continue
    var j = 1
    while j <= need and i + j < s.len:
      let c = s[i + j].uint8
      if j == 1 and (c < lo or c > hi): break
      if j > 1 and (c < 0x80 or c > 0xBF): break
      inc j
    if j > need:
      result.add s[i ..< i + j]
    else:
      result.add "�"
    i += j

proc readText*(path: string, limit = -1): string =
  try:
    let f = open(path)
    defer: f.close()
    if limit >= 0:
      let size = f.getFileSize
      f.setFilePos(max(0'i64, size - limit))
    sanitizeUtf8(f.readAll())
  except IOError, OSError:
    ""

proc pySplitLines*(s: string): seq[string] =
  var line = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\n' or c == '\r':
      result.add line
      line = ""
      if c == '\r' and i + 1 < s.len and s[i + 1] == '\n':
        inc i
    else:
      line.add c
    inc i
  if line.len > 0:
    result.add line

proc pyEscape(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    elif c.ord < 0x20: result.add "\\u" & c.ord.toHex(4).toLowerAscii
    else: result.add c
  result.add '"'

proc pyDumps*(n: JsonNode): string =
  case n.kind
  of JNull: "null"
  of JBool: (if n.getBool: "true" else: "false")
  of JInt: $n.getBiggestInt
  of JFloat: $n.getFloat
  of JString: pyEscape(n.getStr)
  of JArray:
    var parts: seq[string]
    for v in n: parts.add pyDumps(v)
    "[" & parts.join(", ") & "]"
  of JObject:
    var parts: seq[string]
    for k, v in n: parts.add pyEscape(k) & ": " & pyDumps(v)
    "{" & parts.join(", ") & "}"

proc pyStr*(n: JsonNode): string =
  if n.isNil: return "None"
  case n.kind
  of JNull: "None"
  of JString: n.getStr
  of JBool: (if n.getBool: "True" else: "False")
  else: pyDumps(n)

proc readJsonFile*(path: string): JsonNode =
  try:
    parseJson(readFile(path))
  except CatchableError:
    newJNull()

proc pyGet*(n: JsonNode, key: string): JsonNode =
  let v = if n.isNil: nil else: n{key}
  if v.isNil: newJNull() else: v

proc isKind*(n: JsonNode, kinds: set[JsonNodeKind]): bool =
  not n.isNil and n.kind in kinds

proc truthy*(n: JsonNode): bool =
  if n.isNil: return false
  case n.kind
  of JNull: false
  of JBool: n.getBool
  of JInt: n.getInt != 0
  of JFloat: n.getFloat != 0
  of JString: n.getStr.len > 0
  of JArray: n.len > 0
  of JObject: n.len > 0

proc loadSettings*(): JsonNode =
  if not fileExists(settingsFile):
    return nil
  try:
    parseJson(readFile(settingsFile))
  except JsonParsingError, IOError:
    raise newException(SettingsBroken, settingsFile)

proc updateSettings*(mutate: proc (data: JsonNode)): JsonNode =
  result = loadSettings()
  if result.isNil:
    result = %*{"version": 1}
  mutate(result)
  createDir(stateDir)
  let tmp = settingsFile & ".tmp"
  writeFile(tmp, result.pretty(2) & "\n")
  moveFile(tmp, settingsFile)

proc repoNames*(settings: JsonNode): seq[string] =
  if settings.isNil or settings.kind != JObject:
    return
  let repos = settings{"repos"}
  if repos.isNil or repos.kind != JObject:
    return
  for name in repos.keys:
    result.add name
  result.sort()

