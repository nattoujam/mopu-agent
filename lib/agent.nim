import std/[json, os, strutils]
from std/posix import Stat, lstat, mkdir, getuid, S_ISDIR
import budget, config, github_app, hooks, log, paths, process, resources

type PollState* = ref object
  cfg*: Config
  auth*: AppAuth
  usage*: Usage
  dryRun*, retry*: bool
  rateLimitHit*, lastTaskOpenedPr*: bool

proc refreshUsage*(p: PollState): string =
  p.usage = parseUsage(fetchUsage(p.cfg))
  if p.usage.known: p.usage.pct5h else: ""

proc relToData*(path: string): string =
  if path.startsWith(dataDir & "/"): path[dataDir.len + 1 .. ^1] else: path

proc abs(path: string): string =
  if path.startsWith("/"): "/" & path else: path

proc command(sub: string): JsonNode = %*{"type": "command", "command": mopuBin & " " & sub}

proc prepareAgentTmpDir*(): bool =
  discard mkdir(agentTmpDir.cstring, 0o700)
  var st: Stat
  if lstat(agentTmpDir.cstring, st) != 0 or not S_ISDIR(st.st_mode) or st.st_uid != getuid() or
      (st.st_mode.cint and 0o777) != 0o700:
    err "エージェント用の TMPDIR を自分だけが使えるディレクトリとして用意できません: " & agentTmpDir
    return false
  true

proc agentTmpEnv*(): seq[(string, string)] =
  @[("TMPDIR", agentTmpDir), ("CLAUDE_CODE_TMPDIR", agentTmpDir)]

# Unix socket をすべて許すと、sandbox から見えるホストの socket（tmux、D-Bus など）に
# つながり、sandbox の外でコマンドを実行できる。tsx などが TMPDIR に置く socket を使えるように
# このリスクを飲み、ホストが socket を置く /run と /tmp を読めなくして、つながる先を
# エージェント用の TMPDIR の中に限っている。$HOME の下の socket は塞いでいない
proc confineUnixSockets*(s: JsonNode) =
  s["sandbox"]["network"]["allowAllUnixSockets"] = %true
  let fs = s["sandbox"]["filesystem"]
  if fs{"denyRead"} == nil:
    fs["denyRead"] = newJArray()
  fs["denyRead"].add %"/run"
  fs["denyRead"].add %"/tmp"
  fs["allowRead"] = %*[agentTmpDir]

# パス制限は絶対パスでしか正しく効かないため、タスクごとに生成する
# （"//" が絶対パスのプレフィックス）。Write ルールは Claude Code が参照しない
# （書き込み系は Edit がカバーする）
proc buildAgentSettings*(cfg: Config, taskDir, output: string): bool =
  let wt = taskDir / repoSubdir
  # permissions の Read は Read ツールに、sandbox の denyRead は Bash にしか効かない
  let secrets = [configEnvFile, stateDir, appKeyFile]
  let link = (try: readFile(wt / ".git").strip(leading = false, chars = {'\n'}) except IOError: "")
  if not link.startsWith("gitdir: ") or link.len == "gitdir: ".len:
    err "worktree の .git を読めません: " & wt
    return false
  let admin = link["gitdir: ".len .. ^1]
  let repoGit = cfg.repoDir / ".git"
  let host = runContainerCommand() & " *"
  var s = parseJson(AgentSettingsJson)

  var allow = %*["Read(" & abs(wt) & "/**)", "Edit(" & abs(wt) & "/**)", "Bash(" & host & ")"]
  for a in s["permissions"]["allow"]: allow.add a
  s["permissions"]["allow"] = allow
  s["sandbox"]["excludedCommands"] = %*[host]
  if s{"hooks"} == nil: s["hooks"] = newJObject()
  s["hooks"]["PreToolUse"] = %*[
    {"matcher": "Bash", "hooks": [command("hook guard-host-commands")]},
    {"matcher": "Edit|Write|NotebookEdit|Bash", "hooks": [command("hook phase-guard")]}]
  s["hooks"]["Stop"] = %*[{"hooks": [command("hook phase-gate")]}]
  var deny = newJArray()
  for p in secrets:
    deny.add %("Read(" & abs(p) & ")")
    deny.add %("Read(" & abs(p) & "/**)")
  deny.add %("Edit(" & abs(wt) & "/.git)")
  deny.add %("Edit(" & abs(wt) & "/.git/**)")
  for d in s["permissions"]["deny"]: deny.add d
  s["permissions"]["deny"] = deny
  # worktree のコミットは共有の .git（repos/<slug>/.git）へ書くので、そこだけ
  # 書き込みを開ける。ただし hooks と config はホストが後で git push を実行する
  # ときに読まれる＝任意コード実行の経路なので閉じる。worktree 側の .git と、
  # 管理ディレクトリの commondir / gitdir は git が config と hooks を探す道筋で、
  # 書き換えると別の hooks を差し込めるため同様に閉じる。info/ は無視リストを持ち、
  # 書き換えると未コミットの変更を git status から隠せるため閉じる
  s["sandbox"]["filesystem"] = %*{
    "allowWrite": [wt, repoGit],
    "denyWrite": [wt / ".git", repoGit / "hooks", repoGit / "config", repoGit / "info",
                  admin / "commondir", admin / "gitdir"],
    "denyRead": secrets,
  }
  confineUnixSockets(s)
  writeFile(output, s.pretty(2) & "\n")
  true

