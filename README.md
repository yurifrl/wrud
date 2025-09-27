# 🚨⚙️ What Are You Doing?

Small macOS floating command palette to quickly log tasks to a Markdown file.

## Quick start

```bash
# build & run in foreground
swift main.swift
```

### Background helpers (need [go-task](https://taskfile.dev))

```bash
# start in background, logs to logs/app.log
task run
# check status
task status
# stop
task stop
```

## Configuration (`config.json`)

Key                   | Type   | Default       | Description
----------------------|--------|---------------|----------------------------------------------
`offsetX` / `offsetY` | number | 40 / centered | Palette window position
`width` / `height`    | number | 600 / 60      | Palette size
`startSelected`       | bool   | true          | Place cursor in field when palette appears
`intervalMinutes`     | int    | 30            | Minutes between automatic prompts
`logFile`             | string | `log.md`      | Absolute or relative path for Markdown log
`hotKey`              | string | `cmd+shift+1` | Global shortcut to open palette
`closeOnBlur`         | bool   | true          | Close palette when it loses focus
`showOnStart`         | bool   | true          | Open palette immediately on app launch
`showDockIcon`        | bool   | false         | Show app icon in Dock (false = menu bar only)
`showMenuBarIcon`     | bool   | true          | Display clickable icon in system menu bar
`updateURL`           | string | -             | Optional releases URL for Check for Updates…

### File routing rules (`files`)

Use the optional `files` map to redirect prompts that match specific regexes. Each entry can point to a fixed file via `"file"` or, with this release, a directory via `"directory"` coupled with an optional `"fileMatch"` regex. When a directory is supplied the app picks the most recently modified file whose name matches the pattern, e.g. daily notes. Example:

```json
"files": {
  "10": {
    "promptMatch": "^dailies?",
    "directory": "~/Obsidian/Global/Dailies",
    "fileMatch": "^\\d{4}-\\d{2}-\\d{2}.*\\.md$",
    "filePositionMatch": "(?m)^## 📝 Tasks$",
    "insertBehavior": "endoflist"
  }
}
```

The sample above sends prompts beginning with `daily` to the latest dated note, appending entries underneath the Tasks heading.

## How it works

* Every prompt submission appends a checkbox entry `- [ ] task HH:MM` to the log file, grouped by date headers.
* The app schedules itself every *intervalMinutes* and can also be invoked any time via the global hot-key.
* Only one palette window is ever shown; attempts to open a second just focus the existing one.

---
Written in plain Swift, no third-party dependencies. 

## Build an installable .app

Requires [go-task](https://taskfile.dev) for convenience tasks.

```bash
# 1) Build an app bundle
task build-app

# 2) Install to ~/Applications
task install-app

# 3) (optional) Create a DMG for distribution
task package-dmg
```

After installation, launch from Spotlight: type "wrud".

## Updates

Add `updateURL` in `config.json` (e.g., a GitHub releases page). Use the menubar “Check for Updates…” to open it.

## Start at Login

Use the menubar toggle “Start at Login”. It manages a user LaunchAgent at `~/Library/LaunchAgents/dev.local.wrud.plist`.
