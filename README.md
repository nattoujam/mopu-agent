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

PR で指示した場合も、ブランチ・ラベル・sub issue は元 Issue 側で扱われる（[タスクの制御](docs/task-flow.md)を参照）。

### オプション

| オプション | 説明 |
|---|---|
| `--dry-run` | 検出したタスクを表示するだけ |
| `--task <番号>` | 指定した Issue だけを処理（ラベル不要、同時進行ゲートも無視） |
| `--retry <番号>` | 失敗したタスクを、残った作業ツリーと会話ごと引き継いで再開 |
| `--ignore-budget` | 利用枠のゲートを無視 |

`--retry` は前回のタスクをそのまま再現する。コメントでトリガーしたタスクなら、
指示だったコメント本文も引き継がれる（`logs/<タスクID>/task.json` に控えてある）。

## 制限

- **ネットワークが遮断されているため、依存パッケージのインストールを伴うタスクは失敗する。**
  その場合エージェントは変更を加えず、理由を Issue にコメントする。
- `poll.sh` 単体では自動起動しない（利用枠を張り付かせないため）。定期実行するなら
  [Web コンソール](docs/console.md)（`./console.sh`）を使う。間隔は控えめにすること。

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [GitHub App として投稿する](docs/github-app.md) | bot 名義で投稿するための設定（任意） |
| [Web コンソール](docs/console.md) | 定期実行とログ閲覧の画面 |
| [タスクの制御](docs/task-flow.md) | 作成される PR、タスク分解、同時進行の制限、利用枠のゲート |
| [実行環境と権限](docs/isolation.md) | エージェントに与えている権限と、その境界 |
| [開発](docs/development.md) | 動作検証の方法とファイル構成 |

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
