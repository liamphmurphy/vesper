import AppKit
import AVKit
import Combine
import PDFKit
import SwiftUI
import VesperCore

// MARK: - Shared Attachment Actions

@MainActor
enum KnowledgeAttachmentActions {
    static func openFullscreen(
        url: String,
        title: String,
        contentType: String?,
        context: NativeScreenContext
    ) {
        let resolved = context.resolvedURL(url)?.absoluteString ?? url
        context.showQuickLook([
            QuickLookItem(url: resolved, title: title, filename: title, contentType: contentType),
        ], index: 0)
    }

    static func openInExternalApp(
        url: String,
        filename: String,
        contentType: String?,
        context: NativeScreenContext
    ) {
        guard let client = context.store.client else { return }
        Task { @MainActor in
            do {
                let localURL = try await LibraryFiles.localFile(
                    path: url,
                    filename: filename,
                    contentType: contentType,
                    client: client
                )
                if !NSWorkspace.shared.open(localURL) {
                    context.showToast(ToastItemModel(
                        id: "knowledge.open-app.err.\(url)",
                        title: "Couldn\u{2019}t open \(filename) in another app",
                        tone: .error
                    ))
                }
            } catch {
                context.showToast(ToastItemModel(
                    id: "knowledge.open-app.err.\(url)",
                    title: "Couldn\u{2019}t open \(filename)",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }

    static func saveCopy(
        url: String,
        filename: String,
        contentType: String?,
        context: NativeScreenContext
    ) {
        LibraryFiles.saveCopy(
            path: url,
            filename: filename,
            contentType: contentType,
            client: context.store.client,
            context: context
        )
    }

    static func copyFile(
        url: String,
        filename: String,
        contentType: String?,
        context: NativeScreenContext
    ) {
        guard let client = context.store.client else { return }
        Task { @MainActor in
            do {
                let localURL = try await LibraryFiles.localFile(
                    path: url,
                    filename: filename,
                    contentType: contentType,
                    client: client
                )
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([localURL as NSURL])
                context.showToast(ToastItemModel(
                    id: "knowledge.copy-file.ok.\(url)",
                    title: "Copied \(filename)",
                    tone: .success
                ))
            } catch {
                context.showToast(ToastItemModel(
                    id: "knowledge.copy-file.err.\(url)",
                    title: "Couldn\u{2019}t copy \(filename)",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }

    static func typeLabel(for contentType: String?, filename: String) -> String {
        let ct = contentType?.lowercased() ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()
        if ct.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "avif"].contains(ext) {
            return "Image"
        }
        if ct.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext) {
            return "Video"
        }
        if ct.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "aiff"].contains(ext) {
            return "Audio"
        }
        if ct.contains("pdf") || ext == "pdf" {
            return "PDF"
        }
        if ct.contains("zip") || ct.contains("tar") || ct.contains("gzip") || ["zip", "tar", "gz", "7z"].contains(ext) {
            return "Archive"
        }
        if !ext.isEmpty {
            return ext.uppercased()
        }
        return "File"
    }

    static func sfSymbol(for contentType: String?, filename: String) -> String {
        let ct = contentType?.lowercased() ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()
        if ct.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "avif"].contains(ext) {
            return "photo"
        }
        if ct.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext) {
            return "film"
        }
        if ct.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "aiff"].contains(ext) {
            return "waveform"
        }
        if ct.contains("pdf") || ext == "pdf" {
            return "doc.richtext"
        }
        if ct.contains("zip") || ct.contains("tar") || ct.contains("gzip") || ["zip", "tar", "gz", "7z"].contains(ext) {
            return "doc.zipper"
        }
        if ct.contains("csv") || ct.contains("spreadsheet") || ["csv", "tsv", "xlsx", "numbers"].contains(ext) {
            return "tablecells"
        }
        if ct.hasPrefix("text/") || ct.contains("json") || ["txt", "md", "json", "yaml", "yml", "xml"].contains(ext) {
            return "doc.text"
        }
        return "doc"
    }

    static func formattedSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func mediaClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Local Media File Loader

@MainActor
@Observable
final class KnowledgeMediaFileLoader {
    var localURL: URL?
    var error: String?
    var isLoading = false

    func load(url: String, filename: String, contentType: String?, client: APIClient?) async {
        guard localURL == nil, !isLoading else { return }
        guard let client else {
            error = APIError.unauthorized.userMessage
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            localURL = try await LibraryFiles.localFile(
                path: url,
                filename: filename,
                contentType: contentType,
                client: client
            )
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

// MARK: - Shared Action Buttons

struct KnowledgeMediaActionButtons: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let filename: String
    let contentType: String?
    var embedRef: String? = nil
    var extraPDFViewerAction: (() -> Void)? = nil

    var body: some View {
        let p = theme.palette
        HStack(spacing: 4) {
            Button {
                KnowledgeAttachmentActions.openFullscreen(
                    url: url,
                    title: filename,
                    contentType: contentType,
                    context: context
                )
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(p.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open Fullscreen (Quick Look)")
            .accessibilityLabel("Open Fullscreen")

            if let extraPDFViewerAction {
                Button(action: extraPDFViewerAction) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open in PDF Viewer")
                .accessibilityLabel("Open in PDF Viewer")
            }

            Button {
                KnowledgeAttachmentActions.openInExternalApp(
                    url: url,
                    filename: filename,
                    contentType: contentType,
                    context: context
                )
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(p.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open in Another App")
            .accessibilityLabel("Open in Another App")

            Menu {
                Button("Open Fullscreen (Quick Look)") {
                    KnowledgeAttachmentActions.openFullscreen(
                        url: url,
                        title: filename,
                        contentType: contentType,
                        context: context
                    )
                }
                Button("Open in Another App") {
                    KnowledgeAttachmentActions.openInExternalApp(
                        url: url,
                        filename: filename,
                        contentType: contentType,
                        context: context
                    )
                }
                if let embedRef, !embedRef.isEmpty {
                    Button("Copy Embed Link") {
                        context.copyToClipboard(embedRef)
                        context.showToast(ToastItemModel(id: "knowledge.att.copy", title: "Copied embed link", tone: .success))
                    }
                }
                Button("Copy File") {
                    KnowledgeAttachmentActions.copyFile(
                        url: url,
                        filename: filename,
                        contentType: contentType,
                        context: context
                    )
                }
                Divider()
                Button("Download\u{2026}") {
                    KnowledgeAttachmentActions.saveCopy(
                        url: url,
                        filename: filename,
                        contentType: contentType,
                        context: context
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
        }
    }
}

// MARK: - Inline Image Card

struct KnowledgeInlineImageCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let label: String
    let contentType: String?
    let embedRef: String?
    let maxImageWidth: CGFloat
    let maxImageHeight: CGFloat
    var containerMaxWidth: CGFloat? = nil
    var explicitDimensions: KnowledgeEmbedDimensions? = nil
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onResizeWidth: ((Int?) -> Void)? = nil

    @State private var isHovered = false
    @State private var dragStartWidth: CGFloat?
    @State private var liveDragWidth: CGFloat?

    private var effectiveContainerMaxWidth: CGFloat {
        max(120, containerMaxWidth ?? maxImageWidth)
    }

    private var activeDimensions: KnowledgeEmbedDimensions? {
        if let liveDragWidth {
            return KnowledgeEmbedDimensions(width: liveDragWidth, height: nil)
        }
        return explicitDimensions
    }

    var body: some View {
        let p = theme.palette
        let captionMaxWidth: CGFloat = {
            if let dims = activeDimensions {
                return min(effectiveContainerMaxWidth, max(120, dims.width))
            }
            return maxImageWidth
        }()

        VStack(alignment: .leading, spacing: 4) {
            AuthenticatedImageView(source: url, maxPixel: 1600) { img, naturalSize in
                let fitted = KnowledgeMarkdownSyntax.fittedInlineImageSize(
                    naturalSize: naturalSize,
                    maxWidth: maxImageWidth,
                    maxHeight: maxImageHeight,
                    explicitDimensions: activeDimensions,
                    containerMaxWidth: effectiveContainerMaxWidth
                )
                ZStack(alignment: .bottomTrailing) {
                    img.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? p.accent : (liveDragWidth != nil ? p.accent.opacity(0.7) : .clear), lineWidth: isSelected ? 2 : 1.5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            KnowledgeAttachmentActions.openFullscreen(
                                url: url,
                                title: label,
                                contentType: contentType,
                                context: context
                            )
                        }
                        .onTapGesture(count: 1) {
                            if let onSelect {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                onSelect()
                            } else {
                                KnowledgeAttachmentActions.openFullscreen(
                                    url: url,
                                    title: label,
                                    contentType: contentType,
                                    context: context
                                )
                            }
                        }

                    if let liveDragWidth {
                        Text("\(Int(liveDragWidth.rounded())) px")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.72), in: Capsule())
                            .padding(.trailing, 30)
                            .padding(.bottom, 8)
                            .allowsHitTesting(false)
                    }

                    if onResizeWidth != nil && (isHovered || isSelected || liveDragWidth != nil) {
                        resizeHandle(currentWidth: fitted.width)
                            .padding(6)
                    }
                }
            } placeholder: {
                ProgressView().controlSize(.small).padding(16)
            } failure: {
                Label(label, systemImage: "photo")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                    .padding(10)
            }

            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: theme.pointSize(.micro) + 1))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                if let dims = activeDimensions {
                    Text("\(Int(dims.width.rounded()))px")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 4)
                KnowledgeMediaActionButtons(
                    url: url,
                    filename: label,
                    contentType: contentType,
                    embedRef: embedRef
                )
            }
            .frame(maxWidth: captionMaxWidth, alignment: .leading)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Open Fullscreen (Quick Look)") {
                KnowledgeAttachmentActions.openFullscreen(url: url, title: label, contentType: contentType, context: context)
            }
            Button("Open in Another App") {
                KnowledgeAttachmentActions.openInExternalApp(url: url, filename: label, contentType: contentType, context: context)
            }
            Button("Copy File") {
                KnowledgeAttachmentActions.copyFile(url: url, filename: label, contentType: contentType, context: context)
            }
            if explicitDimensions != nil, let onResizeWidth {
                Divider()
                Button("Reset Image Size") {
                    onResizeWidth(nil)
                }
            }
            Divider()
            Button("Download\u{2026}") {
                KnowledgeAttachmentActions.saveCopy(url: url, filename: label, contentType: contentType, context: context)
            }
        }
    }

    private func resizeHandle(currentWidth: CGFloat) -> some View {
        let p = theme.palette
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(p.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.35), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .help("Drag to resize image (double-click to reset)")
            .onTapGesture(count: 2) {
                onResizeWidth?(nil)
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = dragStartWidth ?? currentWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        let clamped = max(80, min(effectiveContainerMaxWidth, start + value.translation.width))
                        liveDragWidth = clamped
                    }
                    .onEnded { value in
                        let start = dragStartWidth ?? currentWidth
                        let final = max(80, min(effectiveContainerMaxWidth, start + value.translation.width))
                        dragStartWidth = nil
                        liveDragWidth = nil
                        onResizeWidth?(Int(final.rounded()))
                    }
            )
    }
}

// MARK: - Inline Video Card

struct KnowledgeInlineVideoCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let label: String
    let contentType: String?
    let embedRef: String?
    var playerHeight: CGFloat = 300
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var loader = KnowledgeMediaFileLoader()
    @State private var player: AVPlayer?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let err = loader.error {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text("Couldn\u{2019}t load video: \(err)")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: playerHeight)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 8))

