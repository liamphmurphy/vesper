import AppKit

/// Native modal sheets for confirmation and single-line text prompts.
@MainActor
enum NativeDialogs {
    static func confirmSheet(
        title: String,
        body: String?,
        confirmLabel: String,
        cancelLabel: String?,
        destructive: Bool,
        window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = body ?? ""
        let confirm = alert.addButton(withTitle: confirmLabel)
        confirm.hasDestructiveAction = destructive
        // NSAlert only gives Esc to a button titled "Cancel"; callers may use another label.
        alert.addButton(withTitle: cancelLabel ?? "Cancel").keyEquivalent = "\u{1b}"
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        // A sheet already up would make this one queue invisibly; decline instead.
        guard window.attachedSheet == nil else { return false }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func promptSheet(
        title: String,
        body: String?,
        label: String?,
        value: String?,
        placeholder: String?,
        confirmLabel: String,
        cancelLabel: String?,
        maxLength: Int?,
        window: NSWindow?
    ) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body ?? label ?? ""
        let confirm = alert.addButton(withTitle: confirmLabel)
        alert.addButton(withTitle: cancelLabel ?? "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        field.placeholderString = placeholder ?? label
        if let value {
            field.stringValue = maxLength.map { String(value.prefix($0)) } ?? value
        }
        let delegate = PromptFieldDelegate(confirmButton: confirm, maxLength: maxLength)
        field.delegate = delegate
        confirm.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.layout()

        let accepted: Bool
        if let window {
            guard window.attachedSheet == nil else { return nil }
            Task { @MainActor in
                field.selectText(nil)
            }
            accepted = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        } else {
            field.selectText(nil)
            accepted = alert.runModal() == .alertFirstButtonReturn
        }
        withExtendedLifetime(delegate) {}
        return accepted ? field.stringValue : nil
    }
}

@MainActor
private final class PromptFieldDelegate: NSObject, NSTextFieldDelegate {
    weak var confirmButton: NSButton?
    let maxLength: Int?

    init(confirmButton: NSButton, maxLength: Int?) {
        self.confirmButton = confirmButton
        self.maxLength = maxLength
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let maxLength, field.stringValue.count > maxLength {
            field.stringValue = String(field.stringValue.prefix(maxLength))
        }
        confirmButton?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
