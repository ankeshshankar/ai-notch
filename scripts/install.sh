#!/bin/sh
# The development install: builds AI Notch (AINotch.app), signs it (with an Apple Development
# identity found in the keychain unless NOTCH_SIGN_IDENTITY and NOTCH_TEAM_ID are set; ad hoc only
# with NOTCH_SIGN_IDENTITY=- or when no identity exists; see assemble-app.sh), puts it in place of the
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

# Signing. macOS keys the Microphone / Input Monitoring / Accessibility grants to the app's
# designated requirement; an ad-hoc build's is its cdhash, which changes on every build, so every
# ad-hoc install loses the grants. A certificate-based requirement stays the same. So a local
# install signs with an Apple Development identity unless told otherwise (release builds through
# make-dmg.sh are not affected: they keep reading NOTCH_SIGN_IDENTITY as before).
#   NOTCH_SIGN_IDENTITY=-   explicit ad hoc (grants reset on each install)
#   NOTCH_SIGN_IDENTITY, NOTCH_TEAM_ID   use these
# Otherwise: the valid "Apple Development" identities, preferring team $PREFERRED_TEAM, the first
# else; the team id is the certificate's OU. Certificates whose subject contains $SKIP_ORG are left
# out. Both come from the environment or a local ~/.config/ai-notch/signing (KEY=value lines).
SIGNING_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ai-notch/signing"
# shellcheck disable=SC1090
[ -f "$SIGNING_CONF" ] && . "$SIGNING_CONF"
PREFERRED_TEAM="${PREFERRED_TEAM:-}"
SKIP_ORG="${SKIP_ORG:-}"
if [ "${NOTCH_SIGN_IDENTITY:-}" = "-" ]; then
  unset NOTCH_SIGN_IDENTITY NOTCH_TEAM_ID
  echo "Signing ad hoc (NOTCH_SIGN_IDENTITY=-): macOS will forget the app's permissions on each install." >&2
elif [ -z "${NOTCH_SIGN_IDENTITY:-}" ] && [ -z "${NOTCH_TEAM_ID:-}" ]; then
  FOUND=""
  while IFS= read -r LINE; do
    HASH="$(printf '%s' "$LINE" | awk '{print $2}')"
    NAME="$(printf '%s' "$LINE" | sed -n 's/^[^"]*"\(Apple Development: .*\)"$/\1/p')"
    [ -n "$NAME" ] || continue
    SUBJ="$(security find-certificate -c "$NAME" -Z -p 2>/dev/null | awk -v h="$HASH" '/^SHA-1 hash:/{m=($3==h)} m&&/BEGIN CERT/{f=1} m&&f{print} m&&/END CERT/{f=0}' | openssl x509 -noout -subject -nameopt multiline 2>/dev/null || true)"
    if [ -n "$SKIP_ORG" ]; then case "$SUBJ" in *"$SKIP_ORG"*) continue ;; esac; fi
    OU="$(printf '%s\n' "$SUBJ" | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
    [ -n "$OU" ] || continue
    if [ -z "$FOUND" ] || [ "$OU" = "$PREFERRED_TEAM" -a "${FOUND##*|}" != "$PREFERRED_TEAM" ]; then
      FOUND="$NAME|$HASH|$OU"
    fi
  done <<IDS
$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development: ')
IDS
  if [ -n "$FOUND" ]; then
    NOTCH_SIGN_IDENTITY="${FOUND%%|*}"
    NOTCH_TEAM_ID="${FOUND##*|}"
    export NOTCH_SIGN_IDENTITY NOTCH_TEAM_ID
    REST="${FOUND#*|}"
    echo "Signing with $NOTCH_SIGN_IDENTITY (${REST%%|*}), team $NOTCH_TEAM_ID." >&2
  else
    echo "WARNING: no Apple Development identity in the keychain: signing ad hoc. macOS will forget the" >&2
    echo "WARNING: app's Microphone / Input Monitoring / Accessibility permissions on EVERY install." >&2
  fi
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
