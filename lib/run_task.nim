import std/[algorithm, json, os, sequtils, strutils, times]
import agent, budget, ci_gate, config, critic, crypto, github, github_app, history, hooks, log, outcome, phases,
       plan, process, project_memory, resources, workspace

const
  # 失敗した state を --retry でやり直すとき、その state より前の結果を前回のログから引き継ぐファイル
  CarryFiles = ["triage.json", "verify.json", "report.json"]
  # CI 待ちでタスクの時間制限を使い切っても、report を書けるようにする呼び出しごとの最低時間
  MinCallSeconds = 300
  CiMaxFixRounds = 5
  CriticMaxRounds = 2
  CiStartWait = 180
  CiPollSeconds = 20
  # エージェントの gh に渡すトークン。CI の結果を読めれば足りるので
  # actions:read に絞る。write を渡すと workflow_dispatch でデプロイ系の
  # ワークフローまで起動できてしまう
  AgentTokenPermissions = """{"actions":"read","contents":"read","metadata":"read"}"""

type Task = ref object
  p: PollState
  cfg: Config
  kind, number, title, body: string
  json: JsonNode
  id, branch, dir, wt, log: string
  commentIds: string
  cost: float
  calls: int
  fix: string
  state, next, failReason, failedState: string
  outcome: JsonNode
  endKind, endDetail, endBody: string
  deadline: int64
  entry, first: string
  pr: JsonNode
  prOurs: bool
  settings, sysPrompt, sysHash, memory, memoryHash: string
  pctBefore: string

proc trimNewlines(s: string): string = s.strip(leading = false, chars = {'\n'})

proc text(node: JsonNode, key: string): string =
  let v = if node == nil or node.kind != JObject: nil else: node{key}
  if v == nil or v.kind == JNull: "" elif v.kind == JString: v.getStr else: $v

proc readJson(path: string): JsonNode =
  try: parseFile(path) except CatchableError: nil

proc writeLine(path, line: string) = writeFile(path, line & "\n")

proc taskBranch*(task: JsonNode, number: string): string =
  let b = text(task, "branch")
  if b.len > 0: b else: BranchPrefix & number

proc phase(t: Task, name: string, detail = "", body = "") =
  recordPhase(t.log / PhaseFileName, name, detail, body)

proc leadQuote(s: string): string =
  if s.len == 0: return ""
  let cut = s.find("\n\n")
  mdQuote(if cut >= 0: s[0 ..< cut] else: s)

proc phaseHeader(name: string): string =
  "# フェーズ: " & name & "\n\nこのメッセージは mopu-agent からの、このフェーズの指示です。"

proc money(f: float): string = formatFloat(f, ffDecimal, 2)

# --- GitHub への報告 ---

proc prNumber(t: Task): string = $t.pr["number"]

proc postReplies(t: Task, outcome: JsonNode, footer = "") =
  let comments = t.json{"comments"}
  if comments == nil or comments.kind != JArray:
    return
  for c in comments:
    let id = c["id"].getStr
    let replies = outcome{"replies"}
    let reply = if replies != nil and replies.kind == JObject: trimNewlines(text(replies, id)) else: ""
    postReply(t.cfg, c["reply_kind"].getStr, $c["reply_number"], id,
              reply & (if footer.len > 0: "\n\n---\n" & footer else: ""), t.id)

# mopu-agent からの報告は、PR が無ければ Issue、あれば PR に書く
proc postTaskReport(t: Task, body: string) =
  discard postComment(t.cfg, if t.pr != nil: t.prNumber else: t.number, body)

proc answerFooter(t: Task): string =
  "回答は、行頭に `" & t.cfg.triggerCommand & "` を付けてコメントしてください。"

# タスクのブランチの、開いている PR を読み込む。gh pr view にブランチ名を渡すと、
# フォークから出た同名ブランチの PR も当たるため isCrossRepository を見る
proc loadTaskPr(t: Task) =
  t.pr = nil
  t.prOurs = false
  let pr = ghJson(["pr", "view", t.branch, "-R", t.cfg.repo, "--json", "number,url,isDraft,body,state,isCrossRepository"])
  if pr == nil or pr.kind != JObject or pr{"state"}.getStr != "OPEN" or
      pr{"isCrossRepository"} == nil or pr["isCrossRepository"].getBool:
    return
  t.pr = pr
  t.prOurs = CommentMarker in text(pr, "body")

proc prBodyWithMarker(t: Task, body: string): string =
  "Closes #" & t.number & "\n\n" & body & "\n\n---\n" & CommentMarker

# --- チェックポイント（Issue ごとの最後の会話） ---

proc sessions(cfg: Config): JsonNode =
  result = readJson(cfg.sessionFile)
  if result == nil or result.kind != JObject:
    result = newJObject()

proc checkpointGet(t: Task): JsonNode = sessions(t.cfg){t.number}

proc checkpointWrite(cfg: Config, data: JsonNode) =
  writeFile(cfg.sessionFile & ".tmp", data.pretty(2) & "\n")
  moveFile(cfg.sessionFile & ".tmp", cfg.sessionFile)

proc checkpointForget(cfg: Config, number: string) =
  var s = sessions(cfg)
  s.delete(number)
  checkpointWrite(cfg, s)

