import AppKit
import Darwin
import KeyHopCore
import SwiftUI

@main
enum KeyHopMain {
    @MainActor
    static func main() {
        let store = ConfigStore()
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--run-cli" {
            exit(CLIHelper.run(requestID: arguments[2], store: store))
        }
        guard arguments.count == 1 else {
            fputs("Unsupported KeyHop native arguments. Use keyhop --help.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(store: store)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: ConfigStore
    private var lockDescriptor: Int32 = -1
    private var ownsLock = false
    private var signalSources: [DispatchSourceSignal] = []
    private var item: NSStatusItem?
    private var window: NSWindow?
    private var model: LauncherModel!
    private var refreshTimer: Timer?
    private var hotKeys: GlobalHotKeyManager?
    private var menuIsOpen = false

    init(store: ConfigStore) { self.store = store }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            lockDescriptor = Darwin.open(store.rootURL.appendingPathComponent("launcher.lock").path,
                                         O_CREAT | O_RDWR, 0o600)
            guard lockDescriptor >= 0 else { throw RuntimeError.lockUnavailable }
            _ = fcntl(lockDescriptor, F_SETFD, FD_CLOEXEC)
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                NSApplication.shared.terminate(nil)
                return
            }
            ownsLock = true
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 KeyHop"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        installSignal(SIGUSR1) { [weak self] in self?.showSettings() }
        installSignal(SIGTERM) { NSApplication.shared.terminate(nil) }
        installSignal(SIGINT) { NSApplication.shared.terminate(nil) }
        let firstRun = !FileManager.default.fileExists(atPath: store.configURL.path)
        model = LauncherModel(store: store)
        hotKeys = GlobalHotKeyManager { [weak self] profileID in self?.openProfile(profileID) }
        model.registerHotKeys = { [weak self] profiles in self?.hotKeys?.update(profiles: profiles) ?? [:] }
        model.onShortcutRecordingChanged = { [weak self] recording in
            guard let self else { return [:] }
            if recording { self.hotKeys?.suspend(); return [:] }
            return self.hotKeys?.resume() ?? [:]
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "arrow.up.forward.circle", accessibilityDescription: "KeyHop")
        item?.button?.toolTip = "KeyHop"
        let menu = NSMenu()
        menu.delegate = self
        item?.menu = menu
        rebuildMenu(menu)
        model.onChange = { [weak self] in
            guard let self, !self.menuIsOpen, let menu = self.item?.menu else { return }
            self.rebuildMenu(menu)
        }
        model.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model?.refreshReceipts() }
        }
        if firstRun || model.errorMessage != nil || !model.hotKeyErrors.isEmpty { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        hotKeys?.stop()
        if ownsLock { model?.stop() }
        if lockDescriptor >= 0 {
            if ownsLock { flock(lockDescriptor, LOCK_UN) }
            Darwin.close(lockDescriptor)
        }
    }

    private func installSignal(_ number: Int32, action: @escaping @MainActor () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { action() } }
        source.resume()
        signalSources.append(source)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshReceipts()
        rebuildMenu(menu)
        menuIsOpen = true
        model.checkIfStale()
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func label(_ title: String, in menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.configuration.proxy.enabled {
            label("\(model.proxySummary) · \(model.endpointDescription)", in: menu)
            menu.addItem(.separator())
        }
        for profile in model.configuration.profiles {
            let entry = NSMenuItem(title: profile.name, action: #selector(launchFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile.id
            entry.isEnabled = !model.isBusy && model.configurationUsable
            entry.image = NSImage(systemSymbolName: profile.kind == .cli ? "terminal" : "app", accessibilityDescription: nil)
            if let hotKey = profile.hotKey {
                let title = NSMutableAttributedString(string: profile.name)
                title.append(NSAttributedString(string: "    \(hotKey.displayString)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                entry.attributedTitle = title
            }
            entry.toolTip = model.hotKeyErrors[profile.id] ?? model.record(for: profile)?.message
            menu.addItem(entry)
        }
        if model.configuration.profiles.isEmpty { label("还没有应用，请在设置中添加", in: menu) }
        menu.addItem(.separator())
        if model.configuration.proxy.enabled { label("App 流量：未验证", in: menu) }
        let add = NSMenuItem(title: "添加新应用…", action: #selector(showSettings), keyEquivalent: "")
        add.target = self
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(add)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 KeyHop", action: #selector(quitLauncher), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func launchFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openProfile(id)
    }

    private func openProfile(_ id: String) {
        guard let profile = model.configuration.profiles.first(where: { $0.id == id }) else { return }
        Task {
            let record = await model.launch(profile)
            if let record, ![.launched, .requested, .activated].contains(record.state) { showSettings() }
        }
    }

    @objc private func quitLauncher() { NSApplication.shared.terminate(nil) }

    @objc func showSettings() {
        guard model != nil else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "KeyHop"
            window.minSize = NSSize(width: 600, height: 420)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum RuntimeError: LocalizedError {
    case lockUnavailable
    var errorDescription: String? { "无法创建运行锁，请检查配置目录权限。" }
}
