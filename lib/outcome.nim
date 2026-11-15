import std/[json, os, sequtils, strutils, unicode]
import process

const outcomeFileName* = ".mopu-agent-outcome.json"

type CallConditions* = object
  headStart*: string
  hasPr*, prOurs*: bool
  commentIds*: seq[string]
  maxSubIssues*: int

proc conditionsFromEnv*(): CallConditions =
  CallConditions(
    headStart: getEnv("MOPU_HEAD_START"),
    hasPr: getEnv("MOPU_HAS_PR", "0") notin ["", "0"],
    prOurs: getEnv("MOPU_PR_OURS", "0") notin ["", "0"],
    commentIds: getEnv("MOPU_COMMENT_IDS").split(' ').filterIt(it.len > 0),
    maxSubIssues: (try: parseInt(getEnv("MOPU_MAX_SUB_ISSUES", "5")) except ValueError: 5),
  )

proc hasText(node: JsonNode): bool =
  node != nil and node.kind == JString and node.getStr.toRunes.anyIt(not it.isWhiteSpace)

proc validPlan*(plan: JsonNode, maxSubIssues: int): bool =
  let subs = if plan != nil and plan.kind == JObject: plan{"sub_issues"} else: nil
  subs != nil and subs.kind == JArray and subs.len in 1 .. maxSubIssues and
    subs.elems.allIt(it.kind == JObject and it{"title"} != nil and it["title"].kind == JString and
                     it["title"].getStr.len > 0)

proc outcomeProblem*(state, wt: string, cond: CallConditions): string =
  let allowed =
    if state.startsWith("triage-"): @["implement", "decompose", "ask", "answer"]
    elif state == "implement": @["done", "ask"]
    elif state == "fix": @["done", "ask", "give_up"]
    elif state == "report": @["done"]
    else: return "出口ファイルを持たない state: " & state
  let head = gitOut(wt, "rev-parse", "HEAD")

  if gitOut(wt, "status", "--porcelain").len > 0:
    return
      if state in ["implement", "fix"]:
        "コミットしていない変更が残っている。git add でファイルを指定してコミットするか、不要なら元に戻す"
      else:
        "このフェーズでは作業ツリーを変更しない。変更を元に戻す"
  let readOnly = state.startsWith("triage-") or state == "report"
  if readOnly and head != cond.headStart:
    return "このフェーズではコミットしない。git reset --hard " & cond.headStart & " で戻す"

  let f = wt / outcomeFileName
  if not fileExists(f) or getFileSize(f) == 0:
    return "出口ファイル " & outcomeFileName & " が無い"
  var outcome: JsonNode
  try:
    outcome = parseFile(f)
  except CatchableError:
    discard
  if outcome == nil or outcome.kind != JObject:
    return outcomeFileName & " が JSON のオブジェクトではない"
  let d = outcome{"decision"}
  let decision =
    if d == nil or d.kind == JNull or (d.kind == JBool and not d.getBool): ""
    elif d.kind == JString: d.getStr
    else: $d
  if decision notin allowed:
    return "decision は " & allowed.join("・") & " のどれか（今は \"" & decision & "\"）"

  var need: seq[string]
  var ending = false
  if state.startsWith("triage-") and decision == "implement":
    need = @["note"]
    if not cond.hasPr:
      need.add "no_split_reason"
  elif state.startsWith("triage-") and decision == "decompose":
    if cond.hasPr:
      return "PR がある Issue は分解できない。implement・ask・answer から選ぶ"
    if not validPlan(outcome{"plan"}, cond.maxSubIssues):
      return "plan.sub_issues は 1〜" & $cond.maxSubIssues & " 件の配列で、各要素に空でない title が要る"
    ending = true
  elif decision == "ask":
    need = @["question"]
    ending = true
  elif decision == "answer":
    need = @["answer"]
    ending = true
  elif decision == "give_up":
    need = @["reason"]
  elif decision == "done" and state in ["implement", "fix"]:
    if head == cond.headStart:
      return "コミットが無い。変更をコミットしてから done にする"
  elif decision == "done" and state == "report":
    if cond.prOurs:
      need = @["pr_body"]
    ending = true

  for k in need:
    if not hasText(outcome{k}):
      return k & " が空"

  if ending and cond.commentIds.len > 0:
    let replies = outcome{"replies"}
    var missing: seq[string]
    for id in cond.commentIds:
      let r = if replies != nil and replies.kind == JObject: replies{id} else: nil
      if r == nil or r.kind != JString or r.getStr.len == 0:
        missing.add id
    if missing.len > 0:
      return "replies に次のコメントへの返信が無い: " & missing.join(" ")
  ""
