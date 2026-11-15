import std/[json, strutils, unicode]
import config, github, log, notify, outcome, phases, process

const
  PlanMarker* = "<!-- mopu-agent:plan -->"
  PlanApprovedMarker = "<!-- mopu-agent:plan-approved -->"
  PlanWithdrawnMarker = "<!-- mopu-agent:plan-withdrawn -->"
  ApproveWord = "approve"

proc trimNewlines(s: string): string = s.strip(leading = false, chars = {'\n'})

proc field(node: JsonNode, key: string): string =
  let v = node{key}
  if v == nil or v.kind == JNull: "" elif v.kind == JString: v.getStr else: $v

proc createSubIssues(cfg: Config, parent: string, plan: JsonNode): seq[string] =
  for sub in plan["sub_issues"]:
    let title = trimNewlines(field(sub, "title"))
    let body = trimNewlines(field(sub, "body")) & "\n\n---\n" & CommentMarker & "\n" & SubIssueMarker & " #" & parent & " -->"
    let r = capture("gh", ["api", "repos/" & cfg.repo & "/issues", "-f", "title=" & title, "-f", "body=" & body,
                           "-f", "labels[]=" & LabelQueued], mergeStderr = true)
    if r.exitCode != 0:
      warn "sub issue の作成に失敗しました: " & title
      let lines = r.output.splitLines
      warn lines[0 ..< min(3, lines.len)].join("\n")
      continue
    let resp = parseJson(r.output)
    let num = $resp["number"]
    # 親子の紐付けだけ失敗しても、作成済みの Issue は残して先へ進む
    if ghRun(["api", "-X", "POST", "repos/" & cfg.repo & "/issues/" & parent & "/sub_issues",
              "-F", "sub_issue_id=" & $resp["id"]]).exitCode != 0:
      warn "#" & num & " を #" & parent & " の sub issue に紐付けられませんでした"
    result.add "- #" & num & " " & title

proc renderPlanComment*(cfg: Config, plan: JsonNode): string =
  result = "このタスクは 1 つの PR には大きいので、次のように分けて進めようと思います。この分け方でよいですか？\n\n"
  let reason = trimNewlines(field(plan, "reason"))
  if reason.len > 0:
    result.add reason & "\n\n"
  var i = 0
  for sub in plan["sub_issues"]:
    inc i
    result.add $i & ". **" & trimNewlines(field(sub, "title")) & "**"
    let outline = trimNewlines(field(sub, "outline"))
    if outline.len > 0:
      result.add " — " & outline
    result.add "\n"
  result.add "\n上から順に、前の PR がマージされてから次に着手します。\n\n"
  result.add "- 承認: `" & cfg.triggerCommand & " " & ApproveWord & "` とコメント\n"
  result.add "- 修正: `" & cfg.triggerCommand & "` に続けて直してほしい点を書く\n"
  result.add "- 却下: ラベル `" & LabelAwaiting & "` を外すか Issue を閉じる\n\n"
  result.add "<details><summary>各 sub issue の本文（承認時はこの内容で作成します。手で直しても構いません）</summary>\n\n```json\n" &
    plan.pretty(2) & "\n```\n\n</details>\n\n" & PlanMarker

proc latestPlanComment*(cfg: Config, number: string): JsonNode =
  for c in ghPages("repos/" & cfg.repo & "/issues/" & number & "/comments"):
    let body = c{"body"}
    if body != nil and body.kind == JString and PlanMarker in body.getStr:
      result = c

proc patchComment(cfg: Config, id, body: string): bool =
  ghRun(["api", "-X", "PATCH", "repos/" & cfg.repo & "/issues/comments/" & id, "-f", "body=" & body]).exitCode == 0

proc withdrawPlan*(cfg: Config, number: string) =
  let comment = latestPlanComment(cfg, number)
  if comment == nil:
    return
  let body = "（この案は取り下げました）\n\n" &
    trimNewlines(comment["body"].getStr.replace(PlanMarker, PlanWithdrawnMarker))
  if not patchComment(cfg, $comment["id"], body):
    warn "#" & number & " の分解案を取り下げられませんでした"

# Web UI で編集されると改行が CRLF になるため、行末の \r を落とす
proc planFromComment*(comment: JsonNode): string =
  var inBlock = false
  var lines: seq[string]
  for raw in comment["body"].getStr.split('\n'):
    let line = if raw.endsWith("\r"): raw[0 ..< ^1] else: raw
    if line == "```json":
      inBlock = true
    elif line == "```" and inBlock:
      break
    elif inBlock:
      lines.add line
  lines.join("\n")

proc isApproveInstruction(cfg: Config, s: string): bool =
  unicode.strip(s) == cfg.triggerCommand & " " & ApproveWord

proc approveCommentId*(cfg: Config, task: JsonNode): string =
  if task{"kind"}.getStr != "comment":
    return ""
  let comments = task{"comments"}
  if comments == nil or comments.kind != JArray:
    return ""
  for c in comments:
    if isApproveInstruction(cfg, c{"instruction"}.getStr):
      return c{"id"}.getStr
  ""

