import AVKit
import Combine
import SwiftUI
import VesperCore

/// The dialog a Library tile opens: the item's header with Quick Look, Download and Remove, over the
/// item itself (web ItemDialog and the per-kind dialogs).
struct LibraryItemSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let item: API.LibraryItem
    /// A click on the tile plays at once; arriving from a chat's "Open in Library" waits for Play.
    let autoPlay: Bool
    let actions: LibraryItemActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(theme.palette.border)
            content
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 960, maxWidth: 1100, minHeight: 420, idealHeight: 680, maxHeight: 780)
        .background(theme.swiftUIColor("surface-raised", fallback: theme.palette.surface))
        .foregroundStyle(theme.palette.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).vesperText(.body, theme).lineLimit(1)
                Text(LibraryLogic.detailCaption(item))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let chat = item.chatId, item.kind != .image, item.kind != .diagram, item.kind != .export {
                Button("Open chat") { dismiss(); context.navigate("/chat/\(chat)") }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.accent)
            }
            if item.kind == .image { LibraryReferenceActions(item: item, actions: actions) }
            if LibraryLogic.isKnowledgeEmbeddable(item) {
                Button { actions.copyEmbed(item) } label: { Label("Copy Embed", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.vesper())
                    .fixedSize()
            }
            Button {
                let ql = QuickLookItem(url: LibraryLogic.contentPath(item.id), title: item.title, filename: item.filename, contentType: item.contentType)
                context.showQuickLook([ql], index: 0)
            } label: { Label("Quick Look", systemImage: "eye") }
                .buttonStyle(.vesper())
                .fixedSize()
            Button { actions.download(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.vesper())
                .fixedSize()
            Button { actions.remove([item]) { dismiss() } } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(.vesper(.danger))
                .fixedSize()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.palette.tertiaryText)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .video:
            LibraryVideoPlayer(item: item, autoPlay: autoPlay)
        case .audio:
            VStack(alignment: .leading, spacing: 16) {
                LibraryAudioPlayer(item: item, autoPlay: autoPlay)
                LibraryRenameField(item: item, actions: actions)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Format").foregroundStyle(theme.palette.tertiaryText)
                        Text(LibraryLogic.audioFormat(contentType: item.contentType, filename: item.filename))
                    }
                    if let method = item.method {
                        GridRow {
                            Text("Made with").foregroundStyle(theme.palette.tertiaryText)
                            Text(method)
                        }
                    }
                }
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                Spacer(minLength: 0)
            }
        case .file:
            VStack(alignment: .leading, spacing: 12) {
                LibraryRenameField(item: item, actions: actions)
                LibraryFilePreview(item: item)
            }
        case .export:
            VStack(alignment: .leading, spacing: 12) {
                LibraryRenameField(item: item, actions: actions)
                Text("A copy as it was when you exported it. \(LibraryLogic.fileMeta(item))")
                    .font(.system(size: theme.pointSize(.reading)))
                    .foregroundStyle(theme.palette.secondaryText)
                ExportSourceLine(item: item)
                if LibraryLogic.isPDF(item.contentType) { LibraryPDFPane(item: item) } else { Spacer(minLength: 0) }
            }
        default:
            LibraryImageView(path: LibraryLogic.contentPath(item.id), maxPixel: nil, fill: false)
                .padding(item.kind == .diagram ? 12 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    item.kind == .diagram
                        ? Color.white
                        : theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
        }
    }
}

