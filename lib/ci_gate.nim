import std/[json, options, os, sequtils, strutils]
import process

type
  Filters* = object
    branches*: Option[seq[string]]
    branchesIgnore*: Option[seq[string]]
    paths*: Option[seq[string]]
    pathsIgnore*: Option[seq[string]]
    types*: Option[seq[string]]

  TriggerKind* = enum
    tkNone = "none"
    tkUnknown = "unknown"
    tkOn = "on"

  PullRequestTrigger* = object
    case kind*: TriggerKind
    of tkNone: discard
    of tkUnknown: reason*: string
    of tkOn: triggers*: seq[Filters]

  Applicability* = enum
    apRuns = "runs"
    apSkips = "skips"
    apUnknown = "unknown"

const
  PrEvents = ["pull_request", "pull_request_target"]
  MaxDiffFiles = 3000

proc `==`*(a, b: PullRequestTrigger): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of tkNone: true
  of tkUnknown: a.reason == b.reason
  of tkOn: a.triggers == b.triggers

proc stripComment(line: string): string =
  var quote = '\0'
  for i, c in line:
    if quote != '\0':
      if c == quote:
        quote = '\0'
    elif c in {'"', '\''}:
      quote = c
    elif c == '#' and (i == 0 or line[i - 1] in Whitespace):
      return line[0 ..< i].strip(leading = false)
  line.strip(leading = false)

proc unquote(s: string): string =
  let t = s.strip
  if t.len >= 2 and ((t[0] == '"' and t[^1] == '"') or (t[0] == '\'' and t[^1] == '\'')):
    t[1 .. ^2]
  else:
    t

proc indentOf(line: string): int =
  line.len - line.strip(trailing = false).len

proc parseFlowSeq(s: string): Option[seq[string]] =
  let t = s.strip
  if not (t.startsWith("[") and t.endsWith("]")):
    return none(seq[string])
  let inner = t[1 .. ^2].strip
  some(if inner.len == 0: @[] else: inner.split(',').map(unquote))

proc seqItem(line: string): Option[string] =
  let t = line.strip(trailing = false)
  if t.startsWith("-"): some(t[1 .. ^1].strip(trailing = false)) else: none(string)

proc keyValue(line: string, keyChars: set[char]): Option[(string, string)] =
  let t = line.strip(trailing = false)
  var i = 0
  while i < t.len and t[i] in keyChars:
    inc i
  if i == 0 or i >= t.len or t[i] != ':':
    return none((string, string))
  some((t[0 ..< i], t[i + 1 .. ^1].strip(trailing = false)))

proc parseList(rest: string, blk: seq[string]): Option[seq[string]] =
  if rest.len > 0:
    return some(parseFlowSeq(rest).get(@[unquote(rest)]))
  var items: seq[string]
  for line in blk:
    let item = seqItem(line)
    if item.isNone:
      return none(seq[string])
    items.add unquote(item.get)
  some(items)

proc childBlock(lines: seq[string], start, indent: int): tuple[blk: seq[string], next: int] =
  var i = start
  while i < lines.len:
    let line = lines[i]
    if line.strip.len > 0:
      if indentOf(line) <= indent:
        break
      result.blk.add line
    inc i
  result.next = i

proc parseFilters(blk: seq[string]): Option[Filters] =
  var filters: Filters
  let base = if blk.len > 0: indentOf(blk[0]) else: 0
  var i = 0
  while i < blk.len:
    let line = blk[i]
    if indentOf(line) != base:
      return none(Filters)
    let kv = keyValue(line, Letters + {'_', '-'})
    if kv.isNone:
      return none(Filters)
    let (key, rest) = kv.get
    let (sub, next) = childBlock(blk, i + 1, base)
    if key in ["branches", "branches-ignore", "paths", "paths-ignore", "types"]:
      let list = parseList(rest, sub)
      if list.isNone:
        return none(Filters)
      case key
      of "branches": filters.branches = list
      of "branches-ignore": filters.branchesIgnore = list
      of "paths": filters.paths = list
      of "paths-ignore": filters.pathsIgnore = list
      else: filters.types = list
    i = next
  some(filters)

proc onKeyRest(line: string): Option[string] =
  for key in ["on:", "\"on\":", "'on':"]:
    if line.startsWith(key) and (line.len == key.len or line[key.len] in Whitespace):
      return some(line[key.len .. ^1].strip(trailing = false))
  none(string)

proc unknown(reason: string): PullRequestTrigger =
  PullRequestTrigger(kind: tkUnknown, reason: reason)

