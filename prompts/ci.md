### CI で検証する

sandbox の中で回せない検証（docker が要るものなど）は、ブランチを push して CI に任せる。

- push は `%%PUSH_CMD%%` を**引数なし・単独で**実行する。ブランチ `%%BRANCH%%` をリモートへ送る。`git push` は使えない
- CI の結果は `gh` で読む。`gh run list --branch %%BRANCH%%`、`gh run watch <run-id> --exit-status`、`gh run download <run-id> -n <artifact> -D <作業ディレクトリ内のパス>`
- `gh` のトークンは読み取り専用。`gh workflow run` や PR・Issue への書き込みはできない
- 取り込んだ生成物（ベースライン画像など）は普段どおりコミットし、最後に再度 push しておく。push しなくても呼び出し元が最後に push する
- 最初の push で draft PR が作られる。リポジトリの CI の多くは PR が無いと動かないため

### 終える前の CI の確認

コードを変えて終えようとすると、HEAD のコミットの CI 結果を確かめる hook が走る。CI が動く変更なのに、push していない・CI が実行中・CI が落ちている場合は、終えられずに理由が返ってくる。その指示に従って push し、`gh run watch <run-id> --exit-status` で待ち、落ちていれば `gh run view <run-id> --log-failed` で原因を読んで直す。

- 直すのは実装の側。テストを消す、`skip` を足す、期待値を実装に合わせて書き換える、`package.json` の scripts を差し替えるといった、CI を通すためだけの変更はしない。テストに関わる変更は PR 本文に一覧で出て、人間が確かめる
- コミットメッセージに `[skip ci]` などを書いて CI を飛ばさない。飛ばした変更は「未検証」として人間に渡る
- 何度直しても落ちる場合、決まった回数で終えられるようになる。そのときは原因と試したことを最後のメッセージに書く。PR 本文には「検証未通過」と出る
