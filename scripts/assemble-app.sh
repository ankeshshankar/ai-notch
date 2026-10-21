#!/bin/sh
# Assembles and signs AINotch.app (AI Notch) at the given path, from the release build (run
# `swift build -c release` first). Used by install.sh (in place, for development) and make-dmg.sh
# (into a staging folder).
#   scripts/assemble-app.sh <path/to/AINotch.app>
#
# Signing is ad hoc by default (`codesign -s -`): no certificate needed, no app group, and no
# desktop widget, because macOS runs a widget only from an app signed by an Apple developer team.
# For a team-signed build with the widget, set both:
#   NOTCH_SIGN_IDENTITY  a codesigning identity in your keychain, e.g. "Apple Development: …"
#   NOTCH_TEAM_ID        its team id; the app and the widget then share the app group
#                        <NOTCH_TEAM_ID>.info.ankeshshiv.notch
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <path/to/AINotch.app>" >&2; exit 2; }
APP="$1"
case "$APP" in *.app) ;; *) echo "$0: the path must end in .app" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="info.ankeshshiv.notch"
VERSION="0.5.0"
BUILD="6"
IDENTITY="${NOTCH_SIGN_IDENTITY:-}"
TEAM="${NOTCH_TEAM_ID:-}"
if [ -n "$IDENTITY" ] && [ -n "$TEAM" ]; then
  GROUP="$TEAM.$BUNDLE_ID"
elif [ -n "$IDENTITY" ] || [ -n "$TEAM" ]; then
  echo "Set both NOTCH_SIGN_IDENTITY and NOTCH_TEAM_ID for a team-signed build, or neither for ad hoc." >&2
  exit 2
else
  IDENTITY="-"
  GROUP=""
fi
APPEX="$APP/Contents/PlugIns/AINotchWidget.appex"
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-notch-assemble.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# A fresh bundle each time: an ad-hoc build after a team-signed one must not keep its widget.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AINotch" "$BIN/ai-notch-hook" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The VPN: its helper with OpenVPN and OpenVPN's DNS script, when scripts/build-openvpn.sh has
# built them into .build/openvpn. Without them the app has no VPN (Setup says so).
ENGINE="$ROOT/.build/openvpn"
HELPERS=""
if [ -x "$ENGINE/openvpn" ] && [ -f "$ENGINE/dns-updown" ]; then
  HELPERS="$APP/Contents/Helpers"
  mkdir -p "$HELPERS" "$APP/Contents/Resources/OpenVPN"
  cp "$BIN/ai-notch-vpnd" "$ENGINE/openvpn" "$HELPERS/"
  cp "$ENGINE/dns-updown" "$ENGINE"/licenses/* "$APP/Contents/Resources/OpenVPN/"
else
  echo "No VPN engine in .build/openvpn: built without the VPN (scripts/build-openvpn.sh builds it)." >&2
fi

# The app group's name in both Info.plists (WidgetSnapshot.appGroup reads it); none when ad hoc.
GROUP_KEY=""
[ -n "$GROUP" ] && GROUP_KEY="<key>AINotchAppGroup</key><string>$GROUP</string>"

if [ -n "$GROUP" ]; then
  # The widget extension: SwiftPM has no extension product, so it is compiled here, with the
  # extension entry point WidgetKit's host calls.
  mkdir -p "$APPEX/Contents/MacOS"
  xcrun swiftc -O -parse-as-library -application-extension -target arm64-apple-macos15.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-name AINotchWidget \
    "$ROOT/Sources/NotchCore/WidgetSnapshot.swift" "$ROOT/Widget/SessionsWidget.swift" \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$APPEX/Contents/MacOS/AINotchWidget"
  cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.widget</string>
  <key>CFBundleName</key><string>AI Notch</string>
  <key>CFBundleDisplayName</key><string>AI Notch</string>
  <key>CFBundleExecutable</key><string>AINotchWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  $GROUP_KEY
  <key>NSExtension</key>
  <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST
  cat > "$WORK/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>$GROUP</string></array>
</dict>
</plist>
PLIST
  cat > "$WORK/widget.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key>
  <array><string>$GROUP</string></array>
</dict>
</plist>
PLIST
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>AI Notch</string>
  <key>CFBundleDisplayName</key><string>AI Notch</string>
  <key>CFBundleExecutable</key><string>AINotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  $GROUP_KEY
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>ainotch</string></array>
  </dict></array>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Inside out: the extension, the hook and the VPN's tools, then the app around them.
if [ -n "$GROUP" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$WORK/widget.entitlements" "$APPEX"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/ai-notch-hook"
  if [ -n "$HELPERS" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$HELPERS/ai-notch-vpnd" "$HELPERS/openvpn"
  fi
  codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$WORK/app.entitlements" "$APP"
else
  codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID.hook" "$APP/Contents/MacOS/ai-notch-hook"
  if [ -n "$HELPERS" ]; then
    codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID.vpnd" "$HELPERS/ai-notch-vpnd"
    codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID.openvpn" "$HELPERS/openvpn"
  fi
  codesign --force --sign - --timestamp=none "$APP"
fi
