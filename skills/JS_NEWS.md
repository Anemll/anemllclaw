# JavaScript News Scanner

Fetch and parse JavaScript-rendered news sites that don't offer clean RSS.

## The Problem

Standard `network.fetch` gets raw HTML — but JS-heavy sites render content client-side. You get an empty page or just `<div id="app"></div>`.

## ✅ Solution: web.render (Primary)

**Use `web.render` first** — it hydrates JS and extracts clean text with metadata.

```javascript
web.render({
  url: "https://techcrunch.com",
  maxChars: 8000  // optional, default varies
})
```

### Returns:
```json
{
  "title": "TechCrunch | Startup and Technology News",
  "text": "Full rendered text content...",
  "links": [{ "href": "...", "text": "..." }],
  "metadata": {
    "hydrationSignals": 4,
    "usedHydrationExtraction": true,
    "normalized": true,
    "renderer": "local-minimal",
    "signals": ["next", "json-script"]
  },
  "truncated": true
}
```

### Tested & Working Sites:
| Site | Status |
|------|--------|
| TechCrunch | ✅ |
| The Verge | ✅ |
| Wired | ✅ |
| Reuters | ✅ |

## Alternative: RSS Feeds

When `web.render` isn't needed or fails, try RSS first:

- TechCrunch: `https://techcrunch.com/feed/`
- The Verge: `https://www.theverge.com/rss/index.xml`
- Wired AI: `https://www.wired.com/feed/tag/ai/latest/rss`
- Ars Technica: `https://feeds.arstechnica.com/arstechnica/index`
- BBC: `https://feeds.bbci.co.uk/news/rss.xml`
- NYT: `https://rss.nytimes.com/services/xml/rss/nyt/World.xml`

## Legacy: Jina AI (Backup)

⚠️ **Rate-limited as of Feb 2026** — use only as fallback.

```bash
https://r.jina.ai/http://[target URL]
```

---

## 🍎 Apple News Sources

### Primary: Apple Newsroom (RSS)
Official Apple press releases — clean and reliable.
- **RSS:** `https://www.apple.com/newsroom/rss-feed.rss`
- **Web:** `https://www.apple.com/newsroom`

### Third-Party: Use web.render

| Site | URL | RSS Available |
|------|-----|---------------|
| **9to5Mac** | `https://9to5mac.com` | ✅ `https://9to5mac.com/feed` |
| **MacRumors** | `https://macrumors.com` | ❌ |
| **AppleInsider** | `https://appleinsider.com` | ❌ |
| **9to5Mac (subsite)** | `https://9to5google.com` | ✅ |

### Apple RSS Feeds

- 9to5Mac: `https://9to5mac.com/feed`
- Apple Newsroom: `https://www.apple.com/newsroom/rss-feed.rss`

### Sample Headlines (Feb 2026)

**9to5Mac:**
- iOS 26.4 beta 1: Notification Forwarding, search on iCloud.com
- AirPods Pro 3 second model coming with IR cameras
- Apple March 4 event: What to expect

**MacRumors:**
- Apple Announces Special Event in New York, London, and Shanghai on March 4
- iOS 26.4 Brings CarPlay Support for ChatGPT, Claude and Gemini
- Apple Working on Three AI Wearables: Smart Glasses, AI Pin, and AirPods With Cameras
- Low-Cost MacBook Expected on March 4

**AppleInsider:**
- OLED iPad Mini release date & pricing
- macOS Tahoe 26.4 displays warnings for apps that won't work after Rosetta 2 ends
- Everything new in iOS 26.4 beta 1

## Usage Priority

1. **Try `web.render`** — works for most JS sites
2. **Fall back to RSS** — if available and web.render fails
3. **Jina AI** — last resort, rate-limited

## Limitations

- **No screenshots** — extracts text only
- **Some paywalls** — may not bypass subscription walls
- **Large pages** — may be truncated (use `maxChars` to control)
- **Metadata varies** — some sites provide more than others
