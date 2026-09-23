# 実行環境と権限

## 境界

タスクは `git worktree` で切り出した専用ディレクトリで実行する。境界は Claude Code の
sandbox（Linux では bubblewrap）が OS レベルで引き、その中ではエージェントは自由に動く。

| | 方針 | 実現 |
|---|---|---|
| 書き込み | タスク用ディレクトリと一時ディレクトリだけ | sandbox の既定 |
| 読み取り | 自由。ただし秘密は不可 | `~/.claude` `~/.ssh` `~/.aws` `~/.config` `config.env` `state/` App 鍵を `denyRead` |
| 実行 | 自由（`node` も `npx` も `npm ci` も） | sandbox 内のコマンドは自動承認。allow リストは持たない |
| 調査 | `WebFetch` / `WebSearch` は自由 | permission で allow |
| Bash からの通信 | パッケージレジストリだけ | `allowedDomains` + `strictAllowlist` |

`git push` と `gh pr create` は**エージェントにやらせない**。`poll.sh` 側が実行するので、
GitHub の認証情報はエージェントに渡らない。

### 作業ディレクトリの構成

```
worktrees/<task-id>/                        ← 書き込みを許す範囲
worktrees/<task-id>/repo/                   ← git worktree（エージェントの cwd）
worktrees/<task-id>/.mopu-agent-plan.json   ← タスク分解の受け渡し用
worktrees/<task-id>/.npm-cache, .cache/     ← npm / XDG のキャッシュ
```

plan とキャッシュをリポジトリの外に置くことで、`git status` の結果をそのまま
「変更を残したか」の判定に使える。キャッシュは `~/.npm` や `~/.cache` が sandbox から
書けないためタスク側に持たせており、タスクごとに作り直しになる。

### ホストが後で実行する git を守る

worktree のコミットは共有の `repos/<slug>/.git` に書かれるので、そこだけ書き込みを開けている。
ただし次の 3 つは閉じる。ホストが `git push` を実行するときに読まれ、任意コードの実行経路になるため。

- `repos/<slug>/.git/hooks`
- `repos/<slug>/.git/config`
- `worktrees/<task-id>/repo/.git`（gitdir を指すファイル。書き換えると別の hooks を差し込める）

### 通信

`WebFetch` / `WebSearch` は Claude Code 本体のツールで sandbox の管轄外。Bash から届くのは
`allowedDomains` のホストだけで、`curl ... | sh` の形を通さないためにそうしている。

`WebFetch` の allow は `WebFetch(domain:*)` ではなく素の `WebFetch` にしてある。
`domain:` 付きは sandbox の許可ドメインにも流れ込み、Bash の通信まで開いてしまう。

pip や cargo を使うリポジトリが来たら、そのレジストリを `allowedDomains` に足す。

## 前提

Ubuntu 24.04 以降は AppArmor の既定ポリシーで bubblewrap がユーザー名前空間を作れない。
[公式ドキュメント](https://code.claude.com/docs/en/sandboxing)のとおりプロファイルを 1 つ足す。

```bash
sudo tee /etc/apparmor.d/bwrap > /dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
sudo systemctl reload apparmor
```

`failIfUnavailable` を立てているので、sandbox が起動できない環境ではタスクが始まらない。
`poll.sh` の起動時にも `bwrap` の自己診断で落とす。

## CI で検証する

`docker` は sandbox と非互換で、中では動かない。コンテナが要る検証（VRT など）は
エージェントがブランチを push して CI に任せ、結果と artifact を `gh` で読む。

- push は `tools/push-branch` が sandbox の外で動く。`excludedCommands` は compound command の
  一部が一致すると全体を sandbox の外で走らせるため、`&&` で繋いだ呼び出しや `$(...)` を含む
  引数は PreToolUse フック（`tools/guard-host-commands`）で弾く。allow ルールだけでは防げない
- `gh` には App の installation token を読み取り権限に絞って渡す。`actions:write` を渡すと
  リポジトリ内の dispatch 可能なワークフロー全部（デプロイ系を含む）を起動できてしまうため
- `workflow_dispatch` は `tools/dispatch-workflow` 経由で、`DISPATCH_WORKFLOWS` に列挙した
  ワークフローだけ起動できる。デプロイ系は列挙しないこと
- `*.blob.core.windows.net` は artifact のダウンロード先。`gh run download` は
  `api.github.com` からそこへリダイレクトされる

**App に `Actions` の権限が要る**。結果を読むだけなら Read、`DISPATCH_WORKFLOWS` を使うなら
Read and write。付いていないとエージェント用トークンの発行が 422 で失敗し、そのタスクでは
`gh` が使えない（push はできる）。App 設定の Permissions で追加し、インストール側で承認する。

GitHub App を使わない構成では、`gh` の認証情報（`~/.config/gh`）が sandbox から読めないため
`gh` は使えない。push はホストの認証で通る。

## できないこと

- `don't ask mode` で拒否される書き方がある。`&` でのバックグラウンド実行、`VAR=x cmd` の
  環境変数の前置、作業ディレクトリの外への `cd` は Claude Code が prompt に回すため、
  sandbox の自動承認を通らない。ログでこの拒否を見ても sandbox の不具合ではない。
  プロンプトではスクリプトに書いて `bash ./script.sh` で実行するよう伝えている

## 依存の準備

`SETUP_CMD` は任意で、ホスト権限で worktree 作成の直後に実行される。出力は
`logs/<task-id>/setup.log` に残り、失敗したときは Issue にも返る。

## セキュリティ

- **タスクを受け付けるユーザー（`ALLOWED_ACTORS`）は必須**。空だと `poll.sh` は起動を拒否する。
  Issue / PR コメントは第三者が書けるため、発行者を絞らないとプロンプトインジェクション経由の任意コード実行に直結する。
- システムプロンプトで、Issue 本文を「信頼できない入力」として扱わせている（`prompts/issue.md`）。
- GitHub App 利用時は、**bot 自身（`app/<slug>` と `<slug>[bot]`）が `ALLOWED_ACTORS` に自動で加わる**。
  タスク分解で作られた sub issue の author は bot になるため、これがないと自動キューが機能しない。
  bot 名義で Issue を作れるのは秘密鍵の持ち主だけなので、第三者の迂回路にはならない。
- sandbox は完全な隔離境界ではない。公式ドキュメントの Limitations が挙げるとおり、
  TLS を覗かないため広いドメインを許すと持ち出し経路になりうる。`allowedDomains` は狭く保つ。
- 対象は自分のリポジトリに限ること。他人のタスクを自分のサブスク枠で代行処理するのは、
  Claude Code の [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) が
  禁じる "resell or intermediate" に該当しうる。
