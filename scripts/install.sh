#!/bin/sh
# The development install: builds AI Notch (AINotch.app), signs it (ad hoc unless
# NOTCH_SIGN_IDENTITY and NOTCH_TEAM_ID are set, see assemble-app.sh), puts it in place of the
# copy in use and starts it at login. Run again after any change: it rebuilds, replaces the app
# and restarts it. (To hand the app to another Mac, use make-dmg.sh.)
#
# The copy in use: $CLAUDE_NOTCH_APP if set, else the one the login item starts (so after a move
# to /Applications from the disk image it updates that one), else ~/Applications/AINotch.app.
# It does not touch the hooks; the app's setup window (footer → Setup) points them at the app.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="info.ankeshshiv.notch"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -n "${CLAUDE_NOTCH_APP:-}" ]; then
  APP="$CLAUDE_NOTCH_APP"
elif CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT" 2>/dev/null)" && [ -x "$CURRENT" ]; then
  APP="${CURRENT%/Contents/MacOS/AINotch}"
else
  APP="$HOME/Applications/AINotch.app"
fi

cd "$ROOT"
swift build -c release

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Any copy started by hand or left from an older install: two panels would overlap.
pkill -x AINotch 2>/dev/null || true
sleep 0.5

"$ROOT/scripts/assemble-app.sh" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# Started at login and restarted after a crash; Quit (a clean exit) keeps it quit until next login.
# The same file the setup window writes (LoginItem in Setup.swift).
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AINotch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed $APP"
echo "Hook command: $APP/Contents/MacOS/ai-notch-hook"
