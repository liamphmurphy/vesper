import SwiftUI
import VesperCore

/// Editor content slot for a Knowledge page.
///
/// Switches on `KnowledgeShellLogic.editorTarget(for:query:)` and renders:
/// - `.deck` -> `HostedWebPageView(path: "/apps/slides/<canvasId>")`
/// - `.design` -> `HostedWebPageView(path: "/apps/designs/<canvasId>")`
/// - standalone PDF page -> native `PDFViewerView`
/// - Docs (`page.kind == .document` with `page.canvasId != nil`) -> Tiptap `HostedWebPageView(path: "/apps/docs/<canvasId>")`
/// - Standard Knowledge markdown pages (`page.kind == .document`, `page.canvasId == nil`, non-PDF) -> native `KnowledgeEditorView`
struct KnowledgePageEditorSlot: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage
    let query: [String: String]
    var headingJumpRequest: KnowledgeHeadingJumpRequest?
    var onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)?

    @State private var pdfModel = PDFViewerModel()

    var body: some View {
        let target = KnowledgeShellLogic.editorTarget(for: page, query: query)
        switch target {
        case .deck(_, let hostedPath), .design(_, let hostedPath):
            HostedWebPageView(path: hostedPath)
                .id(hostedPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pdf(let sourcePath, let title):
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(theme.palette.secondaryText)
                    Text(title)
                        .vesperText(.heading, theme)
                        .lineLimit(1)
                    Spacer()
                    Button("Open in PDF Viewer") {
                        let encoded = APIQuery.encode([
                            URLQueryItem(name: "src", value: sourcePath),
                            URLQueryItem(name: "title", value: title),
                        ])
                        context.navigate("/pdf?\(encoded)")
                    }
                    .buttonStyle(.vesper())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.palette.surface)

                Divider().overlay(theme.palette.border)

                PDFViewerView(model: pdfModel) {
                    Task { await pdfModel.load(path: sourcePath, client: context.store.client) }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: sourcePath) {
                await pdfModel.load(path: sourcePath, client: context.store.client)
            }
            .onAppear {
                context.find.searcher = pdfModel
            }
            .onDisappear {
                if context.find.searcher === pdfModel {
                    context.find.searcher = nil
                }
            }
        case .hostedPage(let hostedPath):
            if page.kind == .document, let canvasId = page.canvasId, !canvasId.isEmpty {
                let docPath = hostedPath.hasPrefix("/apps/docs/") ? hostedPath : "/apps/docs/\(canvasId)"
                HostedWebPageView(path: docPath)
                    .id(docPath)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KnowledgeEditorView(
                    page: page,
                    headingJumpRequest: headingJumpRequest,
                    onHeadingsChange: onHeadingsChange
                )
                    .id(page.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
