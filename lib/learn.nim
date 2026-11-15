import std/[algorithm, json, os, sequtils, strutils, times, unicode]
import agent, budget, config, discover, github, log, notify, paths, phases, process, project_memory, run_task,
       workspace

const
  KnownMaxChars = 20000
  MaxIssues = 3
  ActionsMaxBytes = 200000

proc text(node: JsonNode, key: string): string =
  let v = if node == nil or node.kind != JObject: nil else: node{key}
  if v == nil or v.kind == JNull: "" elif v.kind == JString: v.getStr else: $v

proc trimNewlines(s: string): string = s.strip(leading = false, chars = {'\n'})

proc clip(s: string, n: int): string =
  let runes = s.toRunes
  if runes.len > n: $runes[0 ..< n] & "…" else: s

proc learnIssuesFile(cfg: Config): string = cfg.repoStateDir / "learn-issues.txt"

proc discoverConfig*(cfg: Config): DiscoverConfig =
  DiscoverConfig(repo: cfg.repo, trigger: cfg.triggerCommand, labelQueued: LabelQueued,
                 allowedActors: cfg.allowedActors.join(" "), branchPrefix: BranchPrefix, commentMarker: CommentMarker,
                 lastPollFile: cfg.lastPollFile, seenFile: cfg.seenFile, spendFile: spendFile,
                 learnedFile: cfg.learnedFile)

# PR の head は、マージ後にブランチが消されても refs/pull/<n>/head に残る。refs/remotes の
# 下に置くと ensureRepo の fetch --prune に消されるので、別の名前空間に取る
proc fetchPrHead(cfg: Config, number: string): bool =
  gitOk(cfg.repoDir, "fetch", "--quiet", "origin", "+refs/pull/" & number & "/head:refs/mopu/pr/" & number)

proc learnTasks*(p: PollState): JsonNode =
  if not p.cfg.learn:
    return nil
  ensureRepo(p.cfg)
  learnTask(discoverConfig(p.cfg))

proc markLearned(cfg: Config, task: JsonNode, status: string) =
  let f = open(cfg.learnedFile, fmAppend)
  for pr in task["prs"]:
    f.writeLine $pr["number"] & "\t" & status
  f.close()

proc summarizeActions(stream: string): string =
  var lines: seq[string]
  for ev in streamEvents(stream):
    let kind = text(ev, "type")
    if kind == "system" and text(ev, "subtype") == "init":
      lines.add "--- エージェントの呼び出し ---"
    elif kind in ["assistant", "user"]:
      let content = ev{"message", "content"}
      if content == nil or content.kind != JArray:
        continue
      for c in content:
        if c.kind != JObject:
          continue
        let ctype = text(c, "type")
        if kind == "assistant":
          if ctype == "text":
            lines.add "[発言] " & clip(text(c, "text"), 2000)
          elif ctype == "thinking" and text(c, "thinking").len > 0:
            lines.add "[思考] " & clip(text(c, "thinking"), 2000)
          elif ctype == "tool_use":
            let input = c{"input"}
            var shown = ""
            for k in ["command", "file_path", "pattern", "url", "query"]:
              let v = if input != nil and input.kind == JObject: input{k} else: nil
              if v != nil and v.kind != JNull and not (v.kind == JBool and not v.getBool):
                shown = if v.kind == JString: v.getStr else: $v
                break
            if shown.len == 0 and input != nil:
              shown = $input
            lines.add "[" & text(c, "name") & "] " & clip(shown, 300)
        elif ctype == "tool_result" and c{"is_error"} != nil and c["is_error"].kind == JBool and c["is_error"].getBool:
          let body = c{"content"}
          let s = if body == nil: "" elif body.kind == JString: body.getStr
                  elif body.kind == JArray: body.elems.mapIt(if it.kind == JObject: text(it, "text") else: "").join("")
                  else: ""
          lines.add "[エラー] " & clip(s, 300)
  lines.join("\n") & (if lines.len > 0: "\n" else: "")

