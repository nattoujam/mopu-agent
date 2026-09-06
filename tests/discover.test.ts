import { deepStrictEqual, strictEqual } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  branchToIssueNumber,
  computeSince,
  extractInstruction,
  hasTrigger,
  isAllowedActor,
  issueNumberFromUrl,
  isTriggerLine,
  sortComments,
  stripCodeBlocks,
  subIssueDeps,
  utcStamp,
  type RawComment,
} from "../lib/discover.ts";

const T = "/claude";

describe("stripCodeBlocks", () => {
  it("フェンスの中身とフェンス行自体を落とす", () => {
    deepStrictEqual(stripCodeBlocks("a\n```\nb\n```\nc"), ["a", "c"]);
  });
  it("インデントされたフェンスも閉じる", () => {
    deepStrictEqual(stripCodeBlocks("a\n  ```sh\nb\n  ```\nc"), ["a", "c"]);
  });
  it("閉じ忘れたフェンス以降は全部落ちる", () => {
    deepStrictEqual(stripCodeBlocks("a\n```\nb\nc"), ["a"]);
  });
});

describe("isTriggerLine", () => {
  it("単独のトリガー", () => strictEqual(isTriggerLine("/claude", T), true));
  it("空白付きの指示", () => strictEqual(isTriggerLine("/claude 直して", T), true));
  it("タブ付きの指示", () => strictEqual(isTriggerLine("/claude\t直して", T), true));
  it("行頭のインデントは無視する", () => strictEqual(isTriggerLine("  /claude 直して", T), true));
  it("前方一致の別コマンドには反応しない", () =>
    strictEqual(isTriggerLine("/claudex 直して", T), false));
  it("行の途中にあるものには反応しない", () =>
    strictEqual(isTriggerLine("これは /claude の話", T), false));
  it("全角空白もインデントとして扱う（ロケールに依存させない）", () =>
    strictEqual(isTriggerLine("　/claude 直して", T), true));
});

describe("hasTrigger", () => {
  it("コードブロック内の例示には反応しない", () => {
    strictEqual(hasTrigger("説明\n```\n/claude やって\n```\n以上", T), false);
  });
  it("コードブロックの外にあれば拾う", () => {
    strictEqual(hasTrigger("```\n例\n```\n/claude やって", T), true);
  });
});

describe("extractInstruction", () => {
  it("トリガー行自身を含めて以降を返す", () => {
    strictEqual(extractInstruction("前置き\n/claude 直して\n詳細", T), "/claude 直して\n詳細");
  });
  it("トリガーが無ければ空", () => strictEqual(extractInstruction("ただの感想", T), ""));
  it("末尾の改行は落とす", () => {
    strictEqual(extractInstruction("/claude 直して\n\n", T), "/claude 直して");
  });
  it("トリガー以降のコードブロックも落ちる", () => {
    strictEqual(extractInstruction("/claude 直して\n```\nx\n```\n以上", T), "/claude 直して\n以上");
  });
});

describe("isAllowedActor", () => {
  it("空白区切りのいずれかに一致", () => strictEqual(isAllowedActor("bob", "alice bob"), true));
  it("部分一致では通さない", () => strictEqual(isAllowedActor("bo", "alice bob"), false));
  it("空文字は通さない", () => strictEqual(isAllowedActor("", "alice bob"), false));
});

describe("branchToIssueNumber", () => {
  const P = "agent/issue-";
  it("prefix と数値なら読み替える", () => strictEqual(branchToIssueNumber("agent/issue-42", P), 42));
  it("prefix が違えば null", () => strictEqual(branchToIssueNumber("feature/x", P), null));
  it("prefix の後が数値でなければ null", () =>
    strictEqual(branchToIssueNumber("agent/issue-bot-check", P), null));
  it("空文字は null", () => strictEqual(branchToIssueNumber("", P), null));
});

describe("issueNumberFromUrl", () => {
  it("issue URL", () =>
    strictEqual(issueNumberFromUrl("https://api.github.com/repos/o/r/issues/54"), 54));
  it("pull URL", () =>
    strictEqual(issueNumberFromUrl("https://api.github.com/repos/o/r/pulls/7"), 7));
  it("末尾が数値でなければ null", () => strictEqual(issueNumberFromUrl("https://x/y"), null));
});

describe("computeSince", () => {
  const now = new Date("2026-09-06T12:00:00Z");
  it("last-poll から 1 分さかのぼる", () => {
    strictEqual(computeSince("2026-09-06T11:30:00Z", now), "2026-09-06T11:29:00Z");
  });
  it("last-poll が無ければ 1 時間 1 分前", () => {
    strictEqual(computeSince(null, now), "2026-09-06T10:59:00Z");
  });
  it("壊れた last-poll はそのまま返す", () => {
    strictEqual(computeSince("not-a-date", now), "not-a-date");
  });
});

describe("sortComments", () => {
  const row = (n: number, at: string): RawComment => ({
    id: n,
    body: "",
    actor: "a",
    url: "",
    issue_url: `https://api.github.com/repos/o/r/issues/${n}`,
    created_at: at,
    reply_kind: "issue",
  });
  it("Issue 番号の昇順", () => {
    const got = sortComments([row(10, "z"), row(2, "z"), row(7, "z")]).map((r) => r.id);
    deepStrictEqual(got, [2, 7, 10]);
  });
  it("同じ Issue なら created_at の昇順", () => {
    const a = { ...row(3, "2026-01-02T00:00:00Z"), id: 200 };
    const b = { ...row(3, "2026-01-01T00:00:00Z"), id: 100 };
    deepStrictEqual(sortComments([a, b]).map((r) => r.id), [100, 200]);
  });
  it("番号は文字列ではなく数値で比べる", () => {
    const got = sortComments([row(9, "z"), row(10, "z")]).map((r) => r.id);
    deepStrictEqual(got, [9, 10]);
  });
});

describe("subIssueDeps", () => {
  const node = (number: number, siblings: { number: number; state: string }[]) => ({
    number,
    parent: { number: 1, subIssues: { nodes: siblings } },
  });
  it("番号が若く open な兄弟だけを返す", () => {
    deepStrictEqual(
      subIssueDeps(node(5, [
        { number: 3, state: "OPEN" },
        { number: 4, state: "CLOSED" },
        { number: 7, state: "OPEN" },
      ])),
      [3],
    );
  });
  it("親が無ければ空", () => deepStrictEqual(subIssueDeps({ number: 5 }), []));
  it("親はあるが兄弟が無ければ空", () =>
    deepStrictEqual(subIssueDeps({ number: 5, parent: { number: 1 } }), []));
});

describe("utcStamp", () => {
  it("ミリ秒を落とした Z 形式", () => {
    strictEqual(utcStamp(new Date("2026-09-06T12:34:56.789Z")), "2026-09-06T12:34:56Z");
  });
});
