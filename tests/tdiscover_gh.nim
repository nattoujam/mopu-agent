import std/[json, options, os, sequtils, strutils, tempfiles, unittest]
import ../lib/discover

const Root = currentSourcePath().parentDir.parentDir

putEnv("PATH", Root / "tests" / "bin" & ":" & getEnv("PATH"))
putEnv("FIXTURES", Root / "tests" / "fixtures")

proc workspace(seenIds: seq[string] = @[], lastPoll = some("2026-09-06T00:00:00Z")): DiscoverConfig =
  let dir = createTempDir("discover-test-", "")
  result = DiscoverConfig(repo: "o/r", trigger: "/claude", labelQueued: "agent:queued", allowedActors: "nattoujam",
                          branchPrefix: "agent/issue-", commentMarker: "<!-- mopu-agent -->",
                          lastPollFile: dir / "last-poll", seenFile: dir / "seen-comments.txt")
  writeFile(result.seenFile, seenIds.mapIt(it & "\n").join)
  if lastPoll.isSome:
    writeFile(result.lastPollFile, lastPoll.get & "\n")

proc seenIds(cfg: DiscoverConfig): seq[string] =
  readFile(cfg.seenFile).splitLines.filterIt(it.len > 0)

proc taskFor(number: int): JsonNode =
  commentTasks(workspace()).filterIt(it["number"].getInt == number)[0]

proc ids(t: JsonNode): seq[string] =
  t["comments"].getElems.mapIt(it["id"].getStr)

suite "labeled":
  test "Issue 番号の昇順で、先行する open な sub-issue を deps に載せる":
    let got = labeledTasks(workspace()).mapIt((it["number"].getInt, it["deps"].getElems.mapIt(it.getInt)))
    check got == @[(11, newSeq[int]()), (12, newSeq[int]()), (13, @[12]), (30, newSeq[int]())]

  test "本文と作成者をそのまま載せる":
    check labeledTasks(workspace())[0] == %*{
      "kind": "issue", "number": 11, "title": "sub-issue 1 番目", "body": "本文11", "actor": "nattoujam", "deps": [],
    }

suite "comments":
  test "作業対象の Issue 番号順に返す":
    check commentTasks(workspace()).mapIt(it["number"].getInt) == @[3, 7, 42]

  test "同じ作業対象へのコメントは 1 タスクに畳む":
    check taskFor(42).ids == @["901", "505"]

  test "畳んだ中の順序は投稿時刻の昇順":
    check taskFor(42)["comments"].getElems.mapIt(it["reply_kind"].getStr) == @["review", "issue"]

  test "拾わないコメントを落とす（コードブロック内・第三者・自分の投稿・トリガーなし）":
    check commentTasks(workspace()).mapIt(it.ids).concat == @["507", "501", "901", "505"]

  test "PR へのコメントは作業対象を元 Issue に読み替え、返信先は PR のまま残す":
    let t = taskFor(42)
    check t["comments"].getElems.filterIt(it["id"].getStr == "505")[0] == %*{
      "id": "505",
      "actor": "nattoujam",
      "instruction": "/claude PR コメントからの指示\n続きの行",
      "reply_kind": "issue",
      "reply_number": 55,
      "url": "https://github.com/o/r/pull/55#c505",
    }
    check t["title"].getStr == "Issue 42 のタイトル"
    check t["body"].getStr == "Issue 42 の本文"
    check not t.hasKey("branch")

  test "Issue と作業先の PR のやり取りを、依頼できるユーザーの投稿に絞って古い順に載せる":
    check taskFor(42)["history"].getElems.mapIt((it["url"].getStr, it["by_agent"].getBool)) == @[
      ("https://github.com/o/r/issues/42#c601", false),
      ("https://github.com/o/r/pull/55#pullrequestreview-701", false),
      ("https://github.com/o/r/pull/55#c603", true),
    ]

  test "やり取りが無ければ history は空":
    check taskFor(3)["history"].len == 0

  test "エージェント以外の PR へのコメントは、その PR のブランチを作業先に載せる":
    check taskFor(7)["branch"].getStr == "feature/hand-made"

  test "PR レビューコメントは reply_kind が review になる":
    let c = taskFor(42)["comments"].getElems.filterIt(it["id"].getStr == "901")[0]
    check c["reply_kind"].getStr == "review"
    check c["reply_number"].getInt == 55

  test "元 Issue へのコメントは読み替えずそのまま使う":
    check taskFor(7)["comments"][0]["reply_number"].getInt == 7

  test "指示の末尾の空行を落とす":
    check taskFor(3)["comments"][0]["instruction"].getStr == "/claude 末尾に空行が続く指示"

  test "自分が投稿したコメントは seen に記録して二度と拾わない":
    let cfg = workspace()
    discard commentTasks(cfg)
    check seenIds(cfg) == @["504"]

  test "seen に記録済みのコメントは拾わない":
    check commentTasks(workspace(seenIds = @["501", "505", "507", "901"])).len == 0

suite "markSeen":
  test "記録する":
    let cfg = workspace()
    markSeen("1234", cfg)
    check seenIds(cfg) == @["1234"]

  test "--retry で再処理しても重複させない":
    let cfg = workspace(seenIds = @["1234"])
    markSeen("1234", cfg)
    check seenIds(cfg) == @["1234"]

  test "空の id は無視する":
    let cfg = workspace()
    markSeen("", cfg)
    check seenIds(cfg).len == 0

suite "initSeenBaseline":
  test "last-poll が無ければ現在時刻の Z 形式で作る（過去のコメントを一斉処理しない）":
    let cfg = workspace(lastPoll = none(string))
    initSeenBaseline(cfg)
    let written = readFile(cfg.lastPollFile).strip
    check written.len == 20 and written[10] == 'T' and written.endsWith("Z")

  test "last-poll があれば触らない":
    let cfg = workspace(lastPoll = some("2020-01-01T00:00:00Z"))
    initSeenBaseline(cfg)
    check readFile(cfg.lastPollFile).strip == "2020-01-01T00:00:00Z"