            Divider().overlay(p.border)

            HStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 12))
                    .foregroundStyle(p.accent)
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                KnowledgeMediaActionButtons(
                    url: url,
                    filename: label,
                    contentType: contentType,
                    embedRef: embedRef
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(p.surface)
            .contentShape(Rectangle())
            .onTapGesture {
                if let onSelect {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    onSelect()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? p.accent : p.border, lineWidth: isSelected ? 2 : 1))
        .task(id: url) {
            await loader.load(url: url, filename: label, contentType: contentType, client: context.store.client)
            if let local = loader.localURL, player == nil {
                player = AVPlayer(url: local)
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Inline Audio Card

struct KnowledgeInlineAudioCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let label: String
    let contentType: String?
    let embedRef: String?
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var loader = KnowledgeMediaFileLoader()
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var rate: Double = 1.0
    @State private var isScrubbing = false

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundStyle(p.accent)
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                KnowledgeMediaActionButtons(
                    url: url,
                    filename: label,
                    contentType: contentType,
                    embedRef: embedRef
                )
            }

            if let err = loader.error {
                Text("Couldn\u{2019}t load audio: \(err)")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            } else {
                HStack(spacing: 10) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(player == nil)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")

                    Slider(
                        value: Binding(
                            get: { duration > 0 ? min(max(position, 0), duration) : 0 },
                            set: { next in
                                position = next
                                player?.seek(to: CMTime(seconds: next, preferredTimescale: 600))
                            }
                        ),
                        in: 0...max(duration, 0.1),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                        }
                    )
                    .disabled(player == nil || duration <= 0)

                    Text("\(KnowledgeAttachmentActions.mediaClock(position)) / \(KnowledgeAttachmentActions.mediaClock(duration))")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                        .fixedSize()

                    Button("\(rate.formatted())\u{00D7}") {
                        rate = LibraryLogic.nextSpeed(rate)
                        if isPlaying {
                            player?.rate = Float(rate)
                        }
                    }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                    .help("Playback speed")
                }
            }
        }
        .padding(10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? p.accent : p.border, lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if let onSelect {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onSelect()
            }
        }
        .task(id: url) {
            await loader.load(url: url, filename: label, contentType: contentType, client: context.store.client)
            guard let local = loader.localURL, player == nil else { return }
            let avPlayer = AVPlayer(url: local)
            player = avPlayer
            if let secs = try? await avPlayer.currentItem?.asset.load(.duration).seconds,
               secs.isFinite, secs > 0 {
                duration = secs
            }
        }
        .onReceive(tick) { _ in
            guard let player, !isScrubbing else { return }
            let cur = player.currentTime().seconds
            if cur.isFinite, cur >= 0 {
                position = cur
            }
            if isPlaying && player.timeControlStatus == .paused && duration > 0 && position >= duration - 0.1 {
                isPlaying = false
            }
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && position >= duration - 0.1 {
                player.seek(to: .zero)
                position = 0
            }
            player.playImmediately(atRate: Float(rate))
            isPlaying = true
        }
    }
}

