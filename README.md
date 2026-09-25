# KeyHop · 捷跃

KeyHop is a macOS menu bar launcher for quickly opening or switching apps with per-app local proxy settings.

## Current status

This repository is the initial, runnable project scaffold. The `keyhop` command builds and opens a minimal menu bar app. Proxy profiles, app launching, and the global hotkey are specified in [the product brief](docs/product.md) and are not implemented yet.

## Run locally

Requirements: macOS 13+, Node.js 20+, and a Swift toolchain (Xcode or Command Line Tools).

```sh
npm install -g .
keyhop
```

The first launch compiles the native menu bar app into `dist/KeyHop.app`. Later launches reuse it. Running `keyhop` again activates the existing app instance.

For development:

```sh
npm run check
npm run build:mac
```

This source-based build is intended for local development. A future published package should include signed, notarized macOS binaries so users do not need a Swift toolchain.
