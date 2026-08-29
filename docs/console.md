# Web コンソール

`poll.sh` を一定間隔で自動実行しつつ、稼働状態とログをブラウザから見るためのコンソール。

```bash
./console.sh
# → http://127.0.0.1:8787
```

Python 3 の標準ライブラリだけで動く。スケジューラと HTTP サーバを 1 プロセスで持ち、時間が来たら
`poll.sh` を子プロセスとして起動して、その出力を `logs/console/poll-<日時>.log` に丸ごと残す。

## 画面

| 領域 | 内容 |
|---|---|
| 稼働状態 | 次回ポーリングまでのカウントダウン、実行間隔、最終ポーリング時刻、`poll.lock` の保持状況、累計コストと直近の 5h 枠 |
| スケジュール | 実行間隔の変更（`300` / `5m` / `1h` のいずれの書き方でも可）、一時停止と再開、今すぐ実行 |
| ポーリング履歴 | 実行ごとの終了コード・所要時間・検出/処理件数と、ログ本文（実行中のものは 2 秒ごとに追尾する） |
| タスクログ | `logs/<task-id>/` の結果・コスト・ターン数と、`stream.jsonl` を読み下したイベント列。ツール呼び出しは引数を項目ごとに整形する。各イベントの `raw` ボタンで対応する 1 行だけをモーダルで開けるほか、`stream.jsonl` 全体と `stderr.log` も原文のまま読める |

## 設定

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

## 常駐させる

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

## 注意

**コンソールは認証を一切持たない。** ここから `poll.sh` を起動できる = ローカルの `claude` を任意に走らせられる
ということなので、loopback 以外での待受は既定で拒否する。それでも公開する場合は `CONSOLE_ALLOW_REMOTE=1`
を設定したうえで、前段のリバースプロキシで認証をかけること。

