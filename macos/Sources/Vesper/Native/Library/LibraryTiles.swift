import AppKit
import SwiftUI
import VesperCore

/// One Library item in the grid, drawn per kind as the web's tiles were.
struct LibraryTile: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let actions: LibraryItemActions
    /// Opens the item's dialog (the export tile's title is a button for it, as on the web).
    let open: () -> Void

    var body: some View {
        switch item.kind {
        case .video: media { VideoThumb(item: item) }
        case .audio: media { AudioThumb(item: item) }
        case .file: media { FileThumb(item: item) }
        case .export: ExportCard(item: item, open: open)
        case .document: DocumentCard(item: item, actions: actions)
        default: media { ImageThumb(item: item) }
        }
    }

    private func media<Thumb: View>(@ViewBuilder _ thumb: () -> Thumb) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb()
            Text(item.title).vesperText(.body, theme).lineLimit(1).help(item.filename)
            LibrarySourceLine(item: item)
        }
    }
}

/// Where an item came from: its persona and chat while they still exist, or the person's upload.
struct LibrarySourceLine: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    var body: some View {
        Group {
            if item.source == .upload {
                Text("Uploaded by you")
            } else {
                HStack(spacing: 0) {
                    Text("\(item.personaName ?? "Assistant") · ")
                    if let chat = item.chatId {
                        Button(item.chatTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Open chat") { context.navigate("/chat/\(chat)") }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.palette.accent)
                    } else {
                        Text("chat deleted")
                    }
                }
            }
        }
        .font(.system(size: theme.pointSize(.small)))
        .foregroundStyle(theme.palette.tertiaryText)
        .lineLimit(1)
    }
}

/// An image fetched from an API path; tiles ask for a downsampled copy.
struct LibraryImageView: View {
    @Environment(NativeScreenContext.self) private var context
    let path: String
    var maxPixel: CGFloat? = 512
    var fill = true
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            image = await LibraryImages.shared.image(path: path, maxPixel: maxPixel, client: context.store.client)
            failed = image == nil
        }
    }
}

/// An image or diagram: square, cropped (a diagram fits on white), with its reference badge.
private struct ImageThumb: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    var body: some View {
        let diagram = item.kind == .diagram
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LibraryImageView(path: LibraryLogic.contentPath(item.id), fill: !diagram)
                    .padding(diagram ? 8 : 0)
                    .background(diagram ? Color.white : theme.palette.selected)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
            .overlay(alignment: .topLeading) {
                if let who = LibraryLogic.referenceBadge(item) {
                    Text("\(who) · reference")
                        .font(.system(size: theme.pointSize(.small) - 1))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.swiftUIColor("surface-raised", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 2, y: 1)
                        .padding(8)
                        .help("New images keep this likeness of \(who == "You" ? "you" : who)")
                }
            }
    }
}

/// A video: its poster with a Video tag and its length.
private struct VideoThumb: View {
    let item: API.LibraryItem

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if item.hasPoster == true {
                    LibraryImageView(path: LibraryLogic.posterPath(item.id))
                } else {
                    Image(systemName: "film").font(.system(size: 22)).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) { OverlayTag(icon: "play.fill", text: "Video").padding(6) }
            .overlay(alignment: .bottomTrailing) {
                if let ms = item.durationMs, ms > 0 { OverlayTag(text: LibraryLogic.clock(ms), mono: true).padding(6) }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }
}

private struct OverlayTag: View {
    var icon: String?
    let text: String
    var mono = false

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 7)) }
            Text(text).font(.system(size: 10, design: mono ? .monospaced : .default))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Audio: its waveform, an Audio tag and its length (or format when the server couldn't read it).
private struct AudioThumb: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    var body: some View {
        VStack(spacing: 6) {
            LibraryWaveform(bars: LibraryLogic.waveBars(item.peaks, count: 32))
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "waveform").font(.system(size: 9))
                    Text("Audio")
                }
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                if let ms = item.durationMs, ms > 0 {
                    Text(LibraryLogic.clock(ms)).font(.system(size: theme.pointSize(.small) - 1, design: .monospaced))
                } else {
                    Text(LibraryLogic.audioFormat(contentType: item.contentType, filename: item.filename))
                }
            }
            .font(.system(size: theme.pointSize(.small) - 1))
            .foregroundStyle(theme.palette.secondaryText)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(theme.swiftUIColor("accent-soft", fallback: theme.palette.selected), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }
}

/// Waveform bars (0…1); with `progress`, the played part is drawn in the accent colour.
struct LibraryWaveform: View {
    @Environment(\.vesperTheme) private var theme
    let bars: [Double]
    var progress: Double?

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    let played = progress.map { Double(index) / Double(max(bars.count, 1)) < $0 } ?? true
                    Capsule()
                        .fill(played ? theme.palette.accent : theme.palette.tertiaryText.opacity(0.5))
                        .frame(height: max(2, geo.size.height * value))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// A file: its type as a large badge and a summary line.
private struct FileThumb: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    var body: some View {
        VStack(alignment: .leading) {
            Text(LibraryLogic.typeBadge(item.filename))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.palette.accent)
            Spacer(minLength: 4)
            Text(LibraryLogic.fileMeta(item)).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.secondaryText).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(2, contentMode: .fit)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }
}

/// "Source: Slides › Q4 deck (edited since)": whether an export still matches what it was made from.
struct ExportSourceLine: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem

    var body: some View {
        if let source = item.exportSource {
            let app = LibraryLogic.exportApp(source.kind)
            let tone: Color = switch source.status.rawValue {
            case "changed": Color(red: 0xC7 / 255, green: 0x77 / 255, blue: 0)
            case "deleted": theme.swiftUIColor("pill-blocked-fg", fallback: .red)
            default: theme.palette.tertiaryText
            }
            HStack(spacing: 0) {
                Text("Source: ")
                if source.status.rawValue == "deleted" {
                    Text(app.label)
                } else {
                    Button("\(app.label) \u{203A} \(source.title ?? "")") { context.navigate("\(app.href)/\(source.id)") }.buttonStyle(.plain)
                }
                Text(" (\(LibraryLogic.exportSourceNote(source.status)))")
            }
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(tone)
            .lineLimit(1)
        }
    }
}

/// An export: a frozen copy of what Slides, Designs or Docs made.
private struct ExportCard: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let app = item.exportSource.map { " · from \(LibraryLogic.exportApp($0.kind).label)" } ?? ""
            Text(LibraryLogic.typeBadge(item.filename) + app)
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(theme.palette.accent)
            Button(action: open) {
                Text(item.title).font(.system(size: theme.pointSize(.body) + 2, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            Text("\(LibraryLogic.fileMeta(item)) · exported \(APIDate.timeline(item.createdAt))")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .lineLimit(1)
            ExportSourceLine(item: item)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }
}

/// A workflow's document: its title, Open and Remove.
private struct DocumentCard: View {
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let actions: LibraryItemActions
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.system(size: theme.pointSize(.body), weight: .medium)).lineLimit(1).help(item.title)
            HStack(spacing: 12) {
                Button("Open") { actions.openDocument(item) }.buttonStyle(.plain).foregroundStyle(theme.palette.accent)
                Button("Remove") {
                    removing = true
                    Task {
                        await actions.delete(item)
                        removing = false
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.secondaryText)
                .disabled(removing)
            }
            .vesperText(.body, theme)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }
}
