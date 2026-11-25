import SwiftUI
import VesperCore
import WebKit

/// Renders `.embedded(kind, source, info, index)` blocks on iOS:
/// - `.svgImage` & `.svgSteps`: sandboxed inline SVG via `WKWebView` (plus step controls & captions)
/// - `.mermaid`: Mermaid diagram via `WKWebView` (with source toggle)
/// - `.app`: sandboxed interactive HTML/JS mini-app via `WKWebView` (with Preview/Code toggle & fullscreen)
/// - `.math`: display math card
struct ChatEmbeddedBlockView: View {
    let kind: EmbeddedBlockKind
    let source: String
    let info: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showCode = false
    @State private var showFullscreen = false
    @State private var currentStep = 1

    private var vizPalette: VizPalette {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        switch kind {
        case .svgImage:
            svgImageCard
        case .svgSteps:
            svgStepsCard
        case .mermaid:
            mermaidCard
        case .app:
            interactiveAppCard
        case .math:
            mathCard
        }
    }

    // MARK: - SVG Image

    private var svgImageCard: some View {
        let themed = ChatSVG.theme(source, palette: vizPalette)
        let title = ChatSVG.title(source) ?? "Diagram"
        let size = ChatSVG.intrinsicSize(source)
        let aspect = size.width > 0 && size.height > 0 ? max(0.35, min(2.4, size.width / size.height)) : 1.5

        return VStack(alignment: .leading, spacing: 8) {
            cardHeader(icon: "sparkles.rectangle.stack", title: title, canExpand: true)
            if showCode {
                codeScroll(source)
            } else {
                SandboxedHTMLView(html: Self.svgHTML(themed, dark: colorScheme == .dark))
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(minHeight: 160, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showFullscreen) {
            fullscreenSheet(title: title, html: Self.svgHTML(themed, dark: colorScheme == .dark))
        }
    }

    // MARK: - SVG Steps

    private var svgStepsCard: some View {
        let parsed = ChatSVG.parseStepsFence(source)
        let total = max(1, ChatSVG.stepCount(parsed.svg, captions: parsed.captions))
        let clamped = min(max(1, currentStep), total)
        let frame = ChatSVG.theme(ChatSVG.stepFrame(parsed.svg, step: clamped), palette: vizPalette)
        let caption = clamped <= parsed.captions.count ? parsed.captions[clamped - 1] : nil
        let title = ChatSVG.title(parsed.svg) ?? "Step-by-Step Diagram"

        return VStack(alignment: .leading, spacing: 8) {
            cardHeader(icon: "rectangle.stack", title: "\(title) (\(clamped)/\(total))", canExpand: true)
            if showCode {
                codeScroll(source)
            } else {
                SandboxedHTMLView(html: Self.svgHTML(frame, dark: colorScheme == .dark))
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                HStack {
                    Button {
                        currentStep = max(1, clamped - 1)
                    } label: {
                        Label("Prev", systemImage: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(clamped <= 1)

                    Spacer()
                    Text("Step \(clamped) of \(total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        currentStep = min(total, clamped + 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(clamped >= total)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showFullscreen) {
            fullscreenSheet(title: title, html: Self.svgHTML(frame, dark: colorScheme == .dark))
        }
    }

    // MARK: - Mermaid

    private var mermaidCard: some View {
        let html = Self.mermaidHTML(source, dark: colorScheme == .dark)
        return VStack(alignment: .leading, spacing: 8) {
            cardHeader(icon: "point.3.connected.trianglepath.dotted", title: "Mermaid Diagram", canExpand: true)
            if showCode {
                codeScroll(source)
            } else {
                SandboxedHTMLView(html: html, allowCDN: true)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showFullscreen) {
            fullscreenSheet(title: "Mermaid Diagram", html: html, allowCDN: true)
        }
    }

    // MARK: - Interactive App

    private var interactiveAppCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(icon: "app.badge", title: "Interactive App", canExpand: true)
            if showCode {
                codeScroll(source)
            } else {
                SandboxedHTMLView(html: source, allowCDN: true)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showFullscreen) {
            fullscreenSheet(title: "Interactive App", html: source, allowCDN: true)
        }
    }

    // MARK: - Display Math

    private var mathCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Math", systemImage: "function")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(.callout, design: .serif))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Chrome Helpers

    private func cardHeader(icon: String, title: String, canExpand: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(showCode ? "Preview" : "Code") {
                showCode.toggle()
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if canExpand && !showCode {
                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func codeScroll(_ code: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(code)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 240)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fullscreenSheet(title: String, html: String, allowCDN: Bool = false) -> some View {
        NavigationStack {
            SandboxedHTMLView(html: html, allowCDN: allowCDN)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showFullscreen = false }
                    }
                }
        }
    }

    private static func svgHTML(_ svg: String, dark: Bool) -> String {
        let bg = dark ? "#1c1c1e" : "#ffffff"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:8px;background:\(bg);display:flex;align-items:center;justify-content:center;min-height:100vh;box-sizing:border-box;}svg{max-width:100%;height:auto;}</style>
        </head><body>\(ChatSVG.document(svg))</body></html>
        """
    }

    private static func mermaidHTML(_ code: String, dark: Bool) -> String {
        let bg = dark ? "#1c1c1e" : "#ffffff"
        let fg = dark ? "#f2f2f7" : "#1c1c1e"
        let theme = dark ? "dark" : "default"
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:10px;background:\(bg);color:\(fg);font-family:-apple-system,sans-serif;}pre.mermaid{margin:0;font-size:12px;white-space:pre-wrap;}</style>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        <script>window.addEventListener('DOMContentLoaded',function(){if(window.mermaid){mermaid.initialize({startOnLoad:true,theme:'\(theme)',securityLevel:'strict'});}});</script>
        </head><body><pre class="mermaid">\(escaped)</pre></body></html>
        """
    }
}

// MARK: - Sandboxed WKWebView for iOS

private struct SandboxedHTMLView: UIViewRepresentable {
    let html: String
    var allowCDN: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(allowCDN: allowCDN) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            uiView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let allowCDN: Bool
        var lastHTML: String = ""

        init(allowCDN: Bool) { self.allowCDN = allowCDN }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
}
