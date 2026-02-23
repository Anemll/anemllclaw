# Dream Mode

## Overview

Dream Mode is an experimental background processing feature that activates when the device has been idle for a configurable period. While the user is away, the LLM runs a structured cycle of memory consolidation and creative exploration. When the user returns, a short digest summarises what happened.

The system consists of three layers:

1. **Visual overlay** — full-screen ambient animation with status pill
2. **Artifact pipeline** — deterministic `dream/` directory for all dream outputs
3. **Heartbeat integration** — the cron/heartbeat system triggers dreams and delivers results

## Architecture

```
User goes idle (> threshold)
         │
         ▼
UserIdleTracker.idleSeconds > idleThresholdSeconds
         │
         ▼
DreamModeManager.evaluateAutoTrigger()
  ├─ checks cooldownUntil (4-hour window)
  ├─ checks interaction epoch (one dream per idle session)
  └─ calls enterDream()
         │
         ├─► DreamView overlay appears (selected animation)
         ├─► DreamStateStore persists run to dream/state.json
         └─► Heartbeat LLM picks up dream via get_idle_time + dream_mode tools
                  │
                  ├─ Consolidate memory (temp 0.1–0.3)
                  ├─ Explore hypotheses (temp 0.7–1.1)
                  ├─ Critic/gate scoring (temp 0.1–0.2)
                  ├─ Write dream/journal/YYYY-MM-DD.md
                  ├─ Write dream/digest.md
                  └─ dream_mode({ "action": "exit" })
                           │
                           ├─► DreamRetentionCleaner runs
                           └─► DreamModeManager.wake()

User returns (idle < 5 min)
         │
         ▼
evaluateDigestDelivery() → pendingDigestPath set
         │
         ▼
Next heartbeat reads dream/digest.md → delivers as chat message
```

## Artifact Directory

All dream outputs live under `dream/` in the workspace root, separate from `memory/` to avoid mixing speculative content with grounded recall.

```
dream/
├── state.json              ← run bookkeeping (native code only — do not edit)
├── digest.md               ← short wake summary (overwritten each run)
├── journal/
│   └── YYYY-MM-DD.md       ← verbose audit trail (14-day retention)
├── patches/
│   └── *.patch              ← proposed diffs, never auto-applied (7-day retention)
└── archive/                 ← optional compressed old journals
```

**Key rules:**
- The LLM writes to `dream/` using the `write` tool, never `memory.append`
- `dream/state.json` is managed by native code only
- `dream/` is excluded from `memory.search` results
- Retention cleanup runs automatically on dream exit and app launch

## Device Tools

### `dream_mode`

Enter, exit, or query dream mode state.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `action` | string | yes | `"enter"`, `"exit"`, or `"status"` |
| `outputRoot` | string | no | Directory for artifacts (default `"dream"`) |
| `writeMode` | string | no | `"patches"` (default) or `"apply_safe"` |

**Response:**

```json
{
  "ok": true,
  "command": "dream_mode",
  "action": "enter",
  "dream_state": "dreaming",
  "dream_enabled": true,
  "runId": "a1b2c3d4-...",
  "outputRoot": "dream",
  "writeMode": "patches"
}
```

On `"exit"`, the native handler calls `DreamRetentionCleaner` to prune old journals (>14 days) and patches (>7 days).

### `get_idle_time`

Returns idle duration and dream-related state for heartbeat decision-making.

**Parameters:** none

**Response:**

```json
{
  "ok": true,
  "command": "get_idle_time",
  "idle_seconds": 1842,
  "last_interaction_at": "2026-02-23T08:15:00Z",
  "dream_state": "awake",
  "dream_enabled": true,
  "idle_threshold_seconds": 600,
  "pending_digest_path": "dream/digest.md",
  "cooldown_until": "2026-02-23T16:30:00Z"
}
```

## Heartbeat Integration

The heartbeat/cron system runs every 5 seconds. On each tick the LLM follows the instructions in `HEARTBEAT.md`:

### A) Start dream when idle

If `idle_seconds > idle_threshold_seconds` and `dream_enabled` is true and no active cooldown:

1. Call `dream_mode({ "action": "enter" })` → receive `runId` and `outputRoot`
2. Run the dream cycle (consolidate → explore → critic)
3. Write journal to `dream/journal/YYYY-MM-DD.md`
4. Write digest to `dream/digest.md` (< 1200 chars)
5. Optionally write patches to `dream/patches/<name>.patch`
6. Call `dream_mode({ "action": "exit" })` to trigger cleanup
7. Respond `HEARTBEAT_OK` (silent — user is away)

### B) Deliver digest on return

If `idle_seconds < 300` and `pending_digest_path` is set:

1. Read `dream/digest.md`
2. Summarise findings as a chat message to the user
3. Native code marks digest as delivered (won't re-send)

## Dream Cycle

The LLM follows the `DREAM.md` template during a dream run. The recommended phases:

| Phase | Temperature | Goal |
|-------|------------|------|
| **Consolidate** | 0.1–0.3 | Summarise, deduplicate, tag, link, normalise grounded memory |
| **Explore** | 0.7–1.1 | Generate candidate ideas, plans, hypotheses |
| **Critic / Gate** | 0.1–0.2 | Score hypotheses for value and plausibility |

### Task Families

- **A) Consolidation** — memory dedup, summarisation, cross-linking
- **B) Maintenance** — read-only scans for stale or broken references
- **C) Exploration** — high-temperature ideation, what-if scenarios
- **D) Meta / Self-Improvement** — process upgrades, workflow optimisation

