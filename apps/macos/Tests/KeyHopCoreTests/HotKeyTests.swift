import AppKit
import Carbon
import Foundation
import Testing
@testable import KeyHopCore

@Suite("Per-app global hotkeys")
struct HotKeyTests {
    @Test func oldConfigurationLoadsWithoutHotKeys() throws {
        let json = """
        {"version":1,"proxy":{"protocol":"http","host":"127.0.0.1","port":7897,"bypass":[]},
         "profiles":[{"id":"codex","name":"Codex","kind":"gui","path":"/Applications/Codex.app", "arguments":[],"launchMethod":"environment"}]}
        """
        let configuration = try JSONDecoder().decode(LauncherConfiguration.self, from: Data(json.utf8))
        try configuration.validate()
        #expect(configuration.profiles[0].hotKey == nil)
    }

    @Test func savedHotKeyRoundTripsWithTheApp() throws {
        let key = HotKey(keyCode: 8, modifiers: HotKey.command | HotKey.option)
        let profile = AppProfile(id: "codex", name: "Codex", kind: .gui, path: "/Applications/Codex.app", hotKey: key)
        let config = LauncherConfiguration(profiles: [profile])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(rootURL: directory)
        try store.save(config)
        #expect(try store.load() == config)
        #expect(try store.load().profiles.first?.hotKey?.displayString == "⌥⌘C")
    }

    @Test func duplicateShortcutsAreRejectedBeforeSaving() {
        let shortcut = HotKey(keyCode: 8, modifiers: HotKey.control | HotKey.option)
        let first = AppProfile(id: "first", name: "Codex", kind: .gui, path: "/Applications/Codex.app", hotKey: shortcut)
        let second = AppProfile(id: "second", name: "ChatGPT", kind: .gui, path: "/Applications/ChatGPT.app", hotKey: shortcut)
        #expect(throws: (any Error).self) { try LauncherConfiguration(profiles: [first, second]).validate() }
    }

    @Test func sameKeyWithDifferentModifiersCanBeBound() throws {
        let first = AppProfile(id: "first", name: "First", kind: .cli, path: "/usr/bin/true", hotKey: HotKey(keyCode: 8, modifiers: HotKey.control | HotKey.option))
        let second = AppProfile(id: "second", name: "Second", kind: .cli, path: "/usr/bin/true", hotKey: HotKey(keyCode: 8, modifiers: HotKey.command | HotKey.option))
        try LauncherConfiguration(profiles: [first, second]).validate()
    }

    @Test func ordinaryTypingAndUnsupportedModifiersCannotBecomeGlobalShortcuts() {
        for key in [HotKey(keyCode: 8, modifiers: 0), HotKey(keyCode: 8, modifiers: HotKey.shift),
                    HotKey(keyCode: 0, modifiers: 16), HotKey(keyCode: 54, modifiers: HotKey.command),
                    HotKey(keyCode: 255, modifiers: HotKey.command)] {
            #expect(throws: (any Error).self) { try key.validate() }
        }
    }

    @Test func functionKeysAndModifiedOrdinaryKeysAreAccepted() throws {
        for code: UInt32 in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90] {
            try HotKey(keyCode: code, modifiers: 0).validate()
        }
        try HotKey(keyCode: 8, modifiers: HotKey.command).validate()
        try HotKey(keyCode: 8, modifiers: HotKey.option | HotKey.shift).validate()
        #expect(HotKey(keyCode: 122, modifiers: 0).displayString == "F1")
        #expect(HotKey(keyCode: 126, modifiers: HotKey.control).displayString == "⌃↑")
    }

    @Test func appKitAndCarbonModifiersUseDistinctMasks() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .capsLock, .function, .numericPad]
        let key = HotKey(keyCode: 8, modifiers: HotKey.modifiers(from: flags))
        #expect(key.modifiers == HotKey.supportedModifiers)
        #expect(key.carbonModifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(key.displayString == "⌃⌥⇧⌘C")
        #expect(HotKey.modifiers(from: [.capsLock, .function, .numericPad]) == 0)
    }

    @MainActor @Test func recorderEventUsesPhysicalKeyAndIgnoresKeyUp() throws {
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "ç", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "ç", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(HotKey(event: down) == HotKey(keyCode: 8, modifiers: HotKey.command | HotKey.option))
        #expect(HotKey(event: up) == nil)
    }
}
