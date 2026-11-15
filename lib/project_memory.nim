# エージェントは --setting-sources '' で起動するので、Claude Code 自身は対象リポジトリの
# CLAUDE.md も .claude/rules/ も読まない。ここで origin にある内容を読んでシステムプロンプトに足す。
# worktree の内容を読まないのは、エージェントが PR の中で書き換えた基準を次の周回に効かせないため

import std/[os, sets, strutils, unicode]
import process, resources

const
  MaxChars = 60000
  # Claude Code の @ の取り込みと同じ深さ
  MaxDepth = 4

proc isBlank(c: char): bool = c in {' ', '\t', '\n', '\v', '\f', '\r'}

proc startsFence(line: string): bool =
  var i = 0
  while i < line.len and isBlank(line[i]): inc i
  line.continuesWith("```", i) or line.continuesWith("~~~", i)

proc normalize*(path: string): string =
  var parts: seq[string]
  for part in path.split('/'):
    case part
    of "", ".": discard
    of "..":
      if parts.len == 0: return ""
      parts.setLen(parts.len - 1)
    else: parts.add part
  parts.join("/")

proc removeInlineCode(line: string): string =
  var i = 0
  while i < line.len:
    if line[i] == '`':
      let close = line.find('`', i + 1)
      if close >= 0:
        i = close + 1
        continue
    result.add line[i]
    inc i

# Claude Code はコードブロックとインラインコードの中の @ を取り込みとして扱わないため、そこは除く
proc imports*(body: string): seq[string] =
  var fence = false
  for raw in body.split('\n'):
    if startsFence(raw):
      fence = not fence
      continue
    if fence:
      continue
    let line = removeInlineCode(raw)
    var i = 0
    while i < line.len:
      if line[i] == '@' and (i == 0 or isBlank(line[i - 1])):
        var j = i + 1
        while j < line.len and not isBlank(line[j]): inc j
        if j > i + 1:
          result.add line[i + 1 ..< j]
        i = j
      else:
        inc i

proc rulePaths*(text: string): string =
  let lines = text.split('\n')
  if lines.len == 0 or lines[0] != "---":
    return ""
  var inList = false
  var listed: seq[string]
  const blank = {' ', '\t', '\v', '\f', '\r'}
  for line in lines[1 .. ^1]:
    if line == "---":
      break
    if line.startsWith("paths:"):
      let rest = line["paths:".len .. ^1]
      if rest.allCharsInSet(blank):
        inList = true
      else:
        return rest.strip(trailing = false, chars = blank).multiReplace(
          ("[", ""), ("]", ""), ("\"", ""), ("'", ""))
    elif inList:
      var i = 0
      while i < line.len and isBlank(line[i]): inc i
      if i < line.len and line[i] == '-':
        inc i
        while i < line.len and isBlank(line[i]): inc i
        listed.add line[i .. ^1]
      else:
        inList = false
  listed.join(", ").multiReplace(("\"", ""), ("'", ""))

# Claude Code はブロック単位の HTML コメントを人間向けのメモとして読み込まないため、同じく除く
proc stripComments*(text: string): string =
  var fence, inComment = false
  var kept: seq[string]
  let lines = text.split('\n')
  for idx, line in lines:
    if idx == lines.len - 1 and line.len == 0:
      break
    if startsFence(line):
      fence = not fence
    if not fence and not inComment and line.strip(trailing = false).startsWith("<!--"):
      inComment = true
    if inComment:
      if line.strip(leading = false).endsWith("-->"):
        inComment = false
      continue
    kept.add line
  kept.join("\n")

proc stripFrontmatter*(text: string): string =
  var fm = false
  var kept: seq[string]
  let lines = text.split('\n')
  for idx, line in lines:
    if idx == lines.len - 1 and line.len == 0:
      break
    if idx == 0 and line == "---":
      fm = true
    elif fm and line == "---":
      fm = false
    elif not fm:
      kept.add line
  kept.join("\n")

