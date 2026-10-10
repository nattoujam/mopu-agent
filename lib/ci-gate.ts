#!/usr/bin/env node
// Stop hook（tools/ci-gate）の判定のうち、ワークフローの起動条件の解釈を受け持つ。
// mopu-agent は実行時の依存を持たないので、YAML は `on:` の書き方のうち実際に使われる形だけを読む。
// 読めない形は "unknown" とし、呼び出し側は「CI が動くはず」として扱う
import { execFileSync } from "node:child_process";

export type Filters = {
  branches?: string[];
  "branches-ignore"?: string[];
  paths?: string[];
  "paths-ignore"?: string[];
  types?: string[];
};

export type PullRequestTrigger =
  | { kind: "none" }
  | { kind: "unknown"; reason: string }
  | { kind: "on"; triggers: Filters[] };

const PR_EVENTS = new Set(["pull_request", "pull_request_target"]);
const FILTER_KEYS = new Set(["branches", "branches-ignore", "paths", "paths-ignore", "types"]);
// GitHub はこの件数を超える差分では、パスの一致を見落として起動しないことがある
const MAX_DIFF_FILES = 3000;

const stripComment = (line: string): string => {
  let quote = "";
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === quote) quote = "";
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === "#" && (i === 0 || /\s/.test(line[i - 1] ?? ""))) {
      return line.slice(0, i).trimEnd();
    }
  }
  return line.trimEnd();
};

const unquote = (s: string): string => {
  const t = s.trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    return t.slice(1, -1);
  }
  return t;
};

const indentOf = (line: string): number => line.length - line.trimStart().length;

const parseFlowSeq = (s: string): string[] | null => {
  const t = s.trim();
  if (!t.startsWith("[") || !t.endsWith("]")) return null;
  const inner = t.slice(1, -1).trim();
  return inner === "" ? [] : inner.split(",").map(unquote);
};

const parseList = (rest: string, block: string[]): string[] | null => {
  if (rest !== "") return parseFlowSeq(rest) ?? [unquote(rest)];
  const items: string[] = [];
  for (const line of block) {
    const m = /^\s*-\s*(.*)$/.exec(line);
    if (!m) return null;
    items.push(unquote(m[1] ?? ""));
  }
  return items;
};

const childBlock = (lines: string[], start: number, indent: number): { block: string[]; next: number } => {
  const block: string[] = [];
  let i = start;
  for (; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (line.trim() === "") continue;
    if (indentOf(line) <= indent) break;
    block.push(line);
  }
  return { block, next: i };
};

const parseFilters = (block: string[]): Filters | null => {
  const filters: Filters = {};
  const base = block.length ? indentOf(block[0] ?? "") : 0;
  for (let i = 0; i < block.length; ) {
    const line = block[i] ?? "";
    if (indentOf(line) !== base) return null;
    const m = /^\s*([A-Za-z_-]+):\s*(.*)$/.exec(line);
    if (!m) return null;
    const key = m[1] ?? "";
    const { block: sub, next } = childBlock(block, i + 1, base);
    if (FILTER_KEYS.has(key)) {
      const list = parseList(m[2] ?? "", sub);
      if (!list) return null;
      filters[key as keyof Filters] = list;
    }
    i = next;
  }
  return filters;
};

export const parsePullRequestTrigger = (yaml: string): PullRequestTrigger => {
  const lines = yaml.split("\n").map(stripComment);
  const at = lines.findIndex((l) => /^(on|"on"|'on'):(\s|$)/.test(l));
  if (at < 0) return { kind: "unknown", reason: "on: が見つからない" };
  const rest = (lines[at] ?? "").replace(/^(on|"on"|'on'):\s*/, "");

  if (rest !== "") {
    const events = parseFlowSeq(rest) ?? (rest.startsWith("{") ? null : [unquote(rest)]);
    if (!events) return { kind: "unknown", reason: `on: の値を読めない: ${rest}` };
    return events.some((e) => PR_EVENTS.has(e)) ? { kind: "on", triggers: [{}] } : { kind: "none" };
  }

  const { block } = childBlock(lines, at + 1, 0);
  if (!block.length) return { kind: "unknown", reason: "on: の中身が空" };
  const base = indentOf(block[0] ?? "");
  const triggers: Filters[] = [];
  for (let i = 0; i < block.length; ) {
    const line = block[i] ?? "";
    if (indentOf(line) !== base) return { kind: "unknown", reason: `インデントを読めない: ${line.trim()}` };
    const seq = /^\s*-\s*(.*)$/.exec(line);
    if (seq) {
      if (PR_EVENTS.has(unquote(seq[1] ?? ""))) triggers.push({});
      i++;
      continue;
    }
    const m = /^\s*([A-Za-z_]+):\s*(.*)$/.exec(line);
    if (!m) return { kind: "unknown", reason: `行を読めない: ${line.trim()}` };
    const { block: sub, next } = childBlock(block, i + 1, base);
    if (PR_EVENTS.has(m[1] ?? "")) {
      const value = (m[2] ?? "").trim();
      if (value === "") {
        const filters = sub.length ? parseFilters(sub) : {};
        if (!filters) return { kind: "unknown", reason: `${m[1]} の絞り込みを読めない` };
        triggers.push(filters);
      } else if (["null", "~", "{}"].includes(value)) {
        triggers.push({});
      } else {
        return { kind: "unknown", reason: `${m[1]} の値を読めない: ${value}` };
      }
    }
    i = next;
  }
  return triggers.length ? { kind: "on", triggers } : { kind: "none" };
};

