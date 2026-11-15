import std/os

let
  mopuBin* = getAppFilename()
  agentDir* = (let d = getEnv("AGENT_DIR"); if d.len > 0: d else: mopuBin.parentDir.parentDir)
  stateDir* = agentDir / "state"
  logsDir* = agentDir / "logs"
  reposRoot* = agentDir / "repos"
  worktreesRoot* = agentDir / "worktrees"
  runLogDir* = logsDir / "console"
  webDir* = agentDir / "web"
  promptsDir* = agentDir / "prompts"
  schemaFile* = agentDir / "settings" / "schema.json"
  agentSettingsFile* = agentDir / "settings" / "agent-settings.json"
  settingsFile* = stateDir / "settings.json"
  runsFile* = stateDir / "console-runs.jsonl"
  spendFile* = stateDir / "spend.jsonl"
  loopMetricsFile* = stateDir / "loop-metrics.json"
  pollLock* = stateDir / "poll.lock"
  secretsDir* = stateDir / "secrets"
  appKeyFile* = secretsDir / "github-app.pem"
  notifyFile* = secretsDir / "nextcloud.json"
  notifyStateFile* = stateDir / "notify-state.json"

const repoSubdir* = "repo"

proc repoSlug*(repo: string): string =
  for c in repo:
    result.add(if c == '/': "__" else: $c)
