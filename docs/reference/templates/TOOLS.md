---
title: "TOOLS.md Template"
summary: "Workspace template for TOOLS.md"
read_when:
  - Bootstrapping a workspace manually
---

# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## Device Tools Reference

These tools access iOS device features. Each requires the user to grant permission in Settings → Tools before use.

### Reminders

| Tool | Description |
|------|-------------|
| `reminders.list` | List reminders with title, due date, completion status |
| `reminders.add` | Create a new reminder |

**reminders.list** params: `status` (incomplete/completed/all), `limit`
**reminders.add** params: `title` (**required**), `dueISO` (ISO-8601), `notes`, `listName`

### Calendar

| Tool | Description |
|------|-------------|
| `calendar.events` | Query calendar events in a date range |
| `calendar.add` | Create a new calendar event |

**calendar.events** params: `startISO` (default: now), `endISO` (default: +7d), `limit`
**calendar.add** params: `title` (**required**), `startISO` (**required**), `endISO` (**required**), `isAllDay`, `location`, `notes`

### Contacts

| Tool | Description |
|------|-------------|
| `contacts.search` | Search contacts by name |
| `contacts.add` | Add a new contact |

**contacts.search** params: `query`, `limit`
**contacts.add** params: `givenName`, `familyName`, `phoneNumbers` (array), `emails` (array)

### Location

| Tool | Description |
|------|-------------|
| `location.get` | Get current GPS coordinates |

**location.get** params: `desiredAccuracy` (coarse/balanced/precise)

### Photos & Camera

| Tool | Description |
|------|-------------|
| `photos.latest` | Get recent photos from photo library (base64 JPEG) |
| `camera.snap` | Take a photo with device camera (app must be in foreground) |

**photos.latest** params: `limit`, `maxWidth` (px), `quality` (0.0–1.0)
**camera.snap** params: `facing` (back/front), `maxWidth` (px), `quality` (0.0–1.0)

### Motion & Fitness

| Tool | Description |
|------|-------------|
| `motion.activity` | Query motion activity history (walking, running, driving, cycling) |
| `motion.pedometer` | Query step count, distance, floors climbed |

**motion.activity** params: `startISO`, `endISO`, `limit`
**motion.pedometer** params: `startISO`, `endISO`

## Your Environment Notes

Add environment-specific notes below: camera names, SSH hosts, TTS voices, device nicknames, cron jobs.

```markdown
### Cron jobs

(Add your own periodic tasks here. Example format:)
- My task every 4 hours:
  - `schedule.kind = "every"`
  - `everyMs = 14400000`
  - `sessionTarget = "isolated"`
  - `payload.kind = "agentTurn"`
  - `payload.message = "Describe what the agent should do"`
```

---

Add whatever helps you do your job. This is your cheat sheet.