proc checkpointSet(t: Task, sessionId: string, cost: float) =
  var s = sessions(t.cfg)
  s[t.number] = %*{"session_id": sessionId, "head": gitOut(t.wt, "rev-parse", "HEAD"), "prompt_hash": t.sysHash,
                   "memory_hash": t.memoryHash, "cost_usd": cost, "updated": localStamp()}
  checkpointWrite(t.cfg, s)

# PR がマージされた Issue の、ローカルブランチとチェックポイントを消す
proc cleanupMerged*(p: PollState) =
  let cfg = p.cfg
  if not fileExists(cfg.sessionFile) or getFileSize(cfg.sessionFile) == 0:
    return
  let merged = ghJson(["pr", "list", "-R", cfg.repo, "--state", "merged", "--limit", "100", "--json", "number,headRefName"])
  if merged == nil or merged.kind != JArray:
    return
  var numbers = toSeq(sessions(cfg).keys)
  numbers.sort()
  for n in numbers:
    var head = ""
    for pr in merged:
      if pr{"headRefName"}.getStr == BranchPrefix & n or $pr{"number"} == n:
        head = pr{"headRefName"}.getStr
        break
    if head.len == 0:
      continue
    if p.dryRun:
      log "PR がマージされたため、" & head & " とチェックポイントを消します（dry-run）: #" & n
      continue
    if dirExists(cfg.repoDir / ".git"):
      discard gitRun(cfg.repoDir, "branch", "-D", head)
    checkpointForget(cfg, n)
    log "PR がマージされたため、" & head & " とチェックポイントを消しました: #" & n

proc taskLogs*(cfg: Config, number: string): seq[string] =
  if not dirExists(cfg.taskLogsDir):
    return
  var rows: seq[(string, string)]
  for kind, path in walkDir(cfg.taskLogsDir):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let name = path.extractFilename
    if not (name.startsWith("issue-" & number & "-") or name.startsWith("comment-" & number & "-")):
      continue
    let stamp = if name.len >= 15 and name[^15 .. ^1].replace("-", "").allCharsInSet(Digits) and name[^7] == '-':
                  name[^15 .. ^1] else: path
    rows.add (stamp, path)
  rows.sort()
  rows.mapIt(it[1])

proc lastTaskLog(cfg: Config, number: string): string =
  let logs = taskLogs(cfg, number)
  if logs.len > 0: logs[^1] else: ""

# その Issue の最後のタスクが失敗していれば、そのタスク JSON を返す
proc loadFailedTask*(cfg: Config, number: string): JsonNode =
  let dir = lastTaskLog(cfg, number)
  if dir.len == 0:
    return nil
  let o = readJson(dir / "outcome.json")
  if o == nil or o.kind != JObject or o{"ok"} == nil or o["ok"].kind != JBool or o["ok"].getBool or
      text(o, "failed_state").len == 0:
    return nil
  result = readJson(dir / TaskFileName)
  if result != nil and result.kind == JObject:
    result.delete("commit")

# --- エージェントの呼び出し ---

