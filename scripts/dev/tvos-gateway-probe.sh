#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HOST="${OPENCLAW_TVOS_GATEWAY_HOST:-127.0.0.1}"
WS_PORT="${OPENCLAW_TVOS_GATEWAY_WS_PORT:-18789}"
TCP_PORT="${OPENCLAW_TVOS_GATEWAY_TCP_PORT:-18790}"
SCHEME="${OPENCLAW_TVOS_GATEWAY_SCHEME:-ws}"
AUTH_MODE="${OPENCLAW_TVOS_GATEWAY_AUTH_MODE:-none}"
TOKEN="${OPENCLAW_TVOS_GATEWAY_TOKEN:-}"
PASSWORD="${OPENCLAW_TVOS_GATEWAY_PASSWORD:-}"
TIMEOUT_MS="${OPENCLAW_TVOS_GATEWAY_TIMEOUT_MS:-8000}"
PROBE_TCP=0
PROBE_STATUS=1

usage() {
  cat <<'EOF'
Usage:
  scripts/dev/tvos-gateway-probe.sh [options]

Options:
  --local                   Force localhost target (127.0.0.1).
  --host <host>             Target host/IP (default: 127.0.0.1).
  --ws-port <port>          WebSocket port (default: 18789).
  --tcp-port <port>         TCP debug port (default: 18790).
  --scheme <ws|wss>         WebSocket scheme (default: ws).
  --tcp                     Also probe TCP debug listener.
  --no-status               Skip "status" request in WS probe.
  --auth <none|token|password>
                            Gateway auth mode (default: none).
  --token <token>           Token value when --auth token.
  --password <password>     Password value when --auth password.
  --timeout-ms <ms>         Per-probe timeout in milliseconds (default: 8000).
  --help                    Show this help text.

Environment overrides:
  OPENCLAW_TVOS_GATEWAY_HOST
  OPENCLAW_TVOS_GATEWAY_WS_PORT
  OPENCLAW_TVOS_GATEWAY_TCP_PORT
  OPENCLAW_TVOS_GATEWAY_SCHEME
  OPENCLAW_TVOS_GATEWAY_AUTH_MODE
  OPENCLAW_TVOS_GATEWAY_TOKEN
  OPENCLAW_TVOS_GATEWAY_PASSWORD
  OPENCLAW_TVOS_GATEWAY_TIMEOUT_MS
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_integer() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    fail "$label must be an integer"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      HOST="127.0.0.1"
      shift
      ;;
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --ws-port)
      WS_PORT="${2:-}"
      shift 2
      ;;
    --tcp-port)
      TCP_PORT="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --tcp)
      PROBE_TCP=1
      shift
      ;;
    --no-status)
      PROBE_STATUS=0
      shift
      ;;
    --auth)
      AUTH_MODE="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      TIMEOUT_MS="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$SCHEME" in
  ws|wss) ;;
  *) fail "--scheme must be ws or wss" ;;
esac

case "$AUTH_MODE" in
  none|token|password) ;;
  *) fail "--auth must be one of: none, token, password" ;;
esac

require_integer "$WS_PORT" "ws port"
require_integer "$TCP_PORT" "tcp port"
require_integer "$TIMEOUT_MS" "timeout-ms"

if [[ "$AUTH_MODE" == "token" && -z "$TOKEN" ]]; then
  fail "--token is required when --auth token"
fi

if [[ "$AUTH_MODE" == "password" && -z "$PASSWORD" ]]; then
  fail "--password is required when --auth password"
fi

if ! command -v node >/dev/null 2>&1; then
  fail "node is required (Node 22+ recommended)"
fi

printf '==> tvOS gateway probe target: %s://%s:%s\n' "$SCHEME" "$HOST" "$WS_PORT"
if [[ "$PROBE_TCP" == "1" ]]; then
  printf '==> tcp debug probe target: tcp://%s:%s\n' "$HOST" "$TCP_PORT"
fi

export OPENCLAW_PROBE_HOST="$HOST"
export OPENCLAW_PROBE_WS_PORT="$WS_PORT"
export OPENCLAW_PROBE_TCP_PORT="$TCP_PORT"
export OPENCLAW_PROBE_SCHEME="$SCHEME"
export OPENCLAW_PROBE_AUTH_MODE="$AUTH_MODE"
export OPENCLAW_PROBE_TOKEN="$TOKEN"
export OPENCLAW_PROBE_PASSWORD="$PASSWORD"
export OPENCLAW_PROBE_TIMEOUT_MS="$TIMEOUT_MS"
export OPENCLAW_PROBE_TCP_ENABLED="$PROBE_TCP"
export OPENCLAW_PROBE_STATUS_ENABLED="$PROBE_STATUS"

