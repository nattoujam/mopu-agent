import std/os
import agent_checks, ci_gate, config, console, critic, discover, github_app, hooks, log, loop_metrics, notify, poll,
       run_container, setup

const Usage = """使い方: mopu <サブコマンド> [引数 ...]

  poll [オプション]           タスクを検出して処理する（詳しくは mopu poll --help）
  console                     Web コンソールを起動する
  setup [--repo owner/repo]   対象リポジトリにラベルを作る
  loop-metrics                差し戻し率などを集計して state/loop-metrics.json に書く
  check agent-runtime         Claude Code の sandbox と hook の挙動を実測する
  check sandbox-placeholders  sandbox が置く placeholder を実測する
  app-check <App ID> <鍵>     GitHub App の ID と秘密鍵の組を確かめる

エージェントや内部から呼ばれるもの:
  run-container <検証のキー> [引数 ...]
  hook phase-gate|phase-guard|guard-host-commands
  notify <設定> [--silent] <本文>
  discover <種類>
  ci-gate inspect <worktree> <origin/BASE> <BASE>
  critic"""

proc hookMain(args: seq[string]): int =
  case (if args.len > 0: args[0] else: "")
  of "phase-gate": phaseGate()
  of "phase-guard": phaseGuard(); 0
  of "guard-host-commands": guardHostCommands(); 0
  else:
    stderr.writeLine Usage
    2

proc dispatch(args: seq[string]): int =
  let sub = if args.len > 0: args[0] else: ""
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  case sub
  of "poll":
    loadConfigEnv()
    pollMain(rest)
  of "console":
    loadConfigEnv()
    requireTools()
    consoleMain()
  of "setup":
    loadConfigEnv()
    setupMain(rest)
  of "loop-metrics": loopMetricsMain(rest)
  of "check":
    loadConfigEnv()
    checkMain(rest)
  of "app-check": appCheckMain(rest)
  of "notify": notifyMain(rest)
  of "discover": discoverMain(rest); 0
  of "ci-gate": ciGateMain(rest)
  of "critic": criticMain()
  of "run-container": runContainerMain(rest)
  of "hook": hookMain(rest)
  of "-h", "--help":
    echo Usage
    0
  else:
    stderr.writeLine Usage
    2

when isMainModule:
  if getEnv("MOPU_ASKPASS") == "1":
    askpassMain(if paramCount() >= 1: paramStr(1) else: "")
    quit 0
  try:
    quit dispatch(commandLineParams())
  except Fatal as e:
    err e.msg
    quit 1
