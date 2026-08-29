# 実行環境と権限

## 隔離

タスクは `git worktree` で切り出した専用ディレクトリで実行する。囲いは次の多層。

| 層 | 内容 |
|---|---|
| ファイル | `Read`/`Edit`/`Write` はタスク用ディレクトリの絶対パス配下のみ許可 |
| シェル | Bash は必要なコマンドだけを明示許可。`rm` / `sudo` / `gh` / `curl` は拒否 |
| ネットワーク | `WebFetch` / `WebSearch` と `curl` / `wget` を拒否。allow する Bash に通信するコマンドを入れない |
| 認証情報 | `~/.ssh` `~/.config/gh` `~/.claude` を読み取り拒否、`GITHUB_TOKEN` 等を環境から除去 |
| 設定 | `--setting-sources ''` と `--strict-mcp-config` で、対象リポジトリの hooks / MCP を読み込まない |
| 資格情報 | App のトークンは `GIT_ASKPASS` 経由で渡し、リモート URL には埋め込まない |

`git push` と `gh pr create` は**エージェントにやらせない**。`poll.sh` 側が実行するので、
GitHub の認証情報はエージェントに渡らない。

### 作業ディレクトリの構成

エージェントの cwd は worktree ではなく、その 1 つ上のタスク用ディレクトリ。

```
worktrees/<task-id>/                   ← エージェントの cwd
worktrees/<task-id>/repo/              ← git worktree（対象リポジトリ）
worktrees/<task-id>/.mopu-agent-plan.json ← タスク分解の受け渡し用
```

`.mopu-agent-plan.json` をリポジトリの外に置けるので、`git status` の結果をそのまま
「変更を残したか」の判定に使える。

### 実装上の注意

- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` を設定すると **permission mode が default に強制される**。
  権限は `settings/agent-settings.json` の allow / deny ルールだけで決まり、`--permission-mode` は効かない。
- `Read`/`Edit`/`Write` のパス制限は、`--settings` 経由ではプロジェクト相対 (`Write(/**)`) が効かない。
  タスク用ディレクトリの絶対パスを実行時に注入している（`lib/run-task.sh`）。
- sandbox は無効（`settings/agent-settings.json` の `sandbox.enabled: false`）。
  bwrap が userns の制限で起動できない環境があるため。隔離は permissions の allow / deny だけで行い、
  Bash も allow ルールで明示的に許可する。プロジェクト固有のコマンドは `EXTRA_ALLOWED_TOOLS` で追加する。

```bash
EXTRA_ALLOWED_TOOLS=('Bash(npm test:*)' 'Bash(npm run:*)')
```

## セキュリティ

- **`ALLOWED_ACTORS` は必須**。空だと `poll.sh` は起動を拒否する。
  Issue / PR コメントは第三者が書けるため、発行者を絞らないとプロンプトインジェクション経由の任意コード実行に直結する。
- システムプロンプトで、Issue 本文を「信頼できない入力」として扱わせている（`prompts/issue.md`）。
- GitHub App 利用時は、**bot 自身（`app/<slug>` と `<slug>[bot]`）が `ALLOWED_ACTORS` に自動で加わる**。
  タスク分解で作られた sub issue の author は bot になるため、これがないと自動キューが機能しない。
  bot 名義で Issue を作れるのは秘密鍵の持ち主だけなので、第三者の迂回路にはならない。
- 対象は自分のリポジトリに限ること。他人のタスクを自分のサブスク枠で代行処理するのは、
  Claude Code の [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) が
  禁じる "resell or intermediate" に該当しうる。