proc callAgent(t: Task, state, body: string): bool =
  var body = body
  let headStart = gitOut(t.wt, "rev-parse", "HEAD")
  removeFile(t.wt / outcomeFileName)
  removeFile(t.log / "phase-gate.count")

  var resumeId = ""
  var baseCost = 0.0
  let cp = t.checkpointGet()
  if cp != nil and text(cp, "prompt_hash") == t.sysHash:
    resumeId = text(cp, "session_id")
    baseCost = (let c = cp{"cost_usd"}; if c == nil or c.kind notin {JInt, JFloat}: 0.0 else: c.getFloat)
    if state.startsWith("triage-") and t.memory.len > 0 and text(cp, "memory_hash") != t.memoryHash:
      body.add "\n\n" & t.memory

  let token = t.p.auth.appTokenWith(parseJson(AgentTokenPermissions))
  if token.len == 0:
    t.failReason = "エージェント用のトークンを取得できませんでした。App に Actions: Read が付与されているか確認してください"
    return false

  let limit = max(int(t.deadline - getTime().toUnix), MinCallSeconds)
  let budget = max(t.cfg.maxTaskBudgetUsd - t.cost, 0.01)
  let cond = CallConditions(headStart: headStart, hasPr: t.pr != nil, prOurs: t.prOurs,
                            commentIds: t.commentIds.split(' ').filterIt(it.len > 0), maxSubIssues: t.cfg.maxSubIssues)
  let env = @[("MOPU_PHASE", state), ("MOPU_HEAD_START", headStart), ("MOPU_HAS_PR", if cond.hasPr: "1" else: "0"),
              ("MOPU_PR_OURS", if cond.prOurs: "1" else: "0"), ("MOPU_COMMENT_IDS", t.commentIds),
              ("MOPU_MAX_SUB_ISSUES", $t.cfg.maxSubIssues)]

  writeLine(t.log / ("prompt-" & align($t.calls, 2, '0') & "-" & state & ".md"), body)
  inc t.calls
  let stream = t.log / "stream.jsonl"
  let linesBefore = fileLineCount(stream)
  let f = open(stream, fmAppend)
  f.writeLine $(%*{"type": "system", "subtype": "mopu_state", "state": state, "resume": resumeId})
  f.close()
  if resumeId.len > 0:
    log "[" & t.id & "] " & state & ": 会話 " & resumeId & " を再開します"
  var inv = Invocation(taskDir: t.dir, logDir: t.log, prompt: body, systemPrompt: t.sysPrompt, settings: t.settings,
                       resumeId: resumeId, limit: limit, budget: budget, env: env, ghToken: token)
  var rc = invokeAgent(t.cfg, inv)

  # 保持期間を過ぎた会話は再開できない。この失敗は課金ゼロで即座に返るので、会話なしでやり直す
  if resumeId.len > 0 and rc != 0:
    let errLines = (try: readFile(t.log / "stderr.log") except IOError: "").strip(leading = false).splitLines
    if errLines[max(0, errLines.len - 5) .. ^1].anyIt("No conversation found with session ID" in it):
      warn "[" & t.id & "] 会話 " & resumeId & " が見つかりません。新しい会話で実行します"
      checkpointForget(t.cfg, t.number)
      resumeId = ""
      baseCost = 0
      inv.resumeId = ""
      inv.prompt = body & "\n\n" & t.memory
      rc = invokeAgent(t.cfg, inv)

  let events = streamEvents(stream, linesBefore)
  let res = lastOfType(events, "result")
  let total = (let c = if res == nil: nil else: res{"total_cost_usd"}; if c == nil or c.kind notin {JInt, JFloat}: 0.0 else: c.getFloat)
  # 再開した会話の total_cost_usd は再開元の分を含む
  t.cost += max(total - baseCost, 0)

  let status = rateLimited(events)
  if status.len > 0:
    warn "[" & t.id & "] レート上限イベント: " & status
    t.p.rateLimitHit = true

  let isError = res != nil and res{"is_error"} != nil and res["is_error"].kind == JBool and res["is_error"].getBool
  if rc != 0 or res == nil or isError:
    let subtype = text(res, "subtype")
    t.failReason = "エージェントの実行に失敗しました (exit=" & $rc & (if subtype.len > 0: ", " & subtype else: "") & ")"
    if rc == 124:
      t.failReason = "時間制限（残り " & $limit & " 秒）で打ち切りました"
    return false
  if not verifyWorkspace(t.wt, t.cfg.repoDir):
    t.failReason = "worktree の .git が書き換えられています"
    return false
  let problem = outcomeProblem(state, t.wt, cond)
  if problem.len > 0:
    t.failReason = "終える条件を満たしませんでした: " & problem
    return false

  t.outcome = parseFile(t.wt / outcomeFileName)
  removeFile(t.wt / outcomeFileName)
  t.checkpointSet(text(res, "session_id"), total)
  true

# --- 本文の材料 ---

proc taskMaterial(t: Task): string =
  var m = ""
  if t.kind == "comment":
    let comments = t.json{"comments"}
    let n = if comments == nil or comments.kind != JArray: 0 else: comments.len
    m.add "## 今回のコメント（" & $n & " 件）\n\n"
    for i in 0 ..< n:
      let c = comments[i]
      m.add "### コメント " & text(c, "id") & "\n\n"
      let url = text(c, "url")
      for line in url.split('\n'):
        if line.len > 0:
          m.add line & "\n\n"
      m.add "```\n" & text(c, "instruction") & "\n```\n\n"
    m.add "## 背景: #" & t.number & "「" & t.title & "」の本文\n"
  else:
    m.add "## Issue #" & t.number & "「" & t.title & "」の本文\n"
  m.add "\n```\n" & (if t.body.len > 0: t.body else: "(本文なし)") & "\n```\n"
  if t.kind == "comment":
    let h = renderHistory(t.json)
    if h.len > 0:
      m.add "\n## 背景: その後のやり取り（古い順）\n\n" & h & "\n"
  m[0 ..< min(m.len, 60000)]

proc prMaterial(t: Task): string =
  if t.pr == nil:
    return ""
  "## 作業先の PR #" & t.prNumber & "\n\n" &
    (if t.prOurs: "mopu-agent が作った PR で、今の本文は次のとおり。\n"
     else: "mopu-agent 以外が作った PR で、本文は次のとおり。\n") &
    "\n" & mdQuote(trimNewlines(text(t.pr, "body"))) & "\n"

# --- 検証の記録（verify.json） ---

proc verifyFile(t: Task): string = t.log / "verify.json"

proc verifyData(t: Task): JsonNode =
  result = readJson(t.verifyFile)
  if result == nil or result.kind != JObject:
    result = newJObject()

proc verifyUpdate(t: Task, mutate: proc (v: JsonNode)) =
  var v = t.verifyData
  mutate(v)
  writeFile(t.verifyFile & ".tmp", v.pretty(2) & "\n")
  moveFile(t.verifyFile & ".tmp", t.verifyFile)

proc ciResult(t: Task, verdict, detail: string, runs = newJArray()) =
  t.verifyUpdate(proc (v: JsonNode) = v["ci"] = %*{"verdict": verdict, "detail": detail, "runs": runs})

