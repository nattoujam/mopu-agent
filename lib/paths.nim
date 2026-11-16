import std/os
from std/posix import getuid

proc defaultDataDir(): string =
  let home = getEnv("MOPU_HOME")
  if home.len > 0:
    return absolutePath(home)
  let xdg = getEnv("XDG_DATA_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share") / "mopu-agent"

let
  mopuBin* = getAppFilename()
  dataDir* = defaultDataDir()
  configEnvFile* = dataDir / "config.env"
  stateDir* = dataDir / "state"
  logsDir* = dataDir / "logs"
  reposRoot* = dataDir / "repos"
  worktreesRoot* = dataDir / "worktrees"
  runLogDir* = logsDir / "console"
  settingsFile* = stateDir / "settings.json"
  runsFile* = stateDir / "console-runs.jsonl"
  spendFile* = stateDir / "spend.jsonl"
  loopMetricsFile* = stateDir / "loop-metrics.json"
  pollLock* = stateDir / "poll.lock"
  secretsDir* = stateDir / "secrets"
  appKeyFile* = secretsDir / "github-app.pem"
  notifyFile* = secretsDir / "nextcloud.json"
  notifyStateFile* = stateDir / "notify-state.json"
  # dataDir の下に置かないのは、Claude Code が TMPDIR の下に作る claude-<uid> のパスが
  # 44 byte を超えると、sandbox の TMPDIR を OS 既定の temp ディレクトリに切り替えるため
  agentTmpDir* = "/tmp/mopu-" & $getuid()

const repoSubdir* = "repo"

proc repoSlug*(repo: string): string =
  for c in repo:
    result.add(if c == '/': "__" else: $c)
