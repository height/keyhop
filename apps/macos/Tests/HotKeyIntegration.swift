import AppKit
import Carbon
import Darwin
import KeyHopCore

/// Exercises actual Carbon registration and dispatches Carbon events directly
/// to the app target. It does not inject keyboard input or launch user apps;
/// a physical-key check remains useful for end-to-end WindowServer delivery.
@main
struct HotKeyIntegration {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func main() {
        FileHandle.standardOutput.write(Data("RUN: Carbon hotkey integration\n".utf8))
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Hotkey integration failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var received: [String] = []
        let manager = GlobalHotKeyManager { received.append($0) }
        defer { manager.stop() }
        let key = HotKey(keyCode: 80, modifiers: HotKey.control | HotKey.option | HotKey.command)
        let profile = AppProfile(id: "smoke", name: "Smoke", kind: .cli, path: "/usr/bin/true", hotKey: key)
        let registration = manager.update(profiles: [profile])
        try require(registration.isEmpty, "Temporary shortcut registration failed: \(registration). Run in a logged-in macOS GUI session; restrictive sandboxes cannot access WindowServer.")

        var duplicate: EventHotKeyRef?
        let duplicateResult = RegisterEventHotKey(key.keyCode, key.carbonModifiers,
            EventHotKeyID(signature: 0x54455354, id: 50), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &duplicate)
        if let duplicate { UnregisterEventHotKey(duplicate) }
        try require(duplicateResult == eventHotKeyExistsErr, "Exclusive conflict was not detected: \(duplicateResult)")

        try send(1, pressed: true)
        try send(1, pressed: true)
        try require(received == ["smoke"], "A held key repeated its action")
        try send(1, pressed: false)
        try send(1, pressed: true)
        try require(received == ["smoke", "smoke"], "Release did not re-arm the shortcut")

        manager.suspend()
        try send(1, pressed: true)
        try require(received.count == 2, "A suspended shortcut fired")
        try require(manager.resume().isEmpty, "Shortcut registration did not resume")
        try send(1, pressed: true)
        try require(received.count == 2, "A stale registration fired after the config changed")
        try send(2, pressed: true)
        try require(received.count == 3, "The resumed shortcut did not fire")
        manager.stop()
        try checkReleased(key, reason: "stop()")

        var releasedOwner: GlobalHotKeyManager? = GlobalHotKeyManager { _ in }
        try require(releasedOwner!.update(profiles: [profile]).isEmpty, "Could not register the deinit cleanup fixture")
        releasedOwner = nil
        try checkReleased(key, reason: "deinit")

        try checkSystemConflict()
        print("PASS: Carbon registration, exclusive conflict, callback routing, held-key suppression, suspend/resume, stale-event rejection, stop and deinit cleanup")
    }

    @MainActor private static func send(_ id: UInt32, pressed: Bool) throws {
        var event: EventRef?
        try require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
            0, EventAttributes(kEventAttributeNone), &event) == noErr, "Could not create Carbon event")
        guard let event else { throw Failure(description: "Missing Carbon event") }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: 0x4B484F50, id: id)
        try require(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID) == noErr, "Could not attach the shortcut ID")
        try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Carbon event was not handled")
    }

    @MainActor private static func checkReleased(_ key: HotKey, reason: String) throws {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key.keyCode, key.carbonModifiers,
            EventHotKeyID(signature: 0x54455354, id: 51), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        try require(result == noErr, "\(reason) did not unregister the shortcut (\(result))")
    }

    @MainActor private static func checkSystemConflict() throws {
        var symbols: Unmanaged<CFArray>?
        try require(CopySymbolicHotKeys(&symbols) == noErr, "Could not read macOS symbolic shortcuts")
        let items = symbols?.takeRetainedValue() as? [[String: Any]] ?? []
        let supportedSystemKey = items.compactMap { item -> HotKey? in
            guard (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let carbon = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return nil }
            var modifiers: UInt32 = 0
            if carbon.uint32Value & UInt32(cmdKey) != 0 { modifiers |= HotKey.command }
            if carbon.uint32Value & UInt32(controlKey) != 0 { modifiers |= HotKey.control }
            if carbon.uint32Value & UInt32(optionKey) != 0 { modifiers |= HotKey.option }
            if carbon.uint32Value & UInt32(shiftKey) != 0 { modifiers |= HotKey.shift }
            let key = HotKey(keyCode: code.uint32Value, modifiers: modifiers)
            guard key.carbonModifiers == carbon.uint32Value, (try? key.validate()) != nil else { return nil }
            return key
        }.first
        guard let key = supportedSystemKey else {
            print("SKIP: No enabled macOS symbolic shortcut with supported keys is available for conflict testing")
            return
        }
        let conflict = GlobalHotKeyManager { _ in }
        defer { conflict.stop() }
        let profile = AppProfile(id: "system", name: "System", kind: .cli, path: "/usr/bin/true", hotKey: key)
        let errors = conflict.update(profiles: [profile])
        try require(errors["system"]?.contains("macOS") == true, "Enabled system shortcut conflict was not rejected")
        print("PASS: Enabled macOS system shortcut rejection")
    }
}
