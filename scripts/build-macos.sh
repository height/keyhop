#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The menu bar app must be built on macOS with Xcode command line tools." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/apps/macos"
SCRATCH="$ROOT/.build"
APP="$ROOT/dist/KeyHop.app"
ARCHITECTURES=(arm64 x86_64)
if [[ "${1:-}" == "--native" && $# == 1 ]]; then
  ARCHITECTURES=("$(uname -m)")
elif [[ $# != 0 ]]; then
  echo "Usage: scripts/build-macos.sh [--native]" >&2
  exit 2
fi

mkdir -p "$SCRATCH/clang-module-cache" "$SCRATCH/swiftpm-cache" "$SCRATCH/swiftpm-config" "$SCRATCH/swiftpm-security"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"
BINARIES=()
for ARCH in "${ARCHITECTURES[@]}"; do
  SWIFT_OPTIONS=(--package-path "$PACKAGE" --scratch-path "$SCRATCH/$ARCH" --cache-path "$SCRATCH/swiftpm-cache" --config-path "$SCRATCH/swiftpm-config" --security-path "$SCRATCH/swiftpm-security" --disable-sandbox --triple "$ARCH-apple-macosx13.0")
  swift build "${SWIFT_OPTIONS[@]}" -c release --product KeyHopMenu
  BIN_PATH="$(swift build "${SWIFT_OPTIONS[@]}" -c release --show-bin-path)"
  BINARIES+=("$BIN_PATH/KeyHopMenu")
done

# Only replace the distributable after all architectures compiled successfully.
STAGING="$(mktemp -d "$SCRATCH/bundle.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/KeyHop.app/Contents/MacOS"
if [[ ${#BINARIES[@]} == 1 ]]; then
  cp "${BINARIES[0]}" "$STAGING/KeyHop.app/Contents/MacOS/KeyHopMenu"
else
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$STAGING/KeyHop.app/Contents/MacOS/KeyHopMenu"
fi
cp "$PACKAGE/Info.plist" "$STAGING/KeyHop.app/Contents/Info.plist"
chmod +x "$STAGING/KeyHop.app/Contents/MacOS/KeyHopMenu"
VERSION="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$ROOT/package.json")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGING/KeyHop.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGING/KeyHop.app"
/usr/bin/codesign --verify --strict "$STAGING/KeyHop.app"
mkdir -p "$ROOT/dist"
rm -rf "$APP"
mv "$STAGING/KeyHop.app" "$APP"
node --input-type=module - "$ROOT" "${ARCHITECTURES[@]}" <<'NODE'
import { writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
const [root, ...architectures] = process.argv.slice(2);
const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
writeFileSync(join(root, 'dist', 'build-info.json'), JSON.stringify({
  version,
  architectures,
  minimumMacOSVersion: '13.0',
  signing: 'ad-hoc',
  notarized: false,
  builtAt: new Date().toISOString(),
}, null, 2) + '\n');
NODE
echo "Built $APP (${ARCHITECTURES[*]}, local ad-hoc signature)"
