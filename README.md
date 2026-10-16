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
- Optionally, a Pipelines section shows your EAS builds and Bitbucket Pipelines runs as they
  queue, run, wait and finish (see [Builds and pipelines](#builds-and-pipelines)).
- With Bitbucket set up, your open pull requests and the ones waiting for your review: the ones
  that need you inline, all of them in a **PRs** panel (see [Pull requests](#pull-requests)).
- The pin in the header keeps the notch open (see [Pinned open](#pinned-open)).
- Optionally, a **Prod** chip in the footer shows your Datadog monitors and incidents (see
  [Prod health](#prod-health-datadog)).
- A **RAM** chip in the footer shows free memory and the dev processes holding it (Metro, Jest,
  `make verify`, the emulator, the Simulator, Gradle), and closes idle ones on request (see
  [Machine guard](#machine-guard)).

### Layout

With agents and pipeline runs (or pull requests that need you) to show, the notch opens wide:
agents on the left, pipelines and pull requests on the right, each with up to six rows. With only one of them, or on a screen narrower than about
900 points, it is one column 470 points wide, the pipelines under the agents. It grows to at most
520 points below the notch (half the screen on a shorter one); past that, a column scrolls by
itself. An open Usage, Code, Machine or PRs panel spans the full width, with the rows under it.

### Pinned open

Click the pin at the right of the header (next to Usage and Code) to keep the notch open: the
pointer leaving and a click on a row (jumping to a session, opening a run) no longer close it,
and the filled pin shows it is pinned. Click it again to unpin. The choice is remembered across
restarts. Pinned, it still lets every click outside its shape through to the app below and never
takes your typing, and it stays on the screen with the notch. While a full-screen app fills that
screen, it opens only on hover, as unpinned; it opens again when you leave full screen. With the
pointer away, a pipeline failure that arrives counts as unseen (its ✕ shows in the wing) until you
move over the notch, as when it is closed.

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
4. If the setup window then says **macOS is blocking AI Notch's helper**, copy the command it
   shows, run it in Terminal, and click **Check Again**. For the usual place that is:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/AINotch.app"
   ```

   It removes the download's quarantine from AI Notch only. The app never does this itself.

Right-click → Open no longer skips this check for apps that are not notarized.

## Set Up

The first launch shows a setup window. Nothing is written until you click **Set Up**. It first
checks that macOS lets the helper run (`ai-notch-hook --probe`, which exits at once and touches
nothing; no answer within 3 seconds counts as blocked). While it is blocked, Set Up connects
nothing and shows the command above. Then it:

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

If the helper of a copy that is already connected stops running, the window opens at launch with
the same command, and **Disconnect…** to take the hooks out meanwhile.

Reopen the window from the panel's footer (**Setup**) or by opening the app again. Only one copy
runs: a second launch hands over to the running one and quits. It opens centred on the screen
with the notch, as tall as its sections up to that screen's height; past that they scroll, with
the buttons kept in view. It can be resized, zoomed and made full screen (Control-Command-F).

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
finishing, sends a macOS notification with the chat's title, the project and what happened. So do
your pipelines' finishes, news on your pull requests (see [Pull requests](#pull-requests)) and
memory critical for 30 seconds (see [Machine guard](#machine-guard)). Prod's Datadog news is the
exception: it notifies while the screen is unlocked too (see [Prod health](#prod-health-datadog)).
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

### Builds and pipelines

Beside the agents (under them in one column), a **Pipelines** section shows EAS builds and Bitbucket Pipelines runs that are
queued or running, waiting (at a manual step or for a deployment lock), finished in the last 3
minutes, or failed since you last opened the notch. Each row (and the running summary in its
header) opens the run on the web. The notch never starts, cancels or reruns anything. The two
sources are separate: each has its own poller, pace and state, and one failing never stalls the
other. Nothing is read until you set it up; until then the section stays hidden.

#### Setting it up

1. Write `~/.claude/notch/builds.json`, leaving out the part you don't use (Setup → Builds →
   **How** shows the same example, with Copy):

   ```json
   {
     "eas": {
       "account": "acme",
       "slug": "mobile-app",
       "projectId": "00000000-0000-0000-0000-000000000000",
       "cli": "~/Code/mobile-app/node_modules/.bin/eas"
     },
     "bitbucket": {
       "workspace": "acme",
       "repos": ["mobile-app", "api", "other-workspace/web"],
       "searchRoots": ["~/Code"],
       "pullRequests": true
     },
     "me": { "emails": ["you@example.com"] }
   }
   ```

   - `eas`: the Expo account that owns the project, the project's slug and its ID
     (`extra.eas.projectId` in the app config). `cli` is optional: an eas-cli 24 or later to fall
     back on when the GraphQL API fails; without it, an `eas` on nvm's or Homebrew's path.
   - `bitbucket`: the workspace, and the repositories as `"name"` (in that workspace),
     `"workspace/name"` or `{"workspace": …, "repo": …, "path": …}`. `searchRoots` (optional) adds
     every local clone under those folders, up to three levels down, that has a bitbucket.org
     remote and a `bitbucket-pipelines.yml`; it is read from each clone's `.git/config`, never run.
     Either `repos` or `searchRoots` is enough. `pullRequests` (optional, on by default) reads
     your pull requests in the same repositories; `false` turns that off (Setup's switch writes it).
   - `me` (optional): the commit emails that make a run yours. Without it, your git `user.email`
     (`~/.gitconfig`, and the clones' own).

   AI Notch reads the file again within seconds of a change; no restart.
2. EAS: sign in with `eas login` (AI Notch reads that login), or store an `EXPO_TOKEN` as the
   Keychain item `ai-notch.expo`.
3. Bitbucket: in Atlassian account settings → Security → API tokens, create an API token with the
   Bitbucket scopes `read:repository`, `read:pipeline`, `read:pullrequest` and `read:user` (the
   last two for [Pull requests](#pull-requests); without them Pipelines still works, and pull
   requests wait quietly). A token cannot gain scopes later: a new one replaces it under the same
   Keychain item. Copy this into Terminal with the
   token's expiry date, then copy the token and press Return. It reads the token from the
   clipboard and clears it; typing the token at the `-w` prompt instead silently keeps only 128 of
   its 192 characters.

   ```sh
   security add-generic-password -U -s ai-notch.bitbucket -a api-token -j "expires YYYY-MM-DD" -w "$(pbpaste)" && pbcopy < /dev/null
   ```

   The notch warns 14 days before the date in the comment. Setup → Builds → **Check Again**
   picks it up at once (pull requests also look for it when the notch opens).

#### What it shows

- **Mine / All**: the switch in the header, remembered across restarts (Mine by default). A
  Bitbucket run is mine when its creator is the token's owner: the account that pushed (for push
  and pull-request runs) or clicked Run. `GET /2.0/user` needs a scope the read-only token lacks,
  so the owner is the Bitbucket user behind commits made with your email (`me.emails`, else your
  git `user.email`; last resort: the git user name against the creator's name). An EAS build is mine when it is linked to
  one of my runs, or was started from the CLI's login; that login may be a shared account, so the
  ⓘ calls this match weak. Only mine notify, once per finish; All is for looking.
- **Pin, mute, branch**: right-click a row to pin it (shown until you unpin it), mute its
  repository or show only its branch; the filter menu in the header undoes them.
- **Each row** shows where it is: the running step and an ETA (the median of the last ten
  successful runs of the same repository and selector, from their timestamps), a queued EAS
  build's place and expected wait, a building one's phase (from its log while the notch is open)
  and ETA (the last ten finished builds of the same platform and profile), and while the notch is
  open, a running step's last log line. A paused run says what it waits for and, after two hours
  with no step change, stops keeping the fast poll going and shows its age instead of a clock; it
  shows for a week while it is the newest run on its branch. Only running and queued runs count
  in the live line and the spinner.
- **Install**: a finished internal EAS build has **Install**, a QR code for its page on expo.dev
  (not the raw artifact), until its artifacts expire.
- **Copy failure** copies what failed and the last 100 lines of the failing part's log. EAS: the
  platform, profile, version, commit, the error code and message, EAS's docs link when it gives
  one, and the first phase that ended `failed`. Bitbucket: the repo, branch and pull request,
  commit, run, the failed step, its failed tests (at most 20) when the step published a test
  report, and the end of its log. Anything that looks like a secret (bearer tokens, JWTs, AWS keys,
  long hex or base64 runs, credentials in URLs, `*_TOKEN=` / `*_SECRET=` / `PASSWORD=` values,
  private keys) is masked first.
- **Status**: `status.expo.dev` (the EAS Build component) and `bitbucket.status.atlassian.com`
  every 10 minutes; a small "EAS degraded" or "Bitbucket degraded" badge shows only while one is
  not operational.
- **EAS**: Expo's GraphQL API (`https://api.expo.dev/graphql`, the queries and BuildFragment
  fields eas-cli 24 uses: `app.byId.builds` for the list, `builds.byId` for a build in flight),
  for the project in `builds.json`, with an `EXPO_TOKEN` from the Keychain item `ai-notch.expo` if
  one exists, else the CLI's login from `~/.expo/state.json` (only its session secret and user name are read; the secret goes only
  into the request header). It is not a documented API, so each answer is checked; an auth or
  schema error falls back to `eas build:list --json` (run in `~/.claude/notch/eas`, a minimal
  project folder written from `builds.json`) for 10 minutes and says so in `notch.log`.
  A list call takes about 0.5 s over GraphQL against about 2 s for the CLI. A build in flight
  every 25 s; the list every 25 s while one of my Bitbucket pipelines runs or waits for a runner
  (not one paused or stale, nor in a muted repository), so a build it queues shows within about
  25 s (every minute on the CLI fallback, and while a build is already in flight); every minute
  while any other build or pipeline runs, else every 5 minutes. The boost lapses two minutes
  after the Bitbucket side stops confirming it, so a Bitbucket failure never keeps EAS fast.
- **Bitbucket**: one workspace request (`/repositories/{ws}?q=updated_on>…` for the listed
  repositories) every 2 minutes tells which were pushed to; a pushed repository, and one with a
  running run, is read every 25 s (stretched so all of it stays under ~360 requests an hour, hard
  cap 390: one running run polls about every 28 s, two in different repositories about every
  53 s), and every repository every 5 minutes, because manual, scheduled and rerun pipelines do
  not move `updated_on`. Opening the notch also reads every unmuted repository not read in the
  last minute (two minutes or more while slowed down), so a pipeline started by hand shows when
  you look. A waiting run that has dropped off its repository's first page is read by itself on
  a sweep at most every 15 minutes. With nothing running that is about 120 requests an hour for
  7 repositories (the gate 30, the sweep 12 per repository, a waiting run 4). Requests ask only for the fields shown (`fields=`) and send
  If-None-Match, so an unchanged answer is a 304 with no body. A 429 pauses for its Retry-After,
  and a 429, `X-RateLimit-NearLimit: true` or our own count passing 80% of the cap slows
  everything for 15 minutes. The header's ⓘ shows the count for the last hour. The token is read
  from the Keychain item `ai-notch.bitbucket` (sent as Bearer; read through `/usr/bin/security`,
  never written to a file or a log). After a 401 the Keychain is read again on the next poll and
  then every minute, so a re-saved token is picked up without a restart; a rejected token of
  exactly 128 characters is reported as truncated. The repositories are `bitbucket` in
  `builds.json` (see above).
- Both pause while the screen is locked with nothing running (for EAS, a pipeline of mine running
  counts), and refresh data older than a minute when the notch opens.
- **Links**: an EAS build whose message ends in ` bb:<workspace>/<repo>#<number>` links to that run,
  and the run back to it; without the suffix, a build of the same commit started during a run is
  linked as *inferred* (dashed). A badge on each row opens the other.
- Collapsed, the left spinner counts running runs with working sessions, and the right side shows
  a red ✕ for a failure of yours you have not seen, or a hammer with the number of running runs
  (see [The collapsed notch](#the-collapsed-notch) for the order).
- Passed and failed runs of yours send a notification only while the screen is locked, like the
  sessions'; a failed one offers **Copy failure details** and **Open**.

### Pull requests

With a `bitbucket` part in `builds.json` (and `pullRequests` not `false`), the notch reads your
open pull requests and the ones you are a reviewer on, in the same repositories as Pipelines and
with the same token. Nothing is approved, merged or commented from the notch.

- **What needs you** shows as rows under Pipelines in the right column (one column: a line under
  Pipelines that opens the panel): a review asked of you (⧗ and who asked), changes requested on
  yours (✕ and by whom), a failed build on yours, new comments by others since you last looked,
  and yours approved (✓ approvals of reviewers, `2/3`). The block's header counts mine, to review
  and the quiet ones. A row opens the pull request on bitbucket.org; right-click mutes it (until it
  closes) or marks it seen.
- **PRs**, the chip in the right column's header, opens a panel across the full width with every
  open pull request, **Mine** and **To review**. **Details** on a row shows its branches, each
  reviewer's review, open tasks, comments and build, and reads its merge checks once ("can merge",
  or what blocks it: `minimum approvals`, `no changes requested`). Hover the chip for the counts
  and the requests of the last hour.
- **Collapsed**, the right wing shows the pull-request mark and how many rows have news you have
  not looked at. Moving over the open notch counts it as seen; the comments the rows showed stop
  counting as new when the notch closes.
- **Notifications**, only while the screen is locked and each once: yours approved, changes
  requested on yours, new comments (grouped per pull request, at most every 10 minutes), a review
  asked of you, and a failed build on yours unless Pipelines already notified that run. Each kind
  has its checkbox in Setup → Builds. What is known is kept in `~/.claude/notch/pr-seen.json`, so a
  restart announces nothing twice.

How it reads, in a budget of its own (about 120 requests an hour, never more than 150; Pipelines
keeps its 390, together well under Bitbucket's 1,000):

- Mine: `GET /2.0/workspaces/{workspace}/pullrequests/{my uuid}?state=OPEN` every 2 minutes (5
  while the screen is locked); opening the notch reads it when it is older than a minute.
- To review: per repository, `GET /2.0/repositories/{workspace}/{repo}/pullrequests` with
  `q=state="OPEN" AND (author.uuid="{me}" OR reviewers.uuid="{me}")`, every 10 minutes (20 while
  one of your pipelines runs or the screen is locked), stretched for many repositories.
- Details only for what changed: `/statuses` when a pull request's `updated_on` moves (every 4
  minutes while a build of yours runs), the 10 newest comments' authors and times (never their
  text) when its comment count moves. `/mergeability/checks` only from Details.
- Your account: the token's `/2.0/user` (`read:user`), else the Bitbucket user behind commits
  made with your email, as Pipelines finds it.

For 7 repositories that is about 70 requests an hour. A token without `read:pullrequest` is
answered with a 403 once; from then on the lane sends nothing, shows a grey "needs
read:pullrequest" in Setup and the PRs chip, and looks for a newer token in the Keychain every 10
minutes (and on Check Again or opening the notch). Pipelines is not affected.

### The collapsed notch

The right wing shows one thing, the first that applies: a session waiting on you (amber dot and
count), memory critical (a still amber memory chip), a turn that just finished (✓), a prod alert
you have not seen (⚠), a pipeline failure of yours you have not seen (✕), news on your pull
requests you have not seen (the pull-request mark and a count), running subagents, then running
pipeline runs (hammer). "Not seen" ends when you move over the open notch. While a monitor
alerts or an incident is open, a still red dot sits in the strip's top right corner; else, while
memory is low, an amber one.

### Prod health (Datadog)

A **Prod** chip on the left of the footer: green, amber (a monitor warns, or a number is over its
line), red (a monitor in Alert, or an active incident), or grey (not connected, "Sign in again",
the keys refused, or no answer for 10 minutes; a sign-in or key problem is never red). Grey, a
click opens Setup at its Prod section. Beside it, the numbers you configure
(for example the 5xx rate and p95). Hover lists the alerting monitors and incidents; a click opens
the one alerting monitor or incident in Datadog, else the monitor list filtered by your query;
right-click snoozes it for an hour (no dot, no ⚠, no notifications). Nothing is read until you set
it up; without it the chip stays hidden.

1. Add a `datadog` part to `~/.claude/notch/builds.json` (Setup → Prod → **How** shows it, with
   Copy):

   ```json
   "datadog": {
     "site": "us3",
     "monitors": "(service:api AND env:production) OR service:gateway",
     "incidents": "state:active",
     "health": [
       { "label": "5xx", "unit": "%", "amber": 2, "aggregator": "sum",
         "queries": {
           "a": "sum:trace.http.request.hits.by_http_status{service:api,env:production,http.status_class:5xx}.as_count()",
           "b": "sum:trace.http.request.hits.by_http_status{service:api,env:production}.as_count()"
         },
         "formula": "100 * a / b" },
       { "label": "p95", "unit": "ms", "scale": 1000, "amber": 1000,
         "query": "p95:trace.http.request{service:api,env:production}" }
     ]
   }
   ```

   - `site`: `us1`, `us3`, `us5`, `eu`, `ap1` or the site's domain.
   - `monitors`: a search as the Manage Monitors page takes it (`AND`, `OR` and parentheses
     work). Muted monitors count as OK: the app adds `AND muted:false`.
   - `incidents` (optional): an incident search, `state:active` by default; `false` leaves
     incidents out.
   - `health` (optional, up to 3): each a `label`, one `query` or named `queries` with a
     `formula`, an `aggregator` (`avg` by default), a `unit` (`%` or `ms`), a `scale` (`1000` turns
     seconds into ms), `amber` (in the shown unit) and `minutes` (the window, 15 by default).

2. Setup → Prod → **Sign in with Datadog**. Your browser opens Datadog's sign-in for the `site`
   in `builds.json`; approve AI Notch there (it asks only for `monitors_read`, `incident_read` and
   `timeseries_query`) and the tab says you can close it. Setup then shows "Signed in as <your
   organization>", and the token renews by itself (see [Signing in](#signing-in-with-datadog)).

   Or, instead, service-account keys (Setup → Prod → **Or use service-account keys**): a Datadog
   admin creates a service account (Organization Settings → Service Accounts →
   New Service Account, role Datadog Read Only Role), opens it and adds an application key (New
   Key) scoped to `monitors_read`, `incident_read` and `timeseries_query`, and an API key
   (Organization Settings → API Keys → New Key). Copy each key, then run its command in Terminal;
   it reads the key from the clipboard and clears it (typing a secret at the `-w` prompt keeps
   only its first 128 characters):

   ```sh
   security add-generic-password -U -s ai-notch.datadog -a api-key -w "$(pbpaste)" && pbcopy < /dev/null
   security add-generic-password -U -s ai-notch.datadog -a app-key -w "$(pbpaste)" && pbcopy < /dev/null
   ```

   Setup → Prod → **Check Again** picks them up at once; otherwise within two minutes.

How it reads, over Datadog's API (`https://api.<site>`, with the sign-in's `Authorization: Bearer`
token, else the headers `DD-API-KEY` and `DD-APPLICATION-KEY`; the sign-in wins when both exist):

- `GET /api/v1/monitor/search` (100 a page) every minute, every 3 minutes while the screen is
  locked: its status facets colour the chip, its page names what alerts.
- `GET /api/v2/incidents/search` every 3 minutes (a public beta API).
- `POST /api/v2/query/scalar`, one request per number, every 5 minutes, not while locked.

That is about 104 requests an hour with two numbers (40 while locked), under a hard cap of 150.
Every answer's `X-RateLimit-*` headers are read: with a tenth or less of a window left, that kind
of request waits for the reset; a 429 waits for it too and halves the pace for 15 minutes. With
the sign-in, a 401 renews the token once and sends the request again; a 403 on the monitor search
(your role cannot read monitors) is grey and tried again in 10 minutes. With the keys, a 401 (or a
403 on the monitor search) means they were refused: the chip turns grey, and the Keychain is read
again every minute, so re-saved keys are picked up by themselves. A 403 on incidents or the
numbers names the missing scope and is tried again an hour later. The keys are read through
`/usr/bin/security` and go only into the request headers, never to a file or a log; the requests
follow no redirects.

#### Signing in with Datadog

OAuth 2 in the browser, the flow of Datadog's own CLI
([pup](https://github.com/DataDog/pup/blob/main/docs/OAUTH2.md)):

- The first sign-in on a site registers AI Notch with Datadog as a public client (Dynamic Client
  Registration, `POST https://api.<site>/api/v2/oauth2/register`, no client secret) with the
  loopback redirects `http://127.0.0.1:{8000,8080,8888,9000}/oauth/callback`. The client id is not
  a secret and is kept in `~/.claude/notch/datadog-oauth-clients.json`; a later sign-in reuses it,
  and one Datadog no longer knows (`invalid_client`) is registered again by itself.
- A listener on 127.0.0.1 only takes the first free port of those four (all taken: any free port,
  registered for itself). It answers one request with the right `state` and stops; it gives up
  after 5 minutes (**Cancel** stops it sooner, **Open Again** shows the page again).
- The authorize page (`https://<site>/oauth2/v1/authorize`, `app.datadoghq.com` on US1) gets PKCE
  S256 and a random `state`; the code comes back to the listener and is exchanged at
  `https://api.<site>/api/v2/oauth2/token`.
- The access token (an hour) and the refresh token (about 30 days) go into one JSON item in your
  login Keychain, `ai-notch.datadog` / account `oauth` (with the expiry, the granted scopes, the
  client id and the site), not synced. The token renews 5 minutes before it ends and after a 401.
  When Datadog refuses the refresh token, the tokens are wiped and Setup and the chip say "Sign in
  again", grey; the service-account keys, if stored, take over meanwhile.
- **Sign Out** deletes that Keychain item. To revoke AI Notch in Datadog too: Organization Settings
  → Mobile and Third-Party Access → AI Notch → Users (an admin, or a role with
  `org_authorized_apps_write`).
- No token, code or verifier reaches a log or a file other than that Keychain item; `notch.log`
  says only what happened ("signed in", "sign-in renewed", "sign-in ended: …").

Alerts, each change once, diffed from one answer to the next (the first answer after launch, or
after a change of site or query, is history: what is already open neither notifies nor counts as
unseen):

- a monitor going to Alert, to Warn, or back to OK from either (No Data shows in the list only);
- an incident declared, its severity changed, resolved;
- a number over its `amber` line for 2 polls in a row, and back under it for 2 polls.

They notify even while the screen is unlocked (unlike the notch's other news), with **Open** (the
monitor, the incident, or the filtered list) and **Snooze 1 h**. Everything from one poll is one
notification ("Datadog · 3 monitors alerting"). A monitor that changes state 3 times in 15 minutes,
going back into a state it had left, is told once as flapping, then not for 30 minutes (after
which a different state is told once). Alert-level news (a monitor in Alert, an incident declared
or escalated, a number going over) also drops a banner from the notch for 6 seconds, longer while
the pointer is on it, with **Open** and ✕; never over a full-screen app, and it never takes your
typing. Warn and recoveries only notify. A snooze (the chip's right-click, or the notification's
Snooze 1 h) silences both for an hour. Each kind, the banner, notifying while unlocked, and an
optional reminder every 2 hours for a monitor still alerting (off by default) are switches kept
as `prod.alerts`. `notch.log` gets each change's kind and id (`prod: monitorAlert (m:123)`), never
a monitor's or incident's name.

### Machine guard

A **RAM** chip on the left of the footer, beside Prod: the free memory in the colour of the
pressure (green, amber under `warnBelowMB` or at the kernel's warning level, red under 2 GB or at
critical), and the biggest idle dev process ("5.6 GB free · Metro idle 22m"). A click opens the
**Machine** panel across the full width, like Usage and Code:

- a memory bar: used of total, compressed, and the pressure;
- a row per dev process with its footprint (`ri_phys_footprint`, children included, as Activity
  Monitor's Memory column counts it, not RSS), its state (idle for how long, in use, running) and
  its button;
- warnings: low memory, more than one `make verify` at once, critical pressure;
- **Close idle · N · size**, which turns into **Confirm close N**: a second click within 5 s
  closes them.

Free memory is free, inactive and speculative pages, as `vm_stat` counts them (the same measure a
`make verify` memory check that waits for 4096 MB uses). Nothing to set up: it is on by default,
and Setup → Machine turns it off.

| Kind | Found by | Idle when | Button |
| --- | --- | --- | --- |
| Metro | node running `expo start`, `@expo/cli … start`, `react-native start` or `metro`; the port from its own listening socket | no client connected to its port (adb reverse counts) and under 1% CPU for `idleMinutes` | Close |
| Jest | `jest/bin/jest.js` (workers: jest-worker's `processChild.js`, counted in their runner) | `--watch` under 1% CPU for `idleMinutes`; a plain run never | Close |
| `make verify`, turbo | make (Xcode's runs as `gnumake`) with the `verify` target; turbo outside it | never | Close |
| Android emulator | `qemu-system-*` with `-avd` | never | Close: `adb -s emulator-NNNN emu kill`, SIGTERM if that fails |
| iOS Simulator | `launchd_sim` and everything under it, one row per device | never | Shut down: `xcrun simctl shutdown <udid>`, never a signal |
| Gradle, Kotlin daemons | java running `GradleDaemon` / `KotlinCompileDaemon` | under 0.5% CPU for 10 minutes | Close |
| adb server, watchman, the Simulator app | by name | — | none (adb serves your devices) |

A process whose parent is gone and whose terminal has no one left on it is idle at once (Metro with
a client excepted). Processes are told apart by their arguments (`KERN_PROCARGS2`), read once per
process for the few named node, java, make, turbo, qemu, adb or launchd_sim, and never written
anywhere. A matching process inside another's tree (Metro's transform workers, a Jest inside
`make verify`) counts in that row.

Closing:

- Only your own processes, and only these kinds. Never an editor (VS Code, Cursor, Xcode) or a
  process it started directly, Claude Code, Codex, Cursor's agent, the notch, a terminal or a
  login shell.
- The process group gets the signal only when its leader is the dev process itself or the make,
  pnpm or npx that started it, and the group holds nothing but that chain and the dev process's
  tree. An editor's group also holds its MCP servers, so a dev process there gets SIGTERM sent
  to its own tree instead.
- Each pid's start time is checked again right before its signal, so a pid reused by another
  process is never signalled.
- SIGTERM first. Still running 5 seconds later, the row offers **Force quit**, which sends
  SIGKILL after a second click. A row that is not idle also needs a second click to close.
- Close idle takes only Metro, Jest and the Gradle and Kotlin daemons, never the emulator or the
  Simulator, and skips anything that used more than 5% of a core in the last minute.
- `notch.log` gets the kind, the pid and the megabytes freed, nothing else.

It scans every 10 seconds (every 2 while the Machine panel is open, and at once on a memory
pressure event) off the main thread: about 0.5–0.8 ms of CPU a scan. The screen redraws only when
something shown changes (memory in 0.1 GB steps).

Collapsed, the wing's memory slot shows when the pressure is critical or less than 2 GB has been
free for 30 seconds. While the screen is locked, that also sends one notification naming the
biggest dev process (Open shows the Machine panel; nothing is ever closed from a notification);
the next one comes only after 10 minutes back at normal. Setup → Machine turns it off.

Optional settings, in `~/.claude/notch/builds.json`:

```json
"machine": { "warnBelowMB": 4096, "idleMinutes": 15, "exclude": [] }
```

`exclude` lists kinds never shown: `metro`, `jest`, `verify`, `turbo`, `emulator`, `simulator`,
`simulatorApp`, `gradle`, `kotlin`, `adb`, `watchman`.

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
security delete-generic-password -s ai-notch.datadog -a api-key    # optional: the Prod keys
security delete-generic-password -s ai-notch.datadog -a app-key
security delete-generic-password -s ai-notch.datadog -a oauth      # optional: the Datadog sign-in
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
middle of the screen (`--hover`: opening on hover and pinning as the real one does),
`AINotch --setup-preview` opens the setup window alone, and
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
- Prod sign-in: Datadog marks Dynamic Client Registration as a preview. The refresh token's
  lifetime (about 30 days) is what pup reports, not a documented number. A port other than the four
  registered ones gets its own registration, which Datadog may refuse. AI Notch writes its Keychain
  item itself, so a build signed by another identity (an ad-hoc upgrade) may make macOS ask once
  before it reads the sign-in.
- Prod: the chip reads the first 100 monitors the search returns (the colour comes from the
  facets, which count them all). The web links (`/monitors/<id>`, `/incidents/<number>`,
  `/monitors/manage?q=`) follow what Datadog's app shows, not a documented format. Incident search
  is a public beta API.
- Machine guard: Metro's clients are the connections accepted on its port, so a client of another
  dev server does not count. A Jest started by an editor's own extension is shown but never
  closed. The emulator's and the Simulator's own shutdowns take their time; the row says if one
  is still running.
- Pull requests: Bitbucket Cloud only. Bitbucket does not say who added a reviewer, so a review
  request names the author. Mine lists up to 50 per workspace, a repository's list up to 50.
- Pipelines: one EAS project, and Bitbucket Cloud only (no GitHub Actions or other CI). Expo's
  GraphQL API is not documented and may change; the CLI then stands in. An EAS build started from
  the CLI counts as yours by the CLI's login, which a team may share. ETAs are medians of recent
  runs, not promises.

## License

MIT. See [LICENSE](LICENSE).
