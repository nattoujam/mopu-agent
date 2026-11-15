import std/[json, options, os, sequtils, strutils, tempfiles, times]
import agent, budget, config, discover, github, github_app, learn, log, loop_metrics, notify, paths, phases, plan,
       process, resources, run_lock, run_task, workspace

const Usage = """使い方: mopu poll [オプション]

  --repo <owner/repo> 指定したリポジトリだけを処理する（省略時は設定にある全リポジトリ）
  --dry-run           検出したタスクを表示するだけで実行しない
  --ignore-budget     利用枠のゲートを無視して実行する
  --task <番号>       指定した Issue 番号だけを処理する（ラベル不要）
  --retry <番号>      その Issue の前回のタスクを、失敗した state からやり直す
  -h, --help          このヘルプ

リポジトリが複数あるとき、--task と --retry には --repo が必要。"""

type Options = object
  dryRun, ignoreBudget, retry: bool
  onlyTask, onlyRepo, maxTasks, reportFile: string
  passthru: seq[string]

proc text(node: JsonNode, key: string): string =
  let v = if node == nil or node.kind != JObject: nil else: node{key}
  if v == nil or v.kind == JNull: "" elif v.kind == JString: v.getStr else: $v

proc parseOptions(args: seq[string]): Options =
  var i = 0
  proc value(name, message: string): string =
    if i + 1 >= args.len or args[i + 1].len == 0:
      die name & ": " & message
    inc i
    args[i]
  while i < args.len:
    let a = args[i]
    case a
    of "--repo": result.onlyRepo = value(a, "--repo には owner/repo が必要です")
    of "--dry-run":
      result.dryRun = true
      result.passthru.add a
    of "--ignore-budget":
      result.ignoreBudget = true
      result.passthru.add a
    of "--task":
      result.onlyTask = value(a, "--task には Issue 番号が必要です")
      result.passthru.add [a, result.onlyTask]
    of "--retry":
      result.onlyTask = value(a, "--retry には Issue 番号が必要です")
      result.retry = true
      result.passthru.add [a, result.onlyTask]
    of "--max-tasks": result.maxTasks = value(a, "値が必要です")
    of "--report": result.reportFile = value(a, "値が必要です")
    of "-h", "--help":
      echo Usage
      quit 0
    else: die "不明なオプション: " & a
    inc i

proc lockPoll(): cint =
  let fd = tryLockPoll()
  if fd.isNone:
    die "別の mopu poll が実行中です"
  fd.get

proc pollAllRepos(o: Options, errorKey: string): int =
  let cfg = loadGlobalConfig()
  log "mopu-agent " & Version & " (" & Commit & ")"
  discard lockPoll()
  let repos = repoNames(loadSettingsFile())
  let n = repos.len
  if n == 0:
    die "リポジトリが設定されていません。コンソールの「設定」で登録してください"
  if o.onlyTask.len > 0 and n > 1:
    die "リポジトリが複数あるため、--task / --retry には --repo も指定してください (" & repos.join(" ") & ")"

  let nextFile = stateDir / "next-repo"
  var start = (try: parseInt(readFile(nextFile).strip) except CatchableError: 0)
  if start < 0: start = 0
  start = start mod n
  if not o.dryRun:
    writeFile(nextFile, $((start + 1) mod n) & "\n")

  var remaining = cfg.maxTasksPerRun
  var total = 0
  var failed = 0
  let (reportHandle, report) = createTempFile("mopu-report-", ".json")
  reportHandle.close()
  defer: removeFile(report)
  for i in 0 ..< n:
    let repo = repos[(start + i) mod n]
    if remaining <= 0:
      log "1回の上限 (" & $cfg.maxTasksPerRun & " 件) に達したため、" & repo & " 以降は次回に回します"
      break
    log "── " & repo & " ──"
    writeFile(report, "")
    let rc = run(@[mopuBin, "poll", "--repo", repo, "--max-tasks", $remaining, "--report", report] & o.passthru)
    let r = (try: parseFile(report) except CatchableError: newJObject())
    let processed = (let p = r{"processed"}; if p != nil and p.kind == JInt and p.getInt >= 0: p.getInt else: 0)
    total += processed
    remaining -= processed
    if rc != 0:
      warn repo & " の処理が異常終了しました (exit=" & $rc & ")"
      failed = 1
    if r{"stop"} != nil and r["stop"].kind == JBool and r["stop"].getBool:
      log "利用枠またはレート上限のため、残りのリポジトリは次回に回します"
      break
  log "全リポジトリの処理を終えました（計 " & $total & " 件）"
  notifyOnChange(errorKey, "", "✅ ポーリングが復旧しました", silent = true)
  if not o.dryRun:
    try:
      discard writeLoopMetrics()
    except CatchableError as e:
      warn "ループの計測に失敗しました: " & e.msg
  failed

