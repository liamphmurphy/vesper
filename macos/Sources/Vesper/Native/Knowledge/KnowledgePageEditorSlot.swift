import SwiftUI
import VesperCore

/// Editor content slot for a Knowledge page.
///
/// **Seam for LAZYAGENTS-288** (native Markdown / Live-Preview knowledge page editor):
/// switches on `KnowledgeShellLogic.editorTarget(for:query:)` and renders:
/// - `.deck` -> `HostedWebPageView(path: "/apps/slides/<canvasId>")`
/// - `.design` -> `HostedWebPageView(path: "/apps/designs/<canvasId>")`
/// - standalone PDF page -> native `PDFViewerView`
/// - Knowledge/Doc page -> `HostedWebPageView(path: "/knowledge/<id>?embed=1")` (or `/apps/docs/<canvasId>`)
struct KnowledgePageEditorSlot: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage
    let query: [String: String]

    @State private var pdfModel = PDFViewerModel()

    var body: some View {
        let target = KnowledgeShellLogic.editorTarget(for: page, query: query)
        switch target {
        case .deck(_, let hostedPath), .design(_, let hostedPath), .hostedPage(let hostedPath):
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
        }
    }
}
