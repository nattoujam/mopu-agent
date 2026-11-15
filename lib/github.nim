import std/[json, os, streams, strutils, tempfiles]
import config, log, process

# gh api --paginate はページごとの配列を続けて出力するため、断片ごとに読む
proc ghPages*(path: string): seq[JsonNode] =
  let r = ghRun(["api", "--paginate", path])
  if r.exitCode != 0:
    return
  try:
    for page in parseJsonFragments(newStringStream(r.output)):
      if page.kind == JArray:
        for item in page:
          result.add item
  except CatchableError:
    discard

proc ghJson*(args: openArray[string]): JsonNode =
  let r = ghRun(args)
  if r.exitCode != 0:
    return nil
  try: parseJson(r.output) except CatchableError: nil

proc issueLabels*(cfg: Config, number: string): seq[string] =
  let r = ghRun(["issue", "view", number, "-R", cfg.repo, "--json", "labels", "--jq", ".labels[].name"])
  if r.exitCode == 0:
    for line in r.output.splitLines:
      if line.len > 0:
        result.add line

proc postComment*(cfg: Config, issue, body: string): bool =
  let (f, path) = createTempFile("mopu-comment-", ".md")
  f.write CommentMarker & "\n\n" & body & "\n"
  f.close()
  defer: removeFile(path)
  ghShowingErrors(["issue", "comment", issue, "-R", cfg.repo, "--body-file", path])

proc alreadyPosted*(cfg: Config, kind, number, marker: string): bool =
  let path = if kind == "review": "pulls/" & number & "/comments" else: "issues/" & number & "/comments"
  for c in ghPages("repos/" & cfg.repo & "/" & path):
    let body = c{"body"}
    if body != nil and body.kind == JString and marker in body.getStr:
      return true
  false

# 返信はコメントが来た場所に返す。PR のレビューコメントは専用のエンドポイントでないと同じスレッドに入らない
proc postReply*(cfg: Config, kind, number, commentId, text, taskId: string) =
  let marker = "<!-- mopu-agent:reply-to " & commentId & " -->"
  let body = text & "\n\n" & marker
  if alreadyPosted(cfg, kind, number, marker):
    return
  if kind == "review":
    let r = ghRun(["api", "-X", "POST", "repos/" & cfg.repo & "/pulls/" & number & "/comments/" & commentId & "/replies",
                   "-f", "body=" & CommentMarker & "\n\n" & body])
    if r.exitCode == 0:
      return
    warn "[" & taskId & "] レビューコメント " & commentId & " への返信に失敗しました。#" & number & " にコメントします"
  discard postComment(cfg, number, body)

# 付いていないラベルの削除は gh がエラーにするため、追加と削除を分けて実行する
proc setLabels*(cfg: Config, issue, add: string) =
  if ghRun(["issue", "edit", issue, "-R", cfg.repo, "--add-label", add]).exitCode != 0:
    warn "ラベル '" & add & "' を付けられませんでした（mopu setup でラベルを作成してください）。既存のラベルは変更しません"
    return
  for label in AgentLabels:
    if label != add:
      discard ghRun(["issue", "edit", issue, "-R", cfg.repo, "--remove-label", label])
