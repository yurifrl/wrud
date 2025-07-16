# What Are You Doing?

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

Key | Type | Default | Description
--- | ---- | ------- | -----------
`offsetX` / `offsetY` | number | 40 / centered | Palette window position
`width` / `height` | number | 600 / 60 | Palette size
`startSelected` | bool | true | Place cursor in field when palette appears
`intervalMinutes` | int | 30 | Minutes between automatic prompts
`logFile` | string | `log.md` | Absolute or relative path for Markdown log
`hotKey` | string | `cmd+shift+1` | Global shortcut to open palette
`closeOnBlur` | bool | true | Close palette when it loses focus
`showOnStart` | bool | true | Open palette immediately on app launch

## How it works

* Every prompt submission appends a checkbox entry `- [ ] task HH:MM` to the log file, grouped by date headers.
* The app schedules itself every *intervalMinutes* and can also be invoked any time via the global hot-key.
* Only one palette window is ever shown; attempts to open a second just focus the existing one.

---
Written in plain Swift, no third-party dependencies. 