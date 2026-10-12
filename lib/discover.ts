#!/usr/bin/env node
// タスク検出。poll.sh からサブコマンドで呼ばれ、JSON Lines を stdout に返す。
// 設定は load_config が export した環境変数から受け取る（解釈を二重に持たない）。
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

export type ReplyKind = "issue" | "review";

export type LabeledTask = {
  kind: "issue";
  number: number;
  title: string;
  body: string;
  actor: string;
  deps: number[];
};

export type CommentRef = {
  id: string;
  actor: string;
  instruction: string;
  reply_kind: ReplyKind;
  reply_number: number;
  url: string;
};

export type CommentTask = {
  kind: "comment";
  number: number;
  title: string;
  body: string;
  actor: string;
  comments: CommentRef[];
};

export type LearnComment = {
  id: string;
  actor: string;
  instruction: string;
  url: string;
  created_at: string;
  path?: string;
};

export type LearnTask = {
  kind: "learn";
  number: number;
  title: string;
  body: string;
  actor: string;
  url: string;
  issue: number;
  issue_title: string;
  issue_body: string;
  merge_commit: string;
  comments: LearnComment[];
};

export type Task = LabeledTask | CommentTask | LearnTask;

export type SpendRun = {
  task: string;
  time: string;
  repo?: string;
  kind?: string | null;
  issue?: number | null;
};

export type MergedPr = {
  number: number;
  title: string;
  body: string;
  url: string;
  headRefName: string;
  createdAt: string;
  mergedAt: string;
  mergeCommit: { oid: string } | null;
};

export type RawComment = {
  id: number;
  body: string;
  actor: string;
  url: string;
  issue_url: string;
  created_at: string;
  reply_kind: ReplyKind;
};

export type Config = {
  repo: string;
  trigger: string;
  labelQueued: string;
  allowedActors: string;
  branchPrefix: string;
  commentMarker: string;
  lastPollFile: string;
  seenFile: string;
};

export type SubIssue = { number: number; state: string };

type LabeledNode = {
  number: number;
  title: string;
  body: string;
  author: { login: string } | null;
  parent?: { number: number; subIssues?: { nodes?: SubIssue[] } } | null;
};

type RestComment = {
  id: number;
  body: string;
  user: { login: string };
  html_url: string;
  created_at: string;
  issue_url?: string;
  pull_request_url?: string;
};


export const utcStamp = (d: Date): string => d.toISOString().replace(/\.\d{3}Z$/, "Z");

const chomp = (s: string): string => s.replace(/\n+$/, "");

