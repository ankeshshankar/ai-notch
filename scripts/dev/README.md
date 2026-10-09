# Dev helpers

- `swiftc -O click.swift -o /tmp/click && /tmp/click <x> <y>` — a real click at global top-left
  points (pointer put back after); `/tmp/click info` prints the notched screen's size and notch height.
- `swiftc -O move.swift -o /tmp/move && /tmp/move <x> <y>` — moves the pointer (e.g. onto the notch).
- `AINotch --preview` (from `.build/release`) — an always-expanded copy mid-screen for screenshots
  (`screencapture -x -R x,y,w,h out.png`); kill it afterwards. With the panel 470 wide, its window
  top is at `screen.midY + 300` (AppKit), i.e. y ≈ 284 on a 1169-tall screen.
- `python3 compare-ccusage.py` — the notch ledger against `ccusage` per month and per tool.
- `CLAUDE_NOTCH_SESSIONS=<dir>` — the app (and the hook) read and write session files there instead
  of `~/.claude/notch/sessions`: fake sessions for a preview or a measurement without the real ones.
- `AINotch --chat-title <transcript.jsonl>` — the custom and AI titles a Claude Code transcript
  holds and the one the notch shows (the editor's chat list shows the same).
- `AINotch --scan-usage <ledger.json>` — one usage scan into that ledger file, a summary per
  tool, the time, and a second scan's time (the 15-second cost). Give it a copy holding only
  `archive` to time a full rebuild (`/usr/bin/time -l` for its peak memory).
- `python3 test-setup.py [--app <AINotch>] [--real]` — the setup window's logic in temporary
  homes, from a built-in sample settings file (`--real`: from copies of your
  `~/.claude/settings.json` and `~/.cursor/hooks.json`, only read): Set Up, Set Up again (no
  change), Disconnect (the original, byte for byte), moving `claude-notch-hook` entries (the old
  name) and other copies' entries in place, user hooks kept, no duplicates, Disconnect with no
  hooks writing nothing, broken JSON, symlinks. Prints diffs.
- `CLAUDE_NOTCH_SETUP_HOME=<dir>` — tests only: setup reads and writes `<dir>/.claude`,
  `<dir>/.cursor` and `<dir>/Library/LaunchAgents` instead of your home.
  `AINotch --setup-cli status|apply|disconnect` runs it without the window;
  `AINotch --setup-preview [--theme light|dark]` opens the window alone (no notch, no socket)
  and prints `setup-window <number> <x> <y> <w> <h>` (AppKit points) for `screencapture -l` and
  clicks. Run it from an assembled `.app` for the real icon and the notification status.
- `scripts/make-dmg.sh` lays out the disk image with Finder AppleScript; `scripts/dmg/background.swift`
  draws its 1x/2x background (the icon positions are shared with `make-dmg.sh`).
