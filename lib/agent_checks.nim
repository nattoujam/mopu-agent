import std/[algorithm, json, os, sequtils, sets, strutils, tempfiles]
from std/posix import Stat, stat, S_ISSOCK, kill, SIGTERM
import agent, log, paths, process, resources, workspace

const SocketProbe = """
out=socket-probe.txt
echo ran > "$out"
own="$TMPDIR/mopu-probe.sock"
socat -u OPEN:/dev/null UNIX-LISTEN:"$own" &
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$own" ] && break; sleep 0.2; done
socat -u UNIX-CONNECT:"$own" STDOUT && echo own >> "$out"
kill $! 2>/dev/null
socat -u UNIX-CONNECT:"$1" STDOUT && echo host >> "$out"
curl -sf -o /dev/null https://registry.npmjs.org/ && echo network >> "$out"
"""

proc isSocket(path: string): bool =
  var st: Stat
  stat(path.cstring, st) == 0 and S_ISSOCK(st.st_mode)

proc claudeBin(): string = getEnv("CLAUDE_BIN", "claude")

proc probeArgs(prompt, settings: string): seq[string] =
  @[claudeBin(), "-p", prompt, "--settings", settings, "--permission-mode", "dontAsk", "--setting-sources", "",
    "--strict-mcp-config", "--mcp-config", """{"mcpServers":{}}""", "--model", "haiku", "--max-budget-usd", "0.2"]

proc claudeVersion(): string = capture(claudeBin(), ["--version"]).output.strip

proc initRepo(dir: string) =
  discard gitRun(dir, "init", "-q")
  discard gitRun(dir, "-c", "user.name=probe", "-c", "user.email=probe@localhost", "commit", "-q", "--allow-empty", "-m", "init")

