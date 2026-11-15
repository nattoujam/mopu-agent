# mopu-agent

## 動作を確かめる

`bin/mopu` は、起動したときにソースから作り直されない。`lib/resources.nim` が埋め込むファイル（prompts など）もビルドのときにバイナリへ入る。`lib/` や埋め込むファイルを変えたら、動かす前に `nim build` を実行する。テストは `nim test` で回す。

`bin/mopu` はデータを `MOPU_HOME` から読み書きする。未設定のときの置き場とデータの中身は `lib/paths.nim` が決める。今どこを使っているかは `./bin/mopu version` で確かめる。

LLM を呼ばずに `mopu poll` の分岐を確かめるときは、`CLAUDE_BIN` を `tools/fake-agent` に向ける。
fake-agent は `MOPU_PHASE`（今の state）ごとに出口ファイルを書く。どの出口にするかは `FAKE_AGENT_TRIAGE` などの環境変数で切り替える。変数と既定値は `tools/fake-agent` の先頭にある。

```bash
CLAUDE_BIN=./tools/fake-agent FAKE_AGENT_TRIAGE=ask ./bin/mopu poll --repo <owner/repo> --task <番号>
```

fake-agent でも、Issue の作成とラベルの操作は本物の GitHub に対して行う。`--repo` には検証用のリポジトリを指定する。

学習は、`FAKE_AGENT_STRUCTURED` に返させる JSON を渡して確かめる。

## Nim の stdlib を使うとき

OS・プロセス・シグナル・ソケット・非同期 I/O に触る stdlib の proc（`std/posix`、`std/osproc`、`std/asyncdispatch`、`std/asynchttpserver`、`std/nativesockets` など）は、使う前に `$(asdf where nim)/lib/` のソースを読み、副作用を確かめてから書く。docstring に書かれていない副作用があり、テストでは気づきにくい。

例: `addSignal` は `signalfd` を使うため、登録したシグナルをプロセス全体で block する。block は exec した子に引き継がれるので、コンソールがそのまま `mopu poll` を起動すると、`mopu poll` が SIGTERM を受け取れない。

`std/strutils` や `std/sequtils` のように値を変換するだけで OS に触らない module は、ソースを読まなくてよい。

## Claude Code を更新したとき

sandbox が作業ディレクトリに置く書き込み禁止の placeholder は、Claude Code のバージョンによって変わる。
更新したら `./bin/mopu check sandbox-placeholders` を実行する。Claude Code へのログインが要り、利用枠を少し使う。
足りない placeholder が出たら、`lib/workspace.nim` の `SandboxPlaceholders` に足す。

`./bin/mopu check agent-runtime` も実行する。タスクの実行が頼っている Claude Code の挙動を実測する。検査の中身は `lib/agent_checks.nim` の `checkAgentRuntime` にある。
