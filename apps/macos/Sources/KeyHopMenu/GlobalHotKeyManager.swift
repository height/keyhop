import AppKit
import Carbon
import KeyHopCore

/// Registers only configured combinations with macOS; no keyboard monitoring or
/// Accessibility permission is needed. All Carbon calls run on the main thread.
@MainActor
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x4B484F50 // KHOP
    private let resources = HotKeyResources()
    private let onPress: (String) -> Void
    private var desiredProfiles: [AppProfile] = []
    private var profileIDs: [UInt32: String] = [:]
    private var nextRegistrationID: UInt32 = 1
    private var heldKeys: Set<UInt32> = []
    private var suspended = false
    private var installationError: OSStatus?

    init(onPress: @escaping (String) -> Void) {
        self.onPress = onPress
        resources.context.callback = { [weak self] id, pressed in
            guard let self, !self.suspended, let profileID = self.profileIDs[id] else { return }
            if pressed {
                guard self.heldKeys.insert(id).inserted else { return }
                self.onPress(profileID)
            } else {
                self.heldKeys.remove(id)
            }
        }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x4B484F50 else { return OSStatus(eventNotHandledErr) }
            let context = Unmanaged<HotKeyEventContext>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { context.callback?(id.id, pressed) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(resources.context).toOpaque(), &resources.handler)
        if result != noErr { installationError = result }
    }

    @discardableResult
    func update(profiles: [AppProfile]) -> [String: String] {
        desiredProfiles = profiles
        unregisterBindings()
        guard !suspended else { return [:] }
        var errors: [String: String] = [:]
        var seen: [HotKey: String] = [:]
        let systemKeys = Self.systemHotKeys()
        for profile in profiles {
            guard let hotKey = profile.hotKey else { continue }
            do { try hotKey.validate() } catch { errors[profile.id] = error.localizedDescription; continue }
            if let otherName = seen[hotKey] {
                errors[profile.id] = "快捷键已绑定给 \(otherName)。"
                continue
            }
            seen[hotKey] = profile.name
            if let installationError {
                errors[profile.id] = "快捷键服务不可用（\(installationError)），请重新启动 KeyHop。"
                continue
            }
            if systemKeys.contains(where: { $0.code == hotKey.keyCode && $0.modifiers == hotKey.carbonModifiers }) {
                errors[profile.id] = "\(hotKey.displayString) 已被 macOS 系统快捷键占用，请换一个组合。"
                continue
            }
            // Never reuse IDs after a config edit: an already queued event from
            // an old registration must not launch the newly selected app.
            let id = nextRegistrationID
            nextRegistrationID &+= 1
            if nextRegistrationID == 0 { nextRegistrationID = 1 }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &reference)
            if result == noErr, let reference {
                resources.references.append(reference)
                profileIDs[id] = profile.id
            } else if result == eventHotKeyExistsErr {
                errors[profile.id] = "\(hotKey.displayString) 已被其他快捷键占用，请换一个组合。"
            } else {
                errors[profile.id] = "无法注册 \(hotKey.displayString)（\(result)），请换一个组合。"
            }
        }
        return errors
    }

    func suspend() {
        suspended = true
        unregisterBindings()
    }

    @discardableResult
    func resume() -> [String: String] {
        suspended = false
        return update(profiles: desiredProfiles)
    }

    func stop() {
        desiredProfiles = []
        suspended = true
        unregisterBindings()
        if let handler = resources.handler { RemoveEventHandler(handler); resources.handler = nil }
        resources.context.callback = nil
    }

    private func unregisterBindings() {
        for reference in resources.references { UnregisterEventHotKey(reference) }
        resources.references.removeAll()
        profileIDs.removeAll()
        heldKeys.removeAll()
    }

    private static func systemHotKeys() -> [(code: UInt32, modifiers: UInt32)] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let items = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let enabled = item[kHISymbolicHotKeyEnabled as String] as? NSNumber, enabled.boolValue,
                  let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return nil }
            return (code.uint32Value, modifiers.uint32Value)
        }
    }
}

private final class HotKeyEventContext: @unchecked Sendable {
    @MainActor var callback: ((UInt32, Bool) -> Void)?
    @MainActor init() {}
}

/// Keeps the handler's unretained context alive until its handler is removed,
/// including if the owning model is released away from the main actor.
private final class HotKeyResources: @unchecked Sendable {
    let context: HotKeyEventContext
    var references: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    @MainActor init() { context = HotKeyEventContext() }
    deinit {
        let cleanup = HotKeyCleanup(references: references, handler: handler, context: context)
        if Thread.isMainThread { cleanup.run() }
        else { DispatchQueue.main.async { cleanup.run() } }
    }
}

private struct HotKeyCleanup: @unchecked Sendable {
    let references: [EventHotKeyRef]
    let handler: EventHandlerRef?
    let context: HotKeyEventContext
    func run() {
        for reference in references { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        withExtendedLifetime(context) {}
    }
}
