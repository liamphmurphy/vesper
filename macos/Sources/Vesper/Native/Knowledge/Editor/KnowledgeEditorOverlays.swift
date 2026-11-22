import SwiftUI
import VesperCore

// MARK: - Inline Embed Preview Card

/// Pure SwiftUI inline preview card for an embedded image, PDF, or linked note inside a prose segment.
struct KnowledgeEmbedPreviewCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let embed: KnowledgeEmbed

    var body: some View {
        let p = theme.palette
        let ct = embed.contentType?.lowercased() ?? ""
        let isPDF = ct.contains("pdf") || (embed.url?.lowercased().hasSuffix(".pdf") ?? false)
        let isImage = ct.hasPrefix("image/")
        let label = (embed.title?.isEmpty == false ? embed.title : nil) ?? embed.ref

        if isImage, let rawURL = embed.url, let resolved = context.resolvedURL(rawURL) {
            Button {
                context.showQuickLook([QuickLookItem(url: rawURL, title: label, contentType: embed.contentType)], index: 0)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    AsyncImage(url: resolved) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 460, maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            Label(label, systemImage: "photo")
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                                .padding(10)
                        default:
                            ProgressView().controlSize(.small).padding(16)
                        }
                    }
                    Text(label)
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .buttonStyle(.plain)
        } else if isPDF, let rawURL = embed.url {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 16))
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Text("PDF Attachment")
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button("Quick Look") {
                    context.showQuickLook([QuickLookItem(url: rawURL, title: label, contentType: embed.contentType)], index: 0)
                }
                .buttonStyle(.vesper())
                Button("Open PDF") {
                    let encoded = APIQuery.encode([
                        URLQueryItem(name: "src", value: rawURL),
                        URLQueryItem(name: "title", value: label),
                    ])
                    context.navigate("/pdf?\(encoded)")
                }
                .buttonStyle(.vesper(.primary))
            }
            .padding(10)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        } else if let md = embed.markdown, !md.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                Text(md)
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
    }
}

// MARK: - Completion Popover

/// Pure SwiftUI floating suggestion popover for `[[`, `![[`, and `#` completion triggers.
struct KnowledgeCompletionPopoverView: View {
    @Environment(\.vesperTheme) private var theme

    let session: KnowledgeCompletionSession
    let onSelect: (Int) -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 2) {
            if session.candidates.isEmpty {
                Text("No matching suggestions")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.candidates.prefix(12).enumerated()), id: \.offset) { idx, item in
                            Button {
                                onSelect(idx)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: icon(for: item.kind))
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.accent)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                                            .foregroundStyle(p.text)
                                            .lineLimit(1)
                                        if !item.detail.isEmpty {
                                            Text(item.detail)
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(p.tertiaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    idx == session.activeIndex ? p.selected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 300)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private func icon(for kind: KnowledgeCompletionCandidateKind) -> String {
        switch kind {
        case .page: return "doc.text"
        case .heading: return "textformat.size"
        case .blockID: return "number.square"
        case .embed: return "photo"
        case .tag: return "tag"
        }
    }
}

// MARK: - Integrated Find Bar

/// Pure SwiftUI `⌘F` find bar searching across both prose segments and embedded table cells.
struct KnowledgeEditorFindBar: View {
    @Environment(\.vesperTheme) private var theme

    @Binding var query: String
    @Binding var caseSensitive: Bool
    var focus: FocusState<Bool>.Binding
    let matchCount: Int
    let activeMatchIndex: Int?
    let onSubmit: () -> Void
    let onQueryChange: (String) -> Void
    let onCaseChange: (Bool) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        let p = theme.palette
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(p.tertiaryText)
            TextField("Find in page and tables\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
                .focused(focus)
                .onSubmit(onSubmit)
                .onChange(of: query) { _, next in onQueryChange(next) }
                .onExitCommand(perform: onClose)

            if !query.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\((activeMatchIndex ?? 0) + 1) of \(matchCount)")
                    .vesperText(.small, theme)
                    .monospacedDigit()
                    .foregroundStyle(p.tertiaryText)
            }

            Toggle("Aa", isOn: $caseSensitive)
                .toggleStyle(.button)
                .controlSize(.small)
                .onChange(of: caseSensitive) { _, next in onCaseChange(next) }

            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(matchCount == 0)
                .help("Previous match")

            Button(action: onNext) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(matchCount == 0)
                .help("Next match")

            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close Find")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }
}
