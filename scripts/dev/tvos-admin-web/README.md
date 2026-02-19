# OpenClaw tvOS Admin Web Client

This is a small browser client for the tvOS gateway control plane.

Important:
- This web client runs in a browser on your host machine.
- tvOS does not run shell scripts.
- The Apple TV app only exposes gateway listeners/RPC endpoints.

Supported RPC methods:
- `config.get`
- `config.set`
- `runtime.restart`
- `health` (quick connectivity probe)
- `cron.list` (view scheduled jobs)
- `pairing.list` (local Telegram pending pairing requests on tvOS)
- `pairing.approve` (approve a local Telegram pairing code on tvOS)

## Run

Open this file in your browser:

```text
scripts/dev/tvos-admin-web/index.html
```

## LAN usage

In the page:
- set `Gateway URL` to `ws://<apple-tv-lan-ip>:18789`
- set connect auth mode/token/password to match tvOS listener auth
- click `Connect`, then `Load Config`

## Notes

- `Save Config` calls `config.set` with a `settings` object.
- `Restart Runtime` calls `runtime.restart`.
- The page does not persist secrets; it stores URL + connect auth mode only.
- The admin page supports local Telegram pairing RPC (`pairing.list`/`pairing.approve`) for tvOS-only runtime.
- If you also run an upstream full gateway, CLI commands remain valid there:
  - `openclaw pairing list telegram`
  - `openclaw pairing approve telegram <CODE>`