# HEAD を push し、PR が無ければ draft PR を作る。PR を作ったときだけ、Issue にそのことを知らせる
proc pushTaskBranch(t: Task): bool =
  if not pushWorkspace(t.cfg, t.wt, t.branch):
    t.failReason = "push に失敗しました"
    return false
  if t.pr != nil:
    return true
  let r = capture("gh", ["pr", "create", "-R", t.cfg.repo, "--draft", "--base", t.cfg.baseBranch, "--head", t.branch,
                         "--title", t.title, "--body",
                         t.prBodyWithMarker("エージェントが作業中です。作業が終わると、この本文を対応内容で置き換えます。")],
                  mergeStderr = true)
  if r.exitCode != 0:
    let lines = r.output.strip(leading = false).splitLines
    t.failReason = "draft PR を作れませんでした: " & (if lines.len > 0: lines[^1] else: "")
    return false
  t.loadTaskPr()
  if t.pr == nil:
    t.failReason = "作った draft PR を読めませんでした"
    return false
  t.p.lastTaskOpenedPr = true
  log "[" & t.id & "] draft PR を作りました: " & text(t.pr, "url")
  let reason = trimNewlines(text(readJson(t.log / "triage.json"), "no_split_reason"))
  discard postComment(t.cfg, t.number, "PR #" & t.prNumber & " を作りました。以降の報告は PR に書きます。" &
    (if reason.len > 0: "\n\n分解しない理由: " & reason else: ""))
  true

proc skipsCi(message: string): bool =
  for line in message.toLowerAscii.splitLines:
    for tag in ["[skip ci]", "[ci skip]", "[no ci]", "[skip actions]", "[actions skip]"]:
      if tag in line:
        return true
    if line.startsWith("skip-checks:") and line["skip-checks:".len .. ^1].strip(trailing = false, chars = {' '}).startsWith("true"):
      return true
  false

# HEAD のコミットの CI を、すべて終わるかタスクの時間制限まで待つ。
# verdict: passed / failed / skipped（変更にかかる CI が無い）/ unverified / timeout
proc waitCi(t: Task) =
  let head = gitOut(t.wt, "rev-parse", "HEAD")
  let refName = "origin/" & t.cfg.baseBranch
  if skipsCi(gitRun(t.wt, "log", "--format=%B", refName & "..HEAD").output):
    t.ciResult("unverified", "コミットメッセージで CI を飛ばしている")
    return
  var inspected: JsonNode
  try:
    inspected = inspect(t.wt, refName, t.cfg.baseBranch)
  except CatchableError:
    t.ciResult("unverified", "CI が動くかを判定できなかった")
    return
  t.verifyUpdate(proc (v: JsonNode) =
    v["test_changes"] = inspected["test_changes"]
    v["files"] = inspected["files"])
  if text(inspected, "ci") == "skips":
    t.ciResult("skipped", "変更したファイルにかかる CI が無い")
    return

  let started = getTime().toUnix
  var runs = newJArray()
  while true:
    runs = newJArray()
    let res = ghJson(["api", "repos/" & t.cfg.repo & "/actions/runs?head_sha=" & head & "&per_page=100"])
    let all = if res == nil: nil else: res{"workflow_runs"}
    if all != nil and all.kind == JArray:
      for r in all:
        if text(r, "event") in ["pull_request", "pull_request_target", "push"]:
          runs.add %*{"id": r{"id"}, "name": r{"name"}, "status": r{"status"}, "conclusion": r{"conclusion"},
                      "url": r{"html_url"}, "head_sha": r{"head_sha"}}
    let now = getTime().toUnix
    if runs.len > 0:
      if runs.elems.allIt(text(it, "status") == "completed"):
        break
    elif now - started >= CiStartWait:
      t.ciResult("unverified", "push から " & $CiStartWait & " 秒待っても CI が起動しなかった")
      return
    if now + CiPollSeconds >= t.deadline:
      t.ciResult("timeout", "タスクの時間制限（" & t.cfg.taskTimeout & "）までに CI が終わらなかった", runs)
      return
    sleep(CiPollSeconds * 1000)

  var failed = newJArray()
  for r in runs:
    if text(r, "conclusion") notin ["success", "skipped", "neutral"] or r{"conclusion"}.kind == JNull:
      failed.add r
  if failed.len == 0:
    var names = runs.elems.mapIt(text(it, "name"))
    names.sort()
    t.ciResult("passed", names.deduplicate(isSorted = true).join("、"), runs)
  else:
    t.ciResult("failed", failed.elems.mapIt(text(it, "name") & "（run " & text(it, "id") & "、" &
      (if it{"conclusion"}.kind == JNull: "null" else: text(it, "conclusion")) & "）").join("、"), failed)

# 変更を書いた会話を共有しない critic に確かめさせる
proc critique(t: Task) =
  var review = runCritic(t.dir, t.cfg.baseBranch, t.log)
  let verdict = review{"verdict"}
  if verdict == nil or verdict.kind == JNull or (verdict.kind == JBool and not verdict.getBool):
    review = %*{"verdict": "error", "reasons": ["critic の出力を読めなかった"], "cost_usd": 0}
  let saved = review
  t.verifyUpdate(proc (v: JsonNode) = v["critic"] = saved)
  let c = review{"cost_usd"}
  if c != nil and c.kind in {JInt, JFloat}:
    t.cost += c.getFloat

# --- state ---

# 作業ツリーを作る起点。チェックポイントのコミットに自分のコミットがあり、push 済みのコミットを
# 捨てずに済むならそこから、そうでなければ push 済みのブランチか、ベースから
proc workspaceStart(t: Task): string =
  let repoDir = t.cfg.repoDir
  let base = "origin/" & t.cfg.baseBranch
  let remote = if gitOk(repoDir, "show-ref", "--verify", "--quiet", "refs/remotes/origin/" & t.branch):
                 "origin/" & t.branch else: ""
  let cpHead = text(t.checkpointGet(), "head")
  if cpHead.len > 0 and gitOk(repoDir, "cat-file", "-e", cpHead & "^{commit}") and
      not gitOk(repoDir, "merge-base", "--is-ancestor", cpHead, base) and
      (remote.len == 0 or gitOk(repoDir, "merge-base", "--is-ancestor", remote, cpHead)):
    return cpHead
  if remote.len > 0: remote else: base

proc statePrepare(t: Task): bool =
  if not createWorkspace(t.cfg, t.branch, t.dir, t.workspaceStart()):
    t.failReason = "作業ツリーの準備に失敗しました。ブランチ `" & t.branch & "` が使用中でないか確認してください"
    return false
  if t.cfg.setupCmd.len > 0:
    log "[" & t.id & "] 依存を準備します: " & t.cfg.setupCmd
    let rc = runSetup(t.cfg, t.wt, t.log / "setup.log")
    if rc != 0:
      t.failReason = "依存の準備コマンドが失敗しました (exit=" & $rc &
        (if rc == 124: ": " & t.cfg.setupTimeout & " で打ち切り" else: "") & ")"
      return false
  t.settings = t.log / "settings.json"
  if not buildAgentSettings(t.cfg, t.dir, t.settings):
    t.failReason = "エージェントの設定を作れませんでした"
    return false
  t.next = t.first
  true

# 入口は Issue の状態で決める。上から順に当てはめる
proc dispatchEntry(t: Task): string =
  if t.kind == "issue":
    return "triage-new"
  let labels = issueLabels(t.cfg, t.number)
  if LabelAwaiting in labels: "triage-plan"
  elif LabelAwaitingInput in labels: "triage-reply"
  elif t.pr != nil and t.prOurs: "triage-review"
  elif t.pr != nil: "triage-foreign"
  else: "triage-request"

proc endWithQuestion(t: Task) =
  if t.kind == "comment":
    t.postReplies(t.outcome, t.answerFooter)
  else:
    t.postTaskReport(trimNewlines(text(t.outcome, "question")) & "\n\n---\n" & t.answerFooter)
  t.endKind = "awaiting-input"
  t.endBody = leadQuote(trimNewlines(text(t.outcome, "question")))

proc stateTriage(t: Task): bool =
  let entry = t.state["triage-".len .. ^1]
  var body = phaseHeader("1. 把握（" & t.state & "）") & "\n\n" & prompt("triage.md") & "\n" &
    prompt("triage" / entry & ".md")
  if t.pr == nil:
    body.add "\n" & prompt("decompose.md").replace("%%MAX_SUB_ISSUES%%", $t.cfg.maxSubIssues)
  if t.kind == "comment":
    body.add "\n" & prompt("replies.md")
  body.add "\n" & t.taskMaterial & "\n" & t.prMaterial
  if entry == "plan":
    let pending = latestPlanComment(t.cfg, t.number)
    if pending != nil:
      body.add "\n## 承認待ちの分解案\n\n```json\n" & trimNewlines(planFromComment(pending)) & "\n```\n"
  if not t.callAgent(t.state, trimNewlines(body)):
    return false
  writeLine(t.log / "triage.json", $t.outcome)

  case text(t.outcome, "decision")
  of "implement":
    withdrawPlan(t.cfg, t.number)
    t.next = "implement"
  of "decompose":
    let plan = t.outcome["plan"]
    writeLine(t.log / "plan.json", plan.pretty(2))
    withdrawPlan(t.cfg, t.number)
    t.postTaskReport(renderPlanComment(t.cfg, plan))
    t.postReplies(t.outcome)
    t.endKind = "awaiting-approval"
    t.endDetail = "分解案 " & $plan["sub_issues"].len & " 件"
  of "ask":
    t.endWithQuestion()
  of "answer":
    let answer = trimNewlines(text(t.outcome, "answer"))
    if t.kind == "comment":
      t.postReplies(t.outcome)
    else:
      t.postTaskReport(answer)
    t.endKind = "answered"
    t.endBody = leadQuote(answer)
  else: discard
  true

proc stateImplement(t: Task): bool =
  let note = trimNewlines(text(readJson(t.log / "triage.json"), "note"))
  t.phase("implement", "", if note.len > 0: mdQuote(note) else: "")
  var body = phaseHeader("2. 実装") & "\n\n" & prompt("implement.md")
  if t.cfg.setupCmd.len > 0:
    body.add "\n" & trimNewlines(prompt("setup.md")).replace("%%SETUP_CMD%%", t.cfg.setupCmd) & "\n"
  if t.cfg.containerChecks.len > 0:
    body.add "\n" & prompt("container.md").replace("%%RUN_CMD%%", runContainerCommand())
    for c in t.cfg.containerChecks:
      let workdir = text(c, "workdir")
      body.add "- `" & text(c, "name") & "`: `" & text(c, "command") & "`（イメージ: `" & text(c, "image") &
        "`、作業ディレクトリ: `" & (if workdir.len == 0: "." else: workdir) & "`、上限 " & text(c, "timeout") & "）\n"
  if note.len > 0:
    body.add "\n## 把握で決めた方針\n\n" & note & "\n"
  if not t.callAgent("implement", trimNewlines(body)):
    return false
  if text(t.outcome, "decision") == "ask":
    if not t.pushTaskBranch():
      return false
    t.endWithQuestion()
    return true
  t.next = "verify"
  true

proc runFix(t: Task, material: string): bool =
  t.phase("verify", "fix")
  let body = phaseHeader("3. 検証の修正") & "\n\n" & prompt("fix.md") & "\n" & material
  if not t.callAgent("fix", trimNewlines(body)):
    return false
  t.fix = text(t.outcome, "decision")
  true

proc verifyEnd(t: Task, reason: string) =
  t.verifyUpdate(proc (v: JsonNode) =
    v["complete"] = %(reason.len == 0)
    v["reason"] = %reason)
  t.next = "report"

proc bullets(items: JsonNode): string =
  if items == nil or items.kind != JArray: "" else: items.elems.mapIt("- " & (if it.kind == JString: it.getStr else: $it)).join("\n")

proc stateVerify(t: Task): bool =
  var ciRounds, criticRounds = 0
  writeLine(t.verifyFile, "{}")
  while true:
    t.p.auth.refreshAppToken()
    t.phase("verify", "push")
    if not t.pushTaskBranch():
      return false
    t.phase("verify", "ci")
    t.waitCi()
    let v = t.verifyData
    let ci = text(v{"ci"}, "verdict")
    let detail = text(v{"ci"}, "detail")

    if ci == "failed":
      inc ciRounds
      let rounds = ciRounds
      t.verifyUpdate(proc (v: JsonNode) = v["ci_rounds"] = %rounds)
      if ciRounds > CiMaxFixRounds:
        t.verifyEnd("CI が " & $CiMaxFixRounds & " 回直しても落ちたまま: " & detail)
        return true
      notifyTask(t.log, "CI が落ちました（" & $ciRounds & "/" & $CiMaxFixRounds & " 回目）: " & detail)
      var lines: seq[string]
      for r in v["ci"]["runs"]:
        lines.add "- run " & text(r, "id") & "「" & text(r, "name") & "」: " & history.text(r{"conclusion"}) & "（" &
          text(r, "url") & "、コミット " & text(r, "head_sha")[0 ..< min(7, text(r, "head_sha").len)] & "）"
      if not t.runFix("## CI が落ちた（" & $ciRounds & "/" & $CiMaxFixRounds & " 回目）\n\n" & lines.join("\n")):
        return false
    elif ci == "timeout":
      t.verifyEnd(detail)
      return true
    else:
      t.phase("verify", "critic")
      t.critique()
      let critic = t.verifyData{"critic"}
      case text(critic, "verdict")
      of "approve":
        t.verifyEnd(if ci in ["passed", "skipped"]: "" else: "CI 未検証: " & detail)
        return true
      of "revise":
        inc criticRounds
        let rounds = criticRounds
        t.verifyUpdate(proc (v: JsonNode) = v["critic_rounds"] = %rounds)
        if criticRounds > CriticMaxRounds:
          t.verifyEnd("レビュアー（critic）の指摘が " & $CriticMaxRounds & " 回直しても残った\n" & bullets(critic{"reasons"}))
          return true
        notifyTask(t.log, "レビュアーが差し戻しました（" & $criticRounds & "/" & $CriticMaxRounds & " 回目）")
        if not t.runFix("## レビュアー（critic）の差し戻し（" & $criticRounds & "/" & $CriticMaxRounds & " 回目）\n\n" &
            "この会話を共有しない別のレビュアーが diff を確かめ、次の点を指摘した。\n\n" & bullets(critic{"reasons"})):
          return false
      else:
        let reasons = critic{"reasons"}
        let first = if reasons != nil and reasons.kind == JArray and reasons.len > 0: reasons[0] else: nil
        t.verifyEnd("レビュアー（critic）が判定できなかった: " &
          (if first == nil or first.kind == JNull: "" else: history.text(first)))
        return true

    case t.fix
    of "ask":
      if not t.pushTaskBranch():
        return false
      t.endWithQuestion()
      return true
    of "give_up":
      t.verifyEnd("エージェントが修正を諦めた: " & trimNewlines(text(t.outcome, "reason")))
      return true
    else: discard