const escapeRegExp = (c: string): string => (/[.()|{}^$\\]/.test(c) ? `\\${c}` : c);

// GitHub のフィルタの書き方: * は / 以外、** は / を含む任意の列、? と + は直前の 1 文字への量指定、[] は文字クラス
export const globToRegExp = (pattern: string): RegExp => {
  let re = "";
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i] ?? "";
    if (c === "*") {
      if (pattern[i + 1] === "*") {
        if (pattern[i + 2] === "/") {
          re += "(?:.*/)?";
          i += 2;
        } else {
          re += ".*";
          i += 1;
        }
      } else {
        re += "[^/]*";
      }
    } else if (c === "[") {
      const end = pattern.indexOf("]", i + 1);
      if (end < 0) {
        re += "\\[";
      } else {
        re += pattern.slice(i, end + 1);
        i = end;
      }
    } else if ((c === "?" || c === "+") && i > 0) {
      re += c;
    } else if (c === "?" || c === "+") {
      re += `\\${c}`;
    } else {
      re += escapeRegExp(c);
    }
  }
  return new RegExp(`^${re}$`);
};

// GitHub は後ろにあるパターンの一致を優先し、! で始まるパターンに一致したら外すため、順に上書きする
export const matchesFilter = (patterns: string[], value: string): boolean => {
  let matched = false;
  for (const p of patterns) {
    if (p.startsWith("!")) {
      if (globToRegExp(p.slice(1)).test(value)) matched = false;
    } else if (globToRegExp(p).test(value)) {
      matched = true;
    }
  }
  return matched;
};

export type Applicability = "runs" | "skips" | "unknown";

// エージェントの push は PR の synchronize として届くため、types にそれが無い絞り込みは判定しない
export const filtersApply = (f: Filters, baseBranch: string, files: string[]): Applicability => {
  if (f.types && !f.types.includes("synchronize")) return "unknown";
  if (files.length > MAX_DIFF_FILES) return "unknown";
  if (f.branches && !matchesFilter(f.branches, baseBranch)) return "skips";
  if (f["branches-ignore"] && matchesFilter(f["branches-ignore"], baseBranch)) return "skips";
  if (files.length === 0) return "skips";
  if (f.paths && !files.some((file) => matchesFilter(f.paths ?? [], file))) return "skips";
  if (f["paths-ignore"] && files.every((file) => matchesFilter(f["paths-ignore"] ?? [], file))) return "skips";
  return "runs";
};

export const workflowApplies = (yaml: string, baseBranch: string, files: string[]): Applicability => {
  const t = parsePullRequestTrigger(yaml);
  if (t.kind === "none") return "skips";
  if (t.kind === "unknown") return "unknown";
  const results = t.triggers.map((f) => filtersApply(f, baseBranch, files));
  if (results.includes("runs")) return "runs";
  if (results.includes("unknown")) return "unknown";
  return "skips";
};

// テストを弱めて CI を通す変更を人間と critic に見せるための目印
const TEST_PATH = /(^|\/)(tests?|__tests__|specs?|e2e|vrt|__snapshots__|__screenshots__)\/|\.(test|spec)\.[^/]+$|(^|\/)(playwright|jest|vitest|mocha|karma|cypress)\.config\.[^/]+$|(^|\/)\.github\/workflows\//;

export const testRelatedFiles = (files: string[]): string[] => files.filter((f) => TEST_PATH.test(f));

const git = (dir: string, args: string[]): string =>
  execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

const scriptsOf = (dir: string, rev: string, path: string): string => {
  try {
    return JSON.stringify(JSON.parse(git(dir, ["show", `${rev}:${path}`])).scripts ?? {});
  } catch {
    return "";
  }
};

// 使い方: ci-gate.ts inspect <worktree> <origin/BASE_BRANCH> <BASE_BRANCH>
const inspect = (wt: string, ref: string, baseBranch: string): void => {
  const files = git(wt, ["diff", "--name-only", "--merge-base", ref, "HEAD"]).split("\n").filter(Boolean);
  const workflowFiles = git(wt, ["ls-tree", "--name-only", ref, ".github/workflows/"])
    .split("\n")
    .filter((f) => /\.ya?ml$/.test(f));
  const workflows = workflowFiles.map((file) => ({
    file,
    applies: workflowApplies(git(wt, ["show", `${ref}:${file}`]), baseBranch, files),
  }));
  const scriptsChanged = files
    .filter((f) => /(^|\/)package\.json$/.test(f))
    .filter((f) => scriptsOf(wt, ref, f) !== scriptsOf(wt, "HEAD", f))
    .map((f) => `${f}（scripts）`);
  const ci = workflows.some((w) => w.applies === "runs")
    ? "runs"
    : workflows.some((w) => w.applies === "unknown")
      ? "unknown"
      : "skips";
  process.stdout.write(
    `${JSON.stringify({ ci, files, workflows, test_changes: [...testRelatedFiles(files), ...scriptsChanged] })}\n`,
  );
};

const main = (): void => {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === "inspect" && rest.length === 3) return inspect(rest[0] ?? "", rest[1] ?? "", rest[2] ?? "");
  process.stderr.write("使い方: ci-gate.ts inspect <worktree> <origin/BASE_BRANCH> <BASE_BRANCH>\n");
  process.exit(1);
};

if (process.argv[1] && import.meta.filename === process.argv[1]) main();
