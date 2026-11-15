import std/[algorithm, json, os, sequtils, sets, strutils, tempfiles]
import log, paths, process, resources, workspace

proc claudeBin(): string = getEnv("CLAUDE_BIN", "claude")

proc probeArgs(prompt, settings: string): seq[string] =
  @[claudeBin(), "-p", prompt, "--settings", settings, "--permission-mode", "dontAsk", "--setting-sources", "",
    "--strict-mcp-config", "--mcp-config", """{"mcpServers":{}}""", "--model", "haiku", "--max-budget-usd", "0.2"]

proc claudeVersion(): string = capture(claudeBin(), ["--version"]).output.strip

proc initRepo(dir: string) =
  discard gitRun(dir, "init", "-q")
  discard gitRun(dir, "-c", "user.name=probe", "-c", "user.email=probe@localhost", "commit", "-q", "--allow-empty", "-m", "init")

proc checkAgentRuntime(): int =
  let dir = createTempDir("mopu-runtime-", "")
  defer: removeDir(dir)
  let wt = dir / repoSubdir
  createDir(wt)
  createDir(dir / "log")
  initRepo(wt)
  var s = parseJson(AgentSettingsJson)
  s["permissions"]["allow"].add %("Edit(/" & wt & "/**)")
  s["sandbox"]["filesystem"] = %*{"allowWrite": [wt]}
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
             ("MOPU_HEAD_START", gitOut(wt, "rev-parse", "HEAD"))]))

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
