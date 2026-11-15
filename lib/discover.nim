import std/[algorithm, json, options, os, sequtils, sets, strutils, tables, times, unicode]
import process

type
  ReplyKind* = enum
    rkIssue = "issue"
    rkReview = "review"

  CommentRef* = object
    id*: string
    actor*: string
    instruction*: string
    reply_kind*: ReplyKind
    reply_number*: int
    url*: string

  HistoryRow* = object
    id*: string
    actor*: string
    by_agent*: bool
    body*: string
    url*: string
    created_at*: string

  HistoryComment* = object
    actor*: string
    by_agent*: bool
    body*: string
    url*: string
    created_at*: string

  LearnComment* = object
    id*: string
    actor*: string
    instruction*: string
    url*: string
    created_at*: string
    path*: string

  LearnPr* = object
    number*: int
    title*: string
    body*: string
    url*: string
    issue*: int
    issue_title*: string
    issue_body*: string
    merge_commit*: string
    merged_at*: string
    comments*: seq[LearnComment]

  SpendRun* = object
    task*: string
    time*: string
    repo*: Option[string]
    kind*: Option[string]
    issue*: Option[int]

  MergeCommit* = object
    oid*: string

  MergedPr* = object
    number*: int
    title*: string
    body*: string
    url*: string
    headRefName*: string
    createdAt*: string
    mergedAt*: string
    mergeCommit*: Option[MergeCommit]

  RawComment* = object
    id*: int
    body*: string
    actor*: string
    url*: string
    issue_url*: string
    created_at*: string
    reply_kind*: ReplyKind

  Config = object
    repo, trigger, labelQueued, allowedActors, branchPrefix, commentMarker, lastPollFile, seenFile: string

  SubIssue* = object
    number*: int
    state*: string

  SubIssueConn* = object
    nodes*: Option[seq[SubIssue]]

  Parent* = object
    number*: int
    subIssues*: Option[SubIssueConn]

  Login = object
    login: string

  LabeledNode = object
    number: int
    title: string
    body: string
    author: Option[Login]
    parent: Option[Parent]

  RestComment = object
    id: int
    body: string
    user: Login
    html_url: string
    created_at: string
    issue_url: Option[string]
    pull_request_url: Option[string]
    path: Option[string]

  Review = object
    id: int
    body: string
    user: Login
    html_url: string
    submitted_at: string

  PrHead* = object
    headRefName*: string
    state*: string
    isCrossRepository*: bool

  CommentTarget* = object
    number*: int
    branch*: string

  ParsedRun* = object
    kind*: string
    issue*: int
    started*: Time

const
  HistoryMaxChars* = 20000
  LearnMaxFailures* = 2
  LearnBatchSize* = 3

proc parseIso*(s: string): Time =
  parse(s, "yyyy-MM-dd'T'HH:mm:sszzz").toTime

proc utcStamp*(t: Time): string =
  t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc chomp(s: string): string =
  s.strip(leading = false, chars = {'\n'})

proc stripCodeBlocks*(body: string): seq[string] =
  var inFence = false
  for line in body.split('\n'):
    if line.strip(trailing = false, chars = {' ', '\t'}).startsWith("```"):
      inFence = not inFence
    elif not inFence:
      result.add line

proc isTriggerLine*(line, trigger: string): bool =
  let s = unicode.strip(line, trailing = false)
  s == trigger or s.startsWith(trigger & " ") or s.startsWith(trigger & "\t")

proc hasTrigger*(body, trigger: string): bool =
  stripCodeBlocks(body).anyIt(isTriggerLine(it, trigger))

proc extractInstruction*(body, trigger: string): string =
  let lines = stripCodeBlocks(body)
  for i, l in lines:
    if isTriggerLine(l, trigger):
      return chomp(lines[i .. ^1].join("\n"))
  ""

proc isAllowedActor*(actor, allowed: string): bool =
  actor in unicode.splitWhitespace(allowed)

proc branchToIssueNumber*(head, prefix: string): Option[int] =
  if head.len == 0 or not head.startsWith(prefix):
    return none(int)
  let suffix = head[prefix.len .. ^1]
  if suffix.len > 0 and suffix.allCharsInSet(Digits):
    some(parseInt(suffix))
  else:
    none(int)

proc commentTarget*(number: int, pr: Option[PrHead], prefix: string): CommentTarget =
  let head = if pr.isSome: pr.get.headRefName else: ""
  let issue = branchToIssueNumber(head, prefix)
  if issue.isSome:
    return CommentTarget(number: issue.get)
  if head.len > 0 and pr.get.state == "OPEN" and not pr.get.isCrossRepository:
    return CommentTarget(number: number, branch: head)
  CommentTarget(number: number)

