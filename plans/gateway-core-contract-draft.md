# Gateway Core Contract (Draft)

## Purpose

Define the minimum wire-level contract a non-Node gateway implementation must satisfy to interoperate with OpenClaw clients.

## Transport

- WebSocket, JSON messages.
- Request includes method name and optional params object.
- Response includes success payload or structured error.

## Authentication

- Support token/password auth currently used by clients.
- Preserve existing "auth required" behavior and error shape.

## Required Methods (MVP)

1. `health`
2. `status`
3. Pairing/session control methods needed by mobile/mac clients

## Error Model

Errors must be stable and typed:

- `AUTH_REQUIRED`
- `AUTH_FAILED`
- `METHOD_NOT_FOUND`
- `UNSUPPORTED_ON_HOST` (new; for Node-only capabilities on tvOS)
- `INTERNAL_ERROR`

## Compatibility Rules

- Do not rename existing method identifiers used by clients.
- Preserve required field names in responses.
- Additional fields are allowed if backward-compatible.

## Fixture Requirements

For each required method, maintain fixtures for:

1. Success response
2. Unauthorized response
3. Invalid params response
4. Host-unsupported response (when applicable)

## Open Questions

1. Exact list of pairing/session methods required by each client surface.
2. Whether any method currently depends on process execution side effects.
3. Canonical timeouts/retry behavior expected by clients.