type Loader = object
  gitdir, refName, output: string
  seen: HashSet[string]
  skipped: seq[string]

proc show(l: Loader, path: string): tuple[text: string, ok: bool] =
  let r = gitRun(l.gitdir, "show", l.refName & ":" & path)
  (r.output, r.exitCode == 0)

proc exists(l: Loader, path: string): bool =
  gitOk(l.gitdir, "cat-file", "-e", l.refName & ":" & path)

proc trimNewlines(s: string): string = s.strip(leading = false, chars = {'\n'})

proc addSection(l: var Loader, header, body: string) =
  let section = "### " & header & "\n\n" & trimNewlines(body)
  if l.output.runeLen + section.runeLen > MaxChars:
    let cut = header.find("（")
    l.skipped.add(if cut >= 0: header[0 ..< cut] else: header)
    return
  l.output.add "\n\n" & section

proc load(l: var Loader, path, header: string, depth: int) =
  if path in l.seen:
    return
  l.seen.incl path
  let (text, ok) = l.show(path)
  if not ok:
    return
  let body = trimNewlines(stripComments(text))
  l.addSection(header, body)
  if depth >= MaxDepth:
    return
  var dir = path.parentDir
  if dir == ".": dir = ""
  for raw in imports(body):
    var tok = raw
    # ホストのファイルをプロンプトに載せないよう、リポジトリの中を指す相対パスだけを展開する
    if tok.startsWith("/") or tok.startsWith("~") or "://" in tok:
      continue
    const trailing = [")", "]", "}", ".", ",", ";", ":", "!", "?", "。", "、", "」", "』", "）"]
    var trimmed = true
    while trimmed:
      trimmed = false
      for t in trailing:
        if tok.endsWith(t):
          tok = tok[0 ..< ^t.len]
          trimmed = true
    let target = normalize((if dir.len > 0: dir & "/" else: "") & tok)
    if target.len == 0 or not l.exists(target):
      continue
    l.load(target, target & "（" & path & " から取り込み）", depth + 1)

proc lsTree(l: Loader, args: varargs[string]): seq[string] =
  for line in gitRun(l.gitdir, @["ls-tree", "-r", "--name-only", l.refName] & @args).output.splitLines:
    if line.len > 0:
      result.add line

proc projectMemoryPrompt*(gitdir, refName: string): string =
  var l = Loader(gitdir: gitdir, refName: refName)
  var rootFound = false
  for path in ["CLAUDE.md", ".claude/CLAUDE.md"]:
    if l.exists(path):
      rootFound = true
      l.load(path, path, 0)
  # Claude Code は CLAUDE.md が無いときだけ AGENTS.md を読む
  if not rootFound and l.exists("AGENTS.md"):
    l.load("AGENTS.md", "AGENTS.md", 0)

  for path in l.lsTree("--", ".claude/rules"):
    if not path.endsWith(".md") or path in l.seen:
      continue
    l.seen.incl path
    let text = l.show(path).text
    let scope = rulePaths(text)
    l.addSection(path & (if scope.len > 0: "（適用範囲: " & scope & "）" else: ""),
                 stripComments(stripFrontmatter(text)))

  for path in l.lsTree():
    if (path == "CLAUDE.md" or path.endsWith("/CLAUDE.md")) and path notin ["CLAUDE.md", ".claude/CLAUDE.md"]:
      l.load(path, path & "（適用範囲: " & path.parentDir & "/**）", 0)

  if l.output.len == 0:
    return ""
  result = prompt("project-memory.md").replace("%%REF%%", refName) & l.output & "\n"
  if l.skipped.len > 0:
    result.add "\n（" & $MaxChars & " 文字の上限を超えたため、次は載せていない。必要なら作業ツリーで読むこと: " &
      l.skipped.join(" ") & "）\n"
  result = trimNewlines(result)
