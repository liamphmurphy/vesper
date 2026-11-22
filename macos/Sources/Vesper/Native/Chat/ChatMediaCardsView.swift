import SwiftUI
import VesperCore

// MARK: - Attachment Card (Image or File)

struct ChatAttachmentCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let attachment: API.ChatAttachment

    private var contentPath: String {
        "/api/v1/chat-attachments/\(APIPath.escape(attachment.id))/content"
    }

    var body: some View {
        if ChatCardDisplay.isImageAttachment(contentType: attachment.contentType) {
            imageCard
        } else {
            fileCard
        }
    }

    private var imageCard: some View {
        let p = theme.palette
        return Button {
            openQuickLook()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AuthenticatedImageView(source: contentPath, maxPixel: 720) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 360, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.swiftUIColor("track", fallback: Color.secondary.opacity(0.12)))
                        .frame(width: 220, height: 140)
                        .overlay(ProgressView().controlSize(.small))
                } failure: {
                    Label(attachment.filename, systemImage: "photo")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                        .padding(12)
                }
                HStack(spacing: 6) {
                    Text(attachment.filename)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(1)
                    if attachment.source == .generated {
                        TonePill(label: "Generated", tone: "neutral")
                    }
                    Spacer(minLength: 4)
                    Text(ChatCardDisplay.formattedFileSize(attachment.sizeBytes))
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                .frame(maxWidth: 360)
            }
            .padding(8)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        }
        .buttonStyle(.plain)
    }

    private var fileCard: some View {
        let p = theme.palette
        return Button {
            openQuickLook()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Text("\(attachment.contentType) · \(ChatCardDisplay.formattedFileSize(attachment.sizeBytes))")
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "eye")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
    }

    private func openQuickLook() {
        let resolved = context.resolvedURL(contentPath)?.absoluteString ?? contentPath
        context.showQuickLook([
            QuickLookItem(
                url: resolved,
                title: attachment.filename,
                filename: attachment.filename,
                contentType: attachment.contentType
            ),
        ])
    }
}

// MARK: - Audio Card

