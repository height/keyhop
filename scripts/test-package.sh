#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/keyhop-package.XXXXXX")"
trap 'rm -rf "$SMOKE"' EXIT
cd "$ROOT"
mkdir -p "$ROOT/dist"
npm pack --pack-destination "$ROOT/dist" --cache "$SMOKE/npm-cache"
VERSION="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$ROOT/package.json")"
ARCHIVE="$ROOT/dist/keyhop-$VERSION.tgz"
npm install --global --prefix "$SMOKE/install" --cache "$SMOKE/npm-cache" --offline --ignore-scripts --no-audit --no-fund "$ARCHIVE"
export KEYHOP_HOME="$SMOKE/config"
[[ "$("$SMOKE/install/bin/proxy-launcher" --version)" == "$VERSION" ]]
[[ "$("$SMOKE/install/bin/keyhop" --version)" == "$VERSION" ]]
"$SMOKE/install/bin/proxy-launcher" --help > "$SMOKE/help.txt"
"$SMOKE/install/bin/proxy-launcher" status --json > "$SMOKE/status.json"
node --input-type=module - "$SMOKE/status.json" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const status = JSON.parse(readFileSync(process.argv[2], 'utf8'));
assert.equal(status.running, false);
assert.equal(status.trafficVerified, false);
assert.equal(status.config, null);
NODE
/usr/bin/codesign --verify --strict "$SMOKE/install/lib/node_modules/keyhop/dist/KeyHop.app"
echo "Local archive verified: $ARCHIVE"
echo "Temporary npm installation and both CLI aliases passed; no real global installation or npm publishing performed."
