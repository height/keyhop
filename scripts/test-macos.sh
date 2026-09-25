#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/.build/tests"
mkdir -p "$SCRATCH/clang-module-cache" "$SCRATCH/cache" "$SCRATCH/config" "$SCRATCH/security"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-module-cache"
swift test --package-path "$ROOT/apps/macos" --scratch-path "$SCRATCH" --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config" --security-path "$SCRATCH/security" --disable-sandbox