struct ChatAudioCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let audio: API.ChatAudio
    @State private var stopping = false

    private var contentPath: String {
        "/api/v1/chats/\(APIPath.escape(chatId))/audio/\(APIPath.escape(audio.id))/content"
    }

    private var stages: [ChatMediaStage] {
        audio.sourceKind?.rawValue == "music" ? ChatCardDisplay.musicStages : ChatCardDisplay.audioStages
    }

    var body: some View {
        let p = theme.palette
        let stateRaw = audio.state.rawValue
        let badge = ChatCardDisplay.stateBadge(for: stateRaw)
        let stageStates = ChatCardDisplay.mediaStageStates(stages: stages, currentStage: audio.stage.rawValue, state: stateRaw)
        let bars = ChatCardDisplay.waveBars(peaks: audio.peaks, count: 48)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(audio.title.isEmpty ? "Generated audio" : audio.title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .lineLimit(1)
                    Text("\(ChatCardDisplay.mediaClock(ms: audio.output?.durationMs ?? audio.durationMs)) · \(audio.method)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            // Compact waveform bars
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(stateRaw == "done" ? p.accent : p.tertiaryText.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, CGFloat(height) * 28))
                }
            }
            .frame(height: 30)

            mediaStagesStrip(stages: stages, states: stageStates, note: audio.stageNote)

            if let err = audio.error, !err.isEmpty {
                Text(err)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack(spacing: 8) {
                if stateRaw == "done" {
                    Button {
                        let resolved = context.resolvedURL(contentPath)?.absoluteString ?? contentPath
                        context.showQuickLook([
                            QuickLookItem(
                                url: resolved,
                                title: audio.title.isEmpty ? "Audio" : audio.title,
                                filename: audio.output?.filename,
                                contentType: audio.output?.contentType ?? "audio/mpeg"
                            ),
                        ])
                    } label: {
                        Label("Listen in Quick Look", systemImage: "play.fill")
                    }
                    .buttonStyle(.vesper(.primary))
                } else if stateRaw == "running" {
                    Button(stopping ? "Stopping…" : "Stop") { stopAudio() }
                        .buttonStyle(.vesper(.danger))
                        .disabled(stopping)
                }
                if let libId = audio.libraryItemId, !libId.isEmpty {
                    Button("Open in Library") {
                        context.navigate("/library?tab=audio&item=\(libId)")
                    }
                    .buttonStyle(.vesper())
                }
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func stopAudio() {
        guard !stopping else { return }
        stopping = true
        Task {
            _ = try? await context.store.mutate(
                API.stopChatAudio(id: chatId, audioId: audio.id),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            stopping = false
        }
    }
}

// MARK: - Video Card

struct ChatVideoCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let video: API.ChatVideo

    private var contentPath: String {
        "/api/v1/chats/\(APIPath.escape(chatId))/videos/\(APIPath.escape(video.id))/content"
    }

    var body: some View {
        let p = theme.palette
        let stateRaw = video.state.rawValue
        let badge = ChatCardDisplay.stateBadge(for: stateRaw)
        let stageStates = ChatCardDisplay.mediaStageStates(
            stages: ChatCardDisplay.videoStages,
            currentStage: video.stage.rawValue,
            state: stateRaw
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(video.title.isEmpty ? "Generated video" : video.title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .lineLimit(1)
                    Text(ChatCardDisplay.videoPlannedMeta(
                        width: video.width,
                        height: video.height,
                        fps: video.fps,
                        durationMs: video.output?.durationMs ?? video.durationMs
                    ))
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if video.framesTotal > 0 && stateRaw == "running" {
                ProgressView(value: Double(video.framesDone), total: Double(video.framesTotal))
                    .tint(p.accent)
            }

            mediaStagesStrip(stages: ChatCardDisplay.videoStages, states: stageStates, note: video.stageNote)

            if let err = video.error, !err.isEmpty {
                Text(err)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack(spacing: 8) {
                if stateRaw == "done" {
                    Button {
                        let resolved = context.resolvedURL(contentPath)?.absoluteString ?? contentPath
                        context.showQuickLook([
                            QuickLookItem(
                                url: resolved,
                                title: video.title.isEmpty ? "Video" : video.title,
                                filename: video.output?.filename,
                                contentType: video.output?.contentType ?? "video/mp4"
                            ),
                        ])
                    } label: {
                        Label("Play in Quick Look", systemImage: "play.fill")
                    }
                    .buttonStyle(.vesper(.primary))
                }
                if let libId = video.libraryItemId, !libId.isEmpty {
                    Button("Open in Library") {
                        context.navigate("/library?tab=videos&item=\(libId)")
                    }
                    .buttonStyle(.vesper())
                }
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - PDF & Canvas Reference Cards

struct ChatPDFCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let itemId: String

    private var itemRequest: APIRequest<API.LibraryItem> {
        API.getLibraryItem(itemId: itemId)
    }

    private var contentPath: String {
        "/api/v1/library/\(APIPath.escape(itemId))/content"
    }

    var body: some View {
        let p = theme.palette
        let item = context.store.entry(itemRequest).data
        let title = item?.title.isEmpty == false ? item!.title : (item?.filename ?? "PDF Document")

        HStack(spacing: 10) {
            Image(systemName: "doc.richtext.fill")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                if let item {
                    Text(ChatCardDisplay.formattedFileSize(item.sizeBytes))
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            Button("Open PDF") {
                let encodedSrc = contentPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contentPath
                let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
                context.navigate("/pdf?src=\(encodedSrc)&title=\(encodedTitle)")
            }
            .buttonStyle(.vesper(.primary))
            Button("Quick Look") {
                let resolved = context.resolvedURL(contentPath)?.absoluteString ?? contentPath
                context.showQuickLook([
                    QuickLookItem(url: resolved, title: title, filename: item?.filename ?? "\(title).pdf", contentType: "application/pdf"),
                ])
            }
            .buttonStyle(.vesper())
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .task(id: itemId) { context.store.load(itemRequest) }
    }
}

struct ChatCanvasRefCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let canvasId: String
    let canvases: [API.ChatCanvasSummary]

    var body: some View {
        let p = theme.palette
        let canvas = canvases.first { $0.id == canvasId }
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .foregroundStyle(p.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(canvas?.title.isEmpty == false ? canvas!.title : "Canvas")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                if let kind = canvas?.kind.rawValue {
                    Text(ChatCardDisplay.canvasKindLabel(kind))
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            Spacer(minLength: 8)
            Button("Open canvas") {
                context.navigate("/chat/\(chatId)?canvas=\(canvasId)")
            }
            .buttonStyle(.vesper())
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - Shared Stage Strip

private func mediaStagesStrip(stages: [ChatMediaStage], states: [ChatMediaStageState], note: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            ForEach(Array(zip(stages, states).enumerated()), id: \.offset) { _, pair in
                let (stage, state) = pair
                HStack(spacing: 4) {
                    Image(systemName: stageIcon(state))
                        .imageScale(.small)
                        .foregroundStyle(stageColor(state))
                    Text(stage.label)
                        .font(.caption2)
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                }
            }
        }
        if !note.isEmpty {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private func stageIcon(_ state: ChatMediaStageState) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .active: "circle.dotted"
    case .failed: "xmark.circle.fill"
    case .pending: "circle"
    }
}

private func stageColor(_ state: ChatMediaStageState) -> Color {
    switch state {
    case .done: .green
    case .active: .accentColor
    case .failed: .red
    case .pending: .secondary
    }
}
