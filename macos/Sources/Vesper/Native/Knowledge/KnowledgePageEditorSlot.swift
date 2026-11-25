import SwiftUI
import VesperCore

/// Editor content slot for a Knowledge page.
///
/// Switches on `KnowledgeShellLogic.editorTarget(for:query:)` and renders:
/// - `.deck` -> redirects to full-screen `/apps/slides/<canvasId>`
/// - `.design` -> redirects to full-screen `/apps/designs/<canvasId>`
/// - standalone PDF page -> native `PDFViewerView`
/// - Docs (`page.kind == .document` with `page.canvasId != nil`) -> native `DocEditorView(canvasId:embedded: true)`
/// - Standard Knowledge markdown pages (`page.kind == .document`, `page.canvasId == nil`, non-PDF) -> native `KnowledgeEditorView`
struct KnowledgePageEditorSlot: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage
    let query: [String: String]
    var headingJumpRequest: KnowledgeHeadingJumpRequest?
    var onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)?
    var onRegisterSave: KnowledgeEditorView.RegisterSave?

    @State private var pdfModel = PDFViewerModel()

    var body: some View {
        let target = KnowledgeShellLogic.editorTarget(for: page, query: query)
        switch target {
        case .deck(_, let hostedPath):
            canvasRedirectView(label: "Opening presentation\u{2026}", destination: hostedPath)
        case .design(_, let hostedPath):
            canvasRedirectView(label: "Opening design\u{2026}", destination: hostedPath)
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
        case .hostedPage:
            if page.kind == .document, let canvasId = page.canvasId, !canvasId.isEmpty {
                DocEditorView(canvasId: canvasId, embedded: true)
                    .id(canvasId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KnowledgeEditorView(
                    page: page,
                    headingJumpRequest: headingJumpRequest,
                    onHeadingsChange: onHeadingsChange,
                    onRegisterSave: onRegisterSave
                )
                    .id(page.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func canvasRedirectView(label: String, destination: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: destination) {
            context.navigate(destination, replace: true)
        }
    }
}