type RepoPoll = ref object
  o: Options
  p: PollState
  cfg: Config
  dcfg: DiscoverConfig
  maxOpenAgentPrs: int
  openBranches: seq[string]
  processed: int
  stopAll: bool

proc gate(r: RepoPoll): Budget =
  if r.o.ignoreBudget:
    log "利用枠のゲートを無視します (--ignore-budget)"
    return bOk
  result = checkBudget(r.cfg, r.p.usage)
  if r.o.dryRun:
    return
  let u = r.p.usage
  case result
  of bOk: notifyOnChange("budget", "", "▶ 利用枠が戻ったため、タスクの処理を再開します", silent = true)
  of bOver:
    notifyOnChange("budget", "over", "⏸ **利用枠の上限で停止中**\n- 5h: " & u.pct5h & "%（resets " &
      (if u.reset5h.len > 0: u.reset5h else: "不明") & "）\n- 7d: " & u.pct7d & "%（resets " &
      (if u.reset7d.len > 0: u.reset7d else: "不明") & "）")
  of bUnknown: notifyOnChange("budget", "unknown", "⏸ **利用枠を取得できないため停止中**")

# 同じ親を持つ sub-issue は、先に作られたものが後続の前提になる。番号が若い
# 兄弟が open（＝PR が未マージでベースに入っていない）うちは着手を見送る。
# 待っている Issue 番号を表示用に返す。--task 指定とコメント由来のタスクは
# deps を持たないので、この判定を素通りする
proc subIssueDeps(task: JsonNode): string =
  let deps = task{"deps"}
  if deps == nil or deps.kind != JArray:
    return ""
  deps.elems.mapIt("#" & $it).join(", ")

proc markTaskSeen(r: RepoPoll, task: JsonNode) =
  let comments = task{"comments"}
  if comments != nil and comments.kind == JArray:
    for c in comments:
      markSeen(text(c, "id"), r.dcfg)

# 進行中 PR を持つ Issue 自身のタスクは通す。ここを塞ぐとレビュー指摘を反映できず
# 「PR が open なので着手できない / 着手できないので PR が進まない」で詰まる。
# 質問への回答や分解案の承認を待っている Issue へのコメントも、着手済みのタスクの続きなので通す。
# mopu-agent 以外が出した PR のブランチに積むタスクは、PR を増やさないので通す
proc inFlightBlocked(r: RepoPoll, task: JsonNode): bool =
  let number = text(task, "number")
  let branch = taskBranch(task, number)
  if r.maxOpenAgentPrs <= 0 or not branch.startsWith(BranchPrefix) or branch in r.openBranches or
      r.openBranches.len < r.maxOpenAgentPrs:
    return false
  if text(task, "kind") != "comment":
    return true
  let labels = issueLabels(r.cfg, number)
  LabelAwaitingInput notin labels and LabelAwaiting notin labels

proc collectTasks(r: RepoPoll): seq[JsonNode] =
  if r.o.onlyTask.len > 0:
    if r.o.retry:
      let t = loadFailedTask(r.cfg, r.o.onlyTask)
      if t != nil:
        log "前回のタスクを引き継ぎます: [" & text(t, "kind") & "] #" & text(t, "number") & " " & text(t, "title")
        return @[t]
    let issue = ghJson(["issue", "view", r.o.onlyTask, "-R", r.cfg.repo, "--json", "number,title,body,author"])
    if issue == nil or issue.kind != JObject:
      die "Issue #" & r.o.onlyTask & " を取得できませんでした"
    return @[%*{"kind": "issue", "number": issue["number"], "title": issue["title"], "body": issue["body"],
                "actor": issue{"author", "login"}}]
  result = labeledTasks(r.dcfg) & commentTasks(r.dcfg)
  # 学習は人の依頼を待たせないよう、通常のタスクの後ろに並べる
  let l = learnTasks(r.p)
  if l != nil:
    result.add l

