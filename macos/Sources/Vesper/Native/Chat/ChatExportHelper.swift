import AppKit
import UniformTypeIdentifiers
import VesperCore

@MainActor
enum ChatExportHelper {
    /// Writes a chat transcript as clean Markdown (with optional tool traces) via NSSavePanel.
    static func exportMarkdown(
        session: API.ChatSession,
        messages: [API.ChatMessage],
        eventsByRunId: [String: [API.RunEvent]],
        includeToolTraces: Bool
    ) throws -> URL? {
        let md = ChatExportLogic.exportMarkdown(
            session: session,
            messages: messages,
            eventsByRunId: eventsByRunId,
            includeToolTraces: includeToolTraces
        )
        let defaultName = ChatExportLogic.defaultFileName(title: ChatNav.chatTitle(session.title), ext: "md")
        return try SettingsFilePanels.saveText(
            md,
            defaultName: defaultName,
            contentType: .plainText,
            title: includeToolTraces ? "Export Chat Markdown (with Tool Traces)" : "Export Chat Markdown"
        )
    }

    /// Renders a chat transcript to a paginated PDF using `PrintRenderer` + `PrintTextView` and saves it via NSSavePanel.
    static func exportPDF(
        session: API.ChatSession,
        messages: [API.ChatMessage],
        eventsByRunId: [String: [API.RunEvent]],
        includeToolTraces: Bool = false
    ) throws -> URL? {
        let defaultName = ChatExportLogic.defaultFileName(title: ChatNav.chatTitle(session.title), ext: "pdf")
        guard let url = SettingsFilePanels.pickSaveURL(
            defaultName: defaultName,
            contentTypes: [.pdf],
            title: "Export Chat as PDF"
        ) else {
            return nil
        }

        let document = ChatExportLogic.printDocument(
            session: session,
            messages: messages,
            eventsByRunId: eventsByRunId,
            includeToolTraces: includeToolTraces
        )
        let info = PrintRenderer.printInfo()
        let width = PrintRenderer.printableWidth(info)
        let rendered = PrintRenderer.render(document, width: width)
        let view = PrintTextView(text: rendered, title: document.title, width: width)
        let rect = NSRect(origin: .zero, size: view.bounds.size)
        let op = NSPrintOperation.pdfOperation(with: view, inside: rect, toPath: url.path, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        let ok = op.run()
        if !ok {
            throw NSError(domain: "VesperChatExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write PDF file."])
        }
        return url
    }
}
