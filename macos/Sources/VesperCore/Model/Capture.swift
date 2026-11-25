import Foundation

// Port of desktop/src/capture.ts: quick capture requests and global shortcut validation.

public enum CaptureKind: String, Sendable, CaseIterable { case note, message }

public struct CaptureInput: Sendable {
    public var kind: CaptureKind
    public var text: String
    /// message: one of the person's persona ids; empty for their default persona.
    public var personaId: String?
    public init(kind: CaptureKind, text: String, personaId: String? = nil) {
        self.kind = kind
        self.text = text
        self.personaId = personaId
    }
}

public enum Capture {
    static let maxText = 100_000
    static let noteTitleMax = 120

    /// The existing API call for a capture, or a message to show.
    public static func buildCaptureRequest(_ input: CaptureInput) -> Result<APICall, CaptureError> {
        let text = input.text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(CaptureError("Write something first.")) }
        if text.utf16.count > maxText { return .failure(CaptureError("That's too long for a quick capture.")) }
        switch input.kind {
        case .note:
            // The server needs a title (it files the note in Inbox). Same split as the web's capture box:
            // the first line (≤120) is the title; the rest is the body, or the whole text when the first line is long.
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let first = String(lines[0])
            let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let body = lines.count > 1 ? rest : (first.count > noteTitleMax ? text : "")
            return .success(APICall(path: "/api/v1/knowledge/capture", body: [
                "title": .string(String(first.prefix(noteTitleMax))), "body_md": .string(body),
            ]))
        case .message:
            let persona = (input.personaId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !persona.isEmpty && persona.range(of: uuidPattern, options: .regularExpression) == nil {
                return .failure(CaptureError("Pick a persona from the list."))
            }
            var body: APIBody = ["message": .object(["body": .string(text)])]
            if !persona.isEmpty { body["persona_id"] = .string(persona) }
            return .success(APICall(path: "/api/v1/chats", body: body))
        }
    }

    /// Where to go after a successful capture, from the API's response. Only known id shapes are used.
    public static func captureResultHref(_ kind: CaptureKind, response: Any?) -> String? {
        let r = response as? [String: Any] ?? [:]
        if let id = r["id"] as? String, id.range(of: uuidPattern, options: .regularExpression) != nil {
            if kind == .message { return "/chat/\(id)" }
            if kind == .note { return "/knowledge/\(id)" }
        }
        return nil
    }

    // MARK: Global shortcuts

    static let modifiers: Set<String> = [
        "Command", "Cmd", "Control", "Ctrl", "CommandOrControl", "CmdOrCtrl", "Alt", "Option", "AltGr", "Shift", "Super", "Meta",
    ]
    static let namedKeys: Set<String> = [
        "Space", "Tab", "Backspace", "Delete", "Insert", "Return", "Enter", "Up", "Down", "Left", "Right", "Home", "End",
        "PageUp", "PageDown", "Escape", "Esc", "Plus",
    ]

    /// Validates an accelerator for a global shortcut: at least one modifier other than Shift, then exactly one key.
    public static func validateGlobalShortcut(_ raw: String?) -> Result<String, CaptureError> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(CaptureError("Enter a shortcut.")) }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.contains(where: \.isEmpty) { return .failure(CaptureError("That shortcut isn't valid.")) }
        let mods = Array(parts.dropLast())
        let key = parts[parts.count - 1]
        if mods.isEmpty { return .failure(CaptureError("Add a modifier such as ⌘, ⌥ or ⌃.")) }
        for m in mods where !modifiers.contains(m) { return .failure(CaptureError("\"\(m)\" isn't a modifier.")) }
        if Set(mods).count != mods.count { return .failure(CaptureError("A modifier is repeated.")) }
        if mods.allSatisfy({ $0 == "Shift" }) { return .failure(CaptureError("Shift alone isn't enough; add ⌘, ⌥ or ⌃.")) }
        let keyOk = key.range(of: #"^[A-Za-z0-9]\z"#, options: .regularExpression) != nil
            || key.range(of: #"^F([1-9]|1[0-9]|2[0-4])\z"#, options: .regularExpression) != nil
            || namedKeys.contains(key)
            || key.range(of: #"^[`\-=\[\];',./]\z"#, options: .regularExpression) != nil
        if !keyOk || modifiers.contains(key) { return .failure(CaptureError("\"\(key)\" isn't a key a shortcut can use.")) }
        let normalizedKey = key.count == 1 ? key.uppercased() : key
        return .success((mods + [normalizedKey]).joined(separator: "+"))
    }

    /// Renders an accelerator with macOS symbols for display (⌥⇧Space).
    public static func formatAccelerator(_ accelerator: String) -> String {
        let symbols = [
            "Command": "⌘", "Cmd": "⌘", "CommandOrControl": "⌘", "CmdOrCtrl": "⌘", "Control": "⌃", "Ctrl": "⌃",
            "Alt": "⌥", "Option": "⌥", "Shift": "⇧", "Super": "⌘", "Meta": "⌘",
        ]
        return accelerator.split(separator: "+", omittingEmptySubsequences: false).map { symbols[String($0)] ?? String($0) }.joined()
    }

    /// macOS system shortcuts a global shortcut can't take (modifier set, key, owner).
    static let systemShortcuts: [(mods: [String], key: String, owner: String)] = [
        (["Command"], "Space", "Spotlight"),
        (["Alt", "Command"], "Space", "Finder search"),
        (["Control"], "Space", "Input source switching"),
        (["Command", "Control"], "Space", "Emoji & Symbols"),
        (["Command"], "Tab", "the app switcher"),
        (["Command", "Shift"], "3", "screenshots"),
        (["Command", "Shift"], "4", "screenshots"),
        (["Command", "Shift"], "5", "screenshots"),
        (["Command", "Control"], "Q", "Lock Screen"),
        (["Command"], "Q", "Quit"),
        (["Command"], "H", "Hide"),
        (["Command"], "M", "Minimize"),
        (["Command"], "W", "Close"),
    ]

    public static func canonicalModifier(_ m: String) -> String {
        switch m {
        case "Cmd", "CommandOrControl", "CmdOrCtrl", "Super", "Meta": return "Command"
        case "Ctrl": return "Control"
        case "Option", "AltGr": return "Alt"
        default: return m
        }
    }

    /// The system feature that owns this shortcut, or nil.
    public static func systemShortcutConflict(_ accelerator: String) -> String? {
        var parts = accelerator.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = (parts.popLast() ?? "").uppercased()
        let mods = parts.map(canonicalModifier).sorted()
        for s in systemShortcuts where s.key.uppercased() == key && s.mods.sorted() == mods { return s.owner }
        return nil
    }
}

public struct CaptureError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
