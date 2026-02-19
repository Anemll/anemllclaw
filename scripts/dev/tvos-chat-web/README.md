# OpenClaw tvOS Chat Web

Simple browser chat client for the tvOS gateway.

This is host-side tooling. tvOS does not run shell or Node scripts.

## Run

From repo root:

```bash
node /Users/anemll/SourceRelease/GITHUB/ML_playground/openclaw/scripts/dev/tvos-chat-web/server.mjs
```

Open:

```text
http://127.0.0.1:8088
```

## Use

1. Set `Gateway URL` (`ws://127.0.0.1:18789` for simulator, or `ws://<apple-tv-ip>:18789` for LAN).
2. Set auth mode/secret if listener auth is enabled.
3. Click `Connect`.
4. Enter a message and click `Send` (or press `Cmd/Ctrl+Enter`).

Implemented RPC flow:
- `connect`
- `chat.send`
- `chat.history`
- `health`