// コードブロック内の例示をトリガーとして拾わないため
export const stripCodeBlocks = (body: string): string[] => {
  let inFence = false;
  return body.split("\n").filter((line) => {
    if (/^[ \t]*```/.test(line)) {
      inFence = !inFence;
      return false;
    }
    return !inFence;
  });
};

// 正規表現に埋め込むとトリガー文字列のエスケープ漏れが起きるため前方一致で判定する。
// \s は全角空白も剥がす。日本語の本文では行頭に混ざりうる
export const isTriggerLine = (line: string, trigger: string): boolean => {
  const s = line.replace(/^\s+/, "");
  return s === trigger || s.startsWith(`${trigger} `) || s.startsWith(`${trigger}\t`);
};

export const hasTrigger = (body: string, trigger: string): boolean =>
  stripCodeBlocks(body).some((l) => isTriggerLine(l, trigger));

export const extractInstruction = (body: string, trigger: string): string => {
  const lines = stripCodeBlocks(body);
  const i = lines.findIndex((l) => isTriggerLine(l, trigger));
  return i < 0 ? "" : chomp(lines.slice(i).join("\n"));
};

export const isAllowedActor = (actor: string, allowed: string): boolean =>
  allowed.split(/\s+/).filter(Boolean).includes(actor);

// エージェントが作った PR はブランチ名に元 Issue 番号を持つ
export const branchToIssueNumber = (head: string, prefix: string): number | null => {
  if (!head || !head.startsWith(prefix)) return null;
  const suffix = head.slice(prefix.length);
  return /^[0-9]+$/.test(suffix) ? Number(suffix) : null;
};

export const issueNumberFromUrl = (url: string): number | null => {
  const m = url.match(/([0-9]+)$/);
  return m ? Number(m[1]) : null;
};

// 取りこぼしを避けて 1 分さかのぼる（重複は seen-comments.txt で弾かれる）。
// URL クエリでは "+09:00" の + が空白として解釈されるため UTC の Z 形式で返す
export const computeSince = (lastPoll: string | null, now: Date): string => {
  const base = lastPoll ? new Date(lastPoll) : new Date(now.getTime() - 3600_000);
  if (Number.isNaN(base.getTime())) return lastPoll as string;
  return utcStamp(new Date(base.getTime() - 60_000));
};

// 分解されたタスクは先に作られた Issue が後続の前提になるため番号の昇順
export const sortComments = (rows: RawComment[]): RawComment[] =>
  [...rows].sort((a, b) => {
    const na = issueNumberFromUrl(a.issue_url) ?? 0;
    const nb = issueNumberFromUrl(b.issue_url) ?? 0;
    if (na !== nb) return na - nb;
    return a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : 0;
  });

// open で番号が若い兄弟は、PR がまだベースに入っていない前提タスク。
// poll.sh はこれが残るうちは着手を見送る
export const subIssueDeps = (
  node: { number: number; parent?: { number: number; subIssues?: { nodes?: SubIssue[] } } | null },
): number[] => {
  const siblings = node.parent?.subIssues?.nodes ?? [];
  return siblings.filter((s) => s.state === "OPEN" && s.number < node.number).map((s) => s.number);
};

const TASK_ID_RE = /^(issue|comment)-([0-9]+)-([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})/;

// 開始時刻はタスク ID にしか無い。タスク ID は記録の time と同じローカル時刻で書かれているため、
// time のオフセットで UTC に直す。kind と issue を持たない古い記録も、タスク ID から補う
export const parseRun = (r: SpendRun): { kind: string; issue: number; started: number } | null => {
  const m = r.task.match(TASK_ID_RE);
  if (!m) return null;
  const [, kind = "", n, y, mo, d, h, mi, s] = m.map((v) => v ?? "");
  const off = r.time.match(/([+-])([0-9]{2}):([0-9]{2})$/);
  const offMin = off ? (off[1] === "-" ? -1 : 1) * (Number(off[2]) * 60 + Number(off[3])) : 0;
  const local = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s));
  return { kind: r.kind ?? kind, issue: r.issue ?? Number(n), started: local - offMin * 60_000 };
};

// PR ができてからマージされるまでに始まったコメント由来の実行を差し戻しとする。
// tools/loop-metrics の差し戻しと同じ定義
export const hasFollowups = (pr: MergedPr, runs: SpendRun[], repo: string, prefix: string): boolean => {
  const issue = branchToIssueNumber(pr.headRefName, prefix);
  if (issue === null) return false;
  const from = Date.parse(pr.createdAt);
  const to = Date.parse(pr.mergedAt);
  return runs.some((r) => {
    if ((r.repo ?? repo) !== repo) return false;
    const p = parseRun(r);
    return p !== null && p.kind === "comment" && p.issue === issue && p.started >= from && p.started <= to;
  });
};

export const LEARN_MAX_FAILURES = 2;

// learned-prs.txt は「PR 番号<TAB>結果」の行。失敗は数えて、上限までやり直す
export const handledPrs = (learned: string): Set<number> => {
  const failures = new Map<number, number>();
  const done = new Set<number>();
  for (const line of learned.split("\n")) {
    const [n, status] = line.split("\t");
    const number = Number(n);
    if (!n || !Number.isInteger(number)) continue;
    if (status === "failed") {
      failures.set(number, (failures.get(number) ?? 0) + 1);
      if ((failures.get(number) ?? 0) >= LEARN_MAX_FAILURES) done.add(number);
    } else {
      done.add(number);
    }
  }
  return done;
};

// 古い順に学ぶ。後の PR の差し戻しは、前の PR で学んだ基準を踏まえて読むほうが重複を避けやすい
export const nextLearnSource = (
  prs: MergedPr[],
  runs: SpendRun[],
  learned: string,
  repo: string,
  prefix: string,
): MergedPr | null => {
  const handled = handledPrs(learned);
  const pending = prs
    .filter((pr) => pr.mergedAt && !handled.has(pr.number) && hasFollowups(pr, runs, repo, prefix))
    .sort((a, b) => Date.parse(a.mergedAt) - Date.parse(b.mergedAt));
  return pending[0] ?? null;
};


const loadConfig = (): Config => {
  const need = (name: string): string => {
    const v = process.env[name];
    if (!v) {
      process.stderr.write(`${name} が渡されていません（load_config で export してください）\n`);
      process.exit(1);
    }
    return v;
  };
  return {
    repo: need("REPO"),
    trigger: need("TRIGGER_COMMAND"),
    labelQueued: need("LABEL_QUEUED"),
    allowedActors: need("ALLOWED_ACTORS"),
    branchPrefix: need("BRANCH_PREFIX"),
    commentMarker: need("COMMENT_MARKER"),
    lastPollFile: need("LAST_POLL_FILE"),
    seenFile: need("SEEN_FILE"),
  };
};

// 失敗は空文字にする。呼び出し側は「該当なし」と同じ扱いで進む
const gh = (args: string[]): string => {
  try {
    return execFileSync("gh", args, {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return "";
  }
};

const ghJson = <T>(args: string[]): T | null => {
  const out = gh(args);
  if (!out.trim()) return null;
  try {
    return JSON.parse(out) as T;
  } catch {
    return null;
  }
};

const log = (msg: string): void => {
  const t = new Date().toTimeString().slice(0, 8);
  process.stderr.write(`${t} ${msg}\n`);
};

const emit = (task: Task): void => {
  process.stdout.write(`${JSON.stringify(task)}\n`);
};

// 子から親を辿れるのは GraphQL だけ（REST の issue.parent は null を返す）。
// IssueOrderField に NUMBER がないため、並べ替えはこちら側で行う
const LABELED_QUERY = `
    query($owner:String!, $name:String!, $label:String!) {
      repository(owner:$owner, name:$name) {
        issues(first:50, states:OPEN, labels:[$label], orderBy:{field:CREATED_AT, direction:ASC}) {
          nodes {
            number title body author { login }
            parent { number subIssues(first:100) { nodes { number state } } }
          }
        }
      }
    }`;

const discoverLabeled = (cfg: Config): void => {
  const [owner, name] = cfg.repo.split("/");
  const res = ghJson<{ data?: { repository?: { issues?: { nodes?: LabeledNode[] } } } }>([
    "api",
    "graphql",
    "-f",
    `owner=${owner}`,
    "-f",
    `name=${name}`,
    "-f",
    `label=${cfg.labelQueued}`,
    "-f",
    `query=${LABELED_QUERY}`,
  ]);
  const nodes = res?.data?.repository?.issues?.nodes ?? [];
  for (const n of [...nodes].sort((a, b) => a.number - b.number)) {
    emit({
      kind: "issue",
      number: n.number,
      title: n.title,
      body: n.body,
      actor: n.author?.login ?? "",
      deps: subIssueDeps(n),
    });
  }
};

// PR へのコメントは PR 番号で届く。タスクの番号は元 Issue のものでなければならない
const resolveIssueNumber = (number: number, cfg: Config): number => {
  const res = ghJson<{ headRefName?: string }>([
    "pr",
    "view",
    String(number),
    "-R",
    cfg.repo,
    "--json",
    "headRefName",
  ]);
  return branchToIssueNumber(res?.headRefName ?? "", cfg.branchPrefix) ?? number;
};

const fetchComments = (cfg: Config, since: string): RawComment[] => {
  // since は updated_at 基準。per_page で溢れるときに窓の新しい側を落とさないよう降順で取る
  const q = `sort=updated&direction=desc&per_page=100&since=${since}`;
  const rows: RawComment[] = [];
  const issueComments = ghJson<RestComment[]>(["api", `repos/${cfg.repo}/issues/comments?${q}`]) ?? [];
  for (const c of issueComments) {
    rows.push({
      id: c.id,
      body: c.body,
      actor: c.user.login,
      url: c.html_url,
      issue_url: c.issue_url ?? "",
      created_at: c.created_at,
      reply_kind: "issue",
    });
  }
  const reviewComments = ghJson<RestComment[]>(["api", `repos/${cfg.repo}/pulls/comments?${q}`]) ?? [];
  for (const c of reviewComments) {
    rows.push({
      id: c.id,
      body: c.body,
      actor: c.user.login,
      url: c.html_url,
      issue_url: c.pull_request_url ?? "",
      created_at: c.created_at,
      reply_kind: "review",
    });
  }
  return sortComments(rows);
};

// 同じ作業対象へのコメントは 1 タスクに畳む。同じブランチを触る以上、別々の
// セッションで順に処理しても後のセッションが前の変更を読み直すだけで、
// 指示どうしの矛盾も見つけられない
const discoverComments = (cfg: Config): void => {
  const lastPollFile = cfg.lastPollFile;
  const lastPoll = existsSync(lastPollFile) ? readFileSync(lastPollFile, "utf8").trim() : null;
  const since = computeSince(lastPoll, new Date());

  const seen = new Set(
    (existsSync(cfg.seenFile) ? readFileSync(cfg.seenFile, "utf8") : "").split("\n").filter(Boolean),
  );

  // PR 番号から Issue 番号への読み替えは API を叩くので、同じ PR では使い回す
  const resolved = new Map<number, number>();
  const hits = new Map<number, CommentRef[]>();

  for (const row of fetchComments(cfg, since)) {
    const id = String(row.id);
    if (seen.has(id)) continue;
    if (row.body.includes(cfg.commentMarker)) {
      appendFileSync(cfg.seenFile, `${id}\n`);
      seen.add(id);
      continue;
    }
    if (!isAllowedActor(row.actor, cfg.allowedActors)) continue;
    if (!hasTrigger(row.body, cfg.trigger)) continue;

    const replyNumber = issueNumberFromUrl(row.issue_url);
    if (replyNumber === null) continue;

    let number = resolved.get(replyNumber);
    if (number === undefined) {
      number = resolveIssueNumber(replyNumber, cfg);
      resolved.set(replyNumber, number);
    }

    const list = hits.get(number) ?? [];
    list.push({
      id,
      actor: row.actor,
      instruction: extractInstruction(row.body, cfg.trigger),
      reply_kind: row.reply_kind,
      reply_number: replyNumber,
      url: row.url,
    });
    hits.set(number, list);
  }

  // Issue 本文とタイトルは畳んだあとに 1 回だけ引く
  for (const number of [...hits.keys()].sort((a, b) => a - b)) {
    const comments = hits.get(number) ?? [];
    const first = comments[0];
    if (!first) continue;

    const issue = ghJson<{ title: string; body: string }>([
      "issue",
      "view",
      String(number),
      "-R",
      cfg.repo,
      "--json",
      "title,body",
    ]);
    if (issue === null) continue;

    emit({
      kind: "comment",
      number,
      title: chomp(issue.title),
      body: chomp(issue.body ?? ""),
      actor: first.actor,
      comments,
    });
  }
};

// 手で作った agent/bot-check のようなブランチを拾わないため
const listOpenAgentBranches = (cfg: Config): void => {
  const prs = ghJson<{ headRefName: string }[]>([
    "pr",
    "list",
    "-R",
    cfg.repo,
    "--state",
    "open",
    "--limit",
    "100",
    "--json",
    "headRefName",
  ]) ?? [];
  for (const pr of prs) {
    if (pr.headRefName.startsWith(cfg.branchPrefix)) process.stdout.write(`${pr.headRefName}\n`);
  }
};

const readJsonLines = <T>(file: string): T[] =>
  (existsSync(file) ? readFileSync(file, "utf8") : "")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line) as T];
      } catch {
        return [];
      }
    });

// 差し戻しは PR の会話とレビュー、元 Issue のどれにでも書かれる。PR ができてから
// マージされるまでに、タスクを受け付けるユーザーが書いたものだけを集める
const fetchLearnComments = (cfg: Config, pr: MergedPr, issue: number): LearnComment[] => {
  const from = pr.createdAt;
  const to = pr.mergedAt;
  const rows: LearnComment[] = [];
  const push = (id: number, actor: string, body: string, url: string, at: string, path?: string): void => {
    if (!body.trim() || body.includes(cfg.commentMarker)) return;
    if (!isAllowedActor(actor, cfg.allowedActors)) return;
    if (at < from || at > to) return;
    rows.push({ id: String(id), actor, instruction: chomp(body), url, created_at: at, ...(path ? { path } : {}) });
  };
  for (const n of [pr.number, issue]) {
    for (const c of ghJson<RestComment[]>(["api", `repos/${cfg.repo}/issues/${n}/comments?per_page=100`]) ?? []) {
      push(c.id, c.user.login, c.body, c.html_url, c.created_at);
    }
  }
  type ReviewComment = RestComment & { path?: string };
  for (const c of ghJson<ReviewComment[]>(["api", `repos/${cfg.repo}/pulls/${pr.number}/comments?per_page=100`]) ?? []) {
    push(c.id, c.user.login, c.body, c.html_url, c.created_at, c.path);
  }
  type Review = { id: number; body: string; user: { login: string }; html_url: string; submitted_at: string };
  for (const r of ghJson<Review[]>(["api", `repos/${cfg.repo}/pulls/${pr.number}/reviews?per_page=100`]) ?? []) {
    push(r.id, r.user.login, r.body ?? "", r.html_url, r.submitted_at ?? "");
  }
  return rows.sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : 0));
};

// 差し戻しがあってマージされた PR を、学習のタスクとして 1 件だけ返す。1 回のポーリングで
// 何件も学ばせると、学習の Issue が一度に増えて読みきれないため
const discoverLearnSource = (cfg: Config): void => {
  const spendFile = process.env.SPEND_FILE ?? "";
  const learnedFile = process.env.LEARNED_FILE ?? "";
  if (!spendFile || !learnedFile) {
    process.stderr.write("SPEND_FILE と LEARNED_FILE が渡されていません（load_config で export してください）\n");
    process.exit(1);
  }
  const prs = ghJson<MergedPr[]>([
    "pr",
    "list",
    "-R",
    cfg.repo,
    "--state",
    "merged",
    "--limit",
    "500",
    "--json",
    "number,title,body,url,headRefName,createdAt,mergedAt,mergeCommit",
  ]) ?? [];
  const learned = existsSync(learnedFile) ? readFileSync(learnedFile, "utf8") : "";
  const pr = nextLearnSource(prs, readJsonLines<SpendRun>(spendFile), learned, cfg.repo, cfg.branchPrefix);
  if (!pr?.mergeCommit) return;
  const issue = branchToIssueNumber(pr.headRefName, cfg.branchPrefix) as number;
  const meta = ghJson<{ title: string; body: string }>(["issue", "view", String(issue), "-R", cfg.repo, "--json", "title,body"]);
  emit({
    kind: "learn",
    number: pr.number,
    title: chomp(pr.title),
    body: chomp(pr.body ?? ""),
    actor: "",
    url: pr.url,
    issue,
    issue_title: chomp(meta?.title ?? ""),
    issue_body: chomp(meta?.body ?? ""),
    merge_commit: pr.mergeCommit.oid,
    comments: fetchLearnComments(cfg, pr, issue),
  });
};

// --retry は記録済みのコメントを再処理するので、同じ id が二度来る
const markSeen = (id: string, cfg: Config): void => {
  if (!id) return;
  const seen = (existsSync(cfg.seenFile) ? readFileSync(cfg.seenFile, "utf8") : "").split("\n");
  if (!seen.includes(id)) appendFileSync(cfg.seenFile, `${id}\n`);
};

// 初回実行時に過去のコメントを一斉処理しないため
const initSeenBaseline = (cfg: Config): void => {
  const lastPollFile = cfg.lastPollFile;
  if (existsSync(lastPollFile)) return;
  writeFileSync(lastPollFile, `${utcStamp(new Date())}\n`);
  log("初回実行のため、これ以降に投稿されたコメントのみを対象にします");
};

const main = (): void => {
  const [sub, ...rest] = process.argv.slice(2);
  const cfg = loadConfig();
  switch (sub) {
    case "labeled":
      return discoverLabeled(cfg);
    case "comments":
      return discoverComments(cfg);
    case "open-branches":
      return listOpenAgentBranches(cfg);
    case "mark-seen":
      return markSeen(rest[0] ?? "", cfg);
    case "init-baseline":
      return initSeenBaseline(cfg);
    case "learn-source":
      return discoverLearnSource(cfg);
    default:
      process.stderr.write(`使い方: discover.ts labeled|comments|open-branches|mark-seen <id>|init-baseline|learn-source\n`);
      process.exit(1);
  }
};

if (process.argv[1] && import.meta.filename === process.argv[1]) main();
