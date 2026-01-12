# Punk Records

Your screen, recorded. Your context, shared with Claude. Stop explaining what you were just doing—Claude already knows.

## What It Does

Punk Records captures your screen every few seconds, runs OCR, and exports structured context to a folder Claude Desktop can read. **Hourly summaries. Daily digests. Intent extraction.** Not raw screenshots, but what you were actually doing.

## Who It's For

People who live in Claude and are tired of re-explaining their work context every conversation. Developers, founders, power users who want Claude to just **know** what's going on. This is a tool for maybe 500 people on earth. You might be one of them.

## Requirements

- Mac (Apple Silicon)
- macOS 13.0 (Ventura) or later
- Claude Desktop with filesystem MCP connector
- Comfort with your AI seeing everything you do

## Installation

1. Download from [Releases](https://github.com/punkrecords/punk-records/releases)
2. Drag to Applications
3. Grant Screen Recording and Accessibility permissions when prompted
4. Configure Claude Desktop to read from `~/punk-records-data/`

## Privacy

**100% local.** Nothing leaves your machine. No cloud, no analytics, no telemetry. The data lives in a folder on your Mac. You own it. Delete it whenever you want.

## Data Storage

1. **Database & Videos**: `~/Library/Application Support/punk.records/`
   - `db.sqlite3` - SQLite database with OCR text and metadata
   - `output-*.mp4` - Video chunks (auto-cleaned after 1 hour)

2. **Exports for Claude**: `~/punk-records-data/`
   - Daily folders organized as `YYYY-MM-DD/`
   - Individual captures as `.md` files with YAML frontmatter
   - Hourly summaries and daily journals as JSON

## Export Format

Individual captures are exported as Markdown:

```markdown
---
timestamp: 2026-01-12T02:35:04Z
app: Safari
frame_id: 632
window_title: "YouTube - Home"
url: https://youtube.com
session_id: Safari-0235
session_duration: 180
---

youtube.com
...OCR text content here...
```

Hourly and daily summaries remain JSON for structured aggregation.

## Configuration

Access settings via the menu bar icon:

- **Launch at startup**: Auto-start when you log in
- **Include clipboard text**: Save copied text with screenshots
- **Fast OCR mode**: Trade accuracy for speed
- **OCR active window only**: Only process the focused window

## Keyboard Shortcuts

- `Cmd+Shift+F` - Open search view
- `Esc` - Close timeline or search view

## Troubleshooting

**"Screen Recording permission denied"**
- System Settings → Privacy & Security → Screen Recording
- Enable Punk Records, then restart the app

**"No data appearing"**
- Check recording is enabled (green indicator in menu bar)
- Verify permissions are granted
- Check `~/Library/Application Support/punk.records/` for data

## License

Proprietary. All rights reserved.

---

Built by [Useful Ventures](https://useful.ventures)

Named after the thing from One Piece, obviously. 🏴‍☠️
