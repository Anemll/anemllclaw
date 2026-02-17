#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HOST="${OPENCLAW_TVOS_LAN_HOST:-}"

if [[ $# -gt 0 && "$1" != --* ]]; then
  HOST="$1"
  shift
fi

if [[ -z "$HOST" ]]; then
  cat <<'EOF' >&2
Usage:
  scripts/dev/tvos-gateway-probe-lan.sh <apple-tv-lan-ip-or-hostname> [probe options]

Examples:
  scripts/dev/tvos-gateway-probe-lan.sh 192.168.1.45
  scripts/dev/tvos-gateway-probe-lan.sh 192.168.1.45 --tcp --auth token --token "$OPENCLAW_TVOS_GATEWAY_TOKEN"

Tip:
  You can also set OPENCLAW_TVOS_LAN_HOST and omit the positional host argument.
EOF
  exit 1
fi

exec "${ROOT_DIR}/scripts/dev/tvos-gateway-probe.sh" --host "$HOST" "$@"
