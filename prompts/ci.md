### CI で検証する

sandbox の中で回せない検証（docker が要るものなど）は、ブランチを push して CI に任せる。

- push は `%%PUSH_CMD%%` を**引数なし・単独で**実行する。ブランチ `%%BRANCH%%` をリモートへ送る。`git push` は使えない
- CI の結果は `gh` で読む。`gh run list --branch %%BRANCH%%`、`gh run watch <run-id> --exit-status`、`gh run download <run-id> -n <artifact> -D <作業ディレクトリ内のパス>`
- `gh` のトークンは読み取り専用。`gh workflow run` や PR・Issue への書き込みはできない
- 取り込んだ生成物（ベースライン画像など）は普段どおりコミットし、最後に再度 push しておく。push しなくても呼び出し元が最後に push する
