#!/bin/sh
# Builds the drag-to-Applications disk image: dist/AI-Notch-<version>.dmg.
#   scripts/make-dmg.sh
# Release build, the app assembled and signed (assemble-app.sh: ad hoc unless NOTCH_SIGN_IDENTITY
# and NOTCH_TEAM_ID are set), a Finder window laid out with hdiutil and Finder AppleScript, then
# compressed (ULFO) and signed the same way. Not notarized: on another Mac, the first open goes
# through System Settings → Privacy & Security → Open Anyway (README).
# Laying out the window drives Finder: the first run may ask to let your terminal control Finder.
# Touches nothing installed: it builds into a temporary folder and dist/.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${NOTCH_SIGN_IDENTITY:--}"
VOLUME="AI Notch"
APP_NAME="AINotch.app"
# The window's content size and the icon centres; background.swift draws to the same numbers.
WIDTH=660
HEIGHT=420
APP_X=170
APPS_X=490
ICONS_Y=196
# Finder's bounds include the title bar (32 points on macOS 26 and 27).
TITLEBAR=32

if [ -e "/Volumes/$VOLUME" ]; then
  echo "A volume named \"$VOLUME\" is mounted; eject it first." >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-notch-dmg.XXXXXX")"
DEVICE=""
cleanup() {
  if [ -n "$DEVICE" ]; then hdiutil detach "$DEVICE" -quiet -force 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
swift build -c release

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
"$ROOT/scripts/assemble-app.sh" "$STAGE/$APP_NAME"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/$APP_NAME/Contents/Info.plist")"
OUT="$ROOT/dist/AI-Notch-$VERSION.dmg"

# No Finder flags on the bundle (a hidden-extension flag is an xattr that strict signature checks
# reject); Finder hides ".app" unless "Show all filename extensions" is on.
ln -s /Applications "$STAGE/Applications"

# The background at 1x and 2x, in one multi-resolution TIFF so a Retina screen gets the 2x.
xcrun swiftc -O "$ROOT/scripts/dmg/background.swift" -o "$WORK/background"
"$WORK/background" "$WORK/background.png" "$WORK/background@2x.png"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff"

# A writable image to lay out, with room for Finder's .DS_Store.
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -size 80m "$WORK/layout.dmg"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/layout.dmg" | awk '/Apple_HFS/ { print $1; exit }')"
MOUNT="/Volumes/$VOLUME"
[ -d "$MOUNT" ] || { echo "The image did not mount at $MOUNT." >&2; exit 1; }

osascript "$ROOT/scripts/dmg/layout.applescript" "$VOLUME" "$APP_NAME" "$WIDTH" "$((HEIGHT + TITLEBAR))" "$APP_X" "$APPS_X" "$ICONS_Y"
# Finder writes the layout to .DS_Store a moment after the window closes.
i=0
while [ ! -s "$MOUNT/.DS_Store" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
[ -s "$MOUNT/.DS_Store" ] || { echo "Finder wrote no layout (.DS_Store)." >&2; exit 1; }

# The volume's own icon, with the custom-icon flag on the volume's root. Added after the layout:
# hdiutil's -srcfolder leaves .VolumeIcon.icns out, and Finder's layout pass deletes it.
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/layout.dmg" -format ULFO -o "$OUT"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier info.ankeshshiv.notch.dmg "$OUT"
codesign --verify --verbose=1 "$OUT"

echo "Built $OUT ($(stat -f %z "$OUT") bytes)"
