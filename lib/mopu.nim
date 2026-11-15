import std/os
import ci_gate, console, critic, discover, github_app, hooks, log, notify, outcome, run_container

const Usage = """使い方: mopu <サブコマンド> [引数 ...]

  console                     Web コンソールを起動する
  app-check <App ID> <鍵>     GitHub App の ID と秘密鍵の組を確かめる
  notify <設定> [--silent] <本文>
  discover <種類>
  ci-gate inspect <worktree> <origin/BASE> <BASE>
  critic
  outcome-problem <state> <worktree>
  run-container <検証のキー> [引数 ...]
  hook phase-gate|phase-guard|guard-host-commands"""

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
  of "console": consoleMain()
  of "app-check": appCheckMain(rest)
  of "notify": notifyMain(rest)
  of "discover": discoverMain(rest); 0
  of "ci-gate": ciGateMain(rest)
  of "critic": criticMain()
  of "outcome-problem":
    if rest.len != 2:
      stderr.writeLine Usage
      return 2
    stdout.write outcomeProblem(rest[0], rest[1], conditionsFromEnv())
    0
  of "run-container": runContainerMain(rest)
  of "hook": hookMain(rest)
  of "-h", "--help":
    echo Usage
    0
  else:
    stderr.writeLine Usage
    2

when isMainModule:
  try:
    quit dispatch(commandLineParams())
  except Fatal as e:
    err e.msg
    quit 1
