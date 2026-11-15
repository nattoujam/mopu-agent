import std/[algorithm, json, os, strutils]
import log, paths, process, resources

const
  CommentMarker* = "<!-- mopu-agent -->"
  # 分解で作られた sub issue の目印。これが本文にある Issue は再分解させない
  SubIssueMarker* = "<!-- mopu-agent:sub-of"
  BranchPrefix* = "agent/issue-"
  LabelQueued* = "agent:queued"
  LabelRunning* = "agent:running"
  LabelAwaiting* = "agent:awaiting-approval"
  LabelAwaitingInput* = "agent:awaiting-input"
  LabelDone* = "agent:done"
  LabelFailed* = "agent:failed"
  AgentLabels* = [LabelQueued, LabelRunning, LabelAwaiting, LabelAwaitingInput, LabelDone, LabelFailed]
  PhaseFileName* = "phases.jsonl"
  TaskFileName* = "task.json"

type Config* = ref object
  appId*, claudeBin*: string
  triggerCommand*, model*, taskTimeout*: string
  maxTaskBudgetUsd*: float
  max5hPercent*, max7dPercent*, maxTasksPerRun*, maxSubIssues*: int
  repo*, baseBranch*, setupCmd*, setupTimeout*: string
  allowedActors*: seq[string]
  maxOpenAgentPrs*: int
  containerChecks*: JsonNode
  learn*: bool
  repoSlug*, repoDir*, repoStateDir*, worktreesDir*, taskLogsDir*: string
  seenFile*, sessionFile*, lastPollFile*, learnedFile*: string

proc unquote(v: string): string =
  if v.len >= 2 and v[0] == v[^1] and v[0] in {'"', '\''}: v[1 .. ^2] else: v

proc loadConfigEnv*() =
  if not fileExists(configEnvFile):
    return
  for raw in readFile(configEnvFile).splitLines:
    let line = raw.strip
    if line.len == 0 or line[0] == '#':
      continue
    let eq = line.find('=')
    if eq <= 0:
      continue
    let key = line[0 ..< eq].strip
    if key.len > 0 and key.allCharsInSet(IdentChars) and not existsEnv(key):
      putEnv(key, unquote(line[eq + 1 .. ^1].strip))

proc loadSettingsFile*(): JsonNode =
  if not fileExists(settingsFile):
    die "設定がありません（" & settingsFile & "）。データの置き場が違うなら MOPU_HOME を指定してください。" &
      "初めてなら mopu console を起動し、画面の「設定」から登録してください"
  try:
    result = parseFile(settingsFile)
  except CatchableError:
    die "state/settings.json を読めません"
  if result.kind != JObject:
    die "state/settings.json を読めません"

proc repoNames*(settings: JsonNode): seq[string] =
  let repos = settings{"repos"}
  if repos != nil and repos.kind == JObject:
    for k in repos.keys:
      result.add k
  result.sort()

proc value(defs, vals: JsonNode, key: string): JsonNode =
  let v = if vals != nil and vals.kind == JObject: vals{key} else: nil
  if v == nil or v.kind == JNull or (v.kind == JBool and not v.getBool): defs[key]["default"] else: v

proc str(n: JsonNode): string =
  case n.kind
  of JString: n.getStr
  of JInt: $n.getBiggestInt
  of JFloat: (if n.getFloat == n.getFloat.int.float: $n.getFloat.int else: $n.getFloat)
  of JBool: $n.getBool
  else: ""

proc toInt(n: JsonNode): int =
  if n.kind == JInt: n.getInt else: n.getFloat.int

proc resolveClaudeBin(): string =
  result = getEnv("CLAUDE_BIN", "claude")
  # エージェントは cd したうえで起動するため、パス指定は絶対パスに直しておく
  if '/' in result:
    result = absolutePath(result).normalizedPath
    if not fileExists(result) or fpUserExec notin getFilePermissions(result):
      die "CLAUDE_BIN を実行できません: " & result
  elif findExe(result).len == 0:
    die "CLAUDE_BIN が見つかりません: " & result
  putEnv("CLAUDE_BIN", result)

