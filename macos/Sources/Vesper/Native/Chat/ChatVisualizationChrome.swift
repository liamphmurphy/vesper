import AppKit
import SwiftUI
import VesperCore

// MARK: - Visualization PNG Export & Library Save

@MainActor
enum ChatVizExporter {
    static func renderPNG<V: View>(of view: V, width: CGFloat = 680) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func copyPNG<V: View>(of view: V, context: NativeScreenContext, width: CGFloat = 680) {
        guard let data = renderPNG(of: view, width: width) else {
            context.showToast(ToastItemModel(id: "viz.png.err", title: "Couldn’t render PNG", tone: .error))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        context.showToast(ToastItemModel(id: "viz.png.copy", title: "Copied chart PNG", tone: .success))
    }

    static func savePNGToLibrary<V: View>(
        of view: V,
        title: String,
        context: NativeScreenContext,
        width: CGFloat = 680
    ) async -> Bool {
        guard let data = renderPNG(of: view, width: width), let client = context.store.client else {
            context.showToast(ToastItemModel(id: "viz.lib.err", title: "Couldn’t save chart to Library", tone: .error))
            return false
        }
        let slug = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = "\(slug.isEmpty ? "chart" : slug).png"
        do {
            _ = try await client.uploadLibraryItem(fileName: filename, mime: "image/png", data: data)
            context.store.invalidate(QueryInvalidation(resources: ["library"]))
            context.showToast(ToastItemModel(id: "viz.lib.ok", title: "Saved chart to Library", tone: .success))
            return true
        } catch {
            context.showToast(ToastItemModel(
                id: "viz.lib.err",
                title: (error as? APIError)?.userMessage ?? "Couldn’t save chart to Library",
                tone: .error
            ))
            return false
        }
    }
}

// MARK: - Shared Theme Visualization Palette

/// Resolved SwiftUI colors from `VizPalette(theme:)` so every native chat visualization
/// shares the exact light/dark categorical and sequential palette.
struct ChatVizPalette {
    let raw: VizPalette
    let surface: Color
    let panel: Color
    let ink: Color
    let muted: Color
    let line: Color
    let grid: Color
    let series: [Color]
    let isDark: Bool

    init(theme: ThemeTokens) {
        let viz = VizPalette(theme: theme)
        self.raw = viz
        self.surface = Color(hex: viz.surface) ?? theme.palette.surface
        self.panel = Color(hex: viz.panel) ?? theme.palette.surface
        self.ink = Color(hex: viz.ink) ?? theme.palette.text
        self.muted = Color(hex: viz.muted) ?? theme.palette.secondaryText
        self.line = Color(hex: viz.line) ?? theme.palette.border
        self.grid = Color(hex: viz.grid) ?? theme.palette.rowBorder
        self.series = viz.series.map { Color(hex: $0) ?? theme.palette.accent }
        self.isDark = viz.isDark
    }

    func seriesColor(at index: Int) -> Color {
        guard !series.isEmpty else { return .accentColor }
        let safe = ((index % series.count) + series.count) % series.count
        return series[safe]
    }

    /// Sequential intensity color (`0.0 ... 1.0`) derived from the primary viz accent and surface.
    func sequentialColor(t: Double, accentIndex: Int = 0) -> Color {
        let clamped = max(0, min(1, t))
        if clamped <= 0.001 {
            return panel
        }
        let alpha = 0.16 + clamped * 0.84
        return seriesColor(at: accentIndex).opacity(alpha)
    }

    static func toneColor(_ tone: String?, theme: ThemeTokens) -> Color {
        switch tone?.lowercased() {
        case "positive", "success", "done", "ok", "green":
            return theme.swiftUIColor("state-done", fallback: .green)
        case "warning", "progress", "amber", "yellow", "caution":
            return theme.swiftUIColor("state-progress", fallback: .orange)
        case "negative", "danger", "error", "blocked", "failed", "red":
            return theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case "accent", "info", "blue":
            return theme.palette.accent
        default:
            return theme.palette.secondaryText
        }
    }
}

// MARK: - Shared Visualization Card Chrome

struct ChatVizCard<HeaderActions: View, Content: View>: View {
    @Environment(\.vesperTheme) private var theme

    let icon: String
    let title: String
    var subtitle: String? = nil
    var supportsLightbox: Bool = false
    @Binding var isLightboxPresented: Bool
    @ViewBuilder var actions: () -> HeaderActions
    @ViewBuilder var content: () -> Content

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        supportsLightbox: Bool = false,
        isLightboxPresented: Binding<Bool> = .constant(false),
        @ViewBuilder actions: @escaping () -> HeaderActions = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.supportsLightbox = supportsLightbox
        self._isLightboxPresented = isLightboxPresented
        self.actions = actions
        self.content = content
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                actions()
                if supportsLightbox {
                    Button {
                        isLightboxPresented = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .imageScale(.small)
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Expand to lightbox")
                    .accessibilityLabel("Expand \(title) to lightbox")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(p.rowBorder).frame(height: 1)
            content()
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - Invalid Spec Fallback View

/// Shown whenever any declarative visualization block fails validation:
/// surfaces the concrete error plus the raw fence source, never breaking the message.
struct ChatInvalidBlockView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let kind: String
    let error: String
    let source: String

    @State private var copied = false

    var body: some View {
        let p = theme.palette
        let errColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(errColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Invalid \(kind) block")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(errColor)
                    Text(error)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    context.copyToClipboard(source)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(errColor.opacity(0.08))

            Rectangle().fill(p.rowBorder).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(source.isEmpty ? "(empty)" : source)
                    .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                    .foregroundStyle(p.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(errColor.opacity(0.45)))
    }
}

// MARK: - Shared Visual Lightbox Modal (LAZYAGENTS-333)

struct ChatLightboxSheet<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    @State private var zoom: CGFloat = 1.0
    @GestureState private var pinchScale: CGFloat = 1.0

    private var effectiveZoom: CGFloat {
        max(0.5, min(3.5, zoom * pinchScale))
    }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { zoom = max(0.5, zoom - 0.25) }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .help("Zoom out")
                    .keyboardShortcut("-", modifiers: .command)

                    Text("\(Int((effectiveZoom * 100).rounded()))%")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                        .frame(minWidth: 42)

                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { zoom = min(3.5, zoom + 0.25) }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .help("Zoom in")
                    .keyboardShortcut("+", modifiers: .command)

                    Button("Fit") {
                        withAnimation(.easeOut(duration: 0.12)) { zoom = 1.0 }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    .keyboardShortcut("0", modifiers: .command)
                }
                .foregroundStyle(p.text)

                Button("Done") { dismiss() }
                    .buttonStyle(.vesper(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.swiftUIColor("surface-raised", fallback: p.surface))

            Rectangle().fill(p.rowBorder).frame(height: 1)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    content()
                        .frame(
                            minWidth: max(geo.size.width - 32, 600) * effectiveZoom,
                            minHeight: max(geo.size.height - 32, 360) * effectiveZoom,
                            alignment: .center
                        )
                        .scaleEffect(effectiveZoom, anchor: .topLeading)
                        .padding(16)
                }
                .gesture(
                    MagnificationGesture()
                        .updating($pinchScale) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            zoom = max(0.5, min(3.5, zoom * value))
                        }
                )
            }
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        }
        .frame(minWidth: 840, idealWidth: 1040, minHeight: 580, idealHeight: 720)
        .background(p.surface)
    }
}
