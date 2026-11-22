import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// File payload extracted from pasteboard or drag-and-drop inside the macOS composer editor.
struct ChatComposerIncomingFile: Sendable {
    let filename: String
    let contentType: String
    let data: Data
    let localURL: URL?
}

/// Isolated macOS AppKit TextKit 2 editor for the native chat composer.
/// All `NSTextView` / pasteboard / drag-and-drop glue lives in this single file so iOS can swap
/// in a `UITextView` adapter cleanly.
struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorUTF16: Int
    @Binding var measuredHeight: CGFloat

    let placeholder: String
    let fontSize: CGFloat
    let textColor: Color
    let placeholderColor: Color
    let isDisabled: Bool
    let isCompletionOpen: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat

    let onSubmit: @MainActor () -> Void
    let onCompletionNavigate: @MainActor (Int) -> Void
    let onCompletionAccept: @MainActor () -> Void
    let onCompletionDismiss: @MainActor () -> Void
    let onAttachFiles: @MainActor ([ChatComposerIncomingFile]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = !isDisabled
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.writingToolsBehavior = .complete
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = NSColor(textColor)
        textView.insertionPointColor = NSColor(textColor)
        textView.placeholderText = placeholder
        textView.placeholderColor = NSColor(placeholderColor)
        textView.registerForDraggedTypes([.fileURL] + Coordinator.imagePasteboardTypes)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.appliedStyle = Coordinator.AppliedStyle(
            fontSize: fontSize,
            textColor: textColor,
            placeholder: placeholder,
            placeholderColor: placeholderColor,
            isDisabled: isDisabled
        )
        context.coordinator.wasEmpty = text.isEmpty
        context.coordinator.lastReportedHeight = measuredHeight
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        // Only mutate NSTextView appearance when it actually changed: writing `font` or
        // `textColor` unconditionally re-attributes the whole text storage and forces a
        // full TextKit 2 relayout on every keystroke.
        let prev = coordinator.appliedStyle
        if prev?.isDisabled != isDisabled {
            textView.isEditable = !isDisabled
        }
        if prev?.fontSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }
        if prev?.textColor != textColor {
            let color = NSColor(textColor)
            textView.textColor = color
            textView.insertionPointColor = color
        }
        if prev?.placeholder != placeholder || prev?.placeholderColor != placeholderColor {
            textView.placeholderText = placeholder
            textView.placeholderColor = NSColor(placeholderColor)
            if textView.string.isEmpty {
                textView.needsDisplay = true
            }
        }
        coordinator.appliedStyle = Coordinator.AppliedStyle(
            fontSize: fontSize,
            textColor: textColor,
            placeholder: placeholder,
            placeholderColor: placeholderColor,
            isDisabled: isDisabled
        )

        if textView.string != text {
            coordinator.isProgrammaticUpdate = true
            textView.string = text
            let clamped = max(0, min(cursorUTF16, (text as NSString).length))
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            coordinator.isProgrammaticUpdate = false
            coordinator.wasEmpty = text.isEmpty
            textView.needsDisplay = true
            coordinator.recalculateHeight()
        } else {
            let currentRange = textView.selectedRange()
            if currentRange.length == 0 && currentRange.location != cursorUTF16 && !textView.hasMarkedText() {
                let clamped = max(0, min(cursorUTF16, (text as NSString).length))
                if currentRange.location != clamped {
                    coordinator.isProgrammaticUpdate = true
                    textView.setSelectedRange(NSRange(location: clamped, length: 0))
                    coordinator.isProgrammaticUpdate = false
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct AppliedStyle: Equatable {
            var fontSize: CGFloat
            var textColor: Color
            var placeholder: String
            var placeholderColor: Color
            var isDisabled: Bool
        }

        var parent: ChatComposerTextView
        weak var textView: ComposerNSTextView?
        var isProgrammaticUpdate = false
        var appliedStyle: AppliedStyle?
        var wasEmpty = true
        var lastReportedHeight: CGFloat = 0
        private var pastedImageCounter = 0

        init(_ parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            let nextText = textView.string
            let loc = textView.selectedRange().location
            parent.text = nextText
            if parent.cursorUTF16 != loc {
                parent.cursorUTF16 = loc
            }
            let nowEmpty = nextText.isEmpty
            if nowEmpty != wasEmpty {
                wasEmpty = nowEmpty
                textView.needsDisplay = true
            }
            recalculateHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            let loc = textView.selectedRange().location
            if parent.cursorUTF16 != loc {
                parent.cursorUTF16 = loc
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }

            if parent.isCompletionOpen {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onCompletionNavigate(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onCompletionNavigate(1)
                    return true
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)):
                    parent.onCompletionAccept()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onCompletionDismiss()
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }

            return false
        }

        func recalculateHeight() {
            guard let textView, let textContainer = textView.textContainer else { return }
            let contentHeight: CGFloat
            if let tlm = textView.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
                contentHeight = tlm.usageBoundsForTextContainer.height
            } else if let lm = textView.layoutManager {
                lm.ensureLayout(for: textContainer)
                contentHeight = lm.usedRect(for: textContainer).height
            } else {
                contentHeight = parent.minHeight
            }
            let inset = textView.textContainerInset.height * 2
            let target = min(max(ceil(contentHeight + inset), parent.minHeight), parent.maxHeight)
            if abs(lastReportedHeight - target) > 0.5 || abs(parent.measuredHeight - target) > 0.5 {
                lastReportedHeight = target
                Task { @MainActor [weak self] in
                    self?.parent.measuredHeight = target
                }
            }
        }

        static let imagePasteboardTypes: [NSPasteboard.PasteboardType] =
            ChatAttachmentRules.pastedImageTypeIdentifiers.map { NSPasteboard.PasteboardType($0) }

        /// Fast check used by menu validation (`validateUserInterfaceItem`) and drag entry
        /// so `⌘V` is enabled when the clipboard holds only an image or file URL.
        func canHandlePasteboard(_ pb: NSPasteboard) -> Bool {
            if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                return true
            }
            return pb.availableType(from: Self.imagePasteboardTypes) != nil
        }

        func handlePasteboard(_ pb: NSPasteboard) -> Bool {
            let files = extractFiles(from: pb)
            guard !files.isEmpty else { return false }
            parent.onAttachFiles(files)
            return true
        }

        private func extractFiles(from pb: NSPasteboard) -> [ChatComposerIncomingFile] {
            var result: [ChatComposerIncomingFile] = []

            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                for url in urls {
                    guard url.isFileURL else { continue }
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let filename = url.lastPathComponent
                    let mime = ChatAttachmentRules.mimeType(for: filename)
                    result.append(ChatComposerIncomingFile(
                        filename: filename,
                        contentType: mime,
                        data: data,
                        localURL: url
                    ))
                }
                // Finder places the file/folder icon in .tiff alongside .fileURL; do not fall through to raw image types.
                return result
            }

            for typeId in ChatAttachmentRules.pastedImageTypeIdentifiers {
                let pbType = NSPasteboard.PasteboardType(typeId)
                guard let rawData = pb.data(forType: pbType), !rawData.isEmpty else { continue }
                if let mime = ChatAttachmentRules.directMimeType(forImageTypeIdentifier: typeId) {
                    pastedImageCounter += 1
                    let name = ChatAttachmentRules.pastedImageName(contentType: mime, index: pastedImageCounter)
                    result.append(ChatComposerIncomingFile(filename: name, contentType: mime, data: rawData, localURL: nil))
                    return result
                }
                if let pngData = Self.transcodeToPNG(rawData) {
                    pastedImageCounter += 1
                    let name = ChatAttachmentRules.pastedImageName(contentType: "image/png", index: pastedImageCounter)
                    result.append(ChatComposerIncomingFile(filename: name, contentType: "image/png", data: pngData, localURL: nil))
                    return result
                }
            }

            return result
        }

        private static func transcodeToPNG(_ data: Data) -> Data? {
            if let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                return rep.representation(using: .png, properties: [:])
            }
            return nil
        }
    }
}

/// TextKit 2 `NSTextView` subclass handling placeholder drawing, clipboard image/file paste,
/// and drag-and-drop file attachment.
final class ComposerNSTextView: NSTextView {
    weak var coordinator: ChatComposerTextView.Coordinator?
    var placeholderText: String = ""
    var placeholderColor: NSColor = .placeholderTextColor

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // Plain-text NSTextView disables Edit -> Paste (⌘V) when the pasteboard only contains
        // an image or file URL; enable it whenever our coordinator can attach the payload.
        if item.action == #selector(NSText.paste(_:)),
           isEditable,
           coordinator?.canHandlePasteboard(.general) == true {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if coordinator?.handlePasteboard(.general) == true {
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if coordinator?.canHandlePasteboard(sender.draggingPasteboard) == true {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if coordinator?.handlePasteboard(sender.draggingPasteboard) == true {
            return true
        }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: placeholderColor,
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 2),
            y: textContainerOrigin.y
        )
        (placeholderText as NSString).draw(at: origin, withAttributes: attrs)
    }
}
