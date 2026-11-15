#!/usr/bin/env bash
set -uo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AGENT_DIR/lib/common.sh"

require_tools
build_tools || die "bin/ のビルドに失敗しました"
# shellcheck disable=SC1091
[[ -f $AGENT_DIR/config.env ]] && source "$AGENT_DIR/config.env"

: "${CONSOLE_HOST:=127.0.0.1}"
: "${CONSOLE_PORT:=8787}"
: "${CONSOLE_ALLOW_REMOTE:=0}"

export AGENT_DIR CONSOLE_HOST CONSOLE_PORT CONSOLE_ALLOW_REMOTE

exec "$MOPU_BIN" console