proc dryRunLine(r: RepoPoll, t: JsonNode): string =
  if text(t, "kind") == "learn":
    var count = 0
    for pr in t["prs"]:
      count += pr["comments"].len
    return "  [learn] " & text(t, "title") & "  ← 差し戻し " & $count & " 件の行動を振り返る"
  result = "  [" & text(t, "kind") & "] #" & text(t, "number") & " " & text(t, "title") & "  (by " & text(t, "actor") & ")"
  let comments = t{"comments"}
  if comments != nil and comments.kind == JArray and comments.len > 1:
    result.add "  ← コメント " & $comments.len & " 件をまとめて処理"
  if approveCommentId(r.cfg, t).len > 0:
    result.add "  ← 分解案の承認（エージェントは起動しない）"
  elif subIssueDeps(t).len > 0:
    result.add "  ← 先行する sub-issue (" & subIssueDeps(t) & ") 待ちでスキップ"
  elif r.inFlightBlocked(t):
    result.add "  ← 進行中の PR があるためスキップ"

proc runTasks(r: RepoPoll) =
  let p = r.p
  let cfg = r.cfg
  # last-poll には収集を始めた時刻を書く。終了時刻にすると、タスクの実行中
  # （実測 2〜6 分）に投稿されたコメントが次回の since 窓から外れて消える。
  # 窓が前回と重なっても、処理済みのコメントは seen-comments.txt が弾く
  initSeenBaseline(r.dcfg)
  let startedAt = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let tasks = r.collectTasks()
  if tasks.len == 0:
    log "処理するタスクはありません"
    writeFile(cfg.lastPollFile, startedAt & "\n")
    return
  log $tasks.len & " 件のタスクを検出しました"

  if r.o.dryRun:
    for t in tasks:
      stdout.writeLine r.dryRunLine(t)
    discard r.gate()
    return

  # 上限/レート制限/利用枠で打ち切ると、コメント由来のタスクは last-poll 更新後の
  # since 窓から外れて二度と検出されなくなる（issue はラベル基準で毎回全件取得する
  # ため影響しない）。打ち切った回は last-poll を更新せず、次回も同じ since から
  # 再走査させて取りこぼしを防ぐ
  var incomplete = false
  for t in tasks:
    if r.processed >= cfg.maxTasksPerRun:
      log "1回の上限 (" & $cfg.maxTasksPerRun & " 件) に達しました"
      incomplete = true
      break
    if p.rateLimitHit:
      warn "レート上限に達したため以降のタスクを中止します"
      incomplete = true
      r.stopAll = true
      break

    # 学習のタスクは mopu-agent 自身が作るので、発行者・進行中 PR・sub-issue の判定を通さない。
    # 対象の PR は learned-prs.txt で管理するので、打ち切っても last-poll には関わらない
    let kind = text(t, "kind")
    if kind == "learn":
      if r.gate() != bOk:
        log "利用枠のため以降のタスクを中止します"
        r.stopAll = true
        break
      ensureRepo(cfg)
      discard runLearnTask(p, t)
      inc r.processed
      continue

    let actor = text(t, "actor")
    if not cfg.isAllowedActor(actor):
      warn "許可されていないユーザーのタスクをスキップします: " & actor
      continue
    let number = text(t, "number")
    # 承認はホストだけで済むので、進行中 PR や利用枠のゲートより前に処理する
    if approvePlanTask(cfg, t):
      r.markTaskSeen(t)
      inc r.processed
      continue
    let deps = subIssueDeps(t)
    if deps.len > 0:
      log "先行する sub-issue (" & deps & ") が未マージのためスキップします: #" & number
      continue
    if r.inFlightBlocked(t):
      log "進行中の PR が " & $r.openBranches.len & " 件あるためスキップします: #" & number & "（マージ/クローズ後に再検出されます）"
      # ラベルは毎回引き直せるが、コメントは last-poll が進めば窓から外れて消える
      if kind == "comment":
        incomplete = true
      continue

    # タスクごとに枠を確認し、連続処理で閾値を跨がないようにする
    if r.gate() != bOk:
      log "利用枠のため以降のタスクを中止します"
      incomplete = true
      r.stopAll = true
      break

    ensureRepo(cfg)
    discard runTask(p, t)
    let branch = taskBranch(t, number)
    if p.lastTaskOpenedPr and branch.startsWith(BranchPrefix):
      r.openBranches.add branch
    r.markTaskSeen(t)
    inc r.processed

  if p.rateLimitHit:
    r.stopAll = true
    notifyOnChange("budget", "rate-limit", "⏸ **レート上限の警告で停止中**")
  if incomplete:
    log "未処理のタスクが残っているため last-poll は更新しません（次回も同じ範囲を再走査します）"
  else:
    writeFile(cfg.lastPollFile, startedAt & "\n")
  log "完了: " & $r.processed & " 件を処理しました"

