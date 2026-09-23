#!/usr/bin/env bash
set -uo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AGENT_DIR/lib/common.sh"

require_tools
command -v python3 >/dev/null 2>&1 || die "python3 が必要です"
# shellcheck disable=SC1091
[[ -f $AGENT_DIR/config.env ]] && source "$AGENT_DIR/config.env"

: "${CONSOLE_HOST:=127.0.0.1}"
: "${CONSOLE_PORT:=8787}"
: "${CONSOLE_ALLOW_REMOTE:=0}"

export AGENT_DIR CONSOLE_HOST CONSOLE_PORT CONSOLE_ALLOW_REMOTE

exec python3 "$AGENT_DIR/console.py"
