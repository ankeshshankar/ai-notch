# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AI Notch is a macOS 15+ app that sits under the notch and shows coding-agent sessions (Claude Code, Cursor, Codex, Gemini CLI, OpenCode, other agents found as processes), with permission prompts, usage and cost, and other panels (builds, pull requests, Datadog health, machine guard, VPN). It is a SwiftPM package with no Xcode project. The README is the user-facing spec, so update it when behaviour changes.

## Agents

The repo's agents in `.claude/agents/` take over from the user-level ones here:

| Request | Agent |
| --- | --- |
| Where is X, how does Y work, which files a change touches | `notch-scout` (Haiku, read-only) |
| Any code change, bug or feature; builds and verifies | `notch` |
| Review the uncommitted change before a commit | `notch-reviewer` (read-only) |
| Prepare a release: version, notes, DMG | `notch-release` (never pushes) |

Usual flow: `notch-scout` finds the files, `notch` makes the change with them, `notch-reviewer` checks it. Skip the scout when the files are already known, and skip the reviewer for copy tweaks.

## Commands

```sh
swift build -c release                  # .build/release/AINotch, ai-notch-hook, ai-notch-vpnd
scripts/install.sh                      # build, assemble, sign and replace the installed copy, then restart it
scripts/make-dmg.sh                     # dist/AI-Notch-<version>.dmg (drives Finder via AppleScript)
scripts/build-openvpn.sh                # once, optional: OpenVPN into .build/openvpn (without it the app has no VPN)
.build/release/ai-notch-vpnd selfcheck  # the only check CI runs besides the build
```

There are no XCTest or Swift Testing targets. Verification uses self-check launch modes (each exits 1 on failure), stub servers and Python scripts:

- `AINotch --pr-selfcheck`, `--prod-alerts-selfcheck`, `--machine-selfcheck scripts/dev/machine-fixtures.json`; `ai-notch-vpnd selfcheck`
- `python3 scripts/dev/test-setup.py` (setup logic in temporary homes), `python3 scripts/dev/test-datadog-oauth.py`
- `AINotch --preview [--theme light|dark] [--collapsed|--hover]` opens an always-expanded copy mid-screen for screenshots. It uses its own approvals socket, so it does not disturb the installed app. `AINotch --setup-preview` opens the setup window by itself.
- `CLAUDE_NOTCH_SESSIONS=<dir>` points the app and the hook at a fake sessions folder. To make sample sessions, pipe hook-event JSON into `.build/release/ai-notch-hook`; `scripts/dev/ci-screenshots.sh` shows how.

`scripts/dev/README.md` documents every dev flag, stub server (`bitbucket-stub.py`, `datadog-stub.py`, `datadog-oauth-stub.py`) and `CLAUDE_NOTCH_*` variable. Read it before testing a feature against a stub.

## Architecture

**Targets** (`Package.swift`):

- `NotchCore`: the session-state model, data paths, the approval socket protocol, limits and the widget snapshot. The hook, the app and the widget all share it.
- `ai-notch-hook`: a small executable that each agent runs on every hook event. It does not link AppKit.
- `AINotch`: the app (AppKit + SwiftUI, links sqlite3).
- `VPNCore` + `ai-notch-vpnd`: a root launch daemon that runs OpenVPN for the app over `/var/run/info.ankeshshiv.notch.vpn.sock`.
- `Widget/SessionsWidget.swift` is **not** a SwiftPM target. `scripts/assemble-app.sh` compiles it with `swiftc`, together with `NotchCore/WidgetSnapshot.swift`, and only for team-signed builds (`NOTCH_SIGN_IDENTITY` and `NOTCH_TEAM_ID`). Ad-hoc builds have no widget.

**Session flow.** Setup writes hook entries into `~/.claude/settings.json`, `~/.cursor/hooks.json`, `~/.codex/hooks.json` and `~/.gemini/settings.json`, plus an OpenCode plugin. Each entry is an absolute path into the app bundle: `ai-notch-hook [cursor|codex|gemini|report]`. The hook folds each event into `~/.claude/notch/sessions/<id>.json` under an flock. It must never block or change a session: it always exits 0, and prints only an approval answer, Gemini's `{}`, or the wrapped status line. `SessionStore.reload()` reads that folder every 0.5 s and merges in `AgentWatcher`'s rows, which come from a process scan every 3 s. The result drives `NotchView`, and `SessionStore` also writes `widget.json` to the app group for the widget.

**Approvals** are the only synchronous path. On `PermissionRequest`, the hook connects to `~/.claude/notch/approvals.sock` (0600, both ends check the uid) and blocks. `ApprovalCenter` holds the connection until a click or a hotkey answers it. If the editor answers first, or the app is gone, the hook exits silently and Claude Code asks the user as usual. `AskRules` mirrors Claude Code's ask rules to decide whether to offer "Allow for session".

**Usage and cost.** `UsageScanner` reads agent transcripts incrementally every 15 s: `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions`, Qwen's chats and OpenCode's SQLite database. It writes `~/.claude/notch/usage-ledger.json`. When the ledger format changes, bump `Ledger.currentVersion`: an older ledger keeps only its archive and is rebuilt. Anthropic prices are hardcoded in `UsageScanner`; `PriceBook` covers other models from LiteLLM, cached daily. `limits.json` comes from the hook's `statusline` wrapper and from `UsageProbe`, which calls an undocumented `get_usage` on `claude`.

**Feature panels** follow one pattern: a `*Source` (an actor or off-main poller, read-only) feeds a `@MainActor *Store` (it publishes only what changed), which feeds `*Views`. Each area has a `*Dev`, `*SelfCheck` or `*Fixtures` file for headless runs. Areas: Builds (EAS + Bitbucket Pipelines), PullRequests (Bitbucket), Prod (Datadog + OAuth/Keychain), Machine, VPN. User config for these lives in `~/.claude/notch/builds.json` (`CLAUDE_NOTCH_BUILDS_CONFIG` overrides it).

## Conventions and gotchas

- Setup edits the user's settings files in place. Use `OrderedJSON` so key order and untouched bytes are preserved, touch only AI Notch's own entries, and write a backup first. Disconnect must restore the original byte for byte (`test-setup.py` checks this).
- Data paths (`~/.claude/notch`) and env vars (`CLAUDE_NOTCH_*`) keep their old names on purpose, so usage history carries over. Don't rename them.
- Releases: `VERSION` and `BUILD` are hardcoded in `scripts/assemble-app.sh`. Pushing tag `v<VERSION>` runs the release workflow, which also needs `.github/release-notes/v<VERSION>.md`.
- Commit subjects read `Area: what it now does` in plain words, with a short body explaining the behaviour. Code comments are written the same way: plain English that says what the code does for the user.