proc stateReport(t: Task): bool =
  let verifyReason = trimNewlines(text(t.verifyData, "reason"))
  var body = phaseHeader("4. 公開（report）") & "\n\n" & prompt("report.md").replace("%%BASE_BRANCH%%", t.cfg.baseBranch)
  if t.prOurs:
    body.add "\n### PR テンプレート\n\n```markdown\n" & prompt("pr-body.md") & "```\n"
  else:
    body.add "\n作業先の PR は mopu-agent 以外が作ったものなので、PR 本文（pr_body）は書かない。\n"
  if t.kind == "comment":
    body.add "\n" & prompt("replies.md") & "\n返信が要るコメント ID: " & t.commentIds & "\n"
  body.add "\n## 検証の結果\n\n"
  if verifyReason.len == 0:
    body.add "CI とレビュアーの確認を通った。\n"
  else:
    body.add "検証を終えられなかった。PR は draft のまま公開される。理由:\n\n" & mdQuote(verifyReason) & "\n"
  body.add "\n" & t.prMaterial
  if not t.callAgent("report", trimNewlines(body)):
    return false
  writeLine(t.log / "report.json", $t.outcome)
  t.next = "publish"
  true

proc verifyComment(t: Task, reason: string): string =
  result = "検証を終えられなかったため、この PR は draft のままにしています（レビューは依頼していません）。\n\n" & mdQuote(reason)
  let tests = t.verifyData{"test_changes"}
  if tests != nil and tests.kind == JArray and tests.len > 0:
    result.add "\n\n**テストに関わる変更**（テストを弱めていないか確かめてください）:\n" &
      tests.elems.mapIt("- `" & (if it.kind == JString: it.getStr else: $it) & "`").join("\n")

proc statePublish(t: Task): bool =
  let report = readJson(t.log / "report.json")
  let v = t.verifyData
  let complete = v{"complete"} != nil and v["complete"].kind == JBool and v["complete"].getBool
  let reason = trimNewlines(text(v, "reason"))
  t.loadTaskPr()
  if t.pr == nil:
    t.failReason = "公開する PR が見つかりません"
    return false
  let pr = t.prNumber
  t.phase("publish", if complete: "検証済み" else: "draft")

  if t.prOurs and not ghShowingErrors(["pr", "edit", pr, "-R", t.cfg.repo, "--body",
                                       t.prBodyWithMarker(trimNewlines(text(report, "pr_body")))]):
    t.failReason = "PR の本文を書き換えられませんでした"
    return false
  let isDraft = t.pr{"isDraft"} != nil and t.pr["isDraft"].kind == JBool and t.pr["isDraft"].getBool
  if complete:
    if isDraft and not ghShowingErrors(["pr", "ready", pr, "-R", t.cfg.repo]):
      t.failReason = "PR を ready にできませんでした"
      return false
    let owner = t.cfg.repo.split('/')[0]
    let r = capture("gh", ["pr", "edit", pr, "-R", t.cfg.repo, "--add-reviewer", owner], mergeStderr = true)
    if r.exitCode != 0:
      warn "[" & t.id & "] レビュアー '" & owner & "' を指定できませんでした: " & r.output.strip(leading = false)
  else:
    if not isDraft and ghRun(["pr", "ready", "--undo", pr, "-R", t.cfg.repo]).exitCode != 0:
      t.failReason = "PR を draft に戻せませんでした"
      return false
    let marker = "<!-- mopu-agent:verify " & gitOut(t.wt, "rev-parse", "HEAD") & " -->"
    if not alreadyPosted(t.cfg, "issue", pr, marker):
      discard postComment(t.cfg, pr, t.verifyComment(reason) & "\n\n" & marker)
  t.postReplies(report)

  if complete:
    t.endKind = "review"
    t.endDetail = "PR #" & pr
    t.endBody = "推定 $" & money(t.cost)
  else:
    t.failedState = "verify"
    t.failReason = "検証を終えられなかったため、PR を draft のまま公開しました: " & reason.split('\n')[0]
  true

# --- タスクの始まりと終わり ---

# 失敗した state を記録し、その state の途中の差分をログに残して報告する
proc taskFailed(t: Task) =
  t.failedState = t.state
  err "[" & t.id & "] " & t.state & ": " & t.failReason
  if dirExists(t.wt) and verifyWorkspace(t.wt, t.cfg.repoDir):
    let cpHead = text(t.checkpointGet(), "head")
    writeFile(t.log / "failed.diff",
      gitRun(t.wt, "log", "--format=commit %H %s", cpHead & "..HEAD").output &
      gitRun(t.wt, "status", "--short").output &
      gitRun(t.wt, "diff", "HEAD").output)
  var body = "エージェントの作業が `" & t.state & "` で止まりました。\n\n" & mdQuote(t.failReason) &
    "\n\nログ: `" & relToData(t.log) & "`"
  let setupLog = t.log / "setup.log"
  if t.state == "prepare" and fileExists(setupLog) and getFileSize(setupLog) > 0:
    let lines = readFile(setupLog).strip(leading = false, chars = {'\n'}).splitLines
    body.add "\n\n```\n" & lines[max(0, lines.len - 20) .. ^1].join("\n") & "\n```"
  t.postTaskReport(body)

