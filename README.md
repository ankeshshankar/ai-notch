# AI Notch

A macOS app that shows your Claude Code and Cursor agent sessions in the MacBook notch.

Hover the notch to see every open session in VS Code, Cursor and the terminal: the chat's title,
the project, the model, whether it is working, waiting for you or idle, the tool or MCP server it
is using now, and its subagents with their own clocks. Click a session to jump to its window;
**Details** shows everything else it recorded. You can answer Claude Code's permission prompts and
single-choice questions from the notch.

- The notch glows amber and plays a sound when a session needs your answer or permission.
- A check mark flashes when a turn finishes; turns longer than 20 seconds also play a sound.
- The Usage panel shows tokens and cost per day and model for Claude Code, Codex, Qwen Code and
  OpenCode, and your Claude Code and Codex plan limits.
- The Code panel shows the lines Claude Code wrote: a grid of lines added per day, and each
  repository's lines beside what was committed to git there.

Requires macOS 15 (Sequoia) or later and is made for MacBooks with a notch.

## Install

With Homebrew:

```sh
brew install --cask ankeshshankar/tap/ai-notch
```

Or download `AI-Notch-<version>.dmg` from the
[Releases page](https://github.com/ankeshshankar/ai-notch/releases), open it, and drag AI Notch to
Applications.

### The first open (macOS 15 and later)

The app is signed ad hoc and not notarized, so macOS blocks it the first time:

1. Open AI Notch from Applications. macOS says it cannot verify it; click **Done**.
2. Open System Settings → Privacy & Security, scroll to Security, and click **Open Anyway** next to
   the message about AI Notch. The button is there for about an hour after the attempt.
3. Confirm with your login password, then **Open**.

Right-click → Open no longer skips this check for apps that are not notarized.

## Set Up

The first launch shows a setup window. Nothing is written until you click **Set Up**, which:

- adds the hook to 13 Claude Code events in `~/.claude/settings.json` (the permission event waits
  up to 1800 s for a click in the notch) and wraps your status line as
  `ai-notch-hook statusline '<your command>'`, which prints exactly what your command prints;
- adds the hook to 8 events of Cursor's own agent in `~/.cursor/hooks.json`, when `~/.cursor`
  exists (none of Cursor's permission events);
- writes the login item `~/Library/LaunchAgents/info.ankeshshiv.notch.plist`, which starts the
  app at login and restarts it after a crash;
- optionally asks for notifications and for Accessibility (to raise a session's exact window).

The hooks point at the app's own `Contents/MacOS/ai-notch-hook`. Setup merges into your files: it
moves existing AI Notch entries to this copy in place (entries of the older `claude-notch-hook`
name included), never adds a second one, and leaves every other hook, setting and your permissions
as they were. Each file it changes is first backed up as `<file>.bak-setup-<time>` and written
atomically; a file that would not change is not touched. Run from the disk image or from a
quarantined copy macOS has moved to a temporary folder, it writes nothing and asks you to move it
to Applications first.

Reopen the window from the panel's footer (**Setup**) or by opening the app again. Only one copy
runs: a second launch hands over to the running one and quits.

## How it works

Claude Code and Cursor run `ai-notch-hook` on each hook event. It folds the event into
`~/.claude/notch/sessions/<session-id>.json` under a file lock, so parallel tool calls are safe. It
never prints and always exits 0, so it cannot block or change a session; if another event holds
the lock for more than about 300 ms it skips its own. The app reads those files twice a second and
drops a session when its process exits.

The spinners, the waiting dot and the waiting glow are Core Animation layers that loop in the
render server at no more than 30 fps, so the app does no work per frame.

### Chat titles

Each row, card, notification and widget row names its chat the way the editor's chat list does.
Claude Code: your rename, else Claude Code's AI title, else your first prompt, else the project,
read from the session transcript (only what was added since the last read). Cursor's agent: the
chat's name in Cursor's state database (`state.vscdb`, one row, read only), else the first prompt.

### Permission prompts and questions

When a Claude Code session asks for permission, its row shows the tool and what it acts on, with
**Allow once**, **Allow for session** and **Deny**. The editor's or terminal's own prompt stays up
at the same time; whichever you answer first counts, and the other closes.

The `PermissionRequest` hook records the prompt, releases the session's lock and asks the app over
`~/.claude/notch/approvals.sock` (mode 0600; both ends check the other runs as you), then waits.
Only a click prints an answer. No app, no socket, the app quitting, the editor answering first, or
the timeout: it exits with no output and Claude Code asks as usual.

- There is no "always allow". **Allow for session** appears only when Claude Code itself suggests
  rules for the prompt and none of your `permissions.ask` rules covers it; the rules are rewritten
  to last for the session, never saved.
- The hook reads your ask rules (managed, user, project and local settings) and matches them the
  way Claude Code does, including each part of a compound command (`a && b | c`, `$(…)`,
  `sh -c '…'`), after `VAR=value`s and wrappers such as `timeout`, `env`, `sudo` and `xargs`. It
  errs towards a match, so commands you ask about get only Allow once and Deny.
- Buttons take a click only 0.6 s after they appear. Each answer is a line in
  `~/.claude/notch/notch.log` (the tool's name only, never its input).

A question (AskUserQuestion) with one single-choice question shows its options as buttons; a click
answers with that option's label. Several questions, multiple choice or a typed answer: only in
the editor. Plan approval cannot be answered by a hook, so the notch only shows that it waits.

### Notifications

Only while the screen is locked: a session that needs you, or a turn longer than a minute
finishing, sends a macOS notification with the chat's title, the project and what happened.
**Open** unlocks to the session. What the lock screen shows follows System Settings →
Notifications → Show previews.

### Tokens and cost

The app reads Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`, subagents included) in
the background, counting each API reply once by its message id, and prices it at Anthropic's API
rates for its model (input, output, cache reads, and cache writes at 1.25× input for the 5-minute
cache or 2× for the 1-hour cache, doubled for fast mode). Only lines added since the last read are
parsed. Running totals live in `~/.claude/notch/usage-ledger.json`, which also keeps the daily
totals of transcripts Claude Code has since deleted, so the history grows past Claude Code's 30
days. On a subscription the cost is what the usage would cost at API prices, not what you pay.

The Usage panel also reads Codex (`~/.codex/sessions`, each response's token record, own thread
only), Qwen Code (`~/.qwen/projects/*/chats`) and OpenCode (`opencode.db`, read only). Prices for
non-Anthropic models come from LiteLLM's public price list, cached daily in
`~/.claude/notch/model-prices.json`. Checked against `ccusage` 20: Claude identical, Codex within
1% on tokens and 2% on cost.

### Limits, burn rate and the prompt cache

The header shows Claude Code's five-hour and weekly plan use. They come from the status line's
`rate_limits`, which the wrapped status line notes in `~/.claude/notch/limits.json`. Only the
terminal runs a status line, so when it has said nothing lately the app asks Claude Code itself: a
short-lived `claude` in SDK mode sends one `get_usage` request (no prompt, no model call), at most
every few minutes while the panel is open or a session is busy. That request is not a documented
interface. Codex's limits come from its newest `token_count` event.

A working row shows what its session spends a minute; an idle row shows how long its prompt cache
stays warm.

### Cursor's own agent

`~/.cursor/hooks.json` runs `ai-notch-hook cursor` on `sessionStart`, `sessionEnd`,
`beforeSubmitPrompt` (answered with an explicit `{"continue":true}`), `postToolUse`,
`postToolUseFailure`, `afterMCPExecution`, `subagentStop` and `stop`. Cursor's permission hooks
are left alone, because an answer there can block or allow an action. So Cursor rows show the last
finished tool rather than the one in flight, subagents once they stop, and no approval waits.

### Light and dark

The panel follows the system's appearance, live. The strip on the notch stays black in both to
blend with the hardware.

## Desktop widget

The **AI Notch** widget (small, medium, large) lists the sessions with live turn timers; each row
opens its session. macOS runs a widget only from an app signed by an Apple developer team, so the
released ad-hoc build has no widget, and its setup window says so. To get it, build the app signed
with your own team (see below).

## Uninstall

```sh
brew uninstall --cask ai-notch          # takes the hooks out, removes the app and the login item
brew uninstall --cask --zap ai-notch    # also deletes ~/.claude/notch (sessions, usage history)
```

The uninstall first runs `AINotch --setup-cli disconnect`, which removes only AI Notch's entries
from `~/.claude/settings.json` and `~/.cursor/hooks.json` and puts your status line back to your
own command (each changed file is backed up first). With no hooks, it writes nothing.

`brew upgrade` runs the same step, so after an upgrade open AI Notch again (once more through Open
Anyway, since each build is new to Gatekeeper); it shows the setup window, and **Set Up** puts the
hooks back.

Without Homebrew: in the setup window click **Disconnect…**, quit AI Notch from the panel's footer,
then:

```sh
launchctl bootout gui/$(id -u)/info.ankeshshiv.notch
rm -rf /Applications/AINotch.app ~/Library/LaunchAgents/info.ankeshshiv.notch.plist
rm -rf ~/.claude/notch    # optional: sessions and usage history
```

If the app is already gone, remove the `ai-notch-hook` entries from both files by hand and set
`statusLine.command` back to the command inside the quotes.

## Building from source

Requires macOS 15 or later and Xcode with the Swift 6 toolchain (Xcode 16 or later).

```sh
swift build -c release   # .build/release/AINotch and ai-notch-hook
scripts/install.sh       # build, assemble, sign and install for development
scripts/make-dmg.sh      # build dist/AI-Notch-<version>.dmg
```

`scripts/install.sh` builds the app, signs it and puts it in place of the copy in use:
`$CLAUDE_NOTCH_APP` if set, else the one the login item starts, else
`~/Applications/AINotch.app`. It stops every running copy first, rewrites the login item and
starts it. It does not touch the hooks; Set Up does. `scripts/make-dmg.sh` lays out the disk
image's window with Finder AppleScript, so its first run may ask to let your terminal control
Finder.

Both sign ad hoc (`codesign -s -`) by default. For a build with the desktop widget, sign with your
own Apple developer team:

```sh
NOTCH_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" NOTCH_TEAM_ID=YOURTEAMID scripts/install.sh
```

The app and the widget then share the app group `<NOTCH_TEAM_ID>.info.ankeshshiv.notch`.

For development: `AINotch --preview [--theme light|dark]` opens an always-expanded copy in the
middle of the screen, `AINotch --setup-preview` opens the setup window alone, and
`python3 scripts/dev/test-setup.py` tests the setup logic in temporary home folders. See
[`scripts/dev/README.md`](scripts/dev/README.md) for these and the other helpers.

The data paths (`~/.claude/notch`) and environment variables (`CLAUDE_NOTCH_*`) keep their names
from the app's first versions, so usage history carries over.

## Known limits

- Claude Code sends no event when you approve a permission in the editor. An approved shell
  command is spotted as a new shell under the Claude Code process; any other approved tool shows
  as waiting until it finishes. A prompt you deny in the editor keeps its notch buttons until the
  session's next event; a click then changes nothing.
- An interrupt (Esc) raises no hook either: the app reads it from the end of the session
  transcript.
- Codex's permission hook is not wired: Codex takes allow or deny but rejects session rules.
- Jumping to the exact window needs Accessibility access; without it, the app the session runs in
  comes to the front. macOS ties the grant to the exact ad-hoc build, so after an update you may
  need to turn it on again (System Settings → Privacy & Security → Accessibility).
- No desktop widget in the ad-hoc build (see above).
- The Homebrew uninstall step can only edit `~/.claude/settings.json` and `~/.cursor/hooks.json`
  in place. If either is a symlink to a file elsewhere, click **Disconnect…** before uninstalling.

## License

MIT. See [LICENSE](LICENSE).
