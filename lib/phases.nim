import std/[json, os, strutils]
import config, log, notify

proc issueRef*(repo: string, number = ""): string =
  let name = if '/' in repo: repo[repo.find('/') + 1 .. ^1] else: repo
  name & (if number.len > 0: "#" & number else: "")

proc mdQuote*(s: string): string =
  "> " & s.replace("\n", "\n> ")

proc taskIssue*(dir: string): tuple[repo, number: string] =
  let taskId = dir.extractFilename
  let slug = dir.parentDir.extractFilename
  for prefix in ["issue-", "comment-"]:
    if taskId.startsWith(prefix):
      let rest = taskId[prefix.len .. ^1]
      let dash = rest.find('-')
      if dash > 0 and rest[0 ..< dash].allCharsInSet(Digits):
        let sep = slug.find("__")
        let repo = if sep >= 0: slug[0 ..< sep] & "/" & slug[sep + 2 .. ^1] else: slug & "/" & slug
        return (repo, rest[0 ..< dash])
  ("", "")

proc notifyTask*(logDir, message: string) =
  let (repo, number) = taskIssue(logDir)
  if repo.len > 0:
    notify(issueRef(repo, number) & " " & message, silent = true)

proc notifyPhase(dir, phase, detail, body: string) =
  let (repo, number) = taskIssue(dir)
  if repo.len == 0:
    return
  let taskId = dir.extractFilename
  let r = issueRef(repo, number)
  let title = (try: parseFile(dir / TaskFileName){"title"}.getStr except CatchableError: "")
  let issueLink = "[Issue #" & number & "](https://github.com/" & repo & "/issues/" & number & ")"
  var silent = false
  var text: string
  case phase
  of "prepare":
    silent = true
    text = "▶ " & r & " " & title & "\n`" & taskId & "`"
  of "implement":
    silent = true
    text = r & " → 実装"
  of "verify":
    if detail == "push":
      return
    silent = true
    text = r & " → 検証（" & detail & "）"
  of "publish":
    silent = true
    text = r & " → 公開" & (if detail.len > 0: "（" & detail & "）" else: "")
  of "review":
    var link = issueLink
    if detail.startsWith("PR #") and detail.len > 4 and detail[4 .. ^1].allCharsInSet(Digits):
      let n = detail[4 .. ^1]
      link = "[PR #" & n & "](https://github.com/" & repo & "/pull/" & n & ")"
    text = "✅ **レビュー待ち** " & r & " " & title & "\n" & link
  of "answered": text = "💬 **回答済み** " & r & " " & title & "\n" & issueLink
  of "awaiting-input": text = "❓ **回答待ち** " & r & " " & title & "\n" & issueLink
  of "awaiting-approval":
    text = "📝 **承認待ち** " & r & " " & title & "\n" & (if detail.len > 0: detail & " · " else: "") & issueLink
  of "failed": text = "❌ **失敗** " & r & " " & title & "\n`" & taskId & "`\n" & mdQuote(detail)
  else: return
  notify(text & (if body.len > 0: "\n" & body else: ""), silent)

# タスクのフェーズの移り変わりを 1 行ずつ足す。最後の行が今のフェーズ
proc recordPhase*(file, phase: string, detail = "", body = "") =
  if file.len == 0 or not dirExists(file.parentDir):
    return
  var row = %*{"phase": phase, "at": localStamp()}
  if detail.len > 0:
    row["detail"] = %detail
  let f = open(file, fmAppend)
  f.writeLine $row
  f.close()
  notifyPhase(file.parentDir, phase, detail, body)
