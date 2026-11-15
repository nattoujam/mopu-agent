import std/[base64, json, os, strutils, tempfiles]
import history, paths, process

const
  MaxDiffChars = 60000
  MaxImagePairs = 4
  MaxImageBytes = 1500 * 1024
  Schema = """{"type":"object","properties":{"verdict":{"type":"string","enum":["approve","revise"]},"reasons":{"type":"array","items":{"type":"string"}}},"required":["verdict","reasons"],"additionalProperties":false}"""

proc failure(reason: string): JsonNode =
  %*{"verdict": "error", "reasons": [reason], "cost_usd": 0}

proc readJson(path: string): JsonNode =
  try: parseFile(path) except CatchableError: nil


proc material(wt, refName, logDir: string): string =
  var m = "## 依頼\n\n"
  let taskFile = logDir / "task.json"
  let task = if fileExists(taskFile) and getFileSize(taskFile) > 0: readJson(taskFile) else: nil
  if task != nil:
    let title = task{"title"}
    let body = task{"body"}
    m.add "### " & (if title == nil or title.kind == JNull: "" else: text(title)) & "\n\n" &
      (if body == nil or body.kind == JNull: "" else: text(body)) & "\n"
    let h = renderHistory(task)
    if h.len > 0:
      m.add "\n### その後のやり取り（古い順）\n\n" & h & "\n"
    let comments = task{"comments"}
    if comments != nil and comments.kind == JArray and comments.len > 0:
      m.add "\n### この作業で対応したコメント\n\n"
      for c in comments:
        m.add "- " & text(c{"instruction"}) & "\n"
  else:
    m.add "（依頼の控えが無い）\n"
  m.add "\n## 対象リポジトリの指示\n\n"
  let memory = logDir / "project-memory.md"
  m.add(if fileExists(memory) and getFileSize(memory) > 0: readFile(memory) else: "（無い）\n")
  m.add "\n## CI の結果\n\n"
  let gate = readJson(logDir / "verify.json")
  if gate == nil:
    m.add "不明\n\n## テストに関わる変更\n\n（不明）\n"
  else:
    let verdict = gate{"ci", "verdict"}
    let detail = gate{"ci", "detail"}
    m.add (if verdict == nil or verdict.kind == JNull: "不明" else: text(verdict)) & " " &
      (if detail == nil or detail.kind == JNull: "" else: text(detail)) & "\n"
    m.add "\n## テストに関わる変更\n\n"
    let tests = gate{"test_changes"}
    if tests == nil or tests.kind != JArray or tests.len == 0:
      m.add "（無い）\n"
    else:
      var lines: seq[string]
      for t in tests:
        lines.add "- " & text(t)
      m.add lines.join("\n") & "\n"
  m.add "\n## diff（" & refName & " からの変更）\n\n```diff\n"
  let diff = gitRun(wt, "diff", "--merge-base", refName, "HEAD", "--", ".", ":(exclude)*.png").output
  m.add diff[0 ..< min(diff.len, MaxDiffChars)]
  m.add "\n```\n"
  m

proc imageContent(wt, refName: string): seq[JsonNode] =
  var pairs = 0
  for png in gitRun(wt, "diff", "--name-only", "--merge-base", refName, "HEAD", "--", "*.png").output.splitLines:
    if png.len == 0:
      continue
    if pairs >= MaxImagePairs:
      break
    let after = gitRun(wt, "show", "HEAD:" & png)
    if after.exitCode != 0:
      continue
    let before = gitRun(wt, "show", refName & ":" & png)
    let beforeData = if before.exitCode == 0: before.output else: ""
    if after.output.len > MaxImageBytes or beforeData.len > MaxImageBytes:
      continue
    result.add %*{"type": "text", "text": "### 画像 " & png & "：変更前（無ければ新規）、変更後の順"}
    if beforeData.len > 0:
      result.add %*{"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                 "data": base64.encode(beforeData)}}
    result.add %*{"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                               "data": base64.encode(after.output)}}
    inc pairs

# 変更を書いたエージェントとは会話を共有しない別の claude -p に変更を確かめさせる。
# diff や依頼の本文はエージェントや第三者が書いたものなので、critic にはツールを渡さず、設定は応答の言語だけを渡す。
# hook と同じく sandbox の外で動くため、ツールが残っていると乗っ取られたときにホストで実行される
proc runCritic*(taskDir, baseBranch, logDir: string): JsonNode =
  let wt = taskDir / repoSubdir
  let refName = "origin/" & baseBranch
  let claude = getEnv("CLAUDE_BIN", "claude")
  let model = getEnv("CRITIC_MODEL", "sonnet")
  let limit = getEnv("CRITIC_TIMEOUT", "420")
  let work = createTempDir("mopu-critic-", "")
  defer: removeDir(work)

  var content = @[%*{"type": "text", "text": material(wt, refName, logDir)}]
  content.add imageContent(wt, refName)
  writeFile(work / "input.jsonl", $(%*{"type": "user", "message": {"role": "user", "content": content}}) & "\n")
  createDir(work / "cwd")
  let language = (let s = readJson(agentSettingsFile); if s == nil: newJNull() else: s{"language"})
  let rc = run(@[
    "timeout", limit, claude, "-p",
    "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    "--append-system-prompt", readFile(promptsDir / "critic.md").strip(leading = false, chars = {'\n'}),
    "--json-schema", Schema, "--model", model, "--tools", "",
    "--settings", $(%*{"language": language}),
    "--setting-sources", "", "--strict-mcp-config", "--mcp-config", """{"mcpServers":{}}""",
    "--permission-mode", "dontAsk"],
    SpawnOptions(stdinPath: work / "input.jsonl", stdout: Output(path: work / "out.jsonl"),
                 stderr: Output(path: "/dev/null"), cwd: work / "cwd"))
  if rc == 124:
    return failure("critic が " & limit & " 秒で終わらなかった")
  var res: JsonNode = nil
  for line in readFile(work / "out.jsonl").splitLines:
    let ev = (try: parseJson(line) except CatchableError: nil)
    if ev != nil and ev.kind == JObject and ev{"type"}.getStr == "result":
      res = ev
  if res == nil:
    return failure("critic の結果を読めなかった (exit=" & $rc & ")")
  let output = res{"structured_output"}
  let verdict = if output != nil and output.kind == JObject: output{"verdict"} else: nil
  let reasons = if output != nil and output.kind == JObject: output{"reasons"} else: nil
  let cost = res{"total_cost_usd"}
  %*{
    "verdict": if verdict == nil or verdict.kind == JNull: %"error" else: verdict,
    "reasons": if reasons == nil or reasons.kind == JNull: %["critic の出力を読めなかった"] else: reasons,
    "cost_usd": if cost == nil or cost.kind == JNull: %0 else: cost,
  }

proc criticMain*(): int =
  let taskDir = getEnv("MOPU_TASK_DIR")
  let baseBranch = getEnv("MOPU_BASE_BRANCH")
  let logDir = getEnv("MOPU_LOG_DIR")
  if taskDir.len == 0 or baseBranch.len == 0 or logDir.len == 0:
    stderr.writeLine "MOPU_TASK_DIR・MOPU_BASE_BRANCH・MOPU_LOG_DIR が要ります"
    return 1
  stdout.writeLine $runCritic(taskDir, baseBranch, logDir)
  0