proc checkAgentRuntime(): int =
  if not prepareAgentTmpDir():
    return 1
  let dir = createTempDir("mopu-runtime-", "", agentTmpDir)
  defer: removeDir(dir)
  let wt = dir / repoSubdir
  createDir(wt)
  createDir(dir / "log")
  initRepo(wt)
  var s = parseJson(AgentSettingsJson)
  s["permissions"]["allow"].add %("Edit(/" & wt & "/**)")
  s["sandbox"]["filesystem"] = %*{"allowWrite": [wt]}
  confineUnixSockets(s)
  s["hooks"] = %*{
    "PreToolUse": [{"matcher": "Edit|Write|NotebookEdit|Bash",
                    "hooks": [{"type": "command", "command": mopuBin & " hook phase-guard"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": mopuBin & " hook phase-gate"}]}],
  }
  writeFile(dir / "settings.json", $s)

  proc probe(state, prompt: string) =
    removeFile(dir / "log" / "phase-gate.count")
    discard run(probeArgs(prompt, dir / "settings.json"), SpawnOptions(
      cwd: wt, stdout: Output(path: "/dev/null"), unsetEnv: @["GH_TOKEN", "GITHUB_TOKEN"],
      env: @[("MOPU_PHASE", state), ("MOPU_TASK_DIR", dir), ("MOPU_LOG_DIR", dir / "log"),
             ("MOPU_HEAD_START", gitOut(wt, "rev-parse", "HEAD"))] & agentTmpEnv()))

  log claudeVersion()
  probe("implement", "Bash ツールで次のコマンドを 1 回だけ実行してから終える。ほかのことはしない: echo probe > probe.txt")
  if fileExists(wt / "probe.txt"):
    log "✓ sandbox の中の Bash が自動で許可された"
  else:
    err "✗ sandbox の中の Bash が拒否された。settings/agent-settings.json の sandbox の設定を確かめる"
    result = 1
  let count = dir / "log" / "phase-gate.count"
  if fileExists(count) and getFileSize(count) > 0:
    log "✓ Stop hook が終えるのを差し戻した（" & readFile(count).strip & " 回）"
  else:
    err "✗ Stop hook が差し戻さなかった"
    result = 1

  probe("triage-new", "Write ツールで note.txt に probe と書いてから終える。拒否されたら、ほかの手段を試さずに終える")
  if not fileExists(wt / "note.txt"):
    log "✓ PreToolUse hook が把握の state での書き込みを拒んだ"
  else:
    err "✗ PreToolUse hook が把握の state での書き込みを拒まなかった"
    result = 1

  let hostDir = createTempDir("mopu-socket-", "", "/tmp")
  defer: removeDir(hostDir)
  let hostSock = hostDir / "host.sock"
  let listener = spawn(@["socat", "-u", "OPEN:/dev/null", "UNIX-LISTEN:" & hostSock],
                       SpawnOptions(stderr: Output(path: "/dev/null")))
  defer:
    discard kill(listener, SIGTERM)
    discard waitExit(listener)
  for _ in 1 .. 20:
    if isSocket(hostSock): break
    sleep 100
  writeFile(wt / "socket-probe.sh", SocketProbe)
  probe("implement", "Bash ツールで次のコマンドを 1 回だけ実行してから終える。ほかのことはしない: sh socket-probe.sh " & hostSock)
  let found = (try: readFile(wt / "socket-probe.txt").splitLines except IOError: @[])
  if not isSocket(hostSock):
    err "✗ ホスト側に検査用の socket を作れなかった（socat を確かめる）"
    result = 1
  elif "ran" notin found:
    err "✗ sandbox の中で socket の検査が実行されなかった"
    result = 1
  else:
    if "own" in found:
      log "✓ sandbox の中で TMPDIR に Unix socket を作ってつなげた"
    else:
      err "✗ sandbox の中で TMPDIR の Unix socket を使えなかった。lib/agent.nim の confineUnixSockets と agentTmpEnv を確かめる"
      result = 1
    if "host" notin found:
      log "✓ /tmp に置いたホストの socket には sandbox からつながらなかった"
    else:
      err "✗ /tmp に置いたホストの socket に sandbox からつながった。lib/agent.nim の confineUnixSockets を確かめる"
      result = 1
    if "network" in found:
      log "✓ /tmp を読めなくしても、sandbox から proxy を通して registry.npmjs.org につながった"
    else:
      err "✗ sandbox から registry.npmjs.org につながらなかった。Claude Code が proxy の socket を TMPDIR の外に置いていないか確かめる"
      result = 1

proc checkSandboxPlaceholders(): int =
  const output = ".mopu-placeholder-probe"
  let dir = createTempDir("mopu-placeholder-", "")
  defer: removeDir(dir)
  discard gitRun(dir, "init", "-q")
  # placeholder は sandbox の中でしか見えないので、git status の結果を作業ディレクトリに書かせて読む
  discard run(probeArgs("Bash ツールで次のコマンドを 1 回だけ実行する。ほかのことはしない: git status --porcelain --untracked-files=all > " &
                        output, $parseJson(AgentSettingsJson)),
              SpawnOptions(cwd: dir, stdout: Output(path: "/dev/null"), unsetEnv: @["GH_TOKEN", "GITHUB_TOKEN"]))
  if not fileExists(dir / output):
    die "sandbox の中で git status が実行されませんでした"
  var actual: HashSet[string]
  for line in readFile(dir / output).splitLines:
    if line.startsWith("?? ") and line != "?? " & output:
      actual.incl "/" & line[3 .. ^1]
  let expected = SandboxPlaceholders.toHashSet
  var missing = toSeq(actual - expected)
  var stale = toSeq(expected - actual)
  missing.sort()
  stale.sort()
  log claudeVersion()
  if stale.len > 0:
    warn "SandboxPlaceholders（lib/workspace.nim）にあるが、置かれなかった placeholder:\n" & stale.join("\n")
  if missing.len > 0:
    die "SandboxPlaceholders（lib/workspace.nim）に足す必要がある placeholder:\n" & missing.join("\n")
  log "SandboxPlaceholders は実際の placeholder をすべて含んでいます (" & $actual.len & " 件)"
  0

proc checkMain*(args: seq[string]): int =
  case (if args.len > 0: args[0] else: "")
  of "agent-runtime": checkAgentRuntime()
  of "sandbox-placeholders": checkSandboxPlaceholders()
  else:
    stderr.writeLine "使い方: mopu check agent-runtime|sandbox-placeholders"
    2