cd "$ROOT_DIR"

node - <<'NODE'
const crypto = require("node:crypto");
const net = require("node:net");

const config = {
  host: process.env.OPENCLAW_PROBE_HOST || "127.0.0.1",
  wsPort: Number(process.env.OPENCLAW_PROBE_WS_PORT || "18789"),
  tcpPort: Number(process.env.OPENCLAW_PROBE_TCP_PORT || "18790"),
  scheme: process.env.OPENCLAW_PROBE_SCHEME || "ws",
  authMode: process.env.OPENCLAW_PROBE_AUTH_MODE || "none",
  token: process.env.OPENCLAW_PROBE_TOKEN || "",
  password: process.env.OPENCLAW_PROBE_PASSWORD || "",
  timeoutMs: Number(process.env.OPENCLAW_PROBE_TIMEOUT_MS || "8000"),
  probeTcp: process.env.OPENCLAW_PROBE_TCP_ENABLED === "1",
  probeStatus: process.env.OPENCLAW_PROBE_STATUS_ENABLED !== "0",
};

const wsURL = `${config.scheme}://${config.host}:${config.wsPort}`;

if (typeof WebSocket === "undefined") {
  console.error("FAIL: global WebSocket is unavailable; use Node 22+.");
  process.exit(3);
}

function makeConnectParams() {
  const params = {
    minProtocol: 3,
    maxProtocol: 3,
    client: {
      id: "openclaw.tvos.probe",
      displayName: "OpenClaw tvOS Probe",
      version: "0.0.0-dev",
      platform: "probe",
      mode: "gateway-smoke",
    },
    role: "operator",
    scopes: ["operator.admin"],
  };

  if (config.authMode === "token") {
    params.auth = { token: config.token };
  } else if (config.authMode === "password") {
    params.auth = { password: config.password };
  }
  return params;
}

function gatewayErrorText(frame) {
  if (!frame || typeof frame !== "object") {
    return "unknown gateway error";
  }
  const error = frame.error;
  if (!error || typeof error !== "object") {
    return "unknown gateway error";
  }
  const code = typeof error.code === "string" ? error.code : "UNKNOWN";
  const message = typeof error.message === "string" ? error.message : "unknown";
  return `${code}: ${message}`;
}

function withTimeout(ms, onTimeout) {
  let timer = null;
  const start = () =>
    new Promise((_, reject) => {
      timer = setTimeout(() => {
        onTimeout();
        reject(new Error(`timeout after ${ms}ms`));
      }, ms);
    });
  const clear = () => {
    if (timer) {
      clearTimeout(timer);
    }
  };
  return { start, clear };
}

