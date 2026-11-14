# mopu-agent

## 動作を確かめる

LLM を呼ばずに `poll.sh` の分岐を確かめるときは、`CLAUDE_BIN` を `tools/fake-agent` に向ける。
挙動は `FAKE_AGENT_MODE` などの環境変数で切り替える。変数と既定値は `tools/fake-agent` の先頭にある。

```bash
CLAUDE_BIN=./tools/fake-agent FAKE_AGENT_MODE=dirty ./poll.sh --repo <owner/repo> --task <番号>
```

fake-agent でも、Issue の作成とラベルの操作は本物の GitHub に対して行う。`--repo` には検証用のリポジトリを指定する。

学習と棚卸しは、`FAKE_AGENT_STRUCTURED` に返させる JSON を渡して確かめる。棚卸しは `LEARN_TIDY_CHARS=100` のように閾値を下げると走る。

## Claude Code を更新したとき

sandbox が作業ディレクトリに置く書き込み禁止の placeholder は、Claude Code のバージョンによって変わる。
更新したら `tools/check-sandbox-placeholders` を実行する。Claude Code へのログインが要り、利用枠を少し使う。
足りない placeholder が出たら、`lib/workspace.sh` の `SANDBOX_PLACEHOLDERS` に足す。
