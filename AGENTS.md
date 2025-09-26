# Repository Guidelines

## Project Structure & Module Organization
The app lives in `main.swift`, written in plain AppKit-based Swift with no external dependencies. Runtime configuration defaults come from `config.json`; contributors can add sample configs but keep defaults minimal. Background helpers and release packaging scripts reside in `Taskfile.yml`. Logs produced by background runs collect under `logs/`. Generated artifacts such as `wrud.app` or DMGs should remain uncommitted.

## Build, Test, and Development Commands
Run the palette in the foreground with `swift main.swift`, which recompiles and launches directly. For background execution with log capture use `task run`, and stop or inspect the worker via `task stop` and `task status`. Package a minimal app bundle with `task build-app`; follow with `task install` to copy into `~/Applications`, or `task package-dmg` to ship a DMG. Use `task purge` to kill stray processes if Startup toggles misbehave.

## Coding Style & Naming Conventions
Follow Swift API Design Guidelines: types in `UpperCamelCase`, properties and functions in `lowerCamelCase`. Indent using four spaces and group related sections with `// MARK:` comments. Prefer small extensions over large files; split `main.swift` only when cohesive subsystems emerge. Keep user-facing strings centralized for easier localization, and guard optional config lookups to avoid runtime crashes.

## Testing Guidelines
Automated tests are currently absent; when adding them prefer XCTest targets mirroring the runtime module name. Name files `FeatureNameTests.swift` and group under `Tests/`. For manual verification, confirm palette launch, global hotkey responsiveness, and log entries in the configured Markdown file. When altering timers or file rules, simulate multiple prompts to ensure no duplicate scheduling.

## Commit & Pull Request Guidelines
Use imperative, descriptive commit subjects (e.g., `Add menu item for manual prompt`). Include focused commits rather than batching unrelated tweaks. PRs should describe user-facing impact, config migrations, and any new background tasks. Link tracking issues when available and attach screenshots or screen recordings for UI changes so reviewers can validate styling quickly.

## Configuration Tips
Document new config keys inside `README.md` and keep `config.json` sample values conservative. Avoid committing personal paths; prefer placeholders like `~/Documents/log.md`. If a change touches launch agent behavior, remind users to reload via the menu bar toggle.
