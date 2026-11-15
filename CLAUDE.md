# mopu-agent

## 動作を確かめる

LLM を呼ばずに `poll.sh` の分岐を確かめるときは、`CLAUDE_BIN` を `tools/fake-agent` に向ける。
fake-agent は `MOPU_PHASE`（今の state）ごとに出口ファイルを書く。どの出口にするかは `FAKE_AGENT_TRIAGE` などの環境変数で切り替える。変数と既定値は `tools/fake-agent` の先頭にある。

```bash
CLAUDE_BIN=./tools/fake-agent FAKE_AGENT_TRIAGE=ask ./poll.sh --repo <owner/repo> --task <番号>
```

fake-agent でも、Issue の作成とラベルの操作は本物の GitHub に対して行う。`--repo` には検証用のリポジトリを指定する。

学習は、`FAKE_AGENT_STRUCTURED` に返させる JSON を渡して確かめる。

## Claude Code を更新したとき

sandbox が作業ディレクトリに置く書き込み禁止の placeholder は、Claude Code のバージョンによって変わる。
更新したら `tools/check-sandbox-placeholders` を実行する。Claude Code へのログインが要り、利用枠を少し使う。
足りない placeholder が出たら、`lib/workspace.sh` の `SANDBOX_PLACEHOLDERS` に足す。

`tools/check-agent-runtime` も実行する。run-task.sh が頼っている Claude Code の挙動（sandbox の中の Bash の自動許可、Stop hook の差し戻し、PreToolUse hook の拒否）を実測する。
