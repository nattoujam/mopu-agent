import { deepStrictEqual, strictEqual } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  filtersApply,
  globToRegExp,
  matchesFilter,
  parsePullRequestTrigger,
  testRelatedFiles,
  workflowApplies,
} from "../lib/ci-gate.ts";

describe("parsePullRequestTrigger", () => {
  it("スカラーの on", () =>
    deepStrictEqual(parsePullRequestTrigger("on: pull_request\njobs: {}\n"), { kind: "on", triggers: [{}] }));
  it("flow seq の on", () =>
    deepStrictEqual(parsePullRequestTrigger("on: [push, pull_request]\n"), { kind: "on", triggers: [{}] }));
  it("pull_request が無ければ none", () =>
    deepStrictEqual(parsePullRequestTrigger("on:\n  push:\n    branches: [main]\n"), { kind: "none" }));
  it("block seq の on", () =>
    deepStrictEqual(parsePullRequestTrigger("on:\n  - push\n  - pull_request\n"), { kind: "on", triggers: [{}] }));
  it("絞り込みの block seq とコメントとクォート", () =>
    deepStrictEqual(
      parsePullRequestTrigger(
        [
          "name: Test",
          "",
          "on:",
          "  pull_request:  # PR だけ",
          "    paths:",
          '      - "server/**"',
          "      - 'web/**'",
          "    branches: [main, 'release/**']",
          "  workflow_dispatch:",
          "    inputs:",
          "      mode:",
          "        type: choice",
          "",
          "jobs:",
          "  test: {}",
        ].join("\n"),
      ),
      { kind: "on", triggers: [{ paths: ["server/**", "web/**"], branches: ["main", "release/**"] }] },
    ));
  it("値の無い pull_request は絞り込みなし", () =>
    deepStrictEqual(parsePullRequestTrigger("on:\n  pull_request:\n  workflow_dispatch:\n"), {
      kind: "on",
      triggers: [{}],
    }));
  it("pull_request と pull_request_target の両方を拾う", () =>
    deepStrictEqual(
      parsePullRequestTrigger("on:\n  pull_request:\n    paths: [a/**]\n  pull_request_target:\n"),
      { kind: "on", triggers: [{ paths: ["a/**"] }, {}] },
    ));
  it("flow mapping は読まない", () =>
    strictEqual(parsePullRequestTrigger("on:\n  pull_request: {paths: [a]}\n").kind, "unknown"));
  it("on が無ければ unknown", () => strictEqual(parsePullRequestTrigger("name: x\n").kind, "unknown"));
});

describe("globToRegExp / matchesFilter", () => {
  const m = (p: string, v: string) => globToRegExp(p).test(v);
  it("* は / をまたがない", () => {
    strictEqual(m("src/*", "src/a.ts"), true);
    strictEqual(m("src/*", "src/a/b.ts"), false);
  });
  it("** は / をまたぐ", () => strictEqual(m("src/**", "src/a/b.ts"), true));
  it("**/ は 0 段のディレクトリにも一致する", () => {
    strictEqual(m("**/README.md", "README.md"), true);
    strictEqual(m("**/README.md", "docs/README.md"), true);
  });
  it("? は直前の 1 文字を任意にする", () => {
    strictEqual(m("*.jsx?", "a.js"), true);
    strictEqual(m("*.jsx?", "a.jsx"), true);
  });
  it(". はそのままの文字", () => strictEqual(m("a.md", "aXmd"), false));
  it("後ろの否定が勝つ", () => {
    strictEqual(matchesFilter(["docs/**", "!docs/draft/**"], "docs/draft/a.md"), false);
    strictEqual(matchesFilter(["docs/**", "!docs/draft/**"], "docs/a.md"), true);
  });
  it("否定の後ろの肯定で戻る", () =>
    strictEqual(matchesFilter(["docs/**", "!docs/draft/**", "docs/draft/keep.md"], "docs/draft/keep.md"), true));
});

describe("filtersApply", () => {
  it("絞り込みなしは変更があれば動く", () => strictEqual(filtersApply({}, "main", ["README.md"]), "runs"));
  it("変更が無ければ動かない", () => strictEqual(filtersApply({}, "main", []), "skips"));
  it("paths に当たらなければ動かない", () =>
    strictEqual(filtersApply({ paths: ["server/**", "web/**"] }, "main", ["README.md"]), "skips"));
  it("paths に 1 つでも当たれば動く", () =>
    strictEqual(filtersApply({ paths: ["web/**"] }, "main", ["README.md", "web/a.ts"]), "runs"));
  it("paths-ignore は全部が当たったときだけ動かない", () => {
    strictEqual(filtersApply({ "paths-ignore": ["docs/**"] }, "main", ["docs/a.md"]), "skips");
    strictEqual(filtersApply({ "paths-ignore": ["docs/**"] }, "main", ["docs/a.md", "a.ts"]), "runs");
  });
  it("branches はマージ先で判定する", () => {
    strictEqual(filtersApply({ branches: ["main"] }, "develop", ["a.ts"]), "skips");
    strictEqual(filtersApply({ "branches-ignore": ["main"] }, "main", ["a.ts"]), "skips");
  });
  it("types に synchronize が無ければ判定しない", () =>
    strictEqual(filtersApply({ types: ["opened"] }, "main", ["a.ts"]), "unknown"));
});

describe("workflowApplies", () => {
  it("読めない YAML は unknown", () => strictEqual(workflowApplies("on: {pull_request: {}}\n", "main", ["a"]), "unknown"));
  it("どれかの起動条件で動けば動く", () =>
    strictEqual(
      workflowApplies("on:\n  pull_request:\n    paths: [a/**]\n  pull_request_target:\n", "main", ["b"]),
      "runs",
    ));
});

describe("testRelatedFiles", () => {
  it("テストと設定と workflow を拾う", () =>
    deepStrictEqual(
      testRelatedFiles([
        "server/test/a.test.ts",
        "web/src/b.spec.tsx",
        "web/playwright.config.ts",
        "web/__screenshots__/baseline/x.png",
        ".github/workflows/test.yml",
        "web/src/c.ts",
        "docs/testing.md",
      ]),
      [
        "server/test/a.test.ts",
        "web/src/b.spec.tsx",
        "web/playwright.config.ts",
        "web/__screenshots__/baseline/x.png",
        ".github/workflows/test.yml",
      ],
    ));
});