proc issueNumberFromUrl*(url: string): Option[int] =
  var i = url.len
  while i > 0 and url[i - 1] in Digits:
    dec i
  if i == url.len: none(int) else: some(parseInt(url[i .. ^1]))

proc computeSince*(lastPoll: Option[string], now: Time): string =
  var base: Time
  if lastPoll.isSome:
    try:
      base = parseIso(lastPoll.get)
    except TimeParseError:
      return lastPoll.get
  else:
    base = now - initDuration(hours = 1)
  utcStamp(base - initDuration(minutes = 1))

proc sortComments*(rows: seq[RawComment]): seq[RawComment] =
  rows.sorted(proc (a, b: RawComment): int =
    result = cmp(issueNumberFromUrl(a.issue_url).get(0), issueNumberFromUrl(b.issue_url).get(0))
    if result == 0:
      result = cmp(a.created_at, b.created_at))

proc selectHistory*(rows: seq[HistoryRow], exclude: HashSet[string], allowed: string,
                    maxChars: int): seq[HistoryComment] =
  let picked = rows
    .filterIt(unicode.strip(it.body).len > 0 and it.id notin exclude and isAllowedActor(it.actor, allowed))
    .sorted(proc (a, b: HistoryRow): int = cmp(a.created_at, b.created_at))
  var total = 0
  var start = picked.len
  while start > 0 and total + picked[start - 1].body.runeLen <= maxChars:
    dec start
    total += picked[start].body.runeLen
  picked[start .. ^1].mapIt(HistoryComment(actor: it.actor, by_agent: it.by_agent, body: it.body,
                                           url: it.url, created_at: it.created_at))

proc subIssueDeps*(number: int, parent: Option[Parent]): seq[int] =
  if parent.isNone or parent.get.subIssues.isNone:
    return
  for s in parent.get.subIssues.get.nodes.get(@[]):
    if s.state == "OPEN" and s.number < number:
      result.add s.number

proc parseRun*(r: SpendRun): Option[ParsedRun] =
  let parts = r.task.split('-')
  if parts.len < 4 or parts[0] notin ["issue", "comment"]:
    return none(ParsedRun)
  let (n, date, clock) = (parts[1], parts[2], parts[3])
  if n.len == 0 or not n.allCharsInSet(Digits) or date.len != 8 or not date.allCharsInSet(Digits) or
      clock.len < 6 or not clock[0 .. 5].allCharsInSet(Digits):
    return none(ParsedRun)
  var offset = "+00:00"
  if r.time.len >= 6 and r.time[^6] in {'+', '-'} and r.time[^3] == ':' and
      r.time[^5 .. ^4].allCharsInSet(Digits) and r.time[^2 .. ^1].allCharsInSet(Digits):
    offset = r.time[^6 .. ^1]
  let stamp = date[0 .. 3] & "-" & date[4 .. 5] & "-" & date[6 .. 7] & "T" &
    clock[0 .. 1] & ":" & clock[2 .. 3] & ":" & clock[4 .. 5] & offset
  some(ParsedRun(kind: r.kind.get(parts[0]), issue: r.issue.get(parseInt(n)), started: parseIso(stamp)))

proc hasFollowups*(pr: MergedPr, runs: seq[SpendRun], repo, prefix: string): bool =
  let issue = branchToIssueNumber(pr.headRefName, prefix)
  if issue.isNone:
    return false
  let (start, stop) = try: (parseIso(pr.createdAt), parseIso(pr.mergedAt))
                      except TimeParseError: return false
  runs.anyIt(it.repo.get(repo) == repo and (
    let p = parseRun(it)
    p.isSome and p.get.kind == "comment" and p.get.issue == issue.get and
      p.get.started >= start and p.get.started <= stop))

proc handledPrs*(learned: string): HashSet[int] =
  var failures = initCountTable[int]()
  for line in learned.split('\n'):
    let cols = line.split('\t')
    let number = try: parseInt(cols[0]) except ValueError: continue
    if cols.len > 1 and cols[1] == "failed":
      failures.inc number
      if failures[number] >= LearnMaxFailures:
        result.incl number
    else:
      result.incl number

