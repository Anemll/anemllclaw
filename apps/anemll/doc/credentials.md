# Skill Credentials System

## Overview

Skills like Notion and Trello require API keys. The credentials system provides device tools that let the LLM securely store and retrieve API keys via the iOS Keychain. Keys persist across sessions and are never exposed in chat logs or skill files.

## Architecture

```
LLM ──► credentials.get({ service: "notion" })
         │
         ▼
DeviceToolBridgeImpl.execute()
         │
         ▼
KeychainStore.loadString(
    service: "ai.openclaw.skill.notion",
    account: "api_key"
)
         │
         ▼
iOS Keychain (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
```

## Device Tools

### `credentials.get`

Retrieve a stored API key for a service.

**Parameters:**
```json
{ "service": "notion" }
```

**Response (key exists):**
```json
{ "ok": true, "service": "notion", "hasKey": true, "key": "ntn_abc123..." }
```

**Response (no key):**
```json
{ "ok": true, "service": "notion", "hasKey": false }
```

### `credentials.set`

Store an API key securely in the device keychain.

**Parameters:**
```json
{ "service": "notion", "key": "ntn_abc123..." }
```

**Response:**
```json
{ "ok": true, "service": "notion", "message": "API key stored securely" }
```

### `credentials.delete`

Remove a stored API key.

**Parameters:**
```json
{ "service": "notion" }
```

**Response:**
```json
{ "ok": true, "service": "notion", "message": "API key removed" }
```

## Keychain Naming Convention

| Component | Value |
|-----------|-------|
| Service prefix | `ai.openclaw.skill.` |
| Account | `api_key` |
| Full service | `ai.openclaw.skill.<service_name>` |

Examples:
- Notion: `service: "ai.openclaw.skill.notion"`, `account: "api_key"`
- Trello API key: `service: "ai.openclaw.skill.trello.key"`, `account: "api_key"`
- Trello token: `service: "ai.openclaw.skill.trello.token"`, `account: "api_key"`

This namespaces skill credentials separately from LLM provider keys (which use `service: "ai.openclaw.llm"`).

## Typical Flow

1. LLM receives a request that requires an API (e.g., "list my Notion pages")
2. LLM calls `credentials.get({ "service": "notion" })`
3. If `hasKey: false`:
   - The tool result `{ "hasKey": false, "service": "notion" }` is rendered in chat
   - The chat UI automatically shows a **credential prompt button**: "Set up API key for notion"
   - User taps the button → a secure entry sheet opens
   - User pastes the key → taps Save → key stored in Keychain via `KeychainStore`
   - The button changes to a green checkmark: "API key configured for notion"
   - LLM should tell the user to tap the button and then retry the request
4. If `hasKey: true`:
   - LLM uses the key in `network.fetch` headers
   - e.g., `"Authorization": "Bearer <stored_key>"`
5. Key persists across app restarts and chat sessions

### Chat Credential Prompt

When the chat UI renders a tool result, it checks two conditions:

1. The tool result's **name** is `"credentials.get"` (matched case-insensitively)
2. The tool result **text** is valid JSON containing `"hasKey": false` and a `"service"` string

If both match, a `CredentialPromptCard` button is rendered instead of (or alongside) the normal tool result card.

**Trigger format — the tool result message must have:**

```
role: "tool_result"          (or inline content type "tool_result")
name: "credentials.get"      (the tool name)
text: '{"ok":true,"service":"notion","hasKey":false}'   (JSON with hasKey: false)
```

The detection parses the `text` field as JSON and looks for:
```json
{
  "hasKey": false,      ← required, must be boolean false
  "service": "notion"   ← required, non-empty string — used as button label
}
```

If `hasKey` is `true` or missing, no button is shown (normal tool result display).

**This works even when "Show Tool Calls" is toggled off** in settings — the credential prompt card is always visible.

The credential save action is injected from the app layer via a SwiftUI environment value (`openClawCredentialSave`), bridging the shared `OpenClawKit` chat UI to the app's `KeychainStore`.

```
credentials.get returns hasKey: false
         │
         ▼
ChatMessageBody detects "credentials.get" in tool result
  - checks: result.name == "credentials.get"
  - parses: result.text as JSON
  - matches: json["hasKey"] == false && json["service"] exists
         │
         ▼
CredentialPromptCard renders button: "Set up API key for <service>"
         │  (user taps)
         ▼
CredentialEntrySheet opens (SecureField + Save)
         │  (user saves)
         ▼
openClawCredentialSave environment closure
         │
         ▼
KeychainStore.saveString(key, service: "ai.openclaw.skill.<service>", account: "api_key")
```

## Implementation Files

| File | Role |
|------|------|
| `Sources/Gateway/KeychainStore.swift` | Low-level Keychain CRUD (existing, reused) |
| `shared/.../GatewayLocalTooling.swift` | Command classification (`deviceCommands` array) |
| `Sources/Gateway/TVOSLocalGatewayRuntime.swift` | `DeviceToolBridgeImpl` — tool execution handlers |
| `Sources/TVOS/TVOSBootstrapTemplateStore.swift` | Skill templates that document the credentials tools |
| `Sources/Settings/SkillsSettingsView.swift` | Key status indicator in skill info sheet |
| `shared/.../ChatTextScale.swift` | `openClawCredentialSave` environment key |
| `shared/.../ChatMessageViews.swift` | `CredentialPromptCard`, `CredentialEntrySheet`, detection logic |
| `Sources/Chat/ChatSheet.swift` | Injects `openClawCredentialSave` with `KeychainStore` |
| `shared/.../Resources/tool-display.json` | Display config for credential tools (emoji, title) |

## Security

- Keys stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — not accessible before first device unlock
- Keys are device-bound — not included in iCloud backups
- The LLM is instructed never to log or display API keys in chat
- `credentials.get` returns keys only to the LLM's tool execution context, not to chat display
- The credential entry sheet uses `SecureField` — the key is never visible in the chat transcript
- Users can remove keys via the skill info sheet in Settings

## Service Name Conventions for Skills

| Skill | Service Name(s) |
|-------|----------------|
| Notion | `notion` |
| Trello | `trello.key`, `trello.token` |
| X (Twitter) | `x` |
| GitHub | `github` |
| Custom | Skill template defines its own service name |

The service name is flexible — the LLM decides the convention based on the skill template's documentation. Each skill template specifies what `credentials.get/set` service names to use.

## Writing Skills that Use Credentials

When creating a new skill that requires an API key, the skill template (`.md` file) should include a **Setup** section that documents the credential tools pattern:

```markdown
## Setup

Before making API calls, retrieve the stored key:

credentials.get({ "service": "<service_name>" })

If `hasKey` is `false`, the user will see a button in chat to enter their API key securely.
Tell the user to tap the "Set up API key" button, then retry.

If `hasKey` is `true`, use the returned key in your API calls.
```

The skill template should also document:
- What service name(s) to use (e.g., `"notion"`, `"trello.key"`)
- Where to get the API key (e.g., "Go to developer.x.com and copy your Bearer Token")
- How to use the key in `network.fetch` headers (e.g., `"Authorization": "Bearer <key>"`)
