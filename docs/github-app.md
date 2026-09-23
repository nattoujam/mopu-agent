# GitHub App として投稿する

未設定だと Issue コメントも PR も**自分のアカウント名義**になり、手作業と見分けがつかない。
GitHub App を登録すると `<app-slug>[bot]` 名義になり、bot バッジが付く。**追加の GitHub アカウントは不要**。

App の登録・秘密鍵の生成・インストールの操作手順は公式ドキュメントに従う。

- [Registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
- [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
- [Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)

以下は mopu-agent 側で決まる値だけ。

## 登録時に指定する値

| 項目 | 値 |
|---|---|
| GitHub App name | 例 `nattoujam-mopu-agent`。グローバルに一意なので `mopu-agent` 単体は取れない可能性が高い |
| Homepage URL | 何でもよい（`https://github.com/nattoujam` など） |
| Webhook | **Active のチェックを外す**。既定は有効だが、ポーリング方式なので不要 |
| Where can this GitHub App be installed? | Only on this account |

Repository permissions は次の 4 つだけ与える。

| 権限 | レベル | 用途 |
|---|---|---|
| Contents | Read and write | ブランチの push |
| Issues | Read and write | コメント投稿、ラベル操作 |
| Pull requests | Read and write | PR の作成、レビュアーの指定 |
| Metadata | Read-only | 必須（自動で付く） |

## コンソールで登録する

コンソール（`./console.sh`）の「設定」タブの下にある「GitHub App」で、App ID と、
ダウンロードした `.pem`（ファイル選択か中身の貼り付け）を入れて「登録」を押す。

登録後の表示は App ID、bot 名、登録日時と、秘密鍵の **SHA-256 フィンガープリント**だけ。鍵の中身は画面にも
API にも出ない。フィンガープリントは GitHub の App 設定画面の「Private keys」に出る値と同じ計算なので、
どの鍵を登録したかはそこで照合できる。

登録した鍵は編集できない。差し替えるときは「削除」してから登録し直す。GitHub 側には鍵を複数置けるので、
先に新しい鍵を発行しておけば、bot 名義で投稿できない時間は画面操作のあいだだけで済む。
以降、Issue コメント・PR・コミットのすべてが bot 名義になる。

## 仕組みと注意点

- JWT は RS256 固定。`iat` を 60 秒過去に、`exp` を上限の 10 分先に置いている（`lib/github-app.sh`）
- installation access token は **1 時間で失効**する。ポーリングごとに取り直す（プロセス内でキャッシュ）
- コミットの author は `<bot-user-id>+<slug>[bot]@users.noreply.github.com`。この形式にすると GitHub 上で App のアイコンが表示される
- 秘密鍵は `state/secrets/github-app.pem`（ディレクトリ 700、ファイル 600）に置かれ、App ID などは
  `state/settings.json` の `github_app` に入る。`state/` はエージェントの sandbox から読めない。
  鍵が 600 でないと `poll.sh` は起動を拒否する
- コンソールと鍵のやりとりをするので、`CONSOLE_ALLOW_REMOTE=1` で公開するなら前段は必ず TLS にすること
- **App が作成した PR は GitHub Actions を発火しない。** 対象リポジトリで CI を回しているなら影響する
