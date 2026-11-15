import std/[json, os, osproc, strutils, tempfiles, unittest]
import ../lib/[hooks, outcome, paths, workspace]

suite "guard-host-commands":
  let rc = runContainerCommand()
  test "キーと素直な引数は通す":
    check allowedHostCommand(rc & " test")
    check allowedHostCommand(rc & " key:1.2-x_y --grep \"a b\" 'c $d'")
    check allowedHostCommand(rc & " k a=b,c:d/e@f%g+h-i.j あいう")
  test "展開やつなぎを含むものは拒む":
    for arg in ["\"$HOME\"", "\"a`id`\"", "\"a\\\\b\"", "\"a!\"", "a*", "a;id", "a | cat", "> x", "$(id)",
                "\"unterminated"]:
      check not allowedHostCommand(rc & " vrt " & arg)
  test "入口の形が違うものは拒む":
    for cmd in [rc, rc & " ", rc & " bad/key", rc & "x test", rc & "\ttest", "cd x && " & rc & " test",
                "sh -c \"" & rc & " test\""]:
      check not allowedHostCommand(cmd)

suite "phase-guard":
  test "git commit を見分ける":
    for cmd in ["git commit -m x", "git  commit", "git\tcommit\n", "cd a && git commit --amend",
                "/usr/bin/git commit", "git status; git commit"]:
      check isGitCommit(cmd)
    for cmd in ["xgit commit", "my-git commit", "git commits", "git commit-tree", "gitcommit",
                "git -C x commit", "echo git; git log"]:
      check not isGitCommit(cmd)

proc git(dir: string, args: varargs[string]): string =
  let (output, code) = execCmdEx("git -C " & quoteShell(dir) & " " & args.join(" "))
  doAssert code == 0, output
  output.strip

suite "outcomeProblem":
  let wt = createTempDir("outcome-test-", "")
  discard git(wt, "init -q")
  discard git(wt, "-c user.name=t -c user.email=t@localhost commit -q --allow-empty -m init")
  writeFile(wt / ".git/info/exclude", "/" & outcomeFileName & "\n")
  let head = git(wt, "rev-parse HEAD")
  let cond = CallConditions(headStart: head, maxSubIssues: 2, commentIds: @["11"])
  proc outcomeIs(o: JsonNode) = writeFile(wt / outcomeFileName, $o)

  test "出口ファイルが無い":
    removeFile(wt / outcomeFileName)
    check outcomeProblem("triage-new", wt, cond) == "出口ファイル " & outcomeFileName & " が無い"
  test "decision が許されていない":
    outcomeIs %*{"decision": "done"}
    check outcomeProblem("triage-new", wt, cond) == "decision は implement・decompose・ask・answer のどれか（今は \"done\"）"
  test "空白だけの欄は空とみなす":
    outcomeIs %*{"decision": "implement", "note": " 　\n", "no_split_reason": "r"}
    check outcomeProblem("triage-new", wt, cond) == "note が空"
  test "分解は件数の上限を見る":
    outcomeIs %*{"decision": "decompose", "plan": {"sub_issues": [{"title": "a"}, {"title": "b"}, {"title": "c"}]},
                 "replies": {"11": "x"}}
    check outcomeProblem("triage-new", wt, cond) == "plan.sub_issues は 1〜2 件の配列で、各要素に空でない title が要る"
  test "終える出口は全コメントへの返信が要る":
    outcomeIs %*{"decision": "ask", "question": "q"}
    check outcomeProblem("triage-new", wt, cond) == "replies に次のコメントへの返信が無い: 11"
    outcomeIs %*{"decision": "ask", "question": "q", "replies": {"11": "x"}}
    check outcomeProblem("triage-new", wt, cond) == ""
  test "実装はコミットが要る":
    outcomeIs %*{"decision": "done"}
    check outcomeProblem("implement", wt, cond) == "コミットが無い。変更をコミットしてから done にする"
  test "把握の state ではコミットしない":
    discard git(wt, "-c user.name=t -c user.email=t@localhost commit -q --allow-empty -m c")
    outcomeIs %*{"decision": "answer", "answer": "a", "replies": {"11": "x"}}
    check outcomeProblem("triage-new", wt, cond) == "このフェーズではコミットしない。git reset --hard " & head & " で戻す"
    check outcomeProblem("implement", wt, cond) == "decision は done・ask のどれか（今は \"answer\"）"

suite "verifyWorkspace":
  let root = createTempDir("workspace-test-", "")
  let repoDir = root / "repo-main"
  createDir(repoDir)
  discard git(repoDir, "init -q")
  discard git(repoDir, "-c user.name=t -c user.email=t@localhost commit -q --allow-empty -m init")
  let wt = root / "task" / repoSubdir
  createDir(root / "task")
  discard git(repoDir, "worktree add -q --detach " & quoteShell(wt))
  test "git が作ったままなら通す":
    check verifyWorkspace(wt, repoDir)
  test "別のリポジトリの worktree は通さない":
    check not verifyWorkspace(wt, root)
  test ".git を書き換えたら通さない":
    let original = readFile(wt / ".git")
    writeFile(wt / ".git", "gitdir: /tmp/evil\n")
    check not verifyWorkspace(wt, repoDir)
    writeFile(wt / ".git", original)
    check verifyWorkspace(wt, repoDir)
  test "symlink の worktree は通さない":
    createSymlink(wt, root / "link")
    check not verifyWorkspace(root / "link", repoDir)