type Invocation* = object
  taskDir*, logDir*, prompt*, systemPrompt*, settings*, resumeId*, jsonSchema*, ghToken*: string
  limit*: int
  budget*: float
  env*: seq[(string, string)]

proc formatNumber*(f: float): string =
  if f == f.int.float: $f.int else: $f

proc invokeAgent*(cfg: Config, inv: Invocation): int =
  var args = @["timeout", $inv.limit, cfg.claudeBin, "-p", inv.prompt]
  # --fork-session で会話を分岐させる。元の会話をそのまま残せるので、再開した
  # 先で失敗しても同じ地点から何度でもやり直せる
  if inv.resumeId.len > 0:
    args.add ["--resume", inv.resumeId, "--fork-session"]
  if inv.jsonSchema.len > 0:
    args.add ["--json-schema", inv.jsonSchema]
  args.add ["--settings", inv.settings, "--permission-mode", "dontAsk", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", """{"mcpServers":{}}""",
            "--append-system-prompt", inv.systemPrompt, "--output-format", "stream-json", "--verbose",
            "--model", cfg.model, "--max-budget-usd", formatNumber(inv.budget)]
  let wt = inv.taskDir / repoSubdir
  # sandbox.credentials は Bash の子プロセスにしか効かない（WebFetch は本体側で動く）
  var env = @[("MOPU_TASK_DIR", inv.taskDir), ("MOPU_LOG_DIR", inv.logDir)] & inv.env
  if inv.ghToken.len > 0:
    env.add ("GH_TOKEN", inv.ghToken)
  # ~/.npm や ~/.cache は sandbox から書けないので、キャッシュを worktree に持たせる
  env.add [("npm_config_cache", wt / ".npm-cache"), ("XDG_CACHE_HOME", wt / ".cache")]
  env.add agentTmpEnv()
  if not dirExists(wt) or not prepareAgentTmpDir():
    return 1
  # sandbox 内の Bash は prompt を経ずに自動承認されるので dontAsk に拒否されない
  run(args, SpawnOptions(
    stdout: Output(path: inv.logDir / "stream.jsonl", append: true),
    stderr: Output(path: inv.logDir / "stderr.log", append: true),
    cwd: wt, env: env,
    unsetEnv: (if inv.ghToken.len > 0: @["GITHUB_TOKEN"] else: @["GH_TOKEN", "GITHUB_TOKEN"])))

proc streamEvents*(path: string, skipLines = 0): seq[JsonNode] =
  if not fileExists(path):
    return
  var i = 0
  for line in readFile(path).splitLines:
    inc i
    if i <= skipLines or line.len == 0:
      continue
    let ev = (try: parseJson(line) except CatchableError: nil)
    if ev != nil and ev.kind == JObject:
      result.add ev

proc lastOfType*(events: seq[JsonNode], kind: string): JsonNode =
  for ev in events:
    if ev{"type"}.getStr == kind:
      result = ev

proc rateLimited*(events: seq[JsonNode]): string =
  let ev = lastOfType(events, "rate_limit_event")
  let status = if ev == nil: "" else: ev{"rate_limit_info", "status"}.getStr
  if status in ["allowed_warning", "rejected"]: status else: ""

proc fileLineCount*(path: string): int =
  if fileExists(path): readFile(path).count('\n') else: 0
