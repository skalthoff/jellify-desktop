#!/usr/bin/env bash
# Wrap the swift-build executable as a minimal .app bundle so macOS treats it
# as a proper GUI process (visible in the Dock, Cmd-Tab, etc.). This is
# dev-grade packaging — signing and notarization come in M4.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS="$ROOT/macos"
BUILD_DIR="$MACOS/.build/arm64-apple-macosx/debug"
EXE="$BUILD_DIR/Jellify"
APP="$MACOS/build/Jellify.app"

if [[ ! -x "$EXE" ]]; then
  echo "error: Jellify executable not found at $EXE — run 'swift build' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Jellify"

# Copy SPM-processed resources (fonts bundle) next to the executable.
BUNDLE="$BUILD_DIR/Jellify_Jellify.bundle"
if [[ -d "$BUNDLE" ]]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# Quoted heredoc delimiter ("EOF") so bash doesn't try to expand backticks or
# variables in the body — the XML comment below mentions MPNowPlayingInfoCenter
# and friends, which would otherwise be parsed as command substitution.
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Jellify</string>
    <key>CFBundleIdentifier</key>
    <string>org.jellify.desktop</string>
    <key>CFBundleName</key>
    <string>Jellify</string>
    <key>CFBundleDisplayName</key>
    <string>Jellify</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!--
      Classifies the app as a music player. macOS uses this for App Store
      categorization and (more relevantly here) to mark the app as a media
      producer, which is what MPNowPlayingInfoCenter / Control Center
      expect. AVAudioSession is iOS-only — background playback on macOS is
      automatic for a regular GUI app as long as it doesn't set
      LSBackgroundOnly or LSUIElement. See issue #47.
    -->
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
EOF

echo "==> Built $APP"
