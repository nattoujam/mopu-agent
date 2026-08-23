# gh-agent

GitHub の Issue / PR コメントをトリガーに、ローカルの Claude Code へタスクを投げるポーリング型エージェント。
Anthropic API key を使わず、ログイン済みの `claude` CLI（サブスクリプション認証）でそのまま動く。

```
Issue に agent:queued ラベル ─┐
                              ├─▶ poll.sh ─▶ git worktree ─▶ claude -p ─▶ push ─▶ Draft PR
コメントに /claude ──────────┘
```

## セットアップ

```bash
cp config.env.example config.env
$EDITOR config.env        # 最低限 REPO と ALLOWED_ACTORS を設定
./setup.sh                # ラベル作成 + 依存確認
./poll.sh --dry-run       # 検出されるタスクを確認
./poll.sh                 # 実行
```

必要なコマンド: `gh`（認証済み）, `jq`, `git`, `claude`, `flock`, `timeout`
サンドボックス用: `bubblewrap`, `socat`, `ripgrep`（`sudo pacman -S bubblewrap socat ripgrep`）

## GitHub App として投稿する（任意）

未設定だと Issue コメントも PR も**あなた自身のアカウント名義**になり、手作業と見分けがつかない。
GitHub App を登録すると `<app-slug>[bot]` 名義になり、bot バッジが付く。**追加の GitHub アカウントは不要**。

### 1. App を作る

[Settings → Developer settings → GitHub Apps → New GitHub App](https://github.com/settings/apps/new) で作成する。

| 項目 | 値 |
|---|---|
| GitHub App name | 例 `nattoujam-gh-agent`（グローバルに一意なので `gh-agent` 単体は取れない可能性が高い） |
| Homepage URL | 何でもよい（`https://github.com/nattoujam` など） |
| Webhook | **Active のチェックを外す**（ポーリング方式なので不要） |

Repository permissions は次の 4 つだけ与える。

| 権限 | レベル | 用途 |
|---|---|---|
| Contents | Read and write | ブランチの push |
| Issues | Read and write | コメント投稿、ラベル操作 |
| Pull requests | Read and write | Draft PR の作成 |
| Metadata | Read-only | 必須（自動で付く） |

"Where can this GitHub App be installed?" は **Only on this account** でよい。

### 2. 秘密鍵を生成してインストールする

1. 作成後の App 設定ページ下部 **Generate a private key** で `.pem` をダウンロード
2. 同じページ上部の **App ID** を控える
3. 左メニュー **Install App** → 自分のアカウント → 対象リポジトリを選んでインストール

### 3. 配置する

```bash
mkdir -p ~/.config/gh-agent
mv ~/Downloads/*.private-key.pem ~/.config/gh-agent/app.pem
chmod 600 ~/.config/gh-agent/app.pem
```

`config.env` に設定する。

```bash
APP_ID='123456'
APP_PRIVATE_KEY='~/.config/gh-agent/app.pem'
```

### 4. 確認する

```bash
./setup.sh
# → GitHub App として動作します: nattoujam-gh-agent[bot]
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

### オプション

| オプション | 説明 |
|---|---|
| `--dry-run` | 検出したタスクを表示するだけ |
| `--task <番号>` | 指定した Issue だけを処理（ラベル不要） |
| `--ignore-budget` | 利用枠のゲートを無視 |

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
| ファイル | `Read`/`Edit`/`Write` は worktree の絶対パス配下のみ許可 |
| シェル | Bash は必要なコマンドだけを明示許可。`rm` / `sudo` / `gh` / `curl` は拒否 |
| ネットワーク | `strictAllowlist` + 空の `allowedDomains` で全遮断 |
| 認証情報 | `~/.ssh` `~/.config/gh` `~/.claude` を読み取り拒否、`GITHUB_TOKEN` 等を環境から除去 |
| 設定 | `--setting-sources ''` と `--strict-mcp-config` で、対象リポジトリの hooks / MCP を読み込まない |
| 資格情報 | App のトークンは `GIT_ASKPASS` 経由で渡し、リモート URL には埋め込まない |

`git push` と `gh pr create` は**エージェントにやらせず**、ラッパースクリプトがサンドボックス外で実行する。
そのため GitHub の認証情報がエージェントに渡ることはない。

### 実装上の注意

- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` を設定すると **permission mode が default に強制される**。
  権限は `settings/agent-settings.json` の allow / deny ルールだけで決まり、`--permission-mode` は効かない。
- `Read`/`Edit`/`Write` のパス制限は、`--settings` 経由ではプロジェクト相対 (`Write(/**)`) が効かない。
  worktree の絶対パスを実行時に注入している（`lib/run-task.sh`）。
- サンドボックスの `autoAllowBashIfSandboxed` は当環境では機能しなかったため、
  Bash は allow ルールで明示的に許可している。プロジェクト固有のコマンドは `EXTRA_ALLOWED_TOOLS` で追加する。

```bash
EXTRA_ALLOWED_TOOLS=('Bash(npm test:*)' 'Bash(npm run:*)')
```

## セキュリティ

- **`ALLOWED_ACTORS` は必須**。空だと `poll.sh` は起動を拒否する。
  Issue / PR コメントは第三者が書けるため、発行者を絞らないとプロンプトインジェクション経由の
  任意コード実行に直結する。
- システムプロンプトで、Issue 本文を「信頼できない入力」として扱うよう指示している（`prompts/issue.md`）。
- 対象は自分のリポジトリに限ること。他人のタスクを自分のサブスク枠で代行処理するのは、
  Claude Code の [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) が
  禁じる "resell or intermediate" に該当しうる。

## ファイル構成

```
config.env              設定（git 管理外）
poll.sh                 エントリポイント
setup.sh                ラベル作成と依存確認
lib/common.sh           設定読み込み・ログ・バリデーション
lib/github-app.sh       GitHub App 認証（JWT → installation token）
lib/budget.sh           利用枠ゲート（/usage のパース）
lib/discover.sh         タスク検出（ラベル / コメント）
lib/workspace.sh        clone と worktree の管理
lib/run-task.sh         claude -p の実行 → push → PR → コメント
prompts/                エージェントへの追加システムプロンプト
settings/               サンドボックスと権限の基本設定
state/                  処理済みコメント ID、ポーリング時刻、コスト実績
logs/<task-id>/         stream-json の生ログ、stderr、生成された settings
```

## 制限

- **ネットワークが遮断されているため、依存パッケージのインストールを伴うタスクは失敗する。**
  その場合エージェントは変更を加えず、理由を Issue にコメントする。
- 自動起動はしない。`./poll.sh` を手動で実行する設計（利用枠を張り付かせないため）。
  常用するなら systemd user timer を噛ませるとよいが、間隔は控えめにすること。