proc approvePlanTask*(cfg: Config, task: JsonNode): bool =
  let approveId = approveCommentId(cfg, task)
  if approveId.len == 0:
    return false
  let number = $task["number"]
  var approve: JsonNode
  for c in task["comments"]:
    if c["id"].getStr == approveId:
      if approve == nil:
        approve = c
      continue
    postReply(cfg, c["reply_kind"].getStr, $c["reply_number"], c["id"].getStr,
      "分解案の承認と同じ回に届いたため、この指示は処理していません。sub issue の作成後に改めて投稿してください。", "")
  proc replyApprove(text: string) =
    postReply(cfg, approve["reply_kind"].getStr, $approve["reply_number"], approveId, text, "")

  let comment = latestPlanComment(cfg, number)
  if comment == nil:
    warn "#" & number & " に承認待ちの分解案がありません"
    replyApprove("承認待ちの分解案がありません。分解が必要なら `" & LabelQueued & "` を付け直してください。")
    return true

  let plan = (try: parseJson(planFromComment(comment)) except CatchableError: nil)
  if plan == nil or not validPlan(plan, cfg.maxSubIssues):
    err "#" & number & " の分解案を解釈できません"
    notify("❌ **失敗** " & issueRef(cfg.repo, number) & "\n" & mdQuote("分解案の plan.json を解釈できませんでした"))
    setLabels(cfg, number, LabelFailed)
    replyApprove("分解案の plan.json を解釈できませんでした。コメントを編集した場合は JSON として正しいか確認してください。")
    return true

  log "#" & number & " の分解案を承認: sub issue を作成します (" & $plan["sub_issues"].len & " 件)"
  let created = createSubIssues(cfg, number, plan)
  if created.len == 0:
    err "#" & number & " の sub issue を 1 件も作成できませんでした"
    notify("❌ **失敗** " & issueRef(cfg.repo, number) & "\n" & mdQuote("分解案は承認されましたが、sub issue を作成できませんでした"))
    setLabels(cfg, number, LabelFailed)
    replyApprove("分解案は承認されましたが、sub issue の作成に失敗しました。")
    return true

  # 同じ案を二度承認して sub issue を重複させないよう、案のマーカーを書き換える
  if not patchComment(cfg, $comment["id"],
                      trimNewlines(comment["body"].getStr.replace(PlanMarker, PlanApprovedMarker))):
    warn "#" & number & " の分解案コメントを承認済みに更新できませんでした"

  setLabels(cfg, number, LabelDone)
  let list = created.join("\n")
  replyApprove("**分解案を承認しました。作成した sub issue**:\n" & list & "\n\n" &
    "それぞれに `" & LabelQueued & "` が付いています。次回のポーリングから順に実装され、すべて閉じたらこの Issue も自動で閉じます。")
  log "#" & number & " 分解完了: " & $created.len & " 件の sub issue を作成しました"
  notify("🧩 " & issueRef(cfg.repo, number) & " sub issue を " & $created.len & " 件作成しました\n" & list, silent = true)
  true

# sub issue の PR は sub issue しか閉じないため、親はここで閉じる。
# subIssuesSummary.completed は not planned の扱いが文書化されていないので state で数える
const CompletedParentsQuery = """
  query($owner:String!, $name:String!, $label:String!) {
    repository(owner:$owner, name:$name) {
      issues(first:50, states:OPEN, labels:[$label]) {
        nodes { number title subIssues(first:100) { nodes { number state } } }
      }
    }
  }"""

proc closeCompletedParents*(cfg: Config, dryRun: bool) =
  let parts = cfg.repo.split('/')
  let res = ghJson(["api", "graphql", "-f", "owner=" & parts[0], "-f", "name=" & parts[^1],
                    "-f", "label=" & LabelDone, "-f", "query=" & CompletedParentsQuery])
  let nodes = if res == nil: nil else: res{"data", "repository", "issues", "nodes"}
  if nodes == nil or nodes.kind != JArray:
    return
  for n in nodes:
    let subNodes = n{"subIssues", "nodes"}
    if subNodes == nil or subNodes.len == 0:
      continue
    var closed = true
    var subs: seq[string]
    for s in subNodes:
      subs.add "#" & $s["number"]
      if s{"state"}.getStr != "CLOSED":
        closed = false
    if not closed:
      continue
    let number = $n["number"]
    let title = n{"title"}.getStr
    let list = subs.join(", ")
    if dryRun:
      log "sub issue (" & list & ") がすべて閉じているため閉じます（dry-run）: #" & number & " " & title
      continue
    if postComment(cfg, number, "sub issue (" & list & ") がすべて閉じたので、この Issue を閉じます。") and
        ghRun(["issue", "close", number, "-R", cfg.repo, "--reason", "completed"]).exitCode == 0:
      log "sub issue (" & list & ") がすべて閉じたため閉じました: #" & number & " " & title
      notify("🏁 " & issueRef(cfg.repo, number) & " " & title & "\nsub issue（" & list & "）がすべて閉じたため閉じました", silent = true)
    else:
      warn "#" & number & " を閉じられませんでした"
