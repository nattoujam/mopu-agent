import std/[algorithm, options, sequtils, sets, strutils, times, unittest]
import ../lib/discover

const T = "/claude"

suite "selectHistory":
  proc row(id, at, body: string, actor = "nattoujam"): HistoryRow =
    HistoryRow(id: id, actor: actor, by_agent: false, body: body,
               url: "https://github.com/o/r/issues/1#c" & id, created_at: at)

  test "上限を超える分は古い側から落とす":
    let rows = @[
      row("3", "2026-09-03T00:00:00Z", "c".repeat(30)),
      row("1", "2026-09-01T00:00:00Z", "a".repeat(10)),
      row("2", "2026-09-02T00:00:00Z", "b".repeat(25)),
    ]
    check selectHistory(rows, initHashSet[string](), "nattoujam", 60).mapIt(it.body.len) == @[25, 30]

  test "上限ちょうどまでは残す":
    let rows = @[row("1", "2026-09-01T00:00:00Z", "a".repeat(10)), row("2", "2026-09-02T00:00:00Z", "b".repeat(20))]
    check selectHistory(rows, initHashSet[string](), "nattoujam", 30).len == 2

  test "除外する ID・空の本文・依頼できないユーザーの投稿を落とす":
    let rows = @[
      row("1", "2026-09-01T00:00:00Z", "残る"),
      row("2", "2026-09-02T00:00:00Z", "今回の指示"),
      row("3", "2026-09-03T00:00:00Z", "  \n"),
      row("4", "2026-09-04T00:00:00Z", "第三者", "stranger"),
    ]
    check selectHistory(rows, ["2"].toHashSet, "nattoujam", 1000).mapIt(it.body) == @["残る"]

suite "stripCodeBlocks":
  test "フェンスの中身とフェンス行自体を落とす":
    check stripCodeBlocks("a\n```\nb\n```\nc") == @["a", "c"]
  test "インデントされたフェンスも閉じる":
    check stripCodeBlocks("a\n  ```sh\nb\n  ```\nc") == @["a", "c"]
  test "閉じ忘れたフェンス以降は全部落ちる":
    check stripCodeBlocks("a\n```\nb\nc") == @["a"]

suite "isTriggerLine":
  test "単独のトリガー": check isTriggerLine("/claude", T)
  test "空白付きの指示": check isTriggerLine("/claude 直して", T)
  test "タブ付きの指示": check isTriggerLine("/claude\t直して", T)
  test "行頭のインデントは無視する": check isTriggerLine("  /claude 直して", T)
  test "前方一致の別コマンドには反応しない": check not isTriggerLine("/claudex 直して", T)
  test "行の途中にあるものには反応しない": check not isTriggerLine("これは /claude の話", T)
  test "全角空白もインデントとして扱う（ロケールに依存させない）": check isTriggerLine("　/claude 直して", T)

suite "hasTrigger":
  test "コードブロック内の例示には反応しない":
    check not hasTrigger("説明\n```\n/claude やって\n```\n以上", T)
  test "コードブロックの外にあれば拾う":
    check hasTrigger("```\n例\n```\n/claude やって", T)

suite "extractInstruction":
  test "トリガー行自身を含めて以降を返す":
    check extractInstruction("前置き\n/claude 直して\n詳細", T) == "/claude 直して\n詳細"
  test "トリガーが無ければ空": check extractInstruction("ただの感想", T) == ""
  test "末尾の改行は落とす":
    check extractInstruction("/claude 直して\n\n", T) == "/claude 直して"
  test "トリガー以降のコードブロックも落ちる":
    check extractInstruction("/claude 直して\n```\nx\n```\n以上", T) == "/claude 直して\n以上"

suite "isAllowedActor":
  test "空白区切りのいずれかに一致": check isAllowedActor("bob", "alice bob")
  test "部分一致では通さない": check not isAllowedActor("bo", "alice bob")
  test "空文字は通さない": check not isAllowedActor("", "alice bob")

