# Dev helpers

- `swiftc -O click.swift -o /tmp/click && /tmp/click <x> <y> [right]` — a real (or right) click at
  global top-left points (pointer put back after); `/tmp/click info` prints the notched screen's size and notch height.
- `swiftc -O move.swift -o /tmp/move && /tmp/move <x> <y>` — moves the pointer (e.g. onto the notch).
- `AINotch --preview` (from `.build/release`) — an always-expanded copy mid-screen for screenshots
  (`screencapture -x -R x,y,w,h out.png`); kill it afterwards. With the panel 470 wide, its window
  top is at `screen.midY + 300` (AppKit), i.e. y ≈ 284 on a 1169-tall screen.
- `AINotch --preview --collapsed` — the collapsed strip in the same place, for wing screenshots.
- `AINotch --preview --hover` — the strip in the same place that opens on hover, closes when the
  pointer leaves and stays open when pinned, like the real notch: for testing the pin and
  click-through without touching the real one. Its pin is the bare binary's own default
  (`defaults read AINotch notch.pinned`), not the installed app's. With `--debug`, each pointer
  tick prints `expanded`, `pinned`, `looking`, `fullScreen` and `key`.
- `<sessions>/preview-builds.json` (with `--preview`) — fixture EAS builds and Bitbucket runs in
  the sources' own JSON shapes (see `BuildFixtures.swift`); a key ending in `Ago` is seconds before
  now. Each source the file leaves out runs for real (when `builds.json` sets it up).
  [`preview-builds.json`](preview-builds.json) here is a sample with neutral names: copy it into a
  `CLAUDE_NOTCH_SESSIONS` folder for a preview of every row state. Reread on change, so editing it plays a state
  change; `--notify-unlocked` lets a preview run from the app bundle notify without locking
  (pull-request notifications included: run `AINotch.app/Contents/MacOS/AINotch --preview
  --notify-unlocked` with the stub's variables).
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
- `python3 bitbucket-stub.py <state.json> [port] [requests.log]` — a stand-in for Bitbucket Cloud
  for both lanes, Pipelines and pull requests, in Bitbucket's own JSON shapes: `fields=`, ETags,
  `q=` (a small BBQL), scopes per token (a 403 naming the missing one), `/user`, commits, merge
  checks, and a `timeline` of changes (approve, changes, comment, addReviewer, status, push,
  merge, a 429, scopes taken away). The docstring has the state file's keys; each request is a
  line in the log with its lane (`pl`, `pr`, `owner`). Run the app (or a dev flag) with
  `CLAUDE_NOTCH_BITBUCKET_API=http://127.0.0.1:<port>/2.0`,
  `CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN=<state.token>` and `CLAUDE_NOTCH_BUILDS_CONFIG=<a builds.json
  listing the stub's repositories>`. Against a stub the muted and seen lists use keys of their
  own (`prs.muted.stub`, `prs.seenNews.stub`).
- `AINotch --pr-selfcheck` — the pull-request data layer's pure parts (parsing, what needs you,
  events and the seen-state, the budget split, Setup's switch writing `builds.json`, the wing's
  order); exits 1 on any failure. `AINotch --pr-watch <seconds> [--prs-only]` — both Bitbucket
  lanes headless, printing each snapshot, each event and the request counts every minute
  (`CLAUDE_NOTCH_TEST_OPENS=70,200` opens the notch at those seconds); against the real API it
  prints counts, states and keys, never a title, branch or name.
- `CLAUDE_NOTCH_PR_SEEN=<file>` — the pull-request seen-state there instead of
  `~/.claude/notch/pr-seen.json` (against a stub it is a file in the temporary folder unless this
  is set). No file at the start makes the first full look silent; a file with an entry whose
  `seenAt` is older than a stub comment makes that comment new, for a preview of `2 new`.
- `python3 compare-ccusage.py` — the notch ledger against `ccusage` per month and per tool.
- `CLAUDE_NOTCH_SESSIONS=<dir>` — the app (and the hook) read and write session files there instead
  of `~/.claude/notch/sessions`: fake sessions for a preview or a measurement without the real ones.
