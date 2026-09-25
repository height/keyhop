import AppKit
import KeyHopCore
import SwiftUI

/// Records only while its button has keyboard focus. The parent pauses global
/// registrations during capture so an existing shortcut can also be reassigned.
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey?
    var onRecordingChanged: (Bool) -> Void = { _ in }
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecorderButton(hotKey: $hotKey, errorMessage: $errorMessage, onRecordingChanged: onRecordingChanged)
                .frame(width: 148, height: 28)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).frame(width: 148, alignment: .leading)
            }
        }
    }
}

private struct RecorderButton: NSViewRepresentable {
    @Binding var hotKey: HotKey?
    @Binding var errorMessage: String?
    var onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> CaptureButton {
        let button = CaptureButton()
        configure(button, enabled: context.environment.isEnabled)
        return button
    }

    func updateNSView(_ button: CaptureButton, context: Context) { configure(button, enabled: context.environment.isEnabled) }

    private func configure(_ button: CaptureButton, enabled: Bool) {
        button.hotKey = hotKey
        button.onRecordingChanged = onRecordingChanged
        button.onCapture = { hotKey = $0 }
        button.onError = { errorMessage = $0 }
        button.isEnabled = enabled
        if !enabled { button.stopRecording() }
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: CaptureButton, coordinator: ()) { button.stopRecording() }
}

@MainActor
private final class CaptureButton: NSButton {
    var hotKey: HotKey?
    var onCapture: ((HotKey?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onError: ((String?) -> Void)?
    private var isRecording = false
    private var localMonitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按快捷键；Esc 取消，Delete 清除。功能键可能需要同时按 Fn。"
        setAccessibilityLabel("录制 App 全局快捷键")
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDeactivated(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDeactivated(_:)), name: NSWindow.willCloseNotification, object: nil)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        title = isRecording ? "请按快捷键…" : (hotKey?.displayString ?? "录制快捷键")
        setAccessibilityValue(title)
    }

    @objc private func beginRecording() {
        if isRecording { stopRecording(); return }
        guard let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        onError?(nil)
        onRecordingChanged?(true)
        refreshTitle()
        // This is a local, temporary monitor. It lets the focused recorder
        // consume Cmd+key before AppKit treats it as a menu command.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self else { return event }
            self.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = HotKey.modifiers(from: event.modifierFlags)
        if modifiers == 0, event.keyCode == 53 { stopRecording(); return }
        if modifiers == 0, event.keyCode == 51 || event.keyCode == 117 {
            stopRecording()
            onCapture?(nil)
            return
        }
        guard let key = HotKey(event: event) else { return }
        do { try key.validate() }
        catch { onError?(error.localizedDescription); return }
        onError?(nil)
        // Resume before publishing, so the parent can attempt registration and
        // reject system conflicts without saving an unusable binding.
        stopRecording()
        onCapture?(key)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        refreshTitle()
        onRecordingChanged?(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func applicationDeactivated() { stopRecording() }
    @objc private func windowDeactivated(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow, changedWindow === window { stopRecording() }
    }
}
