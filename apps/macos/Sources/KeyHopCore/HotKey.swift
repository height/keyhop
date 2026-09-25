import AppKit
import Carbon
import Foundation

/// A physical keyboard key plus portable modifier bits, persisted with each app.
public struct HotKey: Codable, Equatable, Hashable, Sendable {
    public static let shift: UInt32 = 1
    public static let control: UInt32 = 2
    public static let option: UInt32 = 4
    public static let command: UInt32 = 8
    public static let supportedModifiers = shift | control | option | command

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(from: event.modifierFlags))
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= shift }
        if flags.contains(.control) { value |= control }
        if flags.contains(.option) { value |= option }
        if flags.contains(.command) { value |= command }
        return value
    }

    public var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers & Self.shift != 0 { value |= UInt32(shiftKey) }
        if modifiers & Self.control != 0 { value |= UInt32(controlKey) }
        if modifiers & Self.option != 0 { value |= UInt32(optionKey) }
        if modifiers & Self.command != 0 { value |= UInt32(cmdKey) }
        return value
    }

    public var displayString: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    public func validate() throws {
        guard modifiers & ~Self.supportedModifiers == 0, Self.keyNames[keyCode] != nil else {
            throw LauncherError.invalidConfiguration("这个按键暂不支持，请使用字母、数字、方向键或 F1–F20。")
        }
        guard Self.functionKeyCodes.contains(keyCode) || modifiers & (Self.control | Self.option | Self.command) != 0 else {
            throw LauncherError.invalidConfiguration("请同时按住 ⌘、⌃ 或 ⌥；也可以使用功能键 F1–F20。")
        }
    }

    private static let functionKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    // Carbon key codes identify physical keys. Labels match the macOS US layout;
    // keeping that mapping stable also makes bindings recognizable after input-source changes.
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +",
        71: "Clear", 75: "Keypad /", 76: "⌤", 78: "Keypad −", 79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0",
        83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        90: "F20", 91: "Keypad 8", 92: "Keypad 9", 93: "¥", 94: "_", 95: "Keypad ,", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 102: "英数", 103: "F11", 104: "かな", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 110: "Menu", 111: "F12", 113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