# ラベルは、タスクの終わりに待っているもので決める
proc finishTask(t: Task): bool =
  let label =
    if latestPlanComment(t.cfg, t.number) != nil: LabelAwaiting
    elif t.endKind == "awaiting-input": LabelAwaitingInput
    elif t.failedState.len > 0: LabelFailed
    else: LabelDone
  setLabels(t.cfg, t.number, label)

  var spend = ""
  if t.failedState.len > 0:
    t.phase("failed", t.failReason)
    spend = if t.failedState == "verify": "draft" else: "failed"
  else:
    t.phase(t.endKind, t.endDetail, t.endBody)
    spend = case t.endKind
      of "review": "pr"
      of "answered": "no-change"
      of "awaiting-input": "question"
      of "awaiting-approval": "plan"
      else: ""
  var o = %*{"ok": t.failedState.len == 0, "entry": t.entry, "cost_usd": t.cost}
  if t.failedState.len == 0:
    o["end"] = %t.endKind
  else:
    o["failed_state"] = %t.failedState
    o["reason"] = %t.failReason
  writeLine(t.log / "outcome.json", $o)

  let pctAfter = t.p.refreshUsage()
  recordSpend(t.cfg, t.id, t.cost, t.pctBefore, pctAfter, spend, t.json)
  discard removeWorkspace(t.cfg, t.dir)
  log "[" & t.id & "] 終了: " & (if t.failedState.len > 0: "失敗（" & t.failedState & "）" else: "") & t.endKind &
    " (推定 $" & money(t.cost) & ", 5h枠 " & (if t.pctBefore.len > 0: t.pctBefore else: "?") & "%→" &
    (if pctAfter.len > 0: pctAfter else: "?") & "%)"
  t.failedState.len == 0

proc runState(t: Task): bool =
  case t.state.split('-')[0]
  of "prepare": t.statePrepare()
  of "triage": t.stateTriage()
  of "implement": t.stateImplement()
  of "verify": t.stateVerify()
  of "report": t.stateReport()
  of "publish": t.statePublish()
  else:
    t.failReason = "不明な state: " & t.state
    false

proc runTask*(p: PollState, task: JsonNode): bool =
  let t = Task(p: p, cfg: p.cfg, json: task)
  t.kind = text(task, "kind")
  t.number = text(task, "number")
  t.title = trimNewlines(text(task, "title"))
  t.body = trimNewlines(text(task, "body"))
  t.id = t.kind & "-" & t.number & "-" & now().format("yyyyMMdd-HHmmss")
  t.branch = taskBranch(task, t.number)
  t.dir = p.cfg.worktreesDir / t.id
  t.wt = workspaceRepo(t.dir)
  t.log = p.cfg.taskLogsDir / t.id
  let comments = task{"comments"}
  if comments != nil and comments.kind == JArray:
    t.commentIds = comments.elems.mapIt(text(it, "id")).join(" ")
  t.deadline = getTime().toUnix + durationSeconds(p.cfg.taskTimeout)
  p.lastTaskOpenedPr = false

  t.loadTaskPr()
  t.entry = t.dispatchEntry()
  t.first = t.entry
  if p.retry:
    let prev = lastTaskLog(p.cfg, t.number)
    let prevOutcome = if prev.len > 0: readJson(prev / "outcome.json") else: nil
    let failed = text(prevOutcome, "failed_state")
    if failed.len > 0:
      let e = text(prevOutcome, "entry")
      if e.len > 0: t.entry = e
      t.first = if failed == "prepare": t.entry else: failed
      createDir(t.log)
      for f in CarryFiles:
        if fileExists(prev / f):
          copyFile(prev / f, t.log / f)
      log "[" & t.id & "] 前回のタスク " & prev.extractFilename & " の " & t.first & " からやり直します"
    else:
      warn "[" & t.id & "] やり直せる失敗が無いため、通常どおり始めます"

  createDir(t.log)
  var saved = task.copy
  saved["commit"] = %Commit
  writeLine(t.log / TaskFileName, $saved)

  t.sysPrompt = trimNewlines(prompt("agent.md"))
  # state/repos/*/sessions.json に残っている値と揃えるため、末尾に改行を足してハッシュする
  t.sysHash = sha256Hex(t.sysPrompt & "\n")[0 ..< 16]
  t.memory = projectMemoryPrompt(p.cfg.repoDir, "origin/" & p.cfg.baseBranch)
  t.memoryHash = sha256Hex(t.memory & "\n")[0 ..< 16]
  if t.memory.len > 0:
    writeLine(t.log / "project-memory.md", t.memory)
    t.sysPrompt.add "\n\n" & t.memory

  t.pctBefore = p.usage.pct5h
  if t.pctBefore.len == 0:
    t.pctBefore = p.refreshUsage()

  log "[" & t.id & "] 開始: #" & t.number & " " & t.title & "（" & t.entry & "）"
  setLabels(p.cfg, t.number, LabelRunning)

  # implement・verify・publish は、記録に添える情報を持つので state の中で記録する
  t.next = "prepare"
  while t.next.len > 0 and t.failedState.len == 0:
    t.state = t.next
    t.next = ""
    if t.state notin ["implement", "verify", "publish"]:
      t.phase(t.state)
    p.auth.refreshAppToken()
    if not t.runState():
      t.taskFailed()
  if t.failedState.len == 0 and t.endKind.len == 0:
    t.failReason = t.state & " の後に進む state がありません"
    t.taskFailed()
  t.finishTask()