suite "branchToIssueNumber":
  const P = "agent/issue-"
  test "prefix と数値なら読み替える": check branchToIssueNumber("agent/issue-42", P) == some(42)
  test "prefix が違えば null": check branchToIssueNumber("feature/x", P).isNone
  test "prefix の後が数値でなければ null": check branchToIssueNumber("agent/issue-bot-check", P).isNone
  test "空文字は null": check branchToIssueNumber("", P).isNone

suite "commentTarget":
  const P = "agent/issue-"
  proc open(head: string, state = "OPEN", cross = false): Option[PrHead] =
    some(PrHead(headRefName: head, state: state, isCrossRepository: cross))
  test "エージェントの PR は元 Issue に読み替え、ブランチは載せない":
    check commentTarget(55, open("agent/issue-42"), P) == CommentTarget(number: 42)
  test "それ以外の open な PR は、PR 番号のままその PR のブランチを載せる":
    check commentTarget(65, open("deps/bump-group-a1b2"), P) ==
      CommentTarget(number: 65, branch: "deps/bump-group-a1b2")
  test "フォークからの PR はブランチを載せない":
    check commentTarget(8, open("feature/x", cross = true), P) == CommentTarget(number: 8)
  test "閉じた PR はブランチを載せない":
    check commentTarget(9, open("feature/x", state = "MERGED"), P) == CommentTarget(number: 9)
  test "PR でなければ番号をそのまま使う":
    check commentTarget(7, none(PrHead), P) == CommentTarget(number: 7)

suite "issueNumberFromUrl":
  test "issue URL": check issueNumberFromUrl("https://api.github.com/repos/o/r/issues/54") == some(54)
  test "pull URL": check issueNumberFromUrl("https://api.github.com/repos/o/r/pulls/7") == some(7)
  test "末尾が数値でなければ null": check issueNumberFromUrl("https://x/y").isNone

suite "computeSince":
  let now = parseIso("2026-09-06T12:00:00Z")
  test "last-poll から 1 分さかのぼる":
    check computeSince(some("2026-09-06T11:30:00Z"), now) == "2026-09-06T11:29:00Z"
  test "last-poll が無ければ 1 時間 1 分前":
    check computeSince(none(string), now) == "2026-09-06T10:59:00Z"
  test "壊れた last-poll はそのまま返す":
    check computeSince(some("not-a-date"), now) == "not-a-date"

suite "sortComments":
  proc row(n: int, at: string, id = n): RawComment =
    RawComment(id: id, issue_url: "https://api.github.com/repos/o/r/issues/" & $n, actor: "a",
               created_at: at, reply_kind: rkIssue)
  test "Issue 番号の昇順":
    check sortComments(@[row(10, "z"), row(2, "z"), row(7, "z")]).mapIt(it.id) == @[2, 7, 10]
  test "同じ Issue なら created_at の昇順":
    let a = row(3, "2026-01-02T00:00:00Z", id = 200)
    let b = row(3, "2026-01-01T00:00:00Z", id = 100)
    check sortComments(@[a, b]).mapIt(it.id) == @[100, 200]
  test "番号は文字列ではなく数値で比べる":
    check sortComments(@[row(9, "z"), row(10, "z")]).mapIt(it.id) == @[9, 10]

suite "subIssueDeps":
  proc parent(siblings: seq[SubIssue]): Option[Parent] =
    some(Parent(number: 1, subIssues: some(SubIssueConn(nodes: some(siblings)))))
  test "番号が若く open な兄弟だけを返す":
    check subIssueDeps(5, parent(@[
      SubIssue(number: 3, state: "OPEN"),
      SubIssue(number: 4, state: "CLOSED"),
      SubIssue(number: 7, state: "OPEN"),
    ])) == @[3]
  test "親が無ければ空": check subIssueDeps(5, none(Parent)).len == 0
  test "親はあるが兄弟が無ければ空": check subIssueDeps(5, some(Parent(number: 1))).len == 0

suite "utcStamp":
  test "秒未満を落とした Z 形式":
    check utcStamp(parseIso("2026-09-06T12:34:56Z") + initDuration(milliseconds = 789)) == "2026-09-06T12:34:56Z"

const
  Repo = "example/app"
  P = "agent/issue-"

