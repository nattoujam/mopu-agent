// poll.sh から呼ばれるのと同じ形（環境変数 + サブコマンド + stdout）で lib/discover.ts を
// 動かし、tests/bin/gh のスタブが返す tests/fixtures を検出結果まで通して確かめる
import { deepStrictEqual, strictEqual } from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { CommentTask, Task } from "../lib/discover.ts";

const ROOT = join(import.meta.dirname, "..");
const ENTRY = join(ROOT, "lib", "discover.ts");

type Env = { seenIds?: string[]; lastPoll?: string | null };

function workspace({ seenIds = [], lastPoll = "2026-09-06T00:00:00Z" }: Env = {}) {
  const dir = mkdtempSync(join(tmpdir(), "discover-test-"));
  const seenFile = join(dir, "seen-comments.txt");
  writeFileSync(seenFile, seenIds.map((id) => `${id}\n`).join(""));
  if (lastPoll !== null) writeFileSync(join(dir, "last-poll"), `${lastPoll}\n`);
  return { dir, seenFile };
}

function run(sub: string, args: string[], ws: { dir: string; seenFile: string }): string {
  return execFileSync("node", [ENTRY, sub, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${join(ROOT, "tests", "bin")}:${process.env["PATH"] ?? ""}`,
      FIXTURES: join(ROOT, "tests", "fixtures"),
      REPO: "o/r",
      TRIGGER_COMMAND: "/claude",
      LABEL_QUEUED: "agent:queued",
      ALLOWED_ACTORS: "nattoujam",
      BRANCH_PREFIX: "agent/issue-",
      COMMENT_MARKER: "<!-- mopu-agent -->",
      STATE_DIR: ws.dir,
      SEEN_FILE: ws.seenFile,
    },
  });
}

function tasks(sub: string, ws: { dir: string; seenFile: string }): Task[] {
  return run(sub, [], ws).split("\n").filter(Boolean).map((l) => JSON.parse(l) as Task);
}

function seenIds(ws: { seenFile: string }): string[] {
  return readFileSync(ws.seenFile, "utf8").split("\n").filter(Boolean);
}

describe("labeled", () => {
  it("Issue 番号の昇順で、先行する open な sub-issue を deps に載せる", () => {
    // fixture の並びは 30, 12, 13, 11。#11 は CLOSED なので #12 の deps には入らない
    deepStrictEqual(
      tasks("labeled", workspace()).map((t) => [t.number, (t as { deps: number[] }).deps]),
      [[11, []], [12, []], [13, [12]], [30, []]],
    );
  });

  it("本文と作成者をそのまま載せる", () => {
    const first = tasks("labeled", workspace())[0];
    deepStrictEqual(first, {
      kind: "issue",
      number: 11,
      title: "sub-issue 1 番目",
      body: "本文11",
      actor: "nattoujam",
      deps: [],
    });
  });
});

describe("comments", () => {
  const idsOf = (t: Task): string[] =>
    t.kind === "comment" ? t.comments.map((c) => c.id) : [];
  const commentTasks = (ws: { dir: string; seenFile: string }): CommentTask[] =>
    tasks("comments", ws).filter((t): t is CommentTask => t.kind === "comment");

  it("作業対象の Issue 番号順に返す", () => {
    deepStrictEqual(commentTasks(workspace()).map((t) => t.number), [3, 7, 42]);
  });

  it("同じ作業対象へのコメントは 1 タスクに畳む", () => {
    // fixture の 505 は PR 55 の会話、901 は PR 55 のレビュー。どちらも元 Issue は 42
    const t = commentTasks(workspace()).find((x) => x.number === 42);
    deepStrictEqual(idsOf(t as Task), ["901", "505"]);
  });

  it("畳んだ中の順序は投稿時刻の昇順", () => {
    const t = commentTasks(workspace()).find((x) => x.number === 42) as CommentTask;
    // 901 が 00:30、505 が 05:00
    deepStrictEqual(t.comments.map((c) => c.reply_kind), ["review", "issue"]);
  });

  it("拾わないコメントを落とす（コードブロック内・第三者・自分の投稿・トリガーなし）", () => {
    // fixture の 502=コードブロック内, 503=第三者, 504=marker 付き, 506=トリガーなし
    deepStrictEqual(
      commentTasks(workspace()).flatMap(idsOf),
      ["507", "501", "901", "505"],
    );
  });

  it("PR へのコメントは作業対象を元 Issue に読み替え、返信先は PR のまま残す", () => {
    const t = commentTasks(workspace()).find((x) => x.number === 42) as CommentTask;
    const c = t.comments.find((x) => x.id === "505");
    deepStrictEqual(c, {
      id: "505",
      actor: "nattoujam",
      instruction: "/claude PR コメントからの指示\n続きの行",
      reply_kind: "issue",
      reply_number: 55,
      url: "https://github.com/o/r/pull/55#c505",
    });
    strictEqual(t.title, "Issue 42 のタイトル");
    strictEqual(t.body, "Issue 42 の本文");
  });

  it("PR レビューコメントは reply_kind が review になる", () => {
    const t = commentTasks(workspace()).find((x) => x.number === 42) as CommentTask;
    const c = t.comments.find((x) => x.id === "901") as { reply_kind: string; reply_number: number };
    strictEqual(c.reply_kind, "review");
    strictEqual(c.reply_number, 55);
  });

  it("元 Issue へのコメントは読み替えずそのまま使う", () => {
    const t = commentTasks(workspace()).find((x) => x.number === 7) as CommentTask;
    strictEqual(t.comments[0]?.reply_number, 7);
  });

  it("指示の末尾の空行を落とす", () => {
    const t = commentTasks(workspace()).find((x) => x.number === 3) as CommentTask;
    strictEqual(t.comments[0]?.instruction, "/claude 末尾に空行が続く指示");
  });

  it("自分が投稿したコメントは seen に記録して二度と拾わない", () => {
    const ws = workspace();
    tasks("comments", ws);
    deepStrictEqual(seenIds(ws), ["504"]);
  });

  it("seen に記録済みのコメントは拾わない", () => {
    const ws = workspace({ seenIds: ["501", "505", "507", "901"] });
    deepStrictEqual(tasks("comments", ws), []);
  });
});

describe("mark-seen", () => {
  it("記録する", () => {
    const ws = workspace();
    run("mark-seen", ["1234"], ws);
    deepStrictEqual(seenIds(ws), ["1234"]);
  });

  it("--retry で再処理しても重複させない", () => {
    const ws = workspace({ seenIds: ["1234"] });
    run("mark-seen", ["1234"], ws);
    deepStrictEqual(seenIds(ws), ["1234"]);
  });

  it("空の id は無視する", () => {
    const ws = workspace();
    run("mark-seen", [""], ws);
    deepStrictEqual(seenIds(ws), []);
  });
});

describe("init-baseline", () => {
  it("last-poll が無ければ現在時刻で作る（過去のコメントを一斉処理しない）", () => {
    const ws = workspace({ lastPoll: null });
    run("init-baseline", [], ws);
    const written = readFileSync(join(ws.dir, "last-poll"), "utf8").trim();
    strictEqual(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(written), true);
  });

  it("last-poll があれば触らない", () => {
    const ws = workspace({ lastPoll: "2020-01-01T00:00:00Z" });
    run("init-baseline", [], ws);
    strictEqual(readFileSync(join(ws.dir, "last-poll"), "utf8").trim(), "2020-01-01T00:00:00Z");
  });

  it("last-poll を作った理由をログに残す", () => {
    const ws = workspace({ lastPoll: null });
    strictEqual(existsSync(join(ws.dir, "last-poll")), false);
    run("init-baseline", [], ws);
    strictEqual(existsSync(join(ws.dir, "last-poll")), true);
  });
});
