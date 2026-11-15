import std/[json, options, os, osproc, tempfiles, unittest]
import ../lib/ci_gate

proc on(triggers: varargs[Filters]): PullRequestTrigger =
  PullRequestTrigger(kind: tkOn, triggers: @triggers)

suite "parsePullRequestTrigger":
  test "スカラーの on":
    check parsePullRequestTrigger("on: pull_request\njobs: {}\n") == on(Filters())
  test "flow seq の on":
    check parsePullRequestTrigger("on: [push, pull_request]\n") == on(Filters())
  test "pull_request が無ければ none":
    check parsePullRequestTrigger("on:\n  push:\n    branches: [main]\n").kind == tkNone
  test "block seq の on":
    check parsePullRequestTrigger("on:\n  - push\n  - pull_request\n") == on(Filters())
  test "絞り込みの block seq とコメントとクォート":
    let yaml = """name: Test

on:
  pull_request:  # PR だけ
    paths:
      - "server/**"
      - 'web/**'
    branches: [main, 'release/**']
  workflow_dispatch:
    inputs:
      mode:
        type: choice

jobs:
  test: {}"""
    check parsePullRequestTrigger(yaml) ==
      on(Filters(paths: some(@["server/**", "web/**"]), branches: some(@["main", "release/**"])))
  test "値の無い pull_request は絞り込みなし":
    check parsePullRequestTrigger("on:\n  pull_request:\n  workflow_dispatch:\n") == on(Filters())
  test "pull_request と pull_request_target の両方を拾う":
    check parsePullRequestTrigger("on:\n  pull_request:\n    paths: [a/**]\n  pull_request_target:\n") ==
      on(Filters(paths: some(@["a/**"])), Filters())
  test "flow mapping は読まない":
    check parsePullRequestTrigger("on:\n  pull_request: {paths: [a]}\n").kind == tkUnknown
  test "on が無ければ unknown":
    check parsePullRequestTrigger("name: x\n").kind == tkUnknown

suite "globMatch / matchesFilter":
  test "* は / をまたがない":
    check globMatch("src/*", "src/a.ts")
    check not globMatch("src/*", "src/a/b.ts")
  test "** は / をまたぐ":
    check globMatch("src/**", "src/a/b.ts")
  test "**/ は 0 段のディレクトリにも一致する":
    check globMatch("**/README.md", "README.md")
    check globMatch("**/README.md", "docs/README.md")
  test "? は直前の 1 文字を任意にする":
    check globMatch("*.jsx?", "a.js")
    check globMatch("*.jsx?", "a.jsx")
  test "+ は直前の 1 文字を 1 回以上にする":
    check globMatch("a+.md", "aaa.md")
    check not globMatch("a+.md", ".md")
  test "量指定の後ろの ? は一致の範囲を変えない":
    check not globMatch("a+?.md", ".md")
  test "文字クラスと否定の文字クラス":
    check globMatch("v[0-9].md", "v3.md")
    check not globMatch("v[^0-9].md", "v3.md")
  test "閉じていない [ はそのままの文字":
    check globMatch("a[b", "a[b")
  test ". はそのままの文字":
    check not globMatch("a.md", "aXmd")
  test "後ろの否定が勝つ":
    check not matchesFilter(@["docs/**", "!docs/draft/**"], "docs/draft/a.md")
    check matchesFilter(@["docs/**", "!docs/draft/**"], "docs/a.md")
  test "否定の後ろの肯定で戻る":
    check matchesFilter(@["docs/**", "!docs/draft/**", "docs/draft/keep.md"], "docs/draft/keep.md")

suite "filtersApply":
  test "絞り込みなしは変更があれば動く":
    check filtersApply(Filters(), "main", @["README.md"]) == apRuns
  test "変更が無ければ動かない":
    check filtersApply(Filters(), "main", @[]) == apSkips
  test "paths に当たらなければ動かない":
    check filtersApply(Filters(paths: some(@["server/**", "web/**"])), "main", @["README.md"]) == apSkips
  test "paths に 1 つでも当たれば動く":
    check filtersApply(Filters(paths: some(@["web/**"])), "main", @["README.md", "web/a.ts"]) == apRuns
  test "paths-ignore は全部が当たったときだけ動かない":
    check filtersApply(Filters(pathsIgnore: some(@["docs/**"])), "main", @["docs/a.md"]) == apSkips
    check filtersApply(Filters(pathsIgnore: some(@["docs/**"])), "main", @["docs/a.md", "a.ts"]) == apRuns
  test "branches はマージ先で判定する":
    check filtersApply(Filters(branches: some(@["main"])), "develop", @["a.ts"]) == apSkips
    check filtersApply(Filters(branchesIgnore: some(@["main"])), "main", @["a.ts"]) == apSkips
  test "types に synchronize が無ければ判定しない":
    check filtersApply(Filters(types: some(@["opened"])), "main", @["a.ts"]) == apUnknown

suite "workflowApplies":
  test "読めない YAML は unknown":
    check workflowApplies("on: {pull_request: {}}\n", "main", @["a"]) == apUnknown
  test "どれかの起動条件で動けば動く":
    check workflowApplies("on:\n  pull_request:\n    paths: [a/**]\n  pull_request_target:\n", "main", @["b"]) == apRuns

suite "testRelatedFiles":
  test "テストと設定と workflow を拾う":
    check testRelatedFiles(@[
      "server/test/a.test.ts",
      "web/src/b.spec.tsx",
      "web/playwright.config.ts",
      "web/__screenshots__/baseline/x.png",
      ".github/workflows/test.yml",
      "web/src/c.ts",
      "docs/testing.md",
    ]) == @[
      "server/test/a.test.ts",
      "web/src/b.spec.tsx",
      "web/playwright.config.ts",
      "web/__screenshots__/baseline/x.png",
      ".github/workflows/test.yml",
    ]
  test "ファイル名の最後が .test. で終わるだけのものは拾わない":
    check testRelatedFiles(@["a.test.", "test", "jest.config."]).len == 0

suite "inspect":
  proc git(dir: string, args: varargs[string]) =
    let (output, code) = execCmdEx("git -C " & quoteShell(dir) & " " & quoteShellCommand(args))
    doAssert code == 0, output

  test "マージ先の workflow で、ブランチの変更に CI が動くかと、テストに関わる変更を返す":
    let dir = createTempDir("ci-gate-test-", "")
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.email", "test@example.invalid")
    git(dir, "config", "user.name", "test")
    createDir(dir / ".github" / "workflows")
    writeFile(dir / ".github" / "workflows" / "test.yml", "on:\n  pull_request:\n    paths: [src/**]\n")
    writeFile(dir / ".github" / "workflows" / "docs.yaml", "on:\n  pull_request:\n    paths: [docs/**]\n")
    writeFile(dir / "package.json", """{"scripts": {"test": "vitest"}}""")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "base")
    git(dir, "checkout", "-q", "-b", "work")
    createDir(dir / "src")
    writeFile(dir / "src" / "a.ts", "")
    writeFile(dir / "package.json", """{"scripts": {"test": "true"}}""")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "work")
    check inspect(dir, "main", "main") == %*{
      "ci": "runs",
      "files": ["package.json", "src/a.ts"],
      "workflows": [
        {"file": ".github/workflows/docs.yaml", "applies": "skips"},
        {"file": ".github/workflows/test.yml", "applies": "runs"},
      ],
      "test_changes": ["package.json（scripts）"],
    }
