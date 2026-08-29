# mopu-agent

GitHub の Issue / PR コメントをトリガーに、ローカルの Claude Code へタスクを投げるポーリング型エージェント。
Anthropic API key を使わず、ログイン済みの `claude` CLI（サブスクリプション認証）でそのまま動く。

```
Issue に agent:queued ラベル ─┐                              ┌─▶ push ─▶ PR
                              ├─▶ poll.sh ─▶ worktree ─▶ claude -p ─┤
コメントに /claude ──────────┘                              └─▶ タスク分解 ─▶ sub issue
```

## 依存

- `gh` 2.73.0 以上 — これ未満は `gh pr edit` が Projects (classic) 廃止の GraphQL エラーで落ちる
- `jq`
- `git`
- `claude`
- `flock`
- `timeout`
- `python3` — Web コンソール用（標準ライブラリのみ。追加パッケージは不要）

## セットアップ

```bash
cp config.env.example config.env
$EDITOR config.env        # 最低限 REPO と ALLOWED_ACTORS を設定
./setup.sh                # ラベル作成 + 依存確認
./poll.sh --dry-run       # 検出されるタスクを確認
./poll.sh                 # 実行
```

## GitHub App として投稿する（任意）

未設定だと Issue コメントも PR も**あなた自身のアカウント名義**になり、手作業と見分けがつかない。
GitHub App を登録すると `<app-slug>[bot]` 名義になり、bot バッジが付く。**追加の GitHub アカウントは不要**。

### 1. App を作る