proc pr(number, issue: int, createdAt, mergedAt: string): MergedPr =
  MergedPr(number: number, title: "PR " & $number, url: "https://github.com/" & Repo & "/pull/" & $number,
           headRefName: P & $issue, createdAt: createdAt, mergedAt: mergedAt,
           mergeCommit: some(MergeCommit(oid: "0".repeat(40))))

proc run(task: string, time = "2026-09-01T23:59:00+09:00", repo = Repo, kind = none(string),
         issue = none(int)): SpendRun =
  SpendRun(task: task, time: time, repo: some(repo), kind: kind, issue: issue)

suite "parseRun":
  test "タスク ID のローカル時刻を time のオフセットで UTC に直す":
    check parseRun(run("comment-12-20260901-120000")) ==
      some(ParsedRun(kind: "comment", issue: 12, started: parseIso("2026-09-01T03:00:00Z")))
  test "負のオフセット":
    check parseRun(run("issue-3-20260901-120000", time = "2026-09-01T13:00:00-04:30")).get.started ==
      parseIso("2026-09-01T16:30:00Z")
  test "記録にある kind と issue を優先する":
    check parseRun(run("comment-12-20260901-120000", kind = some("issue"), issue = some(7))).get.issue == 7
  test "学習のタスクは対象外": check parseRun(run("learn-40-20260901-120000")).isNone

suite "hasFollowups":
  let p = pr(40, 12, "2026-09-01T02:00:00Z", "2026-09-02T00:00:00Z")
  test "PR ができた後のコメント由来の実行があれば差し戻しあり":
    check hasFollowups(p, @[run("comment-12-20260901-120000")], Repo, P)
  test "PR ができる前のコメント（実装の依頼や分解の承認）は数えない":
    check not hasFollowups(p, @[run("comment-12-20260901-100000")], Repo, P)
  test "マージ後のコメントは数えない":
    check not hasFollowups(p, @[run("comment-12-20260903-120000")], Repo, P)
  test "Issue 由来の実行は数えない":
    check not hasFollowups(p, @[run("issue-12-20260901-120000")], Repo, P)
  test "別の Issue の実行は数えない":
    check not hasFollowups(p, @[run("comment-13-20260901-120000")], Repo, P)
  test "別のリポジトリの実行は数えない":
    check not hasFollowups(p, @[run("comment-12-20260901-120000", repo = "example/other")], Repo, P)
  test "エージェントのブランチでない PR は対象外":
    var q = p
    q.headRefName = "feature/x"
    check not hasFollowups(q, @[run("comment-12-20260901-120000")], Repo, P)

suite "handledPrs":
  test "結果が出たものと、失敗が上限に達したものを済みにする":
    check toSeq(handledPrs("40\tpr\n41\tno-change\n42\tfailed\n43\tfailed\n43\tfailed\n\n")).sorted ==
      @[40, 41, 43]

suite "nextLearnBatch":
  let runs = @[
    run("comment-12-20260901-120000"),
    run("comment-14-20260905-120000"),
    run("comment-16-20260907-120000"),
    run("comment-17-20260908-120000"),
  ]
  let a = pr(40, 12, "2026-09-01T02:00:00Z", "2026-09-06T00:00:00Z")
  let b = pr(41, 14, "2026-09-05T02:00:00Z", "2026-09-05T12:00:00Z")
  let noFollowup = pr(42, 15, "2026-09-05T02:00:00Z", "2026-09-05T06:00:00Z")
  let c = pr(43, 16, "2026-09-07T02:00:00Z", "2026-09-07T18:00:00Z")
  let d = pr(44, 17, "2026-09-08T02:00:00Z", "2026-09-08T18:00:00Z")
  test "差し戻しのあった PR を、マージが古いものから決まった件数だけ返す":
    check nextLearnBatch(@[d, c, noFollowup, b, a], runs, "", Repo, P).mapIt(it.number) == @[41, 40, 43]
  test "済みの PR は飛ばす":
    check nextLearnBatch(@[a, b, c, d], runs, "41\tissue\n", Repo, P).mapIt(it.number) == @[40, 43, 44]
  test "件数に満たなければ空":
    check nextLearnBatch(@[a, b, c, d], runs, "40\tissue\n41\tissue\n", Repo, P).len == 0