proc nextLearnBatch*(prs: seq[MergedPr], runs: seq[SpendRun], learned, repo, prefix: string): seq[MergedPr] =
  let handled = handledPrs(learned)
  let pending = prs
    .filterIt(it.mergedAt.len > 0 and it.mergeCommit.isSome and it.number notin handled and
              hasFollowups(it, runs, repo, prefix))
    .sorted(proc (a, b: MergedPr): int = cmp(parseIso(a.mergedAt), parseIso(b.mergedAt)))
  if pending.len >= LearnBatchSize: pending[0 ..< LearnBatchSize] else: @[]

proc loadConfig(): Config =
  proc need(name: string): string =
    result = getEnv(name)
    if result.len == 0:
      stderr.writeLine name & " が渡されていません（load_config で export してください）"
      quit 1
  Config(
    repo: need("REPO"),
    trigger: need("TRIGGER_COMMAND"),
    labelQueued: need("LABEL_QUEUED"),
    allowedActors: need("ALLOWED_ACTORS"),
    branchPrefix: need("BRANCH_PREFIX"),
    commentMarker: need("COMMENT_MARKER"),
    lastPollFile: need("LAST_POLL_FILE"),
    seenFile: need("SEEN_FILE"),
  )

proc gh(args: openArray[string]): string =
  let (output, code) = capture("gh", args)
  if code == 0: output else: ""

proc ghJson[T](args: openArray[string]): Option[T] =
  let output = gh(args)
  if output.strip.len == 0:
    return none(T)
  try:
    some(to(parseJson(output), T))
  except CatchableError:
    none(T)

proc log(msg: string) =
  stderr.writeLine now().format("HH:mm:ss") & " " & msg

proc emit(task: JsonNode) =
  stdout.writeLine $task

proc readText(path: string): string =
  if fileExists(path): readFile(path) else: ""

proc appendLine(path, line: string) =
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine line

const LabeledQuery = """
    query($owner:String!, $name:String!, $label:String!) {
      repository(owner:$owner, name:$name) {
        issues(first:50, states:OPEN, labels:[$label], orderBy:{field:CREATED_AT, direction:ASC}) {
          nodes {
            number title body author { login }
            parent { number subIssues(first:100) { nodes { number state } } }
          }
        }
      }
    }"""

type
  LabeledIssues = object
    nodes: Option[seq[LabeledNode]]
  LabeledRepo = object
    issues: Option[LabeledIssues]
  LabeledData = object
    repository: Option[LabeledRepo]
  LabeledResponse = object
    data: Option[LabeledData]

proc discoverLabeled(cfg: Config) =
  let (owner, name) = (cfg.repo.split('/')[0], cfg.repo.split('/')[^1])
  let res = ghJson[LabeledResponse](["api", "graphql", "-f", "owner=" & owner, "-f", "name=" & name,
                                     "-f", "label=" & cfg.labelQueued, "-f", "query=" & LabeledQuery])
  var nodes: seq[LabeledNode]
  if res.isSome and res.get.data.isSome and res.get.data.get.repository.isSome and
      res.get.data.get.repository.get.issues.isSome:
    nodes = res.get.data.get.repository.get.issues.get.nodes.get(@[])
  for n in nodes.sortedByIt(it.number):
    emit %*{
      "kind": "issue",
      "number": n.number,
      "title": n.title,
      "body": n.body,
      "actor": (if n.author.isSome: n.author.get.login else: ""),
      "deps": subIssueDeps(n.number, n.parent),
    }

proc resolveTarget(number: int, cfg: Config): CommentTarget =
  let pr = ghJson[PrHead](["pr", "view", $number, "-R", cfg.repo, "--json", "headRefName,state,isCrossRepository"])
  commentTarget(number, pr, cfg.branchPrefix)

proc fetchComments(cfg: Config, since: string): seq[RawComment] =
  let q = "sort=updated&direction=desc&per_page=100&since=" & since
  var rows: seq[RawComment]
  for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/issues/comments?" & q]).get(@[]):
    rows.add RawComment(id: c.id, body: c.body, actor: c.user.login, url: c.html_url,
                        issue_url: c.issue_url.get(""), created_at: c.created_at, reply_kind: rkIssue)
  for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/pulls/comments?" & q]).get(@[]):
    rows.add RawComment(id: c.id, body: c.body, actor: c.user.login, url: c.html_url,
                        issue_url: c.pull_request_url.get(""), created_at: c.created_at, reply_kind: rkReview)
  sortComments(rows)

