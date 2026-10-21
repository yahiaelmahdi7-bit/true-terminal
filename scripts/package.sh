#!/usr/bin/env bash
# Assemble the SwiftPM executable into True.app (ad-hoc signed) -- no Xcode required. Never launches the app.
# Usage: scripts/package.sh [debug|release]
# Env:   TRUE_VERSION      bundle version (default 1.2.2)
#        TRUE_APP_OUT      output path (default ./True.app)
#        TRUE_PREBUILT_BIN prebuilt binary to use instead of running swift build
#        TRUE_UPDATE_PUBKEY base64 raw Ed25519 public key that update zips must be signed with (set in releases;
#                          without it the build still runs but does not enforce update signatures)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="${TRUE_APP_OUT:-True.app}"
BIN="True"
BUNDLE_ID="io.github.true-terminal.True"
VERSION="${TRUE_VERSION:-1.2.2}"

if [ -n "${TRUE_PREBUILT_BIN:-}" ]; then
  BIN_PATH="$TRUE_PREBUILT_BIN"
else
  echo "==> swift build ($CONFIG)..."
  nice -n 10 swift build -j 4 -c "$CONFIG"
  BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN"
fi
PUBKEY="${TRUE_UPDATE_PUBKEY:-}"
if [ -n "$PUBKEY" ]; then
  [ "$(printf %s "$PUBKEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = "32" ] || { echo "ERROR: TRUE_UPDATE_PUBKEY is not base64 of 32 bytes"; exit 1; }
  PUBKEY_PLIST="<key>TrueUpdatePublicKey</key><string>${PUBKEY}</string>"
else
  PUBKEY_PLIST=""
fi
[ -f "$BIN_PATH" ] || { echo "ERROR: build product not found at $BIN_PATH"; exit 1; }

echo "==> assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>True</string>
  <key>CFBundleDisplayName</key><string>True</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${BIN}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Turns on built-in auto-update (GitHub Releases of this repo). Public build only; without the key the updater is inert. -->
  <key>TrueUpdateRepo</key><string>yahiaelmahdi7-bit/true-terminal</string>
  ${PUBKEY_PLIST}
  <key>NSHighResolutionCapable</key><true/>
  <!-- Strangers must not get --dangerously-skip-permissions by default; the Settings toggle can turn it on. -->
  <key>TrueClaudeAutostartDefault</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- macOS charges a child process's mic use to the app that launched it; without this key a
       program run inside True that wants the microphone is refused silently, with no prompt. -->
  <key>NSMicrophoneUsageDescription</key><string>Programs you run in True may use the microphone.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"
echo "OK: built $APP (ad-hoc signed, version $VERSION, not launched)"
