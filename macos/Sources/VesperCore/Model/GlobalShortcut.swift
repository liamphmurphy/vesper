import Foundation

// Maps a validated accelerator ("Alt+Shift+Space", see Capture.validateGlobalShortcut) to the
// virtual key code and Carbon modifier mask RegisterEventHotKey wants, and back (the recorder).
// Key codes are the kVK_ANSI_* / kVK_* values from HIToolbox; spelled out so this stays UI-free.

public struct HotKeyBinding: Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum GlobalShortcut {
    /// Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    static let keyCodes: [String: UInt32] = {
        var t: [String: UInt32] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13,
            "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37, "J": 38,
            "'": 39, "K": 40, ";": 41, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "`": 50,
            "Return": 36, "Enter": 76, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53, "Esc": 53, "Plus": 24,
            "Delete": 117, "Insert": 114, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
            "Left": 123, "Right": 124, "Down": 125, "Up": 126,
        ]
        let f: [Int: UInt32] = [
            1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111,
            13: 105, 14: 107, 15: 113, 16: 106, 17: 64, 18: 79, 19: 80, 20: 90,
        ]
        for (n, code) in f { t["F\(n)"] = code }
        return t
    }()

    /// Key names the recorder writes, by key code ("Space" rather than "Esc" for 49/53 where aliases exist).
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        for (name, code) in keyCodes where !["Esc", "Plus", "Enter"].contains(name) { names[code] = name }
        names[76] = "Enter"
        return names
    }()

    /// The binding for an accelerator, or nil when it's invalid or its key has no virtual key code here (F21-F24).
    public static func binding(for accelerator: String) -> HotKeyBinding? {
        guard case .success(let valid) = Capture.validateGlobalShortcut(accelerator) else { return nil }
        var parts = valid.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast(), let code = keyCodes[key.count == 1 ? key.uppercased() : key] else { return nil }
        var mods: UInt32 = 0
        for m in parts {
            switch Capture.canonicalModifier(m) {
            case "Command": mods |= cmd
            case "Shift": mods |= shift
            case "Alt": mods |= option
            case "Control": mods |= control
            default: return nil
            }
        }
        return HotKeyBinding(keyCode: code, modifiers: mods)
    }

    /// An accelerator string from a key press, for the recorder. nil when the key isn't one a shortcut can use.
    public static func accelerator(keyCode: UInt32, command: Bool, shift s: Bool, option o: Bool, control c: Bool) -> String? {
        guard let name = keyNames[keyCode] else { return nil }
        var parts: [String] = []
        if c { parts.append("Control") }
        if o { parts.append("Alt") }
        if s { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(name)
        return parts.joined(separator: "+")
    }
}
