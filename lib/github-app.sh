#!/usr/bin/env bash

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# GitHub App の JWT は RS256 固定。iat は時計ずれ対策で 60 秒過去に置き、
# exp は仕様上の上限が 10 分先
app_jwt() {
  local now header payload signature
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -binary -sign "$APP_PRIVATE_KEY" | b64url) || return 1
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# installation access token は 1 時間で失効する。ポーリング 1 回のあいだは
# 使い回せるので、プロセス内でキャッシュする
APP_TOKEN=""
APP_TOKEN_EXPIRES=0

app_token() {
  local now jwt
  now=$(date +%s)
  if [[ -n $APP_TOKEN ]] && (( now < APP_TOKEN_EXPIRES - 300 )); then
    printf '%s' "$APP_TOKEN"
    return 0
  fi

  jwt=$(app_jwt) || { err "JWT の生成に失敗しました（秘密鍵を確認してください）"; return 1; }

  local install_id
  install_id=$(GH_TOKEN="" gh api -H "Authorization: Bearer $jwt" \
    "repos/$REPO/installation" --jq '.id' 2>/dev/null)
  if [[ -z $install_id ]]; then
    err "App が $REPO にインストールされていません（またはApp ID/秘密鍵が不正です）"
    return 1
  fi

  local resp
  resp=$(GH_TOKEN="" gh api -X POST -H "Authorization: Bearer $jwt" \
    "app/installations/$install_id/access_tokens" 2>/dev/null) || return 1

  APP_TOKEN=$(jq -r '.token // empty' <<<"$resp")
  [[ -n $APP_TOKEN ]] || { err "installation access token を取得できませんでした"; return 1; }
  APP_TOKEN_EXPIRES=$(date -d "$(jq -r '.expires_at' <<<"$resp")" +%s 2>/dev/null || echo $((now + 3600)))
  printf '%s' "$APP_TOKEN"
}

# bot のコミット author 名義。App の bot ユーザー ID は変わらないので一度だけ引く
APP_BOT_NAME="" APP_BOT_EMAIL=""

app_bot_identity() {
  [[ -n $APP_BOT_EMAIL ]] && return 0
  local jwt slug uid
  # GET /app は JWT 専用で、installation access token では 401 になる
  jwt=$(app_jwt) || return 1
  slug=$(GH_TOKEN="" gh api -H "Authorization: Bearer $jwt" app --jq '.slug' 2>/dev/null)
  [[ -n $slug ]] || return 1
  uid=$(gh api "users/${slug}[bot]" --jq '.id' 2>/dev/null)
  [[ -n $uid ]] || return 1
  APP_BOT_NAME="${slug}[bot]"
  APP_BOT_EMAIL="${uid}+${slug}[bot]@users.noreply.github.com"
}

use_github_app() {
  [[ -n ${APP_ID:-} && -n ${APP_PRIVATE_KEY:-} ]]
}

# App を使う場合、gh と git push の両方をこのトークンで通す
setup_app_auth() {
  use_github_app || return 0
  [[ -f $APP_PRIVATE_KEY ]] || die "秘密鍵が見つかりません: $APP_PRIVATE_KEY"

  local tok
  tok=$(app_token) || die "GitHub App の認証に失敗しました"
  export GH_TOKEN="$tok"

  if app_bot_identity; then
    export GIT_AUTHOR_NAME="$APP_BOT_NAME"  GIT_AUTHOR_EMAIL="$APP_BOT_EMAIL"
    export GIT_COMMITTER_NAME="$APP_BOT_NAME" GIT_COMMITTER_EMAIL="$APP_BOT_EMAIL"
    # 分解で作られた sub issue の author は bot 自身になるため、許可アクターに
    # 加えないと次のポーリングで弾かれる。bot 名義で Issue を作れるのは秘密鍵の
    # 持ち主だけなので、第三者の迂回には使えない。
    # gh の author.login は "app/<slug>"、REST の user.login は "<slug>[bot]"
    ALLOWED_ACTORS+=" app/${APP_BOT_NAME%\[bot\]} $APP_BOT_NAME"
    log "GitHub App として動作します: $APP_BOT_NAME"
  else
    warn "App の bot 情報を取得できませんでした。コミット author は既定値になります"
  fi
}

# push は認証情報をURLに埋めず、資格情報ヘルパー経由で渡す
app_git_askpass() {
  local helper="$STATE_DIR/askpass.sh"
  cat > "$helper" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) echo "x-access-token" ;;
  *)          echo "$GH_TOKEN" ;;
esac
EOF
  chmod 700 "$helper"
  printf '%s' "$helper"
}
