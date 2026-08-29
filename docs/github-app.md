# GitHub App として投稿する

未設定だと Issue コメントも PR も**あなた自身のアカウント名義**になり、手作業と見分けがつかない。
GitHub App を登録すると `<app-slug>[bot]` 名義になり、bot バッジが付く。**追加の GitHub アカウントは不要**。

App の登録・秘密鍵の生成・インストールの操作手順は公式ドキュメントに従う。

- [Registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
- [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
- [Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)

以下は mopu-agent 側で決まる値だけを書く。

## 登録時に指定する値

| 項目 | 値 |
|---|---|
| GitHub App name | 例 `nattoujam-mopu-agent`（グローバルに一意なので `mopu-agent` 単体は取れない可能性が高い） |
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

## 秘密鍵の配置と設定

ダウンロードした `.pem` を置く。

```bash
mkdir -p ~/.config/mopu-agent
mv ~/Downloads/*.private-key.pem ~/.config/mopu-agent/app.pem
chmod 600 ~/.config/mopu-agent/app.pem
```

`config.env` に App ID と鍵のパスを設定する。

```bash
APP_ID='123456'
APP_PRIVATE_KEY='~/.config/mopu-agent/app.pem'
```

## 確認

```bash
./setup.sh
# → GitHub App として動作します: nattoujam-mopu-agent[bot]
```

以降、Issue コメント・PR・コミットのすべてが bot 名義になる。

## 仕組みと注意点

- App の JWT は RS256 固定。`iat` を 60 秒過去に、`exp` を上限の 10 分先に置いている（`lib/github-app.sh`）
- installation access token は **1 時間で失効**するため、ポーリングごとに取り直す（プロセス内でキャッシュ）
- コミットの author には `<bot-user-id>+<slug>[bot]@users.noreply.github.com` を使う。
  この形式にすると GitHub 上で App のアイコンが表示される
- 秘密鍵は `config.env` ごと `.gitignore` 済み。`chmod 600` でないと警告が出る
- **App が作成した PR は GitHub Actions のワークフローをトリガーしない。**
  対象リポジトリで CI を回しているなら、この点だけ運用に影響する