proc fetchThread(cfg: Config, numbers: seq[int]): seq[HistoryRow] =
  proc row(id: int, actor, body, url, at: string): HistoryRow =
    HistoryRow(id: $id, actor: actor, by_agent: cfg.commentMarker in body, body: chomp(body), url: url,
               created_at: at)
  for n in numbers:
    for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/issues/" & $n & "/comments?per_page=100"]).get(@[]):
      result.add row(c.id, c.user.login, c.body, c.html_url, c.created_at)
    for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/pulls/" & $n & "/comments?per_page=100"]).get(@[]):
      result.add row(c.id, c.user.login, c.body, c.html_url, c.created_at)
    for r in ghJson[seq[Review]](["api", "repos/" & cfg.repo & "/pulls/" & $n & "/reviews?per_page=100"]).get(@[]):
      result.add row(r.id, r.user.login, r.body, r.html_url, r.submitted_at)

type PrNumber = object
  number: int

proc threadNumbers(cfg: Config, number: int, comments: seq[CommentRef], branch: string): seq[int] =
  result = @[number]
  for c in comments:
    if c.reply_number notin result:
      result.add c.reply_number
  let pr = ghJson[PrNumber](["pr", "view", branch, "-R", cfg.repo, "--json", "number"])
  if pr.isSome and pr.get.number notin result:
    result.add pr.get.number

type IssueMeta = object
  title: string
  body: string

proc discoverComments(cfg: Config) =
  let lastPoll = if fileExists(cfg.lastPollFile): some(readFile(cfg.lastPollFile).strip) else: none(string)
  let since = computeSince(lastPoll, getTime())
  var seen = readText(cfg.seenFile).split('\n').filterIt(it.len > 0).toHashSet

  var resolved = initTable[int, CommentTarget]()
  var branches = initTable[int, string]()
  var hits = initOrderedTable[int, seq[CommentRef]]()

  for row in fetchComments(cfg, since):
    let id = $row.id
    if id in seen:
      continue
    if cfg.commentMarker in row.body:
      appendLine(cfg.seenFile, id)
      seen.incl id
      continue
    if not isAllowedActor(row.actor, cfg.allowedActors) or not hasTrigger(row.body, cfg.trigger):
      continue
    let replyNumber = issueNumberFromUrl(row.issue_url)
    if replyNumber.isNone:
      continue
    if replyNumber.get notin resolved:
      resolved[replyNumber.get] = resolveTarget(replyNumber.get, cfg)
    let target = resolved[replyNumber.get]
    if target.branch.len > 0:
      branches[target.number] = target.branch
    hits.mgetOrPut(target.number, @[]).add CommentRef(
      id: id,
      actor: row.actor,
      instruction: extractInstruction(row.body, cfg.trigger),
      reply_kind: row.reply_kind,
      reply_number: replyNumber.get,
      url: row.url,
    )

  for number in toSeq(hits.keys).sorted:
    let comments = hits[number]
    let issue = ghJson[IssueMeta](["issue", "view", $number, "-R", cfg.repo, "--json", "title,body"])
    if issue.isNone:
      continue
    let branch = branches.getOrDefault(number)
    let history = selectHistory(
      fetchThread(cfg, threadNumbers(cfg, number, comments, if branch.len > 0: branch else: cfg.branchPrefix & $number)),
      comments.mapIt(it.id).toHashSet,
      cfg.allowedActors,
      HistoryMaxChars,
    )
    var task = %*{
      "kind": "comment",
      "number": number,
      "title": chomp(issue.get.title),
      "body": chomp(issue.get.body),
      "actor": comments[0].actor,
      "comments": comments,
      "history": history,
    }
    if branch.len > 0:
      task["branch"] = %branch
    emit task

type HeadRef = object
  headRefName: string

proc listOpenAgentBranches(cfg: Config) =
  let prs = ghJson[seq[HeadRef]](["pr", "list", "-R", cfg.repo, "--state", "open", "--limit", "100",
                                  "--json", "headRefName"]).get(@[])
  for pr in prs:
    if pr.headRefName.startsWith(cfg.branchPrefix):
      stdout.writeLine pr.headRefName

proc readSpendRuns(path: string): seq[SpendRun] =
  for line in readText(path).split('\n'):
    if line.len == 0:
      continue
    try:
      result.add to(parseJson(line), SpendRun)
    except CatchableError:
      discard

