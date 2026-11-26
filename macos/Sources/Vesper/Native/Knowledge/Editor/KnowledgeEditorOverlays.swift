import SwiftUI
import VesperCore

// MARK: - Inline Embed Preview Card

/// Pure SwiftUI inline preview card for an embedded image, video, audio, PDF, file, or linked note inside a prose segment.
struct KnowledgeEmbedPreviewCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let embed: KnowledgeEmbed
    var target: KnowledgeWikiTarget? = nil
    var maxImageWidth: CGFloat = 460
    var maxImageHeight: CGFloat = 320
    var containerMaxWidth: CGFloat? = nil
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    var onResizeWidth: ((Int?) -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var onDeleteAttachment: (() -> Void)? = nil

    @State private var isHoveringNoteRemove = false

    var body: some View {
        let p = theme.palette
        let label = target?.displayLabel(resolvedTitle: embed.title)
            ?? (embed.title?.isEmpty == false ? embed.title : nil)
            ?? embed.ref

        if embed.isImageEmbed, let rawURL = embed.url, !rawURL.isEmpty {
            KnowledgeInlineImageCard(
                url: rawURL,
                label: label,
                contentType: embed.contentType,
                embedRef: target?.raw ?? embed.ref,
                maxImageWidth: maxImageWidth,
                maxImageHeight: maxImageHeight,
                containerMaxWidth: containerMaxWidth,
                explicitDimensions: target?.embedDimensions,
                isSelected: isSelected,
                onSelect: onSelect,
                onResizeWidth: onResizeWidth,
                onRemove: onRemove,
                onDeleteAttachment: onDeleteAttachment
            )
        } else if embed.isVideoEmbed, let rawURL = embed.url, !rawURL.isEmpty {
            KnowledgeInlineVideoCard(
                url: rawURL,
                label: label,
                contentType: embed.contentType,
                embedRef: target?.raw ?? embed.ref,
                isSelected: isSelected,
                onSelect: onSelect,
                onRemove: onRemove,
                onDeleteAttachment: onDeleteAttachment
            )
        } else if embed.isAudioEmbed, let rawURL = embed.url, !rawURL.isEmpty {
            KnowledgeInlineAudioCard(
                url: rawURL,
                label: label,
                contentType: embed.contentType,
                embedRef: target?.raw ?? embed.ref,
                isSelected: isSelected,
                onSelect: onSelect,
                onRemove: onRemove,
                onDeleteAttachment: onDeleteAttachment
            )
        } else if embed.isPDFEmbed, let rawURL = embed.url, !rawURL.isEmpty {
            KnowledgeInlinePDFCard(
                url: rawURL,
                label: label,
                contentType: embed.contentType,
                embedRef: target?.raw ?? embed.ref,
                isSelected: isSelected,
                onSelect: onSelect,
                onRemove: onRemove,
                onDeleteAttachment: onDeleteAttachment
            )
        } else if embed.isFileEmbed, let rawURL = embed.url, !rawURL.isEmpty {
            KnowledgeInlineFileCard(
                url: rawURL,
                label: label,
                contentType: embed.contentType,
                embedRef: target?.raw ?? embed.ref,
                isSelected: isSelected,
                onSelect: onSelect,
                onRemove: onRemove,
                onDeleteAttachment: onDeleteAttachment
            )
        } else if let md = embed.markdown, !md.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    isHoveringNoteRemove
                                        ? theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                                        : p.secondaryText
                                )
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .onHover { isHoveringNoteRemove = $0 }
                        .help("Remove from Note")
                        .accessibilityLabel("Remove from Note")
                    }
                }
                Text(KnowledgePanelsLogic.unlinkWikiText(md))
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? p.accent : p.border, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture {
                if let onSelect {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    onSelect()
                }
            }
            .contextMenu {
                if let onRemove {
                    Button("Remove from Note", role: .destructive) {
                        onRemove()
                    }
                }
            }
        }
    }
}

