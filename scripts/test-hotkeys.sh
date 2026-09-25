#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOTKEY_SCRATCH="$ROOT/.build/hotkey-tests"
mkdir -p "$HOTKEY_SCRATCH/clang-module-cache" "$HOTKEY_SCRATCH/cache" "$HOTKEY_SCRATCH/config" "$HOTKEY_SCRATCH/security"
export CLANG_MODULE_CACHE_PATH="$HOTKEY_SCRATCH/clang-module-cache"
SWIFT_OPTIONS=(--package-path "$ROOT/apps/macos" --scratch-path "$HOTKEY_SCRATCH" --cache-path "$HOTKEY_SCRATCH/cache" --config-path "$HOTKEY_SCRATCH/config" --security-path "$HOTKEY_SCRATCH/security" --disable-sandbox)
swift build "${SWIFT_OPTIONS[@]}" --target KeyHopCore
HOTKEY_BIN_PATH="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"
HOTKEY_APP="$HOTKEY_SCRATCH/HotKeyTests.app"
mkdir -p "$HOTKEY_APP/Contents/MacOS"
cat > "$HOTKEY_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.height.keyhop.hotkeytests</string>
  <key>CFBundleName</key><string>KeyHop Hotkey Tests</string>
  <key>CFBundleExecutable</key><string>HotKeyTests</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 6 -parse-as-library -I "$HOTKEY_BIN_PATH/Modules" \
  "$ROOT/apps/macos/Sources/KeyHopMenu/GlobalHotKeyManager.swift" \
  "$ROOT/apps/macos/Tests/HotKeyIntegration.swift" \
  "$HOTKEY_BIN_PATH"/KeyHopCore.build/*.swift.o \
  -o "$HOTKEY_APP/Contents/MacOS/HotKeyTests"
codesign --force --sign - "$HOTKEY_APP"
"$HOTKEY_APP/Contents/MacOS/HotKeyTests"
