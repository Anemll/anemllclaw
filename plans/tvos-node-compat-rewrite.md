# tvOS Node-Compat Rewrite Plan

## Goal

Run an OpenClaw-compatible local gateway runtime on Apple TV (tvOS) without relying on desktop Node runtime behavior.

## Constraints

- No assumption of full Node parity on tvOS.
- `child_process` semantics must be replaced, not emulated with OS process spawning.
- Gateway behavior must remain wire-compatible for existing OpenClaw clients.

## Current Facts (from codebase)

- Gateway and daemon control are TypeScript/Node-Bun based (`src/cli/gateway-cli`, `src/daemon`).
- Process-spawning is used broadly via `node:child_process` across gateway-adjacent infra and tooling.
- No direct `node:cluster` runtime use found in `src/`.

## Migration Strategy

1. Define a strict "Gateway Core Contract".
2. Build an in-process Swift runtime that implements only that contract.
3. Add compatibility adapters for request/response payloads.
4. Move Node-only capabilities behind feature gates and remote delegation.

## Core Contract (MVP)

- WebSocket server lifecycle.
- Session/auth handshake (token/password + TLS fingerprint policy if enabled).
- Gateway methods:
  - `health`
  - `status` (minimal)
  - control channel methods needed by iOS/tvOS/macOS clients for pairing and session operations.
- Discovery beacon advertisement and probing compatibility.

## Explicit Non-Goals (MVP)

- Shell command execution parity with Node CLI.
- Plugin runtime parity with arbitrary JS plugins.
- Daemon supervisors (`launchd/systemd/schtasks`) parity.

## `child_process` Replacement Model

Use a capability interface instead of direct process APIs:

1. `ProcessExecutionCapability` (protocol) with implementations:
   - `DisabledExecutionCapability` (tvOS default)
   - `RemoteExecutionCapability` (proxy to remote gateway)
   - `HostExecutionCapability` (future macOS-only)
2. Refactor gateway features that currently assume spawn/exec to depend on capability injection.
3. Return structured "unsupported-on-host" errors where neither local nor remote execution is enabled.

## Implementation Phases

### Phase 0 - Contract Freeze (1 week)

- Capture request/response schemas and method-level behavior from current gateway.
- Build golden fixtures for compatibility tests.

### Phase 1 - Swift Gateway Skeleton (2 weeks)

- Create Swift package `GatewayCoreSwift` (name placeholder).
- Implement ws accept loop, auth/session state, and `health` endpoint.
- Add integration tests against fixtures.

### Phase 2 - Compatibility Adapters (2-3 weeks)

- Implement status + pairing/session operations required by existing apps.
- Add compatibility test harness replaying fixture corpus.

### Phase 3 - Capability Gating (2 weeks)

- Introduce execution-capability abstraction.
- Route unsupported process features to explicit errors or remote gateway.

### Phase 4 - tvOS Host Integration (2 weeks)

- Embed runtime in `OpenClawTV`.
- Add lifecycle-safe start/stop/recover behavior.
- Add diagnostics UI (status, logs, capability matrix).

## First Backlog Items (ready now)

1. Add a "Gateway Core Contract" markdown spec with method list and JSON examples.
2. Add a fixture capture script in TS to snapshot canonical responses.
3. Add Swift test target that replays fixtures and validates schema/fields.
4. Add capability matrix doc (`supported`, `remote-only`, `unsupported`) for tvOS.

## Exit Criteria (MVP)

- Apple TV app starts local gateway and passes contract fixture tests.
- Existing OpenClaw iOS/macOS clients can connect and pass pairing + health flows.
- Unsupported Node-only features fail deterministically with typed errors.
