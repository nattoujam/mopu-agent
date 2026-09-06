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

export type Task = LabeledTask | CommentTask;

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
  stateDir: string;
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
    stateDir: need("STATE_DIR"),
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
  const lastPollFile = `${cfg.stateDir}/last-poll`;
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

// --retry は記録済みのコメントを再処理するので、同じ id が二度来る
const markSeen = (id: string, cfg: Config): void => {
  if (!id) return;
  const seen = (existsSync(cfg.seenFile) ? readFileSync(cfg.seenFile, "utf8") : "").split("\n");
  if (!seen.includes(id)) appendFileSync(cfg.seenFile, `${id}\n`);
};

// 初回実行時に過去のコメントを一斉処理しないため
const initSeenBaseline = (cfg: Config): void => {
  const lastPollFile = `${cfg.stateDir}/last-poll`;
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
    default:
      process.stderr.write(`使い方: discover.ts labeled|comments|open-branches|mark-seen <id>|init-baseline\n`);
      process.exit(1);
  }
};

if (process.argv[1] && import.meta.filename === process.argv[1]) main();