/// Hosts one paragraph's inline embed cards inside `LivePreviewNSTextView` and reports intrinsic size updates
/// (for example when an authenticated image finishes loading or is resized) so TextKit 2 paragraph spacing updates in place.
struct KnowledgeInlineEmbedGroupView: View {
    let placements: [KnowledgeInlineEmbedPlacement]
    let maxWidth: CGFloat
    let fillsWidth: Bool
    var selectedEmbedID: String? = nil
    var onSelectEmbed: ((KnowledgeInlineEmbedPlacement) -> Void)? = nil
    var onResizeImage: ((KnowledgeInlineEmbedPlacement, Int?) -> Void)? = nil
    var onRemoveEmbed: ((KnowledgeInlineEmbedPlacement) -> Void)? = nil
    var canDeleteAttachment: ((KnowledgeInlineEmbedPlacement) -> Bool)? = nil
    var onDeleteAttachment: ((KnowledgeInlineEmbedPlacement) -> Void)? = nil
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(placements) { placement in
                let allowDeleteFile = canDeleteAttachment?(placement) ?? false
                KnowledgeEmbedPreviewCard(
                    embed: placement.embed,
                    target: placement.target,
                    maxImageWidth: min(maxWidth, 460),
                    containerMaxWidth: maxWidth,
                    isSelected: selectedEmbedID == placement.id,
                    onSelect: onSelectEmbed.map { cb in { cb(placement) } },
                    onResizeWidth: onResizeImage.map { cb in { width in cb(placement, width) } },
                    onRemove: onRemoveEmbed.map { cb in { cb(placement) } },
                    onDeleteAttachment: allowDeleteFile ? onDeleteAttachment.map { cb in { cb(placement) } } : nil
                )
            }
        }
        .frame(width: fillsWidth ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            onSizeChange(newSize)
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
                                    Image(systemName: item.symbolName ?? icon(for: item.kind))
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

// MARK: - Inline Heading Outline (TOC) & Backlinks Drawer

enum KnowledgeInlineDrawerMode: Equatable, Sendable {
    case outline
    case backlinks
}

/// Sleek inline drawer docked beside the document prose for quick jump-to-heading TOC
/// and one-click Backlinks / Unlinked Mentions navigation.
struct KnowledgeInlineDrawerView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage
    @Binding var mode: KnowledgeInlineDrawerMode?
    let headings: [KnowledgeOutlineHeading]
    let backlinks: [KnowledgeBacklinkItem]
    let outgoingResolved: [KnowledgeBacklinkItem]
    let outgoingUnresolved: [String]
    let unlinkedMentions: [KnowledgeUnlinkedMention]
    let onJumpHeading: (KnowledgeOutlineHeading) -> Void
    let onLinkMention: (KnowledgeUnlinkedMention) -> Void
    let linkingMentionId: String?

    @State private var headingFilter = ""

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                drawerTabButton(
                    title: "Outline",
                    symbol: "list.bullet.indent",
                    count: headings.count,
                    active: mode == .outline
                ) {
                    mode = .outline
                }
                drawerTabButton(
                    title: "Links",
                    symbol: "arrow.triangle.branch",
                    count: backlinks.count + unlinkedMentions.count,
                    active: mode == .backlinks
                ) {
                    mode = .backlinks
                }
                Spacer(minLength: 4)
                Button {
                    mode = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Close drawer")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(p.surface)

            Divider().overlay(p.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .outline:
                        outlineBody
                    case .backlinks:
                        backlinksBody
                    case nil:
                        EmptyView()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 248)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private func drawerTabButton(
        title: String,
        symbol: String,
        count: Int,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: theme.pointSize(.micro) + 1, weight: active ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(active ? p.accent : p.tertiaryText)
                }
            }
            .foregroundStyle(active ? p.accent : p.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(active ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var outlineBody: some View {
        let p = theme.palette
        if headings.count > 6 {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(p.tertiaryText)
                TextField("Filter headings\u{2026}", text: $headingFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.micro) + 1))
                if !headingFilter.isEmpty {
                    Button { headingFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }

        let trimmed = headingFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty
            ? headings
            : headings.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }

        if shown.isEmpty {
            Text(headings.isEmpty ? "No headings yet. Start a line with # to build a table of contents." : "No matching headings.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
                .padding(.top, 4)
        } else {
            let minLevel = headings.map(\.level).min() ?? 1
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { heading in
                    let depth = max(0, heading.level - minLevel)
                    Button {
                        onJumpHeading(heading)
                    } label: {
                        HStack(spacing: 5) {
                            Text(heading.text)
                                .font(.system(size: theme.pointSize(.small), weight: heading.level <= 2 ? .medium : .regular))
                                .foregroundStyle(p.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text("H\(heading.level)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.leading, CGFloat(6 + depth * 11))
                        .padding(.trailing, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(p.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    @ViewBuilder
    private var backlinksBody: some View {
        let p = theme.palette
        sectionTitle("Backlinks", count: backlinks.count)
        if backlinks.isEmpty {
            Text("No other pages link here yet.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(backlinks) { item in
                    Button {
                        context.navigate(KnowledgeShellLogic.pageHref(id: item.id, title: item.title))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.accent)
                                .lineLimit(1)
                            Text(KnowledgeShellLogic.folderDisplay(of: item.path))
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                                .lineLimit(1)
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        sectionTitle("Unlinked Mentions", count: unlinkedMentions.count)
            .padding(.top, 4)
        if unlinkedMentions.isEmpty {
            Text("No unlinked mentions found.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(unlinkedMentions) { mention in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Button(mention.pageTitle) {
                                context.navigate(KnowledgeShellLogic.pageHref(id: mention.pageId, title: mention.pageTitle))
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.accent)
                            .lineLimit(1)

                            Spacer(minLength: 4)

                            Button(linkingMentionId == mention.id ? "\u{2026}" : "Link") {
                                onLinkMention(mention)
                            }
                            .buttonStyle(.vesper())
                            .controlSize(.mini)
                            .disabled(linkingMentionId != nil)
                        }
                        Text(mention.snippet)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }

        if !outgoingResolved.isEmpty || !outgoingUnresolved.isEmpty {
            sectionTitle("Outgoing Links", count: outgoingResolved.count + outgoingUnresolved.count)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outgoingResolved) { item in
                    Button {
                        context.navigate(KnowledgeShellLogic.pageHref(id: item.id, title: item.title))
                    } label: {
                        Text(item.title)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(outgoingUnresolved, id: \.self) { missing in
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                        Text(missing)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        let p = theme.palette
        return HStack {
            Text(title.uppercased())
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.tertiaryText)
            Spacer()
            Text("\(count)")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.tertiaryText)
        }
    }
}