proc writeActionLogs(cfg: Config, pr: JsonNode, outDir: string): seq[string] =
  var merged: string
  try:
    merged = parseTime(text(pr, "merged_at"), "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).local.format("yyyyMMdd-HHmmss")
  except CatchableError:
    return
  createDir(outDir)
  for dir in taskLogs(cfg, text(pr, "issue")):
    let name = dir.extractFilename
    if name.len >= 15 and name[^15 .. ^1] > merged:
      continue
    let stream = dir / "stream.jsonl"
    if not fileExists(stream) or getFileSize(stream) == 0:
      continue
    let summary = summarizeActions(stream)
    writeFile(outDir / name & ".md", summary[0 ..< min(summary.len, ActionsMaxBytes)])
    result.add outDir / name & ".md"

proc buildLearnPrompt(cfg: Config, task: JsonNode, actionsDir: string): string =
  let prs = task["prs"]
  var m = "# タスク\n\n差し戻しのあった次の " & $prs.len &
    " 件の PR がマージされた。これらのタスクでのエージェントの行動を振り返り、対象リポジトリの指示の変更案を出すこと。\n"
  for pr in prs:
    m.add "\n## PR #" & text(pr, "number") & "「" & text(pr, "title") & "」（" & text(pr, "url") & "）\n\n"
    m.add "### 元の Issue #" & text(pr, "issue") & "「" & text(pr, "issue_title") & "」\n\n"
    let issueBody = text(pr, "issue_body")
    m.add "```\n" & (if issueBody.len == 0: "(本文なし)" else: issueBody) & "\n```\n\n"
    let body = text(pr, "body")
    m.add "### PR の本文\n\n```\n" & (if body.len == 0: "(本文なし)" else: body) & "\n```\n\n"
    m.add "### 差し戻しのコメント（古い順）\n"
    let comments = pr{"comments"}
    let count = if comments == nil or comments.kind != JArray: 0 else: comments.len
    for i in 0 ..< count:
      let c = comments[i]
      let path = text(c, "path")
      m.add "\n#### " & text(c, "created_at") & " " & text(c, "actor") &
        (if path.len > 0: "（" & path & " への行コメント）" else: "") & "\n\n" & text(c, "url") & "\n\n"
      m.add "```\n" & text(c, "instruction") & "\n```\n"
    if count == 0:
      m.add "\n（コメントを取得できなかった。コミットの前後から読み取ること）\n"
    m.add "\n### PR のコミット\n\n"
    m.add "`git log --reverse --format=fuller -p " & text(pr, "merge_commit") & "^1..refs/mopu/pr/" & text(pr, "number") &
      "` で、この PR のコミットを古い順に読める。コミットの日時を上のコメントの日時と突き合わせると、差し戻しの前後で何が変わったかが分かる。\n"
    m.add "\n### エージェントの行動ログ（古い順）\n\n"
    let logs = writeActionLogs(cfg, pr, actionsDir / text(pr, "number"))
    if logs.len > 0:
      for l in logs:
        m.add "- " & l & "\n"
    else:
      m.add "（残っていない。コミットの順から推すこと）\n"
  m[0 ..< min(m.len, 60000)]

proc buildKnownIssuesContext(cfg: Config): string =
  let file = learnIssuesFile(cfg)
  if not fileExists(file) or getFileSize(file) == 0:
    return ""
  var numbers: seq[int]
  for line in readFile(file).splitLines:
    let n = line.split('\t')[0]
    if n.len > 0:
      try: numbers.add parseInt(n) except ValueError: discard
  let issues = ghJson(["issue", "list", "-R", cfg.repo, "--state", "all", "--limit", "500", "--json",
                       "number,title,body,state,stateReason"])
  if issues == nil or issues.kind != JArray:
    return ""
  var rows = issues.elems.filterIt(it{"number"}.getInt in numbers)
  if rows.len == 0:
    return ""
  rows.sort(proc (a, b: JsonNode): int = cmp(b["number"].getInt, a["number"].getInt))
  var parts: seq[string]
  for r in rows:
    let status = if text(r, "state") == "OPEN": "対応待ち" elif text(r, "stateReason") == "COMPLETED": "採用" else: "却下"
    let body = text(r, "body").split("\n\n---\n")[0].split("<details>")[0].toRunes
    parts.add "\n#### #" & text(r, "number") & "「" & text(r, "title") & "」（" & status & "）\n\n" &
      $body[0 ..< min(body.len, 1500)]
  let s = "### これまでに出した案（新しい順）\n" & parts.join("\n")
  trimNewlines(s[0 ..< min(s.len, KnownMaxChars)])

proc learnSchema(): string =
  $(%*{
    "type": "object",
    "properties": {
      "issues": {"type": "array", "maxItems": MaxIssues, "items": {
        "type": "object",
        "properties": {"title": {"type": "string"}, "body": {"type": "string"}},
        "required": ["title", "body"], "additionalProperties": false}},
      "skipped": {"type": "array", "items": {
        "type": "object",
        "properties": {"url": {"type": "string"}, "reason": {"type": "string"}},
        "required": ["url", "reason"], "additionalProperties": false}},
    },
    "required": ["issues"], "additionalProperties": false})

# 学習のエージェントには読むことしかさせない。書き込みの許可、ホスト側のコマンド、
# フェーズの Stop hook を外す
proc learnAgentSettings(cfg: Config, taskDir, output, actionsDir: string): bool =
  if not buildAgentSettings(cfg, taskDir, output & ".base"):
    return false
  var s = parseFile(output & ".base")
  var allow = newJArray()
  for a in s["permissions"]["allow"]:
    let v = a.getStr
    if not (v.startsWith("Edit(") or mopuBin in v):
      allow.add a
  allow.add %("Read(/" & actionsDir & "/**)")
  s["permissions"]["allow"] = allow
  s["sandbox"]["excludedCommands"] = newJArray()
  s["sandbox"]["filesystem"]["allowWrite"] = newJArray()
  s["hooks"].delete("Stop")
  writeFile(output, s.pretty(2) & "\n")
  removeFile(output & ".base")
  true

type Learn = ref object
  p: PollState
  task: JsonNode
  id, title, dir, log: string
  pctBefore: string
  cost: float
  issueUrls: seq[string]

proc recordOutcome(l: Learn, ok: bool, reason = "") =
  var o = %*{"ok": ok}
  if reason.len > 0:
    o["reason"] = %reason
  writeFile(l.log / "outcome.json", $o & "\n")

proc failed(l: Learn, reason: string): bool =
  let cfg = l.p.cfg
  err "[" & l.id & "] " & reason
  l.recordOutcome(false, reason)
  notify("❌ **失敗** " & issueRef(cfg.repo) & " " & l.title & "\n`" & l.id & "`\n" & mdQuote(reason))
  markLearned(cfg, l.task, "failed")
  recordSpend(cfg, l.id, l.cost, l.pctBefore, "", "failed", l.task)
  if dirExists(l.dir):
    log "[" & l.id & "] 作業ディレクトリを調査用に残します: " & l.dir
  false

# 作った Issue は、作った時点で控える。途中で失敗してやり直したときに、作り済みの案を
# 既に出した案としてプロンプトに載せ、同じ Issue を二重に作らせないため
proc publishLearnIssues(l: Learn, issues: JsonNode, footer, source: string): bool =
  let cfg = l.p.cfg
  for issue in issues["issues"]:
    let r = ghRun(["issue", "create", "-R", cfg.repo, "--title", trimNewlines(text(issue, "title")),
                   "--body", trimNewlines(text(issue, "body")) & "\n\n---\n" & footer & "\n" & CommentMarker])
    if r.exitCode != 0:
      return false
    var url = ""
    for word in strutils.splitWhitespace(r.output):
      if word.startsWith("https://") and "/issues/" in word and word.rsplit('/', 1)[^1].allCharsInSet(Digits):
        url = word
    let f = open(learnIssuesFile(cfg), fmAppend)
    f.writeLine url.rsplit('/', 1)[^1] & "\t" & source
    f.close()
    l.issueUrls.add url
  true

proc runLearn(l: Learn): bool =
  let p = l.p
  let cfg = p.cfg
  let t = l.task
  let wt = workspaceRepo(l.dir)
  let actionsDir = l.dir / "actions"
  let prNumbers = t["prs"].elems.mapIt($it["number"])

  l.pctBefore = p.usage.pct5h
  if l.pctBefore.len == 0:
    l.pctBefore = p.refreshUsage()
  log "[" & l.id & "] 開始: " & l.title

  for n in prNumbers:
    if not fetchPrHead(cfg, n):
      return l.failed("PR #" & n & " の head を取得できませんでした")
  # 案は、マージ後に積まれた変更も含めた今のベースブランチに合わせて書かせる
  createDir(l.dir)
  if not gitOk(cfg.repoDir, "worktree", "add", "--quiet", "--detach", wt, "origin/" & cfg.baseBranch):
    return l.failed("worktree の準備に失敗しました")

  var sysPrompt = trimNewlines(readFile(promptsDir / "learn.md"))
  let known = buildKnownIssuesContext(cfg)
  if known.len > 0:
    sysPrompt.add "\n\n" & known
  sysPrompt.add "\n\n" & trimNewlines(readFile(promptsDir / "read-only.md"))
  let memory = projectMemoryPrompt(cfg.repoDir, "origin/" & cfg.baseBranch)
  if memory.len > 0:
    sysPrompt.add "\n\n" & memory
    writeFile(l.log / "project-memory.md", memory & "\n")

  let prompt = trimNewlines(buildLearnPrompt(cfg, t, actionsDir))
  let settings = l.log / "settings.json"
  if not learnAgentSettings(cfg, l.dir, settings, actionsDir):
    return l.failed("エージェントの設定を作れませんでした")

  let rc = invokeAgent(cfg, Invocation(taskDir: l.dir, logDir: l.log, prompt: prompt, systemPrompt: sysPrompt,
                                       settings: settings, limit: durationSeconds(cfg.taskTimeout),
                                       budget: cfg.maxTaskBudgetUsd, jsonSchema: learnSchema()))
  let events = streamEvents(l.log / "stream.jsonl")
  let res = lastOfType(events, "result")
  let isError = if res == nil or res{"is_error"} == nil: "" else: $res["is_error"]
  l.cost = (let c = if res == nil: nil else: res{"total_cost_usd"}; if c == nil or c.kind notin {JInt, JFloat}: 0.0 else: c.getFloat)
  let status = rateLimited(events)
  if status.len > 0:
    warn "[" & l.id & "] レート上限イベント: " & status
    p.rateLimitHit = true

  if rc != 0 or isError == "true":
    return l.failed("エージェントの実行に失敗しました (exit=" & $rc & ", is_error=" & isError & ")")
  var issues = if res == nil: nil else: res{"structured_output"}
  if issues == nil or issues.kind != JObject or issues{"issues"} == nil or issues["issues"].kind != JArray:
    return l.failed("エージェントが案を構造化出力で返しませんでした")

  # 案にしなかった判断は Issue が無いと GitHub に残らないので、ログにも出す
  let skipped = issues{"skipped"}
  if skipped != nil and skipped.kind == JArray and skipped.len > 0:
    let lines = skipped.elems.mapIt("- " & text(it, "url") & ": " & text(it, "reason")).join("\n")
    writeFile(l.log / "skipped.md", lines & "\n")
    log "[" & l.id & "] 案にしなかった差し戻し:\n" & lines
    if issues["issues"].len > 0:
      let last = issues["issues"][^1]
      last["body"] = %(text(last, "body") & "\n\n<details>\n<summary>案にしなかった差し戻し</summary>\n\n" & lines &
                       "\n\n</details>")

  if issues["issues"].len == 0:
    log "[" & l.id & "] 案にするものはありませんでした"
    markLearned(cfg, t, "no-change")
    recordSpend(cfg, l.id, l.cost, l.pctBefore, "", "no-change", t)
    discard removeWorkspace(cfg, l.dir)
    return true

  let footer = prNumbers.mapIt("#" & it).join("・") & " の差し戻しを振り返って、mopu-agent が出した案です。"
  if not l.publishLearnIssues(issues, footer, prNumbers.join(",")):
    return l.failed("Issue を作れませんでした" &
      (if l.issueUrls.len > 0: "（作れたもの: " & l.issueUrls.join(" ") & "）" else: ""))

  markLearned(cfg, t, "issue")
  let pctAfter = p.refreshUsage()
  recordSpend(cfg, l.id, l.cost, l.pctBefore, pctAfter, "issue", t)
  discard removeWorkspace(cfg, l.dir)
  log "[" & l.id & "] 完了: " & l.issueUrls.join(" ") & " (推定 $" & formatFloat(l.cost, ffDecimal, 2) & ", 5h枠 " &
    (if l.pctBefore.len > 0: l.pctBefore else: "?") & "%→" & (if pctAfter.len > 0: pctAfter else: "?") & "%)"
  notify("📚 **学習の案** " & issueRef(cfg.repo) & " " & l.title & "\n- " & l.issueUrls.join("\n- "))
  true

proc runLearnTask*(p: PollState, task: JsonNode): bool =
  let number = text(task, "number")
  let id = "learn-" & number & "-" & now().format("yyyyMMdd-HHmmss")
  let l = Learn(p: p, task: task, id: id, title: text(task, "title"),
                dir: p.cfg.worktreesDir / id, log: p.cfg.taskLogsDir / id)
  createDir(l.log)
  var saved = task.copy
  saved["commit"] = %p.cfg.agentCommit
  writeFile(l.log / TaskFileName, $saved & "\n")
  try:
    result = l.runLearn()
  except CatchableError as e:
    l.recordOutcome(false, "中断しました: " & e.msg)
    raise
  if not fileExists(l.log / "outcome.json"):
    l.recordOutcome(result)