proc requireLabelsReady(cfg: Config) =
  let r = ghRun(["label", "list", "-R", cfg.repo, "--limit", "200", "--json", "name", "--jq", ".[].name"])
  if r.exitCode != 0:
    die "ラベル一覧を取得できませんでした: " & cfg.repo
  let existing = r.output.splitLines
  let missing = AgentLabels.filterIt(it notin existing)
  # ラベルが未作成のまま動かすと、setLabels の付与だけが失敗して削除は通るため、
  # Issue に付いていた agent:queued が外れてしまう
  if missing.len > 0:
    die "ラベルが未作成です (" & missing.join(" ") & ")。先に mopu setup を実行してください"

# 設定で明示されていればそれを優先する（PR のベースを既定ブランチ以外に
# したい場合があるため）。gh で引く都合上、App 認証を張った後に呼ぶ
proc resolveBaseBranch(cfg: Config) =
  if cfg.baseBranch.len > 0:
    return
  cfg.baseBranch = ghOut(["repo", "view", cfg.repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]).strip
  if cfg.baseBranch.len == 0:
    die "既定ブランチを取得できませんでした: " & cfg.repo
  log "ベースブランチ: " & cfg.baseBranch

proc pollRepo(o: Options, r: RepoPoll) =
  let cfg = loadConfig(o.onlyRepo)
  r.cfg = cfg
  if o.maxTasks.len > 0:
    cfg.maxTasksPerRun = (try: parseInt(o.maxTasks) except ValueError: die "--max-tasks には整数を指定してください")
  if o.reportFile.len == 0:
    log "mopu-agent " & Version & " (" & Commit & ")"
    # 親から呼ばれたときは、親がロックを握っている
    discard lockPoll()

  let auth = setupAppAuth(cfg)
  r.p = PollState(cfg: cfg, auth: auth, dryRun: o.dryRun, retry: o.retry)
  resolveBaseBranch(cfg)
  requireLabelsReady(cfg)
  r.dcfg = discoverConfig(cfg)

  r.maxOpenAgentPrs = cfg.maxOpenAgentPrs
  # --task は人が明示的に指定した 1 件なので、進行中 PR のゲートは適用しない
  if o.onlyTask.len > 0 and r.maxOpenAgentPrs > 0:
    log "手動指定 (--task) のため、進行中 PR のゲートを無視します"
    r.maxOpenAgentPrs = 0

  cleanupMerged(r.p)
  closeCompletedParents(cfg, o.dryRun)
  r.openBranches = openAgentBranches(r.dcfg)
  if r.openBranches.len > 0:
    log "進行中の PR: " & $r.openBranches.len & " 件 (" & r.openBranches.join(" ") & ")"
  r.runTasks()

proc pollMain*(args: seq[string]): int =
  var errorKey = "poll"
  var label = ""
  try:
    let o = parseOptions(args)
    if o.onlyRepo.len > 0:
      errorKey = "poll:" & o.onlyRepo
      label = " " & issueRef(o.onlyRepo)
    requireTools()
    if o.onlyRepo.len == 0:
      return pollAllRepos(o, errorKey)
    let r = RepoPoll(o: o)
    var ok = false
    try:
      pollRepo(o, r)
      ok = true
    finally:
      if o.reportFile.len > 0:
        writeFile(o.reportFile, $(%*{"processed": r.processed, "stop": r.stopAll}) & "\n")
    if ok:
      notifyOnChange(errorKey, "", "✅ ポーリングが復旧しました" & label, silent = true)
    0
  except Fatal as e:
    err e.msg
    notifyOnChange(errorKey, e.msg, "⚠ **ポーリングを中止**" & label & "\n" & mdQuote(e.msg))
    1
