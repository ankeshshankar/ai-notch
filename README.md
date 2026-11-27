# AI Notch

A macOS app that shows your coding agents' sessions in the MacBook notch, and lets you answer their
permission prompts from there.

[![AI Notch promo video](docs/media/ai-notch-promo.gif)](docs/media/ai-notch-promo.mp4)

Click the preview to play the full video.

## What it does

- **Sessions and approvals.** Hover the notch to see every open session in VS Code, Cursor and the
  terminal: title, model, state, current tool and subagents. Click a row to jump to its window.
  Answer Claude Code's permission prompts and questions from the notch.
  [Details](docs/GUIDE.md#permission-prompts-and-questions)
- **Tokens, cost and limits.** Tokens and cost per day and model, your plan limits and burn rate,
  and the lines of code Claude Code wrote. [Details](docs/GUIDE.md#tokens-and-cost)
  ([limits](docs/GUIDE.md#limits-burn-rate-and-the-prompt-cache))
- **Builds and pipelines.** EAS builds and Bitbucket Pipelines runs as they queue, run and finish.
  [Details](docs/GUIDE.md#builds-and-pipelines)
- **Pull requests.** Your open pull requests and the ones waiting for your review.
  - *Merge gate.* A review ends in Ready, Not ready or Needs your look (`gate.json`, from the review skill). The app recomputes it from the facts and takes the stricter one; Approve stays off unless it is Ready. A defect already in the base (`PRE-EXISTING`) gets a card but caps the gate at Needs your look; `followUps` (real defects on unchanged lines) are listed in the gate panel and never change the gate.
  - *Follow-up.* Reads the author's new commits (merges of the target are skipped, big diffs are split), other people's open threads and the earlier gate; a fix counts only when confirmed.
  - *Runs.* Each run of a head is kept in `runs/<n>/`; cards are rebuilt from the latest full run and keep your on/off choices.
  - *Lessons.* A card you switch off, a reply you agree with, or a comment from someone else we missed becomes a proposal; only one you approve is added to the skill's `lessons.md`.
  [Details](docs/GUIDE.md#pull-requests)
- **Board.** One view of every session and pull request of yours, in four groups.
  [Details](docs/GUIDE.md#board)
- **Prod health and the Prod page.** Datadog monitors and incidents in a footer chip, with a Prod
  page and a deploy check. [Health](docs/GUIDE.md#prod-health-datadog),
  [Prod page](docs/GUIDE.md#prod-page)
- **Machine guard.** Free memory and the dev processes holding it, with a button to close idle
  ones. [Details](docs/GUIDE.md#machine-guard)
- **VPN.** Connect your OpenVPN profiles from the notch, with nothing else to install.
  [Details](docs/GUIDE.md#vpn-openvpn)
- **Dictation (new in 0.9.0).** Hold a key, talk, let go: the words are typed into the app you are
  in. Off until you turn it on. [Details](docs/GUIDE.md#dictation)
- **Keep awake.** The Mac stays awake while a session works.
  [Details](docs/GUIDE.md#keeping-the-mac-awake)
- **Desktop widget.** Sessions with live timers on the desktop.
  [Details](docs/GUIDE.md#desktop-widget)
- **Other agents.** Claude Code, Cursor, Codex and Gemini CLI through their hooks; Aider, Goose,
  Amp, Copilot CLI, OpenCode and more as processes. [Details](docs/GUIDE.md#other-agents)

The full guide, with every setting and limit, is [docs/GUIDE.md](docs/GUIDE.md).

## Install

Requires macOS 15 (dictation: macOS 26). Made for MacBooks with a notch.

```sh
brew install --cask ankeshshankar/tap/ai-notch
```

Or download `AI-Notch-<version>.dmg` from the
[Releases page](https://github.com/ankeshshankar/ai-notch/releases) and drag AI Notch to
Applications.

The app is signed ad hoc and not notarized, so macOS blocks it the first time:

1. Open AI Notch from Applications. macOS says it cannot verify it; click **Done**.
2. Open System Settings, Privacy & Security, and click **Open Anyway** next to the message about
   AI Notch. Confirm with your login password.
3. If the setup window says **macOS is blocking AI Notch's helper**, run this in Terminal and
   click **Check Again**:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/AINotch.app"
   ```

More in [the first open](docs/GUIDE.md#the-first-open-macos-15-and-later).

## Set Up

The first launch shows a setup window. Nothing is written until you click **Set Up**.

- It adds the AI Notch hook to Claude Code, and to Cursor, Codex and Gemini CLI when they are
  installed. Every file it changes is backed up first.
- It adds a login item so the app starts at login.
- It may ask for notifications and Accessibility.

Reopen it from the panel's footer (**Setup**). See [Set Up](docs/GUIDE.md#set-up).

## Uninstall

```sh
brew uninstall --cask ai-notch
```

This takes the hooks out, and removes the app and the login item. Without Homebrew, see
[Uninstall](docs/GUIDE.md#uninstall).

## Building from source

Requires macOS 15 and Xcode 16 or later (Swift 6).

```sh
swift build -c release
scripts/install.sh
```

See [Building from source](docs/GUIDE.md#building-from-source) for the signed widget build and the
disk image.

## License

MIT. See [LICENSE](LICENSE).
