# 開発

## 動作検証

`CLAUDE_BIN` を `./tools/fake-agent` に向けると、LLM を呼ばずに `poll.sh` の分岐だけを踏める。
スタブはプロンプトを読まず、環境変数で挙動を決める。

```bash
CLAUDE_BIN="./tools/fake-agent" FAKE_AGENT_MODE=dirty ./poll.sh --repo owner/sandbox --task 12
```

| `FAKE_AGENT_MODE` | スタブの挙動 | 到達する終端 |
|---|---|---|
| `commit`（既定） | worktree にファイルを追加してコミット | push → PR 作成 → `agent:done` |
| `noop` | 何もせず結果だけ返す | 「コード変更なし」でコメントのみ |
| `dirty` | 編集するがコミットしない | 未コミット検知 → `agent:failed` |
| `plan` | 妥当な `.mopu-agent-plan.json` を書く | 分解案をコメント → `agent:awaiting-approval` |
| `badplan` | `sub_issues` が空の plan を書く | `validate_plan` 不合格 → `agent:failed` |
| `error` | `is_error: true` を返す | 実行失敗 → `agent:failed` |
| `crash` | stderr を出して exit 1 | 実行失敗 → `agent:failed` |
| `nosession` | `--resume` 付きのときだけ「会話が見つからない」で落ちる | 会話なしで実行し直す |
| `budget` | `error_max_budget_usd` を返す | 実行失敗 → `agent:failed`、控えた会話 ID は捨てる |

モードと独立して効く変数もある。

| 変数 | 既定 | 用途 |
|---|---|---|
| `FAKE_AGENT_USAGE_5H` / `FAKE_AGENT_USAGE_7D` | `0` | `/usage` が返す使用率。利用枠ゲートの検証に使う |
| `FAKE_AGENT_RATE_LIMIT` | 空 | `allowed_warning` / `rejected` を指定すると `rate_limit_event` を混ぜる |
| `FAKE_AGENT_SLEEP` | `0` | 指定秒だけ待つ。`TASK_TIMEOUT` の検証に使う |
| `FAKE_AGENT_COST` | `0.01` | `total_cost_usd` の値。`state/spend.jsonl` の検証に使う |
| `FAKE_AGENT_SUB_ISSUES` | `2` | `plan` モードで作る sub issue の件数 |
| `FAKE_AGENT_SESSION_ID` | `00000000-0000-4000-8000-fa4ea9e00000` | `result` に載せる会話 ID。`state/sessions.json` の検証に使う |
| `FAKE_AGENT_STRUCTURED` | 空 | `--json-schema` 付きで呼ばれたときに `structured_output` として返す JSON。モードより優先し、作業ツリーには触れない。差し戻しの分類の検証に使う |

Issue の作成やラベル操作は本物の GitHub を叩く。コンソールの設定で、対象リポジトリには検証用のものを指定すること。

## Claude Code を更新したとき

Claude Code の sandbox が作業ディレクトリに置く書き込み禁止の placeholder は、バージョンによって変わる。
更新したら次を実行し、`lib/workspace.sh` の `SANDBOX_PLACEHOLDERS` と食い違わないか確かめる。

```bash
tools/check-sandbox-placeholders
```

Claude Code にログインしている必要があり、利用枠を少し使う。足りない placeholder があれば一覧を出して終了コード 1 で終わるので、
`SANDBOX_PLACEHOLDERS` に足す。置かれなくなった placeholder は警告として出る。

## モジュールの責務

名前から読み取れないものだけを載せる。

```
lib/common.sh           設定読み込み・ログ・バリデーション
lib/github-app.sh       GitHub App 認証（JWT → installation token）
lib/budget.sh           利用枠ゲート（/usage のパース）
lib/discover.ts         タスク検出（ラベル / コメント）
lib/workspace.sh        clone と worktree の管理
lib/plan.sh             タスク分解の提案と承認（sub issue 作成）
lib/run-task.sh         claude -p の実行 → push → PR → コメント
lib/project-memory.sh   対象リポジトリの CLAUDE.md と rules をベースブランチから読み、プロンプトにする
tools/fake-agent        claude の代役スタブ（動作検証用）
tools/push-branch       エージェントが自分のブランチを push する入口（sandbox 外で動く）
tools/dispatch-workflow エージェントが workflow_dispatch を起動する入口（同上、許可リスト付き）
tools/run-container     エージェントが設定済みの検証をコンテナで回す入口（同上、設定した検証だけ）
tools/guard-host-commands 上の 3 つを単独でしか呼べなくする PreToolUse フック
tools/ci-gate           HEAD の CI 結果が出るまでエージェントを終えさせない Stop フック
lib/ci-gate.ts          ワークフローの起動条件から、PR の変更で CI が動くかを判定する
tools/check-sandbox-placeholders sandbox の placeholder と無視リストの食い違いを調べる（開発用）
tools/loop-metrics      差し戻し率・PR あたりのコスト・差し戻しの種類を集計する
prompts/issue.md        エージェントへの追加システムプロンプト
prompts/ci.md           push と CI の結果の読み方
prompts/container.md    コンテナでの検証の回し方
prompts/command.md      コメントトリガー時に追記される断片
prompts/decompose.md    タスク分解の判断基準
prompts/project-memory.md 対象リポジトリの指示の前置き
settings/               エージェントの sandbox と権限の基本設定
state/                  設定、コスト実績、GitHub App の鍵（secrets/）
state/repos/<slug>/     リポジトリごとの処理済みコメント ID、ポーリング時刻、会話 ID
logs/<slug>/<task-id>/  stream-json の生ログ、stderr、生成された settings（slug は owner__repo）
logs/console/           コンソールが起動した poll.sh の実行ログ
```

## ログとコードの対応

どのコードが出したログなのかを追えるよう、`AGENT_DIR` の短縮 SHA を次の 3 か所に
記録している。未コミットの変更があるときは `f559662-dirty` のように印が付く。

| 記録先 | 形 |
| --- | --- |
| `logs/<slug>/<task-id>/task.json` | タスクの控えに `"commit"` を足す |
| `logs/console/poll-<日時>.log` | 先頭行に `mopu-agent <SHA>` |
| `state/console-runs.jsonl` | 各実行の記録に `"commit"` を足す（poll ログの先頭行から拾う） |
