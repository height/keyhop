#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/apps/macos"
SCRATCH="$ROOT/.build"
APP="$ROOT/dist/KeyHop.app"

mkdir -p "$SCRATCH/clang-module-cache" "$SCRATCH/swiftpm-cache" "$SCRATCH/swiftpm-config" "$SCRATCH/swiftpm-security"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"

SWIFT_OPTIONS=(--package-path "$PACKAGE" --scratch-path "$SCRATCH" --cache-path "$SCRATCH/swiftpm-cache" --config-path "$SCRATCH/swiftpm-config" --security-path "$SCRATCH/swiftpm-security" --disable-sandbox)
swift build "${SWIFT_OPTIONS[@]}" -c release --product KeyHopMenu
BIN_PATH="$(swift build "${SWIFT_OPTIONS[@]}" -c release --show-bin-path)"

mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/KeyHopMenu" "$APP/Contents/MacOS/KeyHopMenu"
cp "$PACKAGE/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/KeyHopMenu"

echo "Built $APP"