proc parsePullRequestTrigger*(yaml: string): PullRequestTrigger =
  let lines = yaml.split('\n').map(stripComment)
  var at = -1
  var rest = ""
  for i, l in lines:
    let r = onKeyRest(l)
    if r.isSome:
      (at, rest) = (i, r.get)
      break
  if at < 0:
    return unknown("on: が見つからない")

  if rest.len > 0:
    let events = parseFlowSeq(rest)
    if events.isNone and rest.startsWith("{"):
      return unknown("on: の値を読めない: " & rest)
    if events.get(@[unquote(rest)]).anyIt(it in PrEvents):
      return PullRequestTrigger(kind: tkOn, triggers: @[Filters()])
    return PullRequestTrigger(kind: tkNone)

  let (blk, _) = childBlock(lines, at + 1, 0)
  if blk.len == 0:
    return unknown("on: の中身が空")
  let base = indentOf(blk[0])
  var triggers: seq[Filters]
  var i = 0
  while i < blk.len:
    let line = blk[i]
    if indentOf(line) != base:
      return unknown("インデントを読めない: " & line.strip)
    let item = seqItem(line)
    if item.isSome:
      if unquote(item.get) in PrEvents:
        triggers.add Filters()
      inc i
      continue
    let kv = keyValue(line, Letters + {'_'})
    if kv.isNone:
      return unknown("行を読めない: " & line.strip)
    let (event, valueRaw) = kv.get
    let (sub, next) = childBlock(blk, i + 1, base)
    if event in PrEvents:
      let value = valueRaw.strip
      if value.len == 0:
        let filters = if sub.len > 0: parseFilters(sub) else: some(Filters())
        if filters.isNone:
          return unknown(event & " の絞り込みを読めない")
        triggers.add filters.get
      elif value in ["null", "~", "{}"]:
        triggers.add Filters()
      else:
        return unknown(event & " の値を読めない: " & value)
    i = next
  if triggers.len > 0: PullRequestTrigger(kind: tkOn, triggers: triggers) else: PullRequestTrigger(kind: tkNone)

type
  AtomKind = enum
    akLit, akClass, akStar, akAny, akDirs
  Atom = object
    kind: AtomKind
    c: char
    negated: bool
    ranges: seq[(char, char)]
    optional, repeat: bool

proc compileGlob(pattern: string): seq[Atom] =
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '*':
      if i + 1 < pattern.len and pattern[i + 1] == '*':
        if i + 2 < pattern.len and pattern[i + 2] == '/':
          result.add Atom(kind: akDirs)
          i += 2
        else:
          result.add Atom(kind: akAny)
          i += 1
      else:
        result.add Atom(kind: akStar)
    elif c == '[' and pattern.find(']', i + 1) >= 0:
      let stop = pattern.find(']', i + 1)
      var body = pattern[i + 1 ..< stop]
      var atom = Atom(kind: akClass)
      if body.startsWith("^"):
        atom.negated = true
        body = body[1 .. ^1]
      var j = 0
      while j < body.len:
        if j + 2 < body.len and body[j + 1] == '-':
          atom.ranges.add (body[j], body[j + 2])
          j += 3
        else:
          atom.ranges.add (body[j], body[j])
          inc j
      result.add atom
      i = stop
    elif c in {'?', '+'} and i > 0 and result.len > 0:
      if not (result[^1].optional or result[^1].repeat):
        if c == '?': result[^1].optional = true else: result[^1].repeat = true
    else:
      result.add Atom(kind: akLit, c: c)
    inc i

proc matchesOne(a: Atom, c: char): bool =
  case a.kind
  of akLit: c == a.c
  of akClass: a.ranges.anyIt(c >= it[0] and c <= it[1]) != a.negated
  else: false

proc matchFrom(atoms: seq[Atom], ai: int, s: string, si: int): bool =
  if ai == atoms.len:
    return si == s.len
  let a = atoms[ai]
  case a.kind
  of akStar, akAny:
    var j = si
    while true:
      if matchFrom(atoms, ai + 1, s, j):
        return true
      if j >= s.len or (a.kind == akStar and s[j] == '/'):
        return false
      inc j
  of akDirs:
    if matchFrom(atoms, ai + 1, s, si):
      return true
    var j = si
    while j < s.len:
      if s[j] == '/' and matchFrom(atoms, ai + 1, s, j + 1):
        return true
      inc j
    return false
  of akLit, akClass:
    if a.optional and matchFrom(atoms, ai + 1, s, si):
      return true
    var j = si
    while j < s.len and matchesOne(a, s[j]):
      inc j
      if matchFrom(atoms, ai + 1, s, j):
        return true
      if not a.repeat:
        break
    return false