- `AINotch --chat-title <transcript.jsonl>` — the custom and AI titles a Claude Code transcript
  holds and the one the notch shows (the editor's chat list shows the same).
- `AINotch --scan-usage <ledger.json>` — one usage scan into that ledger file, a summary per
  tool, the time, and a second scan's time (the 15-second cost). Give it a copy holding only
  `archive` to time a full rebuild (`/usr/bin/time -l` for its peak memory).
- `python3 test-setup.py [--app <AINotch>] [--real]` — the setup window's logic in temporary
  home folders, from a built-in sample settings file (`--real`: from copies of your
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
  `AINotch --setup-preview [--theme light|dark] [--focus prod]` opens the window alone (no notch,
  no socket; `--focus prod` opens it scrolled to Prod, as the grey Prod chip does)
  and prints `setup-window <number> <x> <y> <w> <h>` (AppKit points) for `screencapture -l` and
  clicks. Run it from an assembled `.app` for the real icon and the notification status.
- `scripts/make-dmg.sh` lays out the disk image with Finder AppleScript; `scripts/dmg/background.swift`
  draws its 1x/2x background (the icon positions are shared with `make-dmg.sh`).
- `python3 datadog-stub.py <state.json> [port] [requests.log]` — a stand-in for Datadog's monitor
  search, incident search and scalar query, in their own JSON shapes; editing the state file plays
  a state change (alert, warn, incident, recovery, `"auth": "401"`, `"rateLimit": true`, a low
  `"remaining"`). Run the app with `CLAUDE_NOTCH_DATADOG_API=http://127.0.0.1:<port>`,
  `CLAUDE_NOTCH_DATADOG_TEST_KEYS_FILE=<file>` (two lines: API key, application key; reread like
  re-saved Keychain items) and `CLAUDE_NOTCH_BUILDS_CONFIG=<a builds.json with a datadog part>`.
  `CLAUDE_NOTCH_DATADOG_EVERY=<s>` runs every kind of request at that pace (halved after a 429);
  `CLAUDE_NOTCH_BUILD_TIMING=1` prints each request. The docstring has the state file's keys.
  A `timeline` in the state file plays scripted steps by the clock (`--steps <file>` lists them);
  [`datadog-timeline.json`](datadog-timeline.json) goes green → Warn → Alert → incident SEV-2 →
  SEV-1 → 5xx over its line → 3 monitors at once → recovery → incident resolved → a flapping
  monitor, in about 4½ minutes with `CLAUDE_NOTCH_DATADOG_EVERY=6` and one `5xx` number (`"scale":
  100`, `"amber": 2`). Notifications need an app bundle outside a temporary folder (macOS refuses
  one under `/tmp` without asking): `.build/<dir>/<Name>.app` with a bundle id of its own, started
  with `open -n --env …`.
- `AINotch --prod-alerts-selfcheck` — Prod's alerts on made-up snapshots: the first answer as
  history, each transition, No Data silent, partial pages, grouping per poll, flapping and its
  quiet, incidents, the numbers' 2-poll hysteresis, the reminder, snooze, full screen, the
  switches (stored and the older ones) and the full-screen test; exits 1 on any failure.
- `python3 datadog-oauth-stub.py <state.json> [port] [requests.log]` — datadog-stub.py plus
  Datadog's sign-in as pup uses it: registration (DCR), the authorize redirect, the token endpoint
  (code with PKCE, refresh), and bearer tokens on the API. The state file's `oauth` part plays
  `invalid_grant`, `invalid_client` (at the exchange, the authorize step or a renewal), consent
  denied, a revoked access token, another site and no refresh token (see its docstring). Codes,
  tokens and verifiers go to `<requests.log>.secrets`, never the log. With a stub, the app keeps
  the sign-in in files under `CLAUDE_NOTCH_DATADOG_OAUTH_DIR` (never the Keychain) and appends the
  authorize URL to `CLAUDE_NOTCH_DATADOG_TEST_BROWSER` instead of opening a browser;
  `CLAUDE_NOTCH_DATADOG_AUTH_TIMEOUT=<s>` shortens the 5-minute wait.
- `AINotch --datadog-auth status|sign-in|token|unauthorized|watch <s>|sign-out` — the sign-in
  headless against that stub (only with the variables above): the browser round trip, a token as
  a request gets it (as an 8-character fingerprint), the renewal after a 401, the Prod source
  polling. `--datadog-auth probe` goes to the real site: it registers once if no client is known
  and loads the authorize page without following it (no Keychain, no browser, no login);
  `--datadog-auth keychain-selftest` round-trips a throwaway Keychain item.
- `python3 test-datadog-oauth.py` — 31 checks of the sign-in against the stub with a fake browser:
  the full flow, wrong state, renewal before expiry, 401 then renew and retry, "Sign in again",
  re-registration, consent denied, timeout, busy ports, the keys as fallback, sign-out, and no
  secret in `notch.log` or the output.
- `AINotch --machine-selfcheck machine-fixtures.json` — the machine guard's classifier and safety
  rules on saved process tables (an editor's group with Claude Code and MCP servers, a terminal
  job led by pnpm, `make verify` with turbo and Jest inside, orphans, daemons, the emulator and the
  Simulator, look-alikes, other users' processes, Xcode's `gnumake`), plus its idle, bulk and
  config rules; exits 1 on any failure. The fixtures use neutral paths.
- `AINotch --machine-scan [seconds] [n]` — two scans of this Mac that far apart (CPU needs two):
  each row's kind, pid, footprint, state and close plan (never the arguments); with `n`, the CPU
  time of `n` scans in a row.
- `CLAUDE_NOTCH_MACHINE_TEST_FREE_MB=<n>` — the machine guard takes `n` MB as the free memory:
  the chip's colours, the wing's memory slot and the notification (with `--notify-unlocked`, from
  the app bundle) without filling the memory. `CLAUDE_NOTCH_BUILDS_CONFIG` with a `machine` part
  (`"idleMinutes": 1`) makes idle show within a minute.
