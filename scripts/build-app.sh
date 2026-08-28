#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP="TypelessSwitchboard.app"
BIN=".build/release/TypelessSwitchboard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TypelessSwitchboard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TypelessSwitchboard</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.typeless.switchboard</string>
  <key>CFBundleName</key>
  <string>Typeless Switchboard</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# v2.3.0：复制 AppIcon.icns 到 .app（若 icns 不存在则现场生成）。
ICON_SRC="Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "WARN: $ICON_SRC not found, generating via scripts/generate-icon.sh"
    ./scripts/generate-icon.sh
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "Built $APP"