proc globMatch*(pattern, value: string): bool =
  matchFrom(compileGlob(pattern), 0, value, 0)

proc matchesFilter*(patterns: seq[string], value: string): bool =
  for p in patterns:
    if p.startsWith("!"):
      if globMatch(p[1 .. ^1], value):
        result = false
    elif globMatch(p, value):
      result = true

proc filtersApply*(f: Filters, baseBranch: string, files: seq[string]): Applicability =
  if f.types.isSome and "synchronize" notin f.types.get:
    return apUnknown
  if files.len > MaxDiffFiles:
    return apUnknown
  if f.branches.isSome and not matchesFilter(f.branches.get, baseBranch):
    return apSkips
  if f.branchesIgnore.isSome and matchesFilter(f.branchesIgnore.get, baseBranch):
    return apSkips
  if files.len == 0:
    return apSkips
  if f.paths.isSome and not files.anyIt(matchesFilter(f.paths.get, it)):
    return apSkips
  if f.pathsIgnore.isSome and files.allIt(matchesFilter(f.pathsIgnore.get, it)):
    return apSkips
  apRuns

proc workflowApplies*(yaml, baseBranch: string, files: seq[string]): Applicability =
  let t = parsePullRequestTrigger(yaml)
  case t.kind
  of tkNone: apSkips
  of tkUnknown: apUnknown
  of tkOn:
    let results = t.triggers.mapIt(filtersApply(it, baseBranch, files))
    if apRuns in results: apRuns
    elif apUnknown in results: apUnknown
    else: apSkips

proc isTestRelated(path: string): bool =
  let parts = path.split('/')
  let name = parts[^1]
  for dir in parts[0 ..< ^1]:
    if dir in ["test", "tests", "__tests__", "spec", "specs", "e2e", "vrt", "__snapshots__", "__screenshots__"]:
      return true
  for i in 0 ..< parts.len - 2:
    if parts[i] == ".github" and parts[i + 1] == "workflows":
      return true
  for marker in [".test.", ".spec."]:
    let at = name.find(marker)
    if at >= 0 and at + marker.len < name.len:
      return true
  for tool in ["playwright", "jest", "vitest", "mocha", "karma", "cypress"]:
    let prefix = tool & ".config."
    if name.startsWith(prefix) and name.len > prefix.len:
      return true
  false

proc testRelatedFiles*(files: seq[string]): seq[string] =
  files.filter(isTestRelated)

proc git(dir: string, args: openArray[string]): string =
  let (output, code) = capture("git", @["-C", dir] & @args)
  if code != 0:
    raise newException(OSError, "git " & args.join(" ") & " が " & $code & " で終わりました")
  output

proc scriptsOf(dir, rev, path: string): string =
  try:
    let scripts = parseJson(git(dir, ["show", rev & ":" & path])){"scripts"}
    if scripts.isNil: "{}" else: $scripts
  except CatchableError:
    ""

proc nonEmptyLines(s: string): seq[string] =
  s.split('\n').filterIt(it.len > 0)

proc inspect*(wt, rf, baseBranch: string): JsonNode =
  let files = git(wt, ["diff", "--name-only", "--merge-base", rf, "HEAD"]).nonEmptyLines
  var workflows = newJArray()
  var applies: seq[Applicability]
  for file in git(wt, ["ls-tree", "--name-only", rf, ".github/workflows/"]).nonEmptyLines:
    if file.endsWith(".yml") or file.endsWith(".yaml"):
      let a = workflowApplies(git(wt, ["show", rf & ":" & file]), baseBranch, files)
      applies.add a
      workflows.add %*{"file": file, "applies": $a}
  var testChanges = testRelatedFiles(files)
  for f in files:
    if f.extractFilename == "package.json" and scriptsOf(wt, rf, f) != scriptsOf(wt, "HEAD", f):
      testChanges.add f & "（scripts）"
  let ci = if apRuns in applies: apRuns elif apUnknown in applies: apUnknown else: apSkips
  %*{"ci": $ci, "files": files, "workflows": workflows, "test_changes": testChanges}

when isMainModule:
  let args = commandLineParams()
  if args.len != 4 or args[0] != "inspect":
    stderr.writeLine "使い方: ci_gate inspect <worktree> <origin/BASE_BRANCH> <BASE_BRANCH>"
    quit 1
  try:
    stdout.writeLine $inspect(args[1], args[2], args[3])
  except OSError as e:
    stderr.writeLine e.msg
    quit 1
