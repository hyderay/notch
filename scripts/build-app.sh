#!/usr/bin/env bash
# Assembles Notch.app from the SwiftPM products.
#
# There is no .xcodeproj here on purpose: the project targets machines with only
# Command Line Tools installed, so the bundle is written by hand and ad-hoc
# signed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Notch"
BUNDLE_ID="com.wanquanlin.notch"
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || printf '1.0.0')"
fi
VERSION="${VERSION#v}"

BIN_DIR="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)"
APP="$ROOT/.build/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RESOURCES_DIR="$APP/Contents/Resources"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT" --product NotchApp
swift build -c "$CONFIGURATION" --package-path "$ROOT" --product notchctl

for binary in NotchApp notchctl; do
  if [[ ! -f "$BIN_DIR/$binary" ]]; then
    echo "error: $BIN_DIR/$binary not found" >&2
    exit 1
  fi
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/NotchApp" "$MACOS_DIR/$APP_NAME"
cp "$BIN_DIR/notchctl" "$MACOS_DIR/notchctl"

ICON_SRC="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "==> Rendering app icon"
  mkdir -p "$ROOT/Resources"
  swift "$ROOT/scripts/render-icon.swift" "$ROOT/Resources"
fi
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Only an ad-hoc signature is possible without a developer identity; it is
# enough for the app to run locally and to keep its preferences domain stable.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$MACOS_DIR/notchctl"
codesign --force --sign - --timestamp=none "$MACOS_DIR/$APP_NAME"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