async function probeWebSocket() {
  return new Promise((resolve, reject) => {
    let done = false;
    let challengeSeen = false;
    let connectOk = false;
    let healthOk = false;
    let statusOk = !config.probeStatus;

    const connectID = `connect-${crypto.randomUUID()}`;
    const healthID = `health-${crypto.randomUUID()}`;
    const statusID = `status-${crypto.randomUUID()}`;

    const ws = new WebSocket(wsURL);
    const timeout = withTimeout(config.timeoutMs, () => {
      try {
        ws.close();
      } catch {}
    });

    const timeoutPromise = timeout.start().catch((error) => {
      if (!done) {
        done = true;
        reject(new Error(`WebSocket probe timeout (${wsURL}): ${error.message}`));
      }
    });
    void timeoutPromise;

    const finish = (result) => {
      if (done) {
        return;
      }
      done = true;
      timeout.clear();
      try {
        ws.close();
      } catch {}
      resolve(result);
    };

    const fail = (error) => {
      if (done) {
        return;
      }
      done = true;
      timeout.clear();
      try {
        ws.close();
      } catch {}
      reject(error instanceof Error ? error : new Error(String(error)));
    };

    ws.addEventListener("error", (event) => {
      fail(new Error(`WebSocket error (${wsURL})`));
    });

    ws.addEventListener("close", () => {
      if (!done) {
        fail(new Error(`WebSocket closed before probe finished (${wsURL})`));
      }
    });

    ws.addEventListener("open", () => {
      ws.send(
        JSON.stringify({
          type: "req",
          id: connectID,
          method: "connect",
          params: makeConnectParams(),
        }),
      );
    });

    ws.addEventListener("message", (event) => {
      const text =
        typeof event.data === "string"
          ? event.data
          : Buffer.isBuffer(event.data)
            ? event.data.toString("utf8")
            : String(event.data);
      let frame;
      try {
        frame = JSON.parse(text);
      } catch {
        return;
      }

      if (!frame || typeof frame !== "object") {
        return;
      }

      if (frame.type === "event" && frame.event === "connect.challenge") {
        challengeSeen = true;
        return;
      }

      if (frame.type !== "res") {
        return;
      }

      if (frame.id === connectID) {
        if (!frame.ok) {
          fail(new Error(`connect failed: ${gatewayErrorText(frame)}`));
          return;
        }
        connectOk = true;
        ws.send(JSON.stringify({ type: "req", id: healthID, method: "health" }));
        return;
      }

      if (frame.id === healthID) {
        if (!frame.ok) {
          fail(new Error(`health failed: ${gatewayErrorText(frame)}`));
          return;
        }
        healthOk = true;
        if (config.probeStatus) {
          ws.send(JSON.stringify({ type: "req", id: statusID, method: "status" }));
        } else {
          finish({ challengeSeen, connectOk, healthOk, statusOk });
        }
        return;
      }

      if (frame.id === statusID) {
        if (!frame.ok) {
          fail(new Error(`status failed: ${gatewayErrorText(frame)}`));
          return;
        }
        statusOk = true;
        finish({ challengeSeen, connectOk, healthOk, statusOk });
      }
    });
  });
}

async function probeTCP() {
  const payload = {
    request: {
      type: "req",
      id: `tcp-health-${crypto.randomUUID()}`,
      method: "health",
    },
  };

  if (config.authMode === "token") {
    payload.auth = { token: config.token };
  } else if (config.authMode === "password") {
    payload.auth = { password: config.password };
  }

  return new Promise((resolve, reject) => {
    let done = false;
    let buffer = "";

    const socket = net.createConnection({ host: config.host, port: config.tcpPort });
    socket.setEncoding("utf8");
    socket.setNoDelay(true);

    const timeout = setTimeout(() => {
      if (!done) {
        done = true;
        socket.destroy();
        reject(new Error(`TCP probe timeout after ${config.timeoutMs}ms`));
      }
    }, config.timeoutMs);

    const finish = (value) => {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timeout);
      socket.end();
      resolve(value);
    };

    const fail = (error) => {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timeout);
      socket.destroy();
      reject(error instanceof Error ? error : new Error(String(error)));
    };

    socket.on("error", (error) => {
      fail(new Error(`TCP connection failed (${config.host}:${config.tcpPort}): ${error.message}`));
    });

    socket.on("connect", () => {
      socket.write(`${JSON.stringify(payload)}\n`);
    });

    socket.on("data", (chunk) => {
      buffer += chunk;
      const newlineIndex = buffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }

      const line = buffer.slice(0, newlineIndex).trim();
      if (!line) {
        fail(new Error("TCP probe received empty response"));
        return;
      }

      let frame;
      try {
        frame = JSON.parse(line);
      } catch (error) {
        fail(new Error(`TCP probe received invalid JSON: ${line}`));
        return;
      }

      if (!frame.ok) {
        fail(new Error(`tcp health failed: ${gatewayErrorText(frame)}`));
        return;
      }

      finish({ ok: true });
    });

    socket.on("close", () => {
      if (!done) {
        fail(new Error("TCP socket closed before receiving a response"));
      }
    });
  });
}

async function main() {
  console.log(`==> probing WebSocket ${wsURL}`);
  const wsResult = await probeWebSocket();
  const statusText = config.probeStatus ? String(wsResult.statusOk) : "skipped";
  console.log(
    `PASS websocket connect=${wsResult.connectOk} health=${wsResult.healthOk} status=${statusText} challengeSeen=${wsResult.challengeSeen}`,
  );

  if (config.probeTcp) {
    console.log(`==> probing TCP debug tcp://${config.host}:${config.tcpPort}`);
    await probeTCP();
    console.log("PASS tcp health");
  }
}

main().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exit(2);
});
NODE