proc loadGlobalConfig*(): Config =
  let settings = loadSettingsFile()
  let schema = parseJson(SchemaJson)
  let g = settings{"global"}
  let defs = schema["global"]
  result = Config(
    appId: (let a = settings{"github_app", "app_id"}; if a == nil: "" else: str(a)),
    triggerCommand: str(value(defs, g, "trigger_command")),
    model: str(value(defs, g, "model")),
    taskTimeout: str(value(defs, g, "task_timeout")),
    maxTaskBudgetUsd: value(defs, g, "max_task_budget_usd").getFloat,
    max5hPercent: toInt(value(defs, g, "max_5h_percent")),
    max7dPercent: toInt(value(defs, g, "max_7d_percent")),
    maxTasksPerRun: toInt(value(defs, g, "max_tasks_per_run")),
    maxSubIssues: toInt(value(defs, g, "max_sub_issues")),
  )
  result.claudeBin = resolveClaudeBin()
  if result.appId.len == 0:
    die "GitHub App が登録されていません。コンソールの「設定」で登録してください"
  if not fileExists(appKeyFile):
    die "GitHub App の秘密鍵がありません。コンソールで App を削除して登録し直してください"
  if getFilePermissions(appKeyFile) != {fpUserRead, fpUserWrite}:
    die "秘密鍵の権限が 600 ではありません: " & appKeyFile
  createDir(stateDir)
  if not fileExists(spendFile):
    writeFile(spendFile, "")

proc loadConfig*(repo: string): Config =
  result = loadGlobalConfig()
  let settings = loadSettingsFile()
  let r = settings{"repos", repo}
  if r == nil:
    die "設定にないリポジトリです: " & repo
  let defs = parseJson(SchemaJson)["repo"]
  if '/' notin repo:
    die "設定: リポジトリは owner/repo 形式で指定してください (現在: " & repo & ")"
  result.repo = repo
  for a in value(defs, r, "allowed_actors"):
    if a.kind == JString and a.getStr.strip.len > 0:
      result.allowedActors.add a.getStr.strip
  # 第三者が書いた Issue/コメントを無条件で実行しないための必須ガード
  if result.allowedActors.len == 0:
    die "設定: " & repo & " のタスクを受け付けるユーザーが空です。誰のタスクを実行するか明示してください"
  result.baseBranch = str(value(defs, r, "base_branch"))
  result.maxOpenAgentPrs = toInt(value(defs, r, "max_open_agent_prs"))
  result.containerChecks = value(defs, r, "container_checks")
  result.setupCmd = str(value(defs, r, "setup_cmd"))
  result.setupTimeout = str(value(defs, r, "setup_timeout"))
  result.learn = value(defs, r, "learn").kind == JBool and value(defs, r, "learn").getBool

  result.repoSlug = repoSlug(repo)
  result.repoDir = reposRoot / result.repoSlug
  result.repoStateDir = stateDir / "repos" / result.repoSlug
  result.worktreesDir = worktreesRoot / result.repoSlug
  result.taskLogsDir = logsDir / result.repoSlug
  result.seenFile = result.repoStateDir / "seen-comments.txt"
  result.sessionFile = result.repoStateDir / "sessions.json"
  result.lastPollFile = result.repoStateDir / "last-poll"
  result.learnedFile = result.repoStateDir / "learned-prs.txt"
  for d in [result.repoStateDir, result.worktreesDir, result.taskLogsDir, reposRoot]:
    createDir(d)
  if not fileExists(result.seenFile):
    writeFile(result.seenFile, "")

proc isAllowedActor*(cfg: Config, actor: string): bool =
  actor in cfg.allowedActors

proc durationSeconds*(v: string): int =
  if v.len == 0:
    return 0
  let n = (try: parseInt(v[0 ..< ^1]) except ValueError: 0)
  case v[^1]
  of 'd': n * 86400
  of 'h': n * 3600
  of 'm': n * 60
  of 's': n
  else: (try: parseInt(v) except ValueError: 0)

proc requireTools*() =
  var missing: seq[string]
  for t in ["gh", "jq", "git", "timeout", "tar", "bwrap", "socat"]:
    if findExe(t).len == 0:
      missing.add t
  if missing.len > 0:
    die "必要なコマンドがありません: " & missing.join(" ")
  if capture("gh", ["auth", "status"]).exitCode != 0:
    die "gh が未認証です。gh auth login を実行してください"
  # failIfUnavailable にしてあるので、ここで落とさないとタスクごとに同じ失敗を繰り返す
  if capture("bwrap", ["--ro-bind", "/", "/", "--dev", "/dev", "--unshare-all", "true"]).exitCode != 0:
    die "bwrap がユーザー名前空間を作れません。https://code.claude.com/docs/en/sandboxing を参照してください"