proc fetchLearnComments(cfg: Config, pr: MergedPr, issue: int): seq[LearnComment] =
  var rows: seq[LearnComment]
  proc add(id: int, actor, body, url, at: string, path = "") =
    if unicode.strip(body).len == 0 or cfg.commentMarker in body:
      return
    if not isAllowedActor(actor, cfg.allowedActors):
      return
    if at < pr.createdAt or at > pr.mergedAt:
      return
    rows.add LearnComment(id: $id, actor: actor, instruction: chomp(body), url: url, created_at: at, path: path)
  for n in [pr.number, issue]:
    for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/issues/" & $n & "/comments?per_page=100"]).get(@[]):
      add(c.id, c.user.login, c.body, c.html_url, c.created_at)
  for c in ghJson[seq[RestComment]](["api", "repos/" & cfg.repo & "/pulls/" & $pr.number & "/comments?per_page=100"]).get(@[]):
    add(c.id, c.user.login, c.body, c.html_url, c.created_at, c.path.get(""))
  for r in ghJson[seq[Review]](["api", "repos/" & cfg.repo & "/pulls/" & $pr.number & "/reviews?per_page=100"]).get(@[]):
    add(r.id, r.user.login, r.body, r.html_url, r.submitted_at)
  rows.sortedByIt(it.created_at)

proc toJson(c: LearnComment): JsonNode =
  result = %*{"id": c.id, "actor": c.actor, "instruction": c.instruction, "url": c.url, "created_at": c.created_at}
  if c.path.len > 0:
    result["path"] = %c.path

proc discoverLearnSource(cfg: Config) =
  let spendFile = getEnv("SPEND_FILE")
  let learnedFile = getEnv("LEARNED_FILE")
  if spendFile.len == 0 or learnedFile.len == 0:
    stderr.writeLine "SPEND_FILE と LEARNED_FILE が渡されていません（load_config で export してください）"
    quit 1
  let prs = ghJson[seq[MergedPr]](["pr", "list", "-R", cfg.repo, "--state", "merged", "--limit", "500", "--json",
                                   "number,title,body,url,headRefName,createdAt,mergedAt,mergeCommit"]).get(@[])
  let batch = nextLearnBatch(prs, readSpendRuns(spendFile), readText(learnedFile), cfg.repo, cfg.branchPrefix)
  if batch.len == 0:
    return
  var learnPrs: seq[LearnPr]
  for pr in batch:
    let issue = branchToIssueNumber(pr.headRefName, cfg.branchPrefix).get
    let meta = ghJson[IssueMeta](["issue", "view", $issue, "-R", cfg.repo, "--json", "title,body"]).get(IssueMeta())
    learnPrs.add LearnPr(
      number: pr.number,
      title: chomp(pr.title),
      body: chomp(pr.body),
      url: pr.url,
      issue: issue,
      issue_title: chomp(meta.title),
      issue_body: chomp(meta.body),
      merge_commit: pr.mergeCommit.get.oid,
      merged_at: pr.mergedAt,
      comments: fetchLearnComments(cfg, pr, issue),
    )
  var prsJson = newJArray()
  for p in learnPrs:
    var j = %*{
      "number": p.number, "title": p.title, "body": p.body, "url": p.url, "issue": p.issue,
      "issue_title": p.issue_title, "issue_body": p.issue_body, "merge_commit": p.merge_commit,
      "merged_at": p.merged_at,
    }
    j["comments"] = %p.comments.map(toJson)
    prsJson.add j
  emit %*{
    "kind": "learn",
    "number": learnPrs[^1].number,
    "title": "差し戻しの振り返り（" & learnPrs.mapIt("#" & $it.number).join(", ") & "）",
    "body": "",
    "actor": "",
    "prs": prsJson,
  }

proc markSeen(id: string, cfg: Config) =
  if id.len == 0:
    return
  if id notin readText(cfg.seenFile).split('\n'):
    appendLine(cfg.seenFile, id)

proc initSeenBaseline(cfg: Config) =
  if fileExists(cfg.lastPollFile):
    return
  writeFile(cfg.lastPollFile, utcStamp(getTime()) & "\n")
  log "初回実行のため、これ以降に投稿されたコメントのみを対象にします"

proc discoverMain*(args: seq[string]) =
  let sub = if args.len > 0: args[0] else: ""
  let cfg = loadConfig()
  case sub
  of "labeled": discoverLabeled(cfg)
  of "comments": discoverComments(cfg)
  of "open-branches": listOpenAgentBranches(cfg)
  of "mark-seen": markSeen(if args.len > 1: args[1] else: "", cfg)
  of "init-baseline": initSeenBaseline(cfg)
  of "learn-source": discoverLearnSource(cfg)
  else:
    stderr.writeLine "使い方: discover labeled|comments|open-branches|mark-seen <id>|init-baseline|learn-source"
    quit 1