[Settings → Developer settings → GitHub Apps → New GitHub App](https://github.com/settings/apps/new) で作成する。

| 項目 | 値 |
|---|---|
| GitHub App name | 例 `nattoujam-mopu-agent`（グローバルに一意なので `mopu-agent` 単体は取れない可能性が高い） |
| Homepage URL | 何でもよい（`https://github.com/nattoujam` など） |
| Webhook | **Active のチェックを外す**（ポーリング方式なので不要） |

Repository permissions は次の 4 つだけ与える。

| 権限 | レベル | 用途 |
|---|---|---|
| Contents | Read and write | ブランチの push |
| Issues | Read and write | コメント投稿、ラベル操作 |
| Pull requests | Read and write | PR の作成、レビュアーの指定 |
| Metadata | Read-only | 必須（自動で付く） |

"Where can this GitHub App be installed?" は **Only on this account** でよい。

### 2. 秘密鍵を生成してインストールする

1. 作成後の App 設定ページ下部 **Generate a private key** で `.pem` をダウンロード
2. 同じページ上部の **App ID** を控える
3. 左メニュー **Install App** → 自分のアカウント → 対象リポジトリを選んでインストール

### 3. 配置する

```bash
mkdir -p ~/.config/mopu-agent
mv ~/Downloads/*.private-key.pem ~/.config/mopu-agent/app.pem
chmod 600 ~/.config/mopu-agent/app.pem
```

`config.env` に設定する。

```bash
APP_ID='123456'
APP_PRIVATE_KEY='~/.config/mopu-agent/app.pem'
```

### 4. 確認する

```bash
./setup.sh
# → GitHub App として動作します: nattoujam-mopu-agent[bot]
```

以降、Issue コメント・PR・コミットのすべてが bot 名義になる。

### 仕組みと注意点

- App の JWT は RS256 固定。`iat` を 60 秒過去に、`exp` を上限の 10 分先に置いている（`lib/github-app.sh`）
- installation access token は **1 時間で失効**するため、ポーリングごとに取り直す（プロセス内でキャッシュ）
- コミットの author には `<bot-user-id>+<slug>[bot]@users.noreply.github.com` を使う。
  この形式にすると GitHub 上で App のアイコンが表示される
- 秘密鍵は `config.env` ごと `.gitignore` 済み。`chmod 600` でないと警告が出る
- **App が作成した PR は GitHub Actions のワークフローをトリガーしない。**
  対象リポジトリで CI を回しているなら、この点だけ運用に影響する

## 使い方

### ラベルでトリガーする

Issue に `agent:queued` を付けて `./poll.sh` を実行する。ラベルは状態機械になっている。

```
agent:queued ──▶ agent:running ──▶ agent:done
                       └────────▶ agent:failed
```

### コメントでトリガーする

Issue や PR のコメントで、**行頭**に `/claude` と書く。

```
/claude この関数のテストを追加して
```

`@claude` を使わないのは、`claude` / `claude-code` / `claude-agent` がいずれも**実在の GitHub ユーザー**で、
メンションするたび無関係な人へ通知が飛ぶため。`/claude` はメンション解決の対象にならない。

コードブロック（``` で囲んだ部分）の中の `/claude` は無視される。

結果は**指示が来たコメントと同じ場所**に返る。

| 指示を書いた場所 | 報告先 |
|---|---|
| Issue のコメント | その Issue |
| PR の会話コメント | その PR |
| PR のレビューコメント | そのレビュースレッドへの返信 |

PR で指示した場合も、ブランチ・ラベル・sub issue は元 Issue 側で扱われる（[同時進行タスクの制限](#同時進行タスクの制限)を参照）。

### オプション

| オプション | 説明 |
|---|---|
| `--dry-run` | 検出したタスクを表示するだけ |
| `--task <番号>` | 指定した Issue だけを処理（ラベル不要、同時進行ゲートも無視） |
| `--retry <番号>` | 失敗したタスクを、残った作業ツリーごと引き継いで再開 |
| `--ignore-budget` | 利用枠のゲートを無視 |

`--retry` は前回のタスクをそのまま再現する。コメントでトリガーしたタスクなら、
指示だったコメント本文も引き継がれる（`logs/<タスクID>/task.json` に控えてある）。

### 作成される PR

| 項目 | 値 |
|---|---|
| 状態 | Open（Draft にしない） |
| Reviewers | `REPO` の owner |
| Assignees | 付けない |

Assignees を付けないのは、**GitHub App の bot ユーザーが assignable ではない**ため。
`GET /repos/{owner}/{repo}/assignees/<app-slug>[bot]` は 404 を返す（人間のアカウントは 204）。

Reviewers の指定に失敗した場合は警告を出すだけで、PR 自体は成立させる。

## Web コンソール

`poll.sh` を一定間隔で自動実行しつつ、稼働状態とログをブラウザから見るためのコンソール。

```bash
./console.sh
# → http://127.0.0.1:8787
```

Python 3 の標準ライブラリだけで動く。スケジューラと HTTP サーバを 1 プロセスで持ち、時間が来たら
`poll.sh` を子プロセスとして起動して、その出力を `logs/console/poll-<日時>.log` に丸ごと残す。

### 画面

| 領域 | 内容 |
|---|---|
| 稼働状態 | 次回ポーリングまでのカウントダウン、実行間隔、最終ポーリング時刻、`poll.lock` の保持状況、累計コストと直近の 5h 枠 |
| スケジュール | 実行間隔の変更（`300` / `5m` / `1h` のいずれの書き方でも可）、一時停止と再開、今すぐ実行 |
| ポーリング履歴 | 実行ごとの終了コード・所要時間・検出/処理件数と、ログ本文（実行中のものは 2 秒ごとに追尾する） |
| タスクログ | `logs/<task-id>/` の結果・コスト・ターン数と、`stream.jsonl` を読み下したイベント列。ツール呼び出しは引数を項目ごとに整形する。各イベントの `raw` ボタンで対応する 1 行だけをモーダルで開けるほか、`stream.jsonl` 全体と `stderr.log` も原文のまま読める |

### 設定

`config.env` で指定する（すべて任意）。

| 変数 | 既定値 | 説明 |
|---|---|---|
| `CONSOLE_HOST` | `127.0.0.1` | 待受アドレス |
| `CONSOLE_PORT` | `8787` | 待受ポート |
| `CONSOLE_INTERVAL` | `300` | 実行間隔の初期値。`5m` / `1h` 形式も可 |

間隔と一時停止の状態は、画面で変更した時点で `state/console.json` に保存され、再起動後も引き継がれる。
`config.env` の `CONSOLE_INTERVAL` は、この保存ファイルが無いときの初期値としてだけ効く。

間隔は 60 秒〜24 時間に制限している。また起動直後には実行せず、必ず 1 間隔ぶん待つ
（起動しただけで利用枠を削らないため）。すぐ走らせたいときは「今すぐ実行」を押す。一時停止中でも動く。

### 常駐させる

systemd user service にすると、ログインしている間ずっと回り続ける。

```ini
# ~/.config/systemd/user/mopu-console.service
[Unit]
Description=mopu-agent web console

[Service]
ExecStart=%h/Code/mopu-agent/console.sh
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now mopu-console
journalctl --user -u mopu-console -f
```

停止時（`SIGTERM` / `Ctrl-C`）は、実行中の `poll.sh` が終わるのを最大 5 分待ってから落ちる。
途中で殺すと Issue に `agent:running` ラベルが残ったままになるため。

### 注意

**コンソールは認証を一切持たない。** ここから `poll.sh` を起動できる = ローカルの `claude` を任意に走らせられる
ということなので、loopback 以外での待受は既定で拒否する。それでも公開する場合は `CONSOLE_ALLOW_REMOTE=1`
を設定したうえで、前段のリバースプロキシで認証をかけること。

## タスク分解

大きすぎるタスクを 1 セッションで実装させると、巨大な PR・タイムアウト・予算超過のいずれかに落ちる。
そこでエージェントは、着手前に**このタスクを分解すべきか**を自分で判断する。

分解すると判断した場合、コード変更を一切行わず sub issue を作って終了する。実装は次回以降のセッションで行う。

```
16:42:10 [issue-7-...] タスクを分解します (3 件)
16:42:18 [issue-7-...] 分解完了: 3 件の sub issue を作成しました
```

判断基準は `prompts/decompose.md` にある。要点は次のとおり。

- **1 つの PR は 1 つの関心事に絞る**。独立してレビュー・revert できる関心事が 2 つ以上あるなら分ける
- **機能改修とリファクタリングを混ぜない**。リファクタが前提なら先行する別 sub issue に切り出す
- 整形・リネーム・依存更新のような機械的な差分は、意味のある変更と混ぜない
- 逆に、本体と不可分なテスト・ドキュメントは切り出さない（単体でレビューできなくなるため）
- 迷ったら実装を優先する（過剰分解のほうが害が大きい）

### 仕組み

エージェントは `gh` も `curl` も拒否されているため、**自分では sub issue を作れない**。
分解結果はタスク用ディレクトリ直下（リポジトリの外）の `.mopu-agent-plan.json` に書かせ、`lib/run-task.sh` がそれを読んで GitHub API を叩く。

```json
{
  "summary": "分解の要約",
  "reason": "1セッションで完結させない理由",
  "sub_issues": [
    { "title": "サブタスク", "body": "## 目的\n...\n## 完了条件\n- [ ] ..." }
  ]
}
```

- 作成される sub issue には `agent:queued` が自動で付く。次回の poll から実装が走る
- 件数は `MAX_SUB_ISSUES`（既定 5）で頭打ちにする
- sub issue は REST の sub-issues API で親に紐付く（`sub_issue_id` は Issue の `number` ではなく `id`）
- 生成した sub issue の本文には `<!-- mopu-agent:sub-of #N -->` が入る。**このマーカーか、REST の `parent_issue_url` を持つ Issue は再分解されない**（無限分解のガード）。
  後者があるので、GitHub 上で手動で親に紐付けた Issue も対象になる

## 同時進行タスクの制限

`MAX_TASKS_PER_RUN`（既定 3）のため、poll.sh は 1 回の実行で複数のタスクを逐次処理する。
放っておくと PR が何本も並び、どれもレビューされないまま溜まる。

`MAX_OPEN_AGENT_PRS`（既定 1）は、**未マージの `agent/issue-*` PR がある間、新しい Issue への着手を止める**。

```
16:40:02 進行中の PR: 1 件 (agent/issue-4)
16:40:02 進行中の PR が 1 件あるためスキップします: #7（マージ/クローズ後に再検出されます）
```

- スキップされたタスクは `agent:queued` のまま残るので、PR がマージ/クローズされた後の poll で再検出される
- **進行中 PR とその元 Issue への `/claude` コメントは例外**として常に処理される。
  ここを塞ぐとレビュー指摘を反映できず、「PR が open なので着手できない / 着手できないので PR が進まない」で詰まる。
  PR へのコメントは、ブランチ名 `agent/issue-<番号>` から元 Issue の番号に読み替えたうえで処理される。
  読み替えるのは作業対象の番号だけで、報告はコメントが来た PR 側に返る
- `--task` での手動指定もゲートを通さない
- `0` にすると従来どおり無制限になる

## 利用枠のゲート

`claude -p "/usage"` で 5 時間枠と週次枠の使用率を取得し、閾値を超えていたらタスクを開始しない。
`/usage` はローカルコマンドとして処理されるため **API 呼び出しを伴わず、枠を消費しない**（約 1.8 秒）。

```
16:30:23 利用枠: 5h=81% (閾値 50%) / 7d=34% (閾値 80%)
16:30:23 5時間枠が 81% に達しています。resets Aug 23, 8:20pm (Asia/Tokyo) 以降に再実行してください
```

- タスク 1 件ごとに測り直すので、連続処理で閾値を跨がない
- `/usage` の出力を解釈できなかった場合は**安全側に倒して起動しない**
- 実行中に `rate_limit_event` が `allowed_warning` / `rejected` になったら、以降のタスクを打ち切る
- 実績は `state/spend.jsonl` に記録される（コストと実行前後の 5h 使用率）

## 隔離

タスクは `git worktree` で切り出した専用ディレクトリで実行され、次の多層で囲われている。

| 層 | 内容 |
|---|---|
| ファイル | `Read`/`Edit`/`Write` はタスク用ディレクトリの絶対パス配下のみ許可 |
| シェル | Bash は必要なコマンドだけを明示許可。`rm` / `sudo` / `gh` / `curl` は拒否 |
| ネットワーク | `WebFetch` / `WebSearch` と `curl` / `wget` を拒否。allow する Bash に通信するコマンドを入れない |
| 認証情報 | `~/.ssh` `~/.config/gh` `~/.claude` を読み取り拒否、`GITHUB_TOKEN` 等を環境から除去 |
| 設定 | `--setting-sources ''` と `--strict-mcp-config` で、対象リポジトリの hooks / MCP を読み込まない |
| 資格情報 | App のトークンは `GIT_ASKPASS` 経由で渡し、リモート URL には埋め込まない |

`git push` と `gh pr create` は**エージェントにやらせず**、`poll.sh` 側のラッパースクリプトが実行する。
そのため GitHub の認証情報がエージェントに渡ることはない。

### 作業ディレクトリの構成

エージェントの cwd は worktree そのものではなく、その 1 つ上のタスク用ディレクトリにしている。

```
worktrees/<task-id>/                   ← エージェントの cwd
worktrees/<task-id>/repo/              ← git worktree（対象リポジトリ）
worktrees/<task-id>/.mopu-agent-plan.json ← タスク分解の受け渡し用
```

`.mopu-agent-plan.json` をリポジトリの外に置けるので、`git status` の結果をそのまま
「エージェントが変更を残したか」の判定に使える。

### 実装上の注意

- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` を設定すると **permission mode が default に強制される**。
  権限は `settings/agent-settings.json` の allow / deny ルールだけで決まり、`--permission-mode` は効かない。
- `Read`/`Edit`/`Write` のパス制限は、`--settings` 経由ではプロジェクト相対 (`Write(/**)`) が効かない。
  タスク用ディレクトリの絶対パスを実行時に注入している（`lib/run-task.sh`）。
- sandbox は無効にしている（`settings/agent-settings.json` の `sandbox.enabled: false`）。
  bwrap が userns の制限で起動できない環境があるため、隔離は permissions の allow / deny
  だけで行う。Bash も allow ルールで明示的に許可する。プロジェクト固有のコマンドは
  `EXTRA_ALLOWED_TOOLS` で追加する。

```bash
EXTRA_ALLOWED_TOOLS=('Bash(npm test:*)' 'Bash(npm run:*)')
```

## 動作検証

`config.env` の `CLAUDE_BIN` を `./tools/fake-agent` に向けると、LLM を一切呼ばずに
`poll.sh` の分岐だけを踏める。スタブはプロンプトを読まず、環境変数で挙動を決める。

```bash
CLAUDE_BIN="./tools/fake-agent" FAKE_AGENT_MODE=dirty ./poll.sh --task 12
```

| `FAKE_AGENT_MODE` | スタブの挙動 | 到達する終端 |
|---|---|---|
| `commit`（既定） | worktree にファイルを追加してコミット | push → PR 作成 → `agent:done` |
| `noop` | 何もせず結果だけ返す | 「コード変更なし」でコメントのみ |
| `dirty` | 編集するがコミットしない | 未コミット検知 → `agent:failed` |
| `plan` | 妥当な `.mopu-agent-plan.json` を書く | 分解 → sub issue 作成 |
| `badplan` | `sub_issues` が空の plan を書く | `validate_plan` 不合格 → `agent:failed` |
| `error` | `is_error: true` を返す | 実行失敗 → `agent:failed` |
| `crash` | stderr を出して exit 1 | 実行失敗 → `agent:failed` |

モードと独立して効く変数もある。

| 変数 | 既定 | 用途 |
|---|---|---|
| `FAKE_AGENT_USAGE_5H` / `FAKE_AGENT_USAGE_7D` | `0` | `/usage` が返す使用率。利用枠ゲートの検証に使う |
| `FAKE_AGENT_RATE_LIMIT` | 空 | `allowed_warning` / `rejected` を指定すると `rate_limit_event` を混ぜる |
| `FAKE_AGENT_SLEEP` | `0` | 指定秒だけ待つ。`TASK_TIMEOUT` の検証に使う |
| `FAKE_AGENT_COST` | `0.01` | `total_cost_usd` の値。`state/spend.jsonl` の検証に使う |
| `FAKE_AGENT_SUB_ISSUES` | `2` | `plan` モードで作る sub issue の件数 |

Issue の作成やラベル操作は本物の GitHub を叩くので、検証用のリポジトリを `REPO` に
指定すること。

## セキュリティ

- **`ALLOWED_ACTORS` は必須**。空だと `poll.sh` は起動を拒否する。
  Issue / PR コメントは第三者が書けるため、発行者を絞らないとプロンプトインジェクション経由の
  任意コード実行に直結する。
- システムプロンプトで、Issue 本文を「信頼できない入力」として扱うよう指示している（`prompts/issue.md`）。
- GitHub App 利用時は、**bot 自身（`app/<slug>` と `<slug>[bot]`）が `ALLOWED_ACTORS` に自動で加わる**。
  タスク分解で作られた sub issue の author は bot になるため、これがないと自動キューが機能しない。
  bot 名義で Issue を作れるのは秘密鍵の持ち主だけなので、第三者の迂回路にはならない。
- 対象は自分のリポジトリに限ること。他人のタスクを自分のサブスク枠で代行処理するのは、
  Claude Code の [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) が
  禁じる "resell or intermediate" に該当しうる。

## ファイル構成

```
config.env              設定（git 管理外）
poll.sh                 エントリポイント
setup.sh                ラベル作成と依存確認
console.sh              Web コンソールの起動ラッパ
console.py              スケジューラ + HTTP サーバ（Python 標準ライブラリのみ）
web/index.html          Web コンソールの画面
lib/common.sh           設定読み込み・ログ・バリデーション
lib/github-app.sh       GitHub App 認証（JWT → installation token）
lib/budget.sh           利用枠ゲート（/usage のパース）
lib/discover.sh         タスク検出（ラベル / コメント）
lib/workspace.sh        clone と worktree の管理
lib/run-task.sh         claude -p の実行 → push → PR → コメント
tools/fake-agent        claude の代役スタブ（動作検証用）
prompts/issue.md        エージェントへの追加システムプロンプト
prompts/command.md      コメントトリガー時に追記される断片
prompts/decompose.md    タスク分解の判断基準
settings/               エージェントの権限の基本設定
state/                  処理済みコメント ID、ポーリング時刻、コスト実績
logs/<task-id>/         stream-json の生ログ、stderr、生成された settings
logs/console/           コンソールが起動した poll.sh の実行ログ
```

## 制限

- **ネットワークが遮断されているため、依存パッケージのインストールを伴うタスクは失敗する。**
  その場合エージェントは変更を加えず、理由を Issue にコメントする。
- `poll.sh` 単体では自動起動しない（利用枠を張り付かせないため）。定期実行するなら
  [Web コンソール](#web-コンソール)（`./console.sh`）を使う。間隔は控えめにすること。
