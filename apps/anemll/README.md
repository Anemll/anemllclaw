AnemllClaw (pronounced "Animal Claw") is a port and fork of OpenClaw that runs a full OpenClaw server on-device on Apple iOS and tvOS. To our knowledge, this is the first OpenClaw server implementation for iOS.

The initial motivation was to experiment with local model workflows and to learn how OpenClaw works internally.

## Goals

The primary goal is to run on-device models so that as much work as possible stays on the device instead of being sent to external providers. Because of the sandboxed environment, bash, TypeScript, and self-modifying code are not supported. On the flip side, this makes it fairly safe to use out of the box.

AnemllClaw keeps all the original OpenClaw workspace files, so the agent adapts to your needs over time just like the upstream project. The full file set:

- **SOUL.md** -- agent core philosophy, personality, and behavioral principles
- **IDENTITY.md** -- agent self-description (name, creature type, vibe, emoji, avatar)
- **USER.md** -- human user profile (name, pronouns, timezone, interests)
- **MEMORY.md** -- long-term curated memory that persists across sessions
- **memory/** -- daily session logs (dated `YYYY-MM-DD.md` files)
- **AGENTS.md** -- workspace operating principles, safety rules, and action boundaries
- **TOOLS.md** -- local configuration (device nicknames, TTS preferences, SSH hosts, etc.)
- **HEARTBEAT.md** -- periodic background check tasks (email, calendar, notifications)
- **BOOTSTRAP.md** -- first-run onboarding ritual (removed once identity setup is complete)
- **skills/** -- skill definition files (e.g. `JS_NEWS.md` for web research)

## Features

**Multi-Provider Support** -- Select, configure, and switch between multiple LLM providers at runtime. Currently supports all major APIs, including local models. Tested with: Anthropic, OpenAI, Grok, and MiniMax. Each provider can be configured with its own base URL, API key, model name, and tool-calling mode.

**OpenClaw Server on tvOS** -- Run a full OpenClaw server natively on Apple TV. Includes TCP and WebSocket transport, local method routing, session management, SQLite-backed memory store, and a web-based admin panel for diagnostics and control.

**New Local Tools** -- AnemllClaw adds tools that are not part of standard OpenClaw:

- `web.render` -- fetches a URL, renders JavaScript, and returns clean extracted text with links and metadata. Also accepts raw HTML or text input.
- `web.extract` -- lightweight content extraction from HTML, text, or a URL without JS rendering.
- `ls` -- list files and directories inside the workspace (with optional recursive mode, sandboxed, capped at 500 entries).
- `credentials.get` / `credentials.set` / `credentials.delete` -- securely store and retrieve per-skill API keys in the iOS Keychain. When a key is missing, a "Set up API key" button appears automatically in the chat UI.

**Tool Management** -- Individual tools can be enabled or disabled from Settings > Tools, letting you reduce noise for workflows that don't need certain capabilities.

**Skills** -- Several skills are pre-installed (JS News, Notion, Trello, X/Twitter API Search, GitHub, and more). Additional skills can be added to the `skills/` directory. Skills can be inspected, copied, and deleted from Settings > Skills. Each skill's credential requirements are shown in the inspector with one-tap setup.

**Backup and Restore** -- Create and restore compressed, encrypted backups of chat history, workspace files, settings, and keychain credentials.

**Full-Screen Message View** -- Tap any message to open it in a full-screen view for easier reading of long or markdown-rich responses on iOS.

**Text Scaling** -- Adjustable text zoom across the chat UI with five scale levels for improved readability.

**Copy & Clear** -- Every chat bubble has a copy button for quick clipboard access. A "Clear Conversation" option in the composer menu permanently deletes all messages in the current session. A "Continue" button resumes interrupted tool-calling loops.

**macOS Support** -- A macOS chat interface with integrated settings, provider management, and text scaling.

## Getting Started

### 1. LLM Provider Setup

On first launch the OpenClaw server starts on-device. The app detects that no LLM provider is configured and prompts you to set one up. You only need one provider to get started:

1. Tap **"Open Settings"** (or navigate to Settings > LLM Providers).
2. Tap **"Add Provider"**, choose a provider type (OpenAI, Anthropic, MiniMax, or Grok), and enter your **API key**. The base URL and model are pre-filled with sensible defaults.
3. Tap **"Save, Restart & Test"** -- the app sends a test probe and shows pass/fail with a response preview.

That's it -- you are ready to chat. You can always add more providers later and switch between them from the chat toolbar.

### 2. Start Chatting

Once a provider is configured:

- Open the **Chat** tab. The composer is ready at the bottom of the screen.
- If you have two or more providers, use the **model switcher** in the top bar to pick which one to use.
- Adjust **text zoom** from the top-bar menu if needed.

### 3. Backup and Restore

In Settings you can back up and restore your entire OpenClaw state. A backup captures:

- **Workspace files** -- chat history and workspace data
- **Settings** -- all UserDefaults (provider configurations, preferences, etc.)
- **Keychain credentials** -- API keys and auth tokens

To create a backup, tap **"Backup to Files"** in Settings. The app produces a single compressed `.ocbackup` file (LZFSE-compressed, tagged with app version and date) that you can save via the system file picker.

To restore, tap **"Restore from Backup"**, select an `.ocbackup` file, and confirm. The app validates the archive version and bundle ID before restoring. Existing data is cleared and replaced with the backup contents.

## Debugging and Web Access

For security reasons, WebSocket access is **disabled by default** -- the server only accepts connections from localhost. To allow access from another device on your local network (e.g. a laptop browser), enable **LAN Access** in Settings.

This repo includes two standalone HTML tools that connect to the on-device server over WebSocket:

- **`scripts/dev/tvos-admin-web/index.html`** -- Admin panel for diagnostics, server status, and reading/writing workspace files and settings.
- **`scripts/dev/tvos-chat-web/index.html`** -- Web-based chat interface for sending messages and viewing conversations from a browser.

Open either file in a browser, point it at the device's WebSocket endpoint, and you can inspect or manage the server state without touching the device itself.

### Inspecting .ocbackup Files

The `.ocbackup` format is a 4-byte `OCB1` magic header followed by LZFSE-compressed JSON. Two shell scripts are provided to unpack and repack backups on macOS:

```bash
# Unpack a backup into a folder (requires: brew install lzfse)
scripts/dev/ocbackup-unpack.sh  MyBackup.ocbackup  output-dir/

# Re-pack an edited folder back into a .ocbackup file
scripts/dev/ocbackup-pack.sh  output-dir/  MyBackup-edited.ocbackup
```

The unpacked folder contains:

- `files/` -- workspace files (SOUL.md, MEMORY.md, skills/, etc.)
- `defaults.plist` -- UserDefaults (inspect with `plutil -p defaults.plist`)
- `keychain.json` -- keychain credentials (contains API keys -- handle with care)
- `archive.json` -- full raw archive for reference

## Clone & Build

```bash
git clone https://github.com/Anemll/anemllclaw.git
cd anemllclaw
git checkout anemll-ios-app
```

Open the Xcode project:

```bash
open apps/anemll/AnemllClaw.xcodeproj
```

### Build Targets

| Scheme | Platform | Description |
|--------|----------|-------------|
| **AnemllClaw** | iOS 18+ | Runs on iPhone, iPad, and Vision Pro |
| **AnemllClawTV** | tvOS 18+ | Runs on Apple TV |

In Xcode, select the scheme from the scheme picker:
- **AnemllClaw** for iOS / iPadOS / visionOS
- **AnemllClawTV** for tvOS

Then build & run (Cmd+R).

### Requirements

- Xcode 16.0+
- Swift 6.0
- macOS with Homebrew (for build-phase linters):
  ```bash
  brew install swiftformat swiftlint
  ```

### Dependencies

All Swift packages are included in the repo under `apps/anemll/shared/`:
- **OpenClawKit** -- Core SDK, chat UI, and protocol
- **OpenClawGatewayCore** -- On-device gateway server

No `pod install` or `swift package resolve` needed -- SPM dependencies resolve automatically on first build.

## Release Notes

See [release-notes/](release-notes/) for per-date changelogs. Latest: [2026-02-22](release-notes/2026-02-22.md).

## Notes

During development AnemllClaw turned out to be quite useful as a daily tool for online research and news collection. Even with a primarily web-focused chat UI, the ability to modify skills enables many different workflows and iterative self-improvement.

Let me know if this repo is useful, to add other skills or harness extensions.