/// "Use as reference" and "Clear reference" for an image: new images of that persona (or the
/// person) keep this likeness.
private struct LibraryReferenceActions: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let actions: LibraryItemActions
    @State private var busy = false
    @State private var error: String?

    private static let personas = API.listPersonas()

    var body: some View {
        let personas = (context.store.entry(Self.personas).data?.personas ?? []).map { (id: $0.id, name: $0.name) }
        HStack(spacing: 8) {
            if let error {
                Text(error).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
            Menu {
                ForEach(LibraryLogic.referenceChoices(item, personas: personas), id: \.key) { choice in
                    Button(choice.label) { run { await actions.setReference(item, choice) } }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2")
                        .imageScale(.small)
                    Text("Use as reference")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .font(.system(size: theme.pointSize(.body), weight: .medium))
                .foregroundStyle(theme.palette.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(theme.swiftUIColor("btn-outline-bg", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.swiftUIColor("btn-secondary-border", fallback: theme.palette.border)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            if LibraryLogic.referenceBadge(item) != nil {
                Button("Clear reference") { run { await actions.clearReference(item) } }
                    .buttonStyle(.vesper())
                    .fixedSize()
                    .disabled(busy)
            }
        }
        .font(.system(size: theme.pointSize(.small)))
        .task { context.store.load(Self.personas) }
    }

    private func run(_ call: @escaping @MainActor () async -> String?) {
        busy = true
        Task {
            error = await call()
            busy = false
        }
    }
}

/// The title field in the audio, file and export dialogs: rename in place.
private struct LibraryRenameField: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let actions: LibraryItemActions
    @State private var title = ""
    @State private var saving = false
    @State private var error: String?

    private var changed: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != item.title
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onChange(of: title) { _, value in if value.count > 300 { title = String(value.prefix(300)) } }
                .accessibilityLabel("Title")
            Button(saving ? "Saving\u{2026}" : "Rename", action: save)
                .buttonStyle(.vesper())
                .disabled(!changed || saving)
            if let error {
                Text(error).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .onAppear { title = item.title }
    }

    private func save() {
        guard changed, !saving else { return }
        saving = true
        Task {
            error = await actions.setTitle(item, title.trimmingCharacters(in: .whitespacesAndNewlines))
            saving = false
        }
    }
}

/// What a file's dialog shows of it: a PDF in PDFKit, text as text, a table's first rows or a zip's
/// names. Never rendered as a web page.
private struct LibraryFilePreview: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    private var request: APIRequest<API.LibraryFilePreview> { API.getLibraryFilePreview(itemId: item.id) }

    var body: some View {
        if LibraryLogic.isPDF(item.contentType) {
            LibraryPDFPane(item: item)
        } else {
            let entry = context.store.entry(request)
            Group {
                if let preview = entry.data {
                    loaded(preview)
                } else if let error = entry.error {
                    Text("Couldn\u{2019}t read a preview: \(error.userMessage)")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                } else {
                    SkeletonBar(height: 192)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .task { context.store.load(request) }
        }
    }

    @ViewBuilder
    private func loaded(_ p: API.LibraryFilePreview) -> some View {
        let sunken = theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)
        let subtle = theme.swiftUIColor("border-subtle", fallback: theme.palette.border)
        let more = Text("Showing the start of the file. Download it for the rest.")
            .font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.tertiaryText)
        switch p.kind {
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView([.vertical, .horizontal]) {
                    Text((p.lines ?? []).joined(separator: "\n"))
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(sunken, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(subtle))
                if p.truncated { more }
            }
        case .table:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array((p.rows ?? []).enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .fontWeight(index == 0 ? .medium : .regular)
                                }
                            }
                            .background(index == 0 ? sunken : .clear)
                            Divider().overlay(subtle)
                        }
                    }
                    .textSelection(.enabled)
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(subtle))
                if p.truncated { more }
            }
            .font(.system(size: theme.pointSize(.small)))
        case .zip:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(p.entries ?? [], id: \.name) { entry in
                            HStack(spacing: 12) {
                                Text(entry.name).font(.system(size: theme.pointSize(.small), design: .monospaced)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(LibraryLogic.formatBytes(entry.size)).foregroundStyle(theme.palette.tertiaryText)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            Divider().overlay(subtle)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(subtle))
                if p.truncated {
                    Text("Showing \(p.entries?.count ?? 0) of \(p.total) files. Nothing is unpacked.")
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            .font(.system(size: theme.pointSize(.small)))
        default:
            Text("No preview for this type of file. Download it to open it.")
                .font(.system(size: theme.pointSize(.reading)))
                .foregroundStyle(theme.palette.secondaryText)
        }
    }
}

/// A Library PDF in the native viewer.
private struct LibraryPDFPane: View {
    @Environment(NativeScreenContext.self) private var context
    let item: API.LibraryItem
    @State private var model = PDFViewerModel()

    var body: some View {
        PDFViewerView(model: model) { load() }
            .frame(minHeight: 420, maxHeight: .infinity)
            .task(id: item.id) { await model.load(path: LibraryLogic.contentPath(item.id), client: context.store.client) }
    }

    private func load() {
        Task { await model.load(path: LibraryLogic.contentPath(item.id), client: context.store.client) }
    }
}

/// Fetches a video or audio file to disk once, for AVPlayer (which can't send the session cookie).
@MainActor
@Observable
private final class LibraryMediaFile {
    var url: URL?
    var error: String?

    func load(_ item: API.LibraryItem, client: APIClient?) async {
        guard url == nil else { return }
        guard let client else { error = APIError.unauthorized.userMessage; return }
        do {
            url = try await LibraryFiles.localFile(path: LibraryLogic.contentPath(item.id), filename: item.filename,
                                                   contentType: item.contentType, client: client)
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct LibraryVideoPlayer: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let autoPlay: Bool
    @State private var file = LibraryMediaFile()
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let error = file.error {
                Text("Couldn\u{2019}t load the video: \(error)").foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await file.load(item, client: context.store.client)
            guard let url = file.url else { return }
            let player = AVPlayer(url: url)
            self.player = player
            if autoPlay { player.play() }
        }
        .onDisappear { player?.pause() }
    }
}

/// The audio dialog's player: waveform scrubbing, play/pause, skip, speed and loop (web AudioPlayer).
private struct LibraryAudioPlayer: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let autoPlay: Bool
    @State private var file = LibraryMediaFile()
    @State private var player: AVPlayer?
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var playing = false
    @State private var rate: Double = 1
    @State private var loop = false

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryWaveform(bars: LibraryLogic.waveBars(item.peaks), progress: duration > 0 ? position / duration : 0)
                .frame(height: 72)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in seek(fraction: value.location.x) })
                .background(GeometryReader { geo in Color.clear.preference(key: WaveWidthKey.self, value: geo.size.width) })
                .onPreferenceChange(WaveWidthKey.self) { waveWidth = $0 }
                .accessibilityElement()
                .accessibilityLabel("Position")
                .accessibilityValue("\(LibraryLogic.clock(Int(position * 1000))) of \(LibraryLogic.clock(Int(duration * 1000)))")
                .accessibilityAdjustableAction { direction in
                    let step = duration * 0.05
                    seek(to: position + (direction == .increment ? step : -step))
                }
            HStack(spacing: 12) {
                Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 20) }
                    .buttonStyle(.vesper(.primary))
                    .accessibilityLabel(playing ? "Pause" : "Play")
                    .disabled(player == nil)
                Button { seek(to: position - 10) } label: { Image(systemName: "gobackward.10") }.buttonStyle(.plain).accessibilityLabel("Back 10 seconds")
                Button { seek(to: position + 10) } label: { Image(systemName: "goforward.10") }.buttonStyle(.plain).accessibilityLabel("Forward 10 seconds")
                Text("\(LibraryLogic.clock(Int(position * 1000))) / \(LibraryLogic.clock(Int(duration * 1000)))")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.secondaryText)
                Spacer()
                if let error = file.error {
                    Text(error).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                Button("\(rate.formatted())\u{00D7}") {
                    rate = LibraryLogic.nextSpeed(rate)
                    if playing { player?.rate = Float(rate) }
                }
                .buttonStyle(.vesper())
                .help("Playback speed")
                Toggle(isOn: $loop) { Image(systemName: "repeat") }
                    .toggleStyle(.button)
                    .help("Loop")
            }
        }
        .task {
            if let ms = item.durationMs { duration = Double(ms) / 1000 }
            await file.load(item, client: context.store.client)
            guard let url = file.url else { return }
            let player = AVPlayer(url: url)
            self.player = player
            if let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { duration = seconds }
            if autoPlay { toggle() }
        }
        .onReceive(tick) { _ in sync() }
        .onDisappear { player?.pause() }
    }

    @State private var waveWidth: CGFloat = 1

    private func toggle() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if duration > 0, position >= duration - 0.05 { player.seek(to: .zero) }
            player.playImmediately(atRate: Float(rate))
        }
        playing.toggle()
    }

    private func sync() {
        guard let player else { return }
        position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        guard playing, duration > 0, position >= duration - 0.05 else { return }
        if loop {
            player.seek(to: .zero)
            player.playImmediately(atRate: Float(rate))
        } else {
            playing = false
        }
    }

    private func seek(fraction x: CGFloat) {
        seek(to: duration * Double(min(max(x / max(waveWidth, 1), 0), 1)))
    }

    private func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        position = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }
}

private struct WaveWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
