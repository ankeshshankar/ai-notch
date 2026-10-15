# Dev helpers

- `swiftc -O click.swift -o /tmp/click && /tmp/click <x> <y> [right]` — a real (or right) click at
  global top-left points (pointer put back after); `/tmp/click info` prints the notched screen's size and notch height.
- `swiftc -O move.swift -o /tmp/move && /tmp/move <x> <y>` — moves the pointer (e.g. onto the notch).
- `AINotch --preview` (from `.build/release`) — an always-expanded copy mid-screen for screenshots
  (`screencapture -x -R x,y,w,h out.png`); kill it afterwards. With the panel 470 wide, its window
  top is at `screen.midY + 300` (AppKit), i.e. y ≈ 284 on a 1169-tall screen.
- `AINotch --preview --collapsed` — the collapsed strip in the same place, for wing screenshots.
- `<sessions>/preview-builds.json` (with `--preview`) — fixture EAS builds and Bitbucket runs in
  the sources' own JSON shapes (see `BuildFixtures.swift`); a key ending in `Ago` is seconds before
  now. Each source the file leaves out runs for real (when `builds.json` sets it up).
  [`preview-builds.json`](preview-builds.json) here is a sample with neutral names: copy it into a
  `CLAUDE_NOTCH_SESSIONS` folder for a preview of every row state. Reread on change, so editing it plays a state
  change; `--notify-unlocked` lets a preview run from the app bundle notify without locking.
- `AINotch --eas-failure <build id>` / `--bitbucket-failure <ws/repo#n>` — the text Copy failure
  copies, printed; `AINotch --redact <file>` — the masking alone.
- `AINotch --bitbucket-runs <ws/repo>` — one poll of a repository as the app does it: each run,
  whether it is mine, waiting or stale, its selector and usual time, and the requests it took.
  `AINotch --bitbucket-watch <seconds>` — the whole Bitbucket poller headless for that long,
  printing each snapshot and the rolling request count (`CLAUDE_NOTCH_BITBUCKET_SWEEP=<s>` changes
  the 5-minute sweep for a test; `CLAUDE_NOTCH_TEST_OPENS=70,90,140` opens the notch at those
  seconds and closes it 3 s later; with `CLAUDE_NOTCH_BUILD_TIMING=1` each sweep and each opening
  prints what it listed and skipped).
- With `CLAUDE_NOTCH_BUILD_TIMING=1`, EAS prints `eas boost <reason|off>` and `eas next in <s>` on
  each poll: a fixture with only a running Bitbucket run of the fixture owner (EAS left real)
  shows the 25 s boost and its end.
- `AINotch --eas-compare -` — three GraphQL list calls and two CLI ones, timed.
  `CLAUDE_NOTCH_EAS_TEST_SESSION=bogus` (auth), `CLAUDE_NOTCH_EAS_TEST_SCHEMA=1` (a field EAS does
  not have) or `CLAUDE_NOTCH_EAS_GRAPHQL=<url>` force a GraphQL failure, for the app's CLI fallback.
- Fixture keys beyond the sources' own: `eas.cliUser`, a build's `phase` and `usualDuration`;
  `bitbucket.owner`, a run's `usualDuration`, `logLine` and `testCases` (a test_cases page);
  top-level `health` (`eas`, `easDetail`, `bitbucket`, `bitbucketDetail`) for the status badges.
- `CLAUDE_NOTCH_BITBUCKET_API=<base> CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN=<t>` (or
  `CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN_FILE=<file>`, reread like a re-saved Keychain item) — the
  Bitbucket source against a stub server instead of api.bitbucket.org (`CLAUDE_NOTCH_BUILDS_CONFIG=<file>`
  for a `builds.json` of its own, the repo list included); `CLAUDE_NOTCH_BUILD_TIMING=1` prints each fetch's time and thread, and the main
  thread's cost per minute.
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
  hooks writing nothing, broken JSON, symlinks, and a hook that does not run (stand-ins that
  hang or exit 1: status says `hook blocked`, apply exits 4 and writes nothing; the real hook back:
  apply connects; Disconnect never runs the hook). Prints diffs.
- `CLAUDE_NOTCH_SETUP_HOME=<dir>` — tests only: setup reads and writes `<dir>/.claude`,
  `<dir>/.cursor` and `<dir>/Library/LaunchAgents` instead of your home.
  `AINotch --setup-cli status|apply|disconnect` runs it without the window (status and apply
  probe the hook first; exit codes: 1 a file failed, 2 usage, 3 disk image or translocated copy,
  4 hook blocked);
  `AINotch --setup-preview [--theme light|dark]` opens the window alone (no notch, no socket)
  and prints `setup-window <number> <x> <y> <w> <h>` (AppKit points) for `screencapture -l` and
  clicks. Run it from an assembled `.app` for the real icon and the notification status.
- `scripts/make-dmg.sh` lays out the disk image with Finder AppleScript; `scripts/dmg/background.swift`
  draws its 1x/2x background (the icon positions are shared with `make-dmg.sh`).
