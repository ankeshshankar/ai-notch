#!/bin/bash
# CI: screenshots of the open notch for a design check. Sample sessions are made by feeding hook
# events through the real hook (a working session with a to-do list, an idle one, one waiting),
# then `AINotch --preview` is shown in light and dark and the screen captured. Writes PNGs to
# $1 (default: screenshots/).
set -u
OUT="${1:-screenshots}"
BIN=.build/release
mkdir -p "$OUT"
export CLAUDE_NOTCH_SESSIONS="$(mktemp -d)"

event() { # session event-json
  echo "$2" | "$BIN/ai-notch-hook" >/dev/null 2>&1 || true
}
cwd="$PWD"
for s in alpha beta gamma; do
  event $s "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$s\",\"cwd\":\"$cwd\",\"source\":\"startup\"}"
done
event alpha "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"alpha\",\"cwd\":\"$cwd\",\"prompt\":\"Add a settings screen with dark mode\"}"
event alpha "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"alpha\",\"cwd\":\"$cwd\",\"tool_name\":\"TodoWrite\",\"tool_use_id\":\"t1\",\"tool_input\":{\"todos\":[{\"content\":\"Read the current settings code\",\"status\":\"completed\",\"activeForm\":\"Reading the settings code\"},{\"content\":\"Add the dark mode toggle\",\"status\":\"in_progress\",\"activeForm\":\"Adding the dark mode toggle\"},{\"content\":\"Write tests\",\"status\":\"pending\",\"activeForm\":\"Writing tests\"}]}}"
event alpha "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"alpha\",\"cwd\":\"$cwd\",\"tool_name\":\"TodoWrite\",\"tool_use_id\":\"t1\"}"
event alpha "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"alpha\",\"cwd\":\"$cwd\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t2\",\"tool_input\":{\"command\":\"npm test\"}}"
event beta "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"beta\",\"cwd\":\"$cwd\",\"prompt\":\"Fix the flaky login test\"}"
event beta "{\"hook_event_name\":\"Stop\",\"session_id\":\"beta\",\"cwd\":\"$cwd\"}"
event gamma "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"gamma\",\"cwd\":\"$cwd\",\"prompt\":\"Deploy the docs site\"}"
event gamma "{\"hook_event_name\":\"Notification\",\"session_id\":\"gamma\",\"cwd\":\"$cwd\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\"}"
ls "$CLAUDE_NOTCH_SESSIONS"

for theme in dark light; do
  "$BIN/AINotch" --preview --theme "$theme" >/dev/null 2>&1 &
  pid=$!
  sleep 6
  screencapture -x "$OUT/notch-$theme.png" || echo "screencapture failed ($theme)"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
done
ls -la "$OUT"