// MARK: - Inline PDF Card

private struct InlinePDFKitView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct KnowledgeInlinePDFCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let label: String
    let contentType: String?
    let embedRef: String?
    var viewerHeight: CGFloat = 420
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var model = PDFViewerModel()

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 13))
                    .foregroundStyle(p.accent)
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)

                if model.pageCount > 0 {
                    Text("Page \(model.pageIndex + 1) of \(model.pageCount)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .fixedSize()

                    HStack(spacing: 2) {
                        Button {
                            model.go(toPage: model.pageIndex - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.pageIndex <= 0)
                        .help("Previous page")

                        Button {
                            model.go(toPage: model.pageIndex + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.pageIndex >= model.pageCount - 1)
                        .help("Next page")
                    }
                }

                Spacer(minLength: 4)

                KnowledgeMediaActionButtons(
                    url: url,
                    filename: label,
                    contentType: contentType,
                    embedRef: embedRef,
                    extraPDFViewerAction: {
                        let encoded = APIQuery.encode([
                            URLQueryItem(name: "src", value: url),
                            URLQueryItem(name: "title", value: label),
                        ])
                        context.navigate("/pdf?\(encoded)")
                    }
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(p.surface)
            .contentShape(Rectangle())
            .onTapGesture {
                if let onSelect {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    onSelect()
                }
            }

            Divider().overlay(p.border)

            ZStack {
                theme.swiftUIColor("surface-sunken", fallback: p.surface)
                if model.phase == .loaded {
                    InlinePDFKitView(pdfView: model.pdfView)
                } else if case .failed(let message) = model.phase {
                    VStack(spacing: 6) {
                        Text("Couldn\u{2019}t render PDF inline: \(message)")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                        Button("Retry") {
                            Task { await model.load(path: url, client: context.store.client) }
                        }
                        .buttonStyle(.vesper())
                    }
                    .padding(16)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: viewerHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? p.accent : p.border, lineWidth: isSelected ? 2 : 1))
        .task(id: url) {
            await model.load(path: url, client: context.store.client)
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: model.pdfView)) { _ in
            model.syncPage()
        }
    }
}

// MARK: - Generic Inline File Card

struct KnowledgeInlineFileCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let url: String
    let label: String
    let contentType: String?
    let embedRef: String?
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    var body: some View {
        let p = theme.palette
        HStack(spacing: 10) {
            Image(systemName: KnowledgeAttachmentActions.sfSymbol(for: contentType, filename: label))
                .font(.system(size: 16))
                .foregroundStyle(p.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Text(contentType?.isEmpty == false ? contentType! : "Attachment")
                    .font(.system(size: theme.pointSize(.micro) + 1))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            KnowledgeMediaActionButtons(
                url: url,
                filename: label,
                contentType: contentType,
                embedRef: embedRef
            )
        }
        .padding(10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? p.accent : p.border, lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            KnowledgeAttachmentActions.openFullscreen(url: url, title: label, contentType: contentType, context: context)
        }
        .onTapGesture(count: 1) {
            if let onSelect {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onSelect()
            }
        }
    }
}

// MARK: - Attachment Detail View (when opened from Explorer attachments/ folder)

struct KnowledgeAttachmentDetailView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let attachment: KnowledgeAttachment
    var onRename: ((KnowledgeAttachment) -> Void)? = nil
    var onDelete: ((KnowledgeAttachment) -> Void)? = nil

    @State private var pdfModel = PDFViewerModel()

    var body: some View {
        let p = theme.palette
        let embed = attachment.asKnowledgeEmbed()
        let sizeText = KnowledgeAttachmentActions.formattedSize(attachment.sizeBytes)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: KnowledgeAttachmentActions.sfSymbol(for: attachment.contentType, filename: attachment.filename))
                    .font(.system(size: 14))
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(attachment.filename)
                            .vesperText(.heading, theme)
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        TonePill(
                            label: attachment.usageSummary,
                            tone: attachment.isOrphaned ? "human" : "done"
                        )
                    }
                    HStack(spacing: 6) {
                        Text(attachment.path)
                        if !attachment.contentType.isEmpty {
                            Text("\u{00B7}")
                            Text(attachment.contentType)
                        }
                        if !sizeText.isEmpty {
                            Text("\u{00B7}")
                            Text(sizeText)
                        }
                        Text("\u{00B7}")
                        Text("Press Space for Quick Look")
                    }
                    .font(.system(size: theme.pointSize(.micro) + 1))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    context.copyToClipboard("![[\(attachment.ref)]]")
                    context.showToast(ToastItemModel(id: "knowledge.att.copy.\(attachment.id)", title: "Copied embed link", tone: .success))
                } label: {
                    Label("Copy Embed", systemImage: "doc.on.doc")
                }
                .buttonStyle(.vesper())

                Button {
                    KnowledgeAttachmentActions.openFullscreen(
                        url: attachment.url,
                        title: attachment.filename,
                        contentType: attachment.contentType,
                        context: context
                    )
                } label: {
                    Label("Quick Look", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.vesper())

                Button {
                    KnowledgeAttachmentActions.openInExternalApp(
                        url: attachment.url,
                        filename: attachment.filename,
                        contentType: attachment.contentType,
                        context: context
                    )
                } label: {
                    Label("Open in App", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.vesper(.primary))

                Menu {
                    Button("Copy File") {
                        KnowledgeAttachmentActions.copyFile(
                            url: attachment.url,
                            filename: attachment.filename,
                            contentType: attachment.contentType,
                            context: context
                        )
                    }
                    Button("Download\u{2026}") {
                        KnowledgeAttachmentActions.saveCopy(
                            url: attachment.url,
                            filename: attachment.filename,
                            contentType: attachment.contentType,
                            context: context
                        )
                    }
                    if attachment.isOwner {
                        Divider()
                        if let onRename {
                            Button("Rename\u{2026}") { onRename(attachment) }
                        }
                        if let onDelete {
                            Button("Delete\u{2026}", role: .destructive) { onDelete(attachment) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(p.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More attachment actions")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(p.surface)

            Divider().overlay(p.border)

            HStack(spacing: 8) {
                if attachment.usedIn.isEmpty {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                    Text("Not currently referenced in any document. Drag it from attachments/ into a doc to embed it.")
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    Text("Used in:")
                        .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachment.usedIn) { doc in
                                Button {
                                    context.navigate(KnowledgeShellLogic.pageHref(id: doc.id, title: doc.title))
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundStyle(p.accent)
                                        Text(doc.title.isEmpty ? KnowledgeShellLogic.nameOf(doc.path) : doc.title)
                                            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
                                            .foregroundStyle(p.text)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(p.surface, in: Capsule())
                                    .overlay(Capsule().stroke(p.border))
                                }
                                .buttonStyle(.plain)
                                .help(doc.path.isEmpty ? doc.title : doc.path)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

            Divider().overlay(p.border)

            Group {
                if embed.isPDFEmbed {
                    PDFViewerView(model: pdfModel) {
                        Task { await pdfModel.load(path: attachment.url, client: context.store.client) }
                    }
                    .padding(14)
                    .task(id: attachment.url) {
                        await pdfModel.load(path: attachment.url, client: context.store.client)
                    }
                    .onAppear { context.find.searcher = pdfModel }
                    .onDisappear {
                        if context.find.searcher === pdfModel { context.find.searcher = nil }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if embed.isImageEmbed {
                                KnowledgeInlineImageCard(
                                    url: attachment.url,
                                    label: attachment.filename,
                                    contentType: attachment.contentType,
                                    embedRef: "![[\(attachment.ref)]]",
                                    maxImageWidth: 820,
                                    maxImageHeight: 620
                                )
                            } else if embed.isVideoEmbed {
                                KnowledgeInlineVideoCard(
                                    url: attachment.url,
                                    label: attachment.filename,
                                    contentType: attachment.contentType,
                                    embedRef: "![[\(attachment.ref)]]",
                                    playerHeight: 460
                                )
                            } else if embed.isAudioEmbed {
                                KnowledgeInlineAudioCard(
                                    url: attachment.url,
                                    label: attachment.filename,
                                    contentType: attachment.contentType,
                                    embedRef: "![[\(attachment.ref)]]"
                                )
                            } else {
                                KnowledgeInlineFileCard(
                                    url: attachment.url,
                                    label: attachment.filename,
                                    contentType: attachment.contentType,
                                    embedRef: "![[\(attachment.ref)]]"
                                )
                            }
                        }
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.background)
        }
    }
}