### Digest Format

```markdown
**Grounded changes:** consolidations, links, dedup performed (2–3 bullets)
**Hypotheses:** H1–H3 with title, summary, expected impact, verification plan
**Verify next:** 1–3 actions to take on wake
**Patches available:** list filenames if any
```

## State Management

### DreamStateStore

Persists `dream/state.json` atomically with `NSLock` for thread safety (accessed from both `@MainActor` and non-isolated contexts).

**Fields in `DreamRunState`:**

| Field | Purpose |
|-------|---------|
| `lastRunId` | UUID of most recent dream run |
| `lastRunAt` | ISO 8601 start time |
| `pendingDigestPath` | Path to digest ready for delivery |
| `deliveredForInteraction` | Epoch key when digest was last delivered |
| `lastDreamForInteraction` | Epoch key to prevent duplicate dreams |
| `cooldownUntil` | ISO 8601 — no new dream before this time |

### Cooldown

After a dream exits, a 4-hour cooldown prevents re-entry even if the device remains idle. This avoids burning compute on repeated back-to-back dream runs.

### Interaction Epoch

Each idle period is keyed by the epoch-seconds of `lastInteractionAt`. A dream only runs once per epoch — if the user briefly taps the screen and goes idle again, the same epoch is detected and the dream is skipped until the user actually interacts meaningfully.

## Animations

Six ambient animations are available, selectable in Settings:

| Animation | SF Symbol | Description |
|-----------|-----------|-------------|
| Flame Pulse | `flame.fill` | Warm radial gradient that breathes in and out |
| Aurora | `sparkles` | Slow-moving northern-lights colour bands |
| Starfield | `star.fill` | Classic forward-flying star tunnel |
| Breathing Orb | `circle.circle` | Soft pulsing circle with glow |
| Flurry | `wind` | Particles drifting through a gradient field |
| Flurry Classic | `wind.circle` | macOS Flurry-style glowing ribbon trails |

## Settings

Located at **Settings > Device > Dream Mode**:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Enable Dream Mode | Toggle | Off | Master switch for automatic activation |
| Idle Threshold | Picker | 10 min | Options: 10 min, 30 min, 1 hr, 2 hr, 4 hr |
| Animation | Tile grid | Flame Pulse | Live thumbnail preview for each animation |
| Preview | Display | — | Large preview of selected animation |

## UI Components

### DreamView

Full-screen overlay shown during dreaming. Renders the selected animation on a black background with a `DreamStatusPill` at the bottom. Tap anywhere to wake.

### DreamStatusPill

Floating capsule at the bottom of the screen showing:
- Moon icon (`moon.zzz.fill`)
- Current task label (e.g., "Consolidating memory…") or default "Dreaming…"

### IdleTouchPassthroughView

Transparent view layered over the app that captures touch events to update `UserIdleTracker.recordInteraction()` while passing them through to underlying views.

## Interrupt Events

Dream mode ends immediately when:
- User taps the screen
- User sends a chat message
- LLM calls `dream_mode({ "action": "exit" })`
- App returns from background
- Heartbeat interrupt signal fires

## Guardrails

- **No external side-effects** — dreams don't send messages, make API calls, or modify files outside `dream/`
- **Reversible trail** — all outputs are in `dream/` with journal audit trail
- **Confidence separation** — grounded facts vs. hypotheses are labelled distinctly
- **Interruptibility** — any user interaction ends the dream immediately
- **Bounded compute** — best-effort < 10% CPU average during dream cycles
- **Memory isolation** — `dream/` excluded from `memory.search` and `memory.append`

## Implementation Files

| File | Role |
|------|------|
| `Sources/Dream/DreamModeManager.swift` | State machine, auto-trigger, cooldown, digest delivery |
| `Sources/Dream/DreamStateStore.swift` | Atomic JSON persistence for `dream/state.json`, retention cleaner |
| `Sources/Dream/UserIdleTracker.swift` | Touch-based idle time tracking |
| `Sources/Dream/DreamView.swift` | Full-screen animation overlay |
| `Sources/Dream/DreamStatusPill.swift` | Floating status capsule |
| `Sources/Dream/IdleTouchPassthroughView.swift` | Touch passthrough for idle tracking |
| `Sources/Dream/Animations/*.swift` | Six animation implementations |
| `Sources/Gateway/TVOSLocalGatewayRuntime.swift` | `dream_mode` and `get_idle_time` tool handlers |
| `Sources/Settings/SettingsTab.swift` | Dream Mode settings UI |
| `Sources/RootCanvas.swift` | Auto-trigger and digest delivery polling (30s loop) |
| `Sources/TVOS/TVOSBootstrapTemplateStore.swift` | DREAM.md and HEARTBEAT.md templates |
| `shared/.../GatewayLocalMethodRouter.swift` | Tool definitions |
| `shared/.../Resources/tool-display.json` | Tool display config (emoji, detail keys) |
