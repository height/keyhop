# KeyHop product brief

## Purpose

KeyHop is a personal macOS menu bar launcher. It starts selected apps with a user's existing local proxy, such as `127.0.0.1:7897`, and provides a configurable keyboard shortcut for quickly opening or switching between apps. KeyHop does not provide a proxy server or change the system-wide proxy.

## Distribution and entry points

- Install the CLI globally with `npm install -g <package>`.
- Run `keyhop` to show the menu bar app. Running it again should activate the same instance.
- The menu bar is the primary daily entry point. A global hotkey opens a searchable app switcher.
- F3 may be selected as a hotkey, but it is used for Mission Control on many Macs. Detect and explain shortcut conflicts rather than silently overriding them.

## App launch flow

1. Configure the local proxy address and its actual protocol (HTTP or SOCKS5).
2. Add an app and choose its supported launch method.
3. Check that the proxy endpoint is reachable before a proxied launch.
4. If the app is not running, start it with its saved proxy configuration.
5. If the app is already running, show its current state and offer to bring it forward or restart it with proxy settings. Never force-quit it without the user's action.

Codex CLI can be launched with proxy environment variables. GUI apps may support environment variables, command-line arguments such as Chromium's `--proxy-server`, or both. Each app profile must record the method actually supported by that app. Local and intranet destinations may require direct-connection rules.

## Status and trust

Show three distinct facts: whether the local proxy is reachable, whether an app was launched with its saved proxy configuration, and whether its traffic has been verified through the proxy. Do not describe a configured or launched app as "fully proxied" without traffic evidence. Environment variables and launch arguments cannot guarantee that every request from an arbitrary app uses the proxy.

## First release scope

- A single-instance menu bar app, launched by the globally installed CLI.
- Per-app profiles for proxy address, protocol, launch method, and direct-connection rules.
- Menu actions to open or switch supported apps.
- Configurable global hotkey and searchable switcher.
- Proxy reachability and honest per-app status.

System-level traffic interception and per-app VPN routing are outside the first release.
