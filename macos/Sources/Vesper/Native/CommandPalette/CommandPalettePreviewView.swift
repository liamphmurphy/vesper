import SwiftUI
import VesperCore

/// The right-hand preview pane for the currently selected row in the native Command Palette.
struct CommandPalettePreviewView: View {
    let model: CommandPaletteModel
    let row: PaletteRow?

    private var theme: ThemeTokens { model.theme }
    private var isDark: Bool { theme.mode == .dark }

    private var paneFill: Color {
        isDark ? Color.white.opacity(0.025) : Color.black.opacity(0.025)
    }

    private var cardFill: Color {
        isDark ? Color.white.opacity(0.045) : Color.white.opacity(0.72)
    }

    private var cardBorder: Color {
        isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    private var primaryText: Color {
        isDark ? Color(red: 0.96, green: 0.96, blue: 0.97) : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    private var bodyText: Color {
        isDark ? Color(red: 0.83, green: 0.83, blue: 0.85) : Color(red: 0.23, green: 0.23, blue: 0.24)
    }

    private var secondaryText: Color {
        isDark ? Color(red: 0.63, green: 0.63, blue: 0.67) : Color(red: 0.43, green: 0.43, blue: 0.45)
    }

    private var tertiaryText: Color {
        isDark ? Color(red: 0.56, green: 0.56, blue: 0.58) : Color(red: 0.53, green: 0.53, blue: 0.55)
    }

    private var accentColor: Color {
        theme.palette.accent
    }

    private var amberColor: Color {
        isDark ? Color(red: 1.0, green: 0.62, blue: 0.04) : Color(red: 0.79, green: 0.41, blue: 0.0)
    }

    private var greenColor: Color {
        isDark ? Color(red: 0.49, green: 0.91, blue: 0.60) : Color(red: 0.12, green: 0.55, blue: 0.28)
    }

    private var purpleColor: Color {
        isDark ? Color(red: 0.89, green: 0.72, blue: 1.0) : Color(red: 0.52, green: 0.25, blue: 0.80)
    }

    var body: some View {
        let actions = model.previewActions(for: row)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview = row?.preview {
                        previewBody(preview)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        actionButton(action)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paneFill)
    }

    // MARK: - Preview Variants

    @ViewBuilder
    private func previewBody(_ preview: PalettePreview) -> some View {
        switch preview {
        case .inbox(let item):
            inboxPreview(item)
        case .ticket(let key, let title):
            ticketPreview(key: key, fallbackTitle: title)
        case .page(let id, let path, let title, let isKnowledge, let rowData):
            pagePreview(id: id, path: path, fallbackTitle: title, isKnowledge: isKnowledge, rowData: rowData)
        case .chat(let chat):
            chatPreview(chat: chat, focusMessage: nil)
        case .message(let chat, let message):
            chatPreview(chat: chat, focusMessage: message)
        case .command(let info):
            commandPreview(info)
        case .item(let label, let title, let detail, let updatedAt):
            genericPreview(label: label, title: title, detail: detail, updatedAt: updatedAt)
        }
    }

    private func inboxPreview(_ item: API.InboxItem) -> some View {
        let kindLabel = item.kind.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
        let header = [kindLabel, item.needsYou ? "NEEDS YOU" : nil, item.ticketKey.isEmpty ? nil : item.ticketKey]
            .compactMap { $0 }
            .joined(separator: " · ")
        let meta = [
            item.agent.map { "\($0.name) asked \(APIDate.timeline(item.createdAt))" } ?? "Waiting since \(APIDate.timeline(item.createdAt))",
            item.project.isEmpty ? nil : item.project,
        ].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 10) {
            sectionKicker(header, color: item.needsYou ? amberColor : accentColor)
            previewTitle(item.title)
            Text(meta)
                .font(.system(size: 12))
                .foregroundStyle(secondaryText)

            if !item.summary.isEmpty {
                if item.kind == .approval {
                    Text(item.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(greenColor)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                        .padding(.top, 4)
                } else {
                    Text(item.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(bodyText)
                        .lineSpacing(4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                        .padding(.top, 4)
                }
            }
        }
    }

    private func ticketPreview(key: String, fallbackTitle: String) -> some View {
        let ticket = key.isEmpty ? nil : model.store?.entry(API.getTicket(key: key)).data
        let title = ticket?.title ?? fallbackTitle
        let excerpt = ticket.map { CommandPaletteLogic.plainExcerpt($0.descriptionMd, max: 280) } ?? ""
        let facts: [String] = [
            ticket?.assignee?.name ?? (ticket != nil ? "unassigned" : nil),
            ticket?.epic?.name,
            ticket?.estimatePoints.map { "\($0) pts" },
        ].compactMap { $0 }

        return VStack(alignment: .leading, spacing: 10) {
            sectionKicker(key.isEmpty ? "TICKET" : "TICKET · \(key)", color: accentColor)
            previewTitle(title)

            if let ticket {
                HStack(spacing: 8) {
                    statusBadge(ticket.status.rawValue)
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            if !excerpt.isEmpty {
                highlightedText(excerpt, query: model.highlightQuery, baseColor: bodyText, matchColor: primaryText)
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .lineLimit(5)
                    .padding(.top, 4)
            }

            if let run = ticket?.run {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LAST RUN")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tertiaryText)
                        .tracking(0.5)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(runStateColor(run.state.rawValue))
                            .frame(width: 7, height: 7)
                        Text(run.state.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(primaryText)
                        Text("· \(run.agent.name) · \(APIDate.shortAgo(run.startedAt))")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                }
                .padding(.top, 8)
            }
        }
    }

    private func pagePreview(id: String, path: String, fallbackTitle: String, isKnowledge: Bool, rowData: KnowledgePageRow?) -> some View {
        let kpage = (isKnowledge && !id.isEmpty) ? model.store?.entry(KnowledgeAPI.getPage(id: id)).data : nil
        let wiki = (!isKnowledge && !path.isEmpty) ? model.store?.entry(API.getWikiPage(path: path)).data : nil
        let backlinks = !id.isEmpty ? (model.store?.entry(API.getBacklinks(kind: .artifact, id: id)).data?.linked ?? []) : []

        let resolvedPath = kpage?.path ?? wiki?.path ?? rowData?.path ?? path
        let folder = CommandPaletteLogic.knowledgeFolder(resolvedPath)
        let kindLabel: String = {
            let k = kpage?.kind ?? rowData?.kind
            switch k {
            case .deck: return "DECK"
            case .design: return "DESIGN"
            default: return "PAGE"
            }
        }()
        let kicker = folder == "Top level" ? kindLabel : "\(kindLabel) · \(folder.uppercased())"
        let title = kpage?.title ?? wiki?.title ?? rowData?.title ?? fallbackTitle

        let audience: String? = {
            if let a = kpage?.audience ?? rowData?.audience {
                return a.rawValue.capitalized
            }
            return wiki?.audience?.capitalized
        }()
        let updatedAt = wiki?.updatedAt ?? rowData?.updatedAt
        let tags: [String] = {
            if let t = wiki?.tags, !t.isEmpty { return Array(t.prefix(3)).map { "#\($0)" } }
            let props = kpage?.properties ?? rowData?.properties ?? [:]
            if case .array(let vals) = props["tags"] {
                return vals.compactMap(\.stringValue).prefix(3).map { "#\($0)" }
            }
            return []
        }()
        let facts = ([audience, updatedAt.map { "edited \(APIDate.timeline($0))" }].compactMap { $0 } + tags).joined(separator: " · ")
        let rawBody = kpage?.bodyMd ?? wiki?.bodyMd ?? rowData?.summary ?? ""
        let excerpt = rawBody.isEmpty ? "" : CommandPaletteLogic.plainExcerpt(rawBody, max: 320)

        return VStack(alignment: .leading, spacing: 10) {
            sectionKicker(kicker, color: isKnowledge ? greenColor : accentColor)
            previewTitle(title)
            if !facts.isEmpty {
                Text(facts)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
            if !excerpt.isEmpty {
                highlightedText(excerpt, query: model.highlightQuery, baseColor: bodyText, matchColor: primaryText)
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .lineLimit(6)
                    .padding(.top, 2)
            }
            if !backlinks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LINKED FROM \(backlinks.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tertiaryText)
                        .tracking(0.5)
                    ForEach(Array(backlinks.prefix(4).enumerated()), id: \.offset) { _, mention in
                        HStack(spacing: 8) {
                            Image(systemName: mention.sourceKind == .ticket ? "checklist" : "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryText)
                            Text(mention.source.displayId ?? mention.source.path ?? mention.source.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(bodyText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func chatPreview(chat: CommandPaletteChatMatch, focusMessage: CommandPaletteMessageMatch?) -> some View {
        let messages = model.store?.entry(API.listChatMessages(id: chat.id, limit: focusMessage != nil ? 20 : 8)).data?.messages ?? []
        let shownMessages: [API.ChatMessage] = {
            if let focus = focusMessage, let idx = messages.firstIndex(where: { $0.id == focus.id }) {
                let start = max(0, idx - 1)
                let end = min(messages.count, idx + 2)
                return Array(messages[start..<end])
            }
            return Array(messages.suffix(4))
        }()

        return VStack(alignment: .leading, spacing: 10) {
            sectionKicker(focusMessage != nil ? "MESSAGE" : "CHAT", color: accentColor)
            previewTitle(chat.title)
            if let persona = chat.persona {
                let meta = [persona, chat.at.map { APIDate.timeline($0) }].compactMap { $0 }.joined(separator: " · ")
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }

            if !shownMessages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shownMessages, id: \.id) { msg in
                        let isFocus = focusMessage?.id == msg.id
                        let isUser = msg.role == .user
                        let who = isUser ? "You" : (msg.persona?.name ?? msg.author?.name ?? "Assistant")
                        let text = CommandPaletteLogic.plainExcerpt(msg.bodyMd, max: isFocus ? 280 : 140)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(who) · \(APIDate.timeline(msg.createdAt))")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(secondaryText)
                            highlightedText(text, query: model.highlightQuery, baseColor: isFocus ? primaryText : bodyText, matchColor: primaryText)
                                .font(.system(size: 12))
                                .lineSpacing(3)
                                .lineLimit(isFocus ? 5 : 3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isFocus ? accentColor.opacity(isDark ? 0.18 : 0.12) : cardFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isFocus ? accentColor.opacity(0.6) : cardBorder, lineWidth: 1)
                        )
                    }
                }
                .padding(.top, 4)
            } else if let focus = focusMessage {
                let snippetText = CommandPaletteLogic.snippetParts(focus.snippet).map(\.text).joined()
                Text("…\(snippetText)…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(bodyText)
                    .lineSpacing(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
            }
        }
    }

    private func commandPreview(_ info: PaletteCommandPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionKicker(info.category.uppercased(), color: purpleColor)
            previewTitle(info.title)
            Text(info.description)
                .font(.system(size: 12.5))
                .foregroundStyle(bodyText)
                .lineSpacing(4)

            if info.shortcut != nil || info.contextLabel != nil {
                VStack(spacing: 0) {
                    if let shortcut = info.shortcut {
                        HStack {
                            Text("Shortcut")
                                .font(.system(size: 12))
                                .foregroundStyle(secondaryText)
                            Spacer()
                            Text(shortcut)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(primaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    if info.shortcut != nil && info.contextLabel != nil {
                        Divider().overlay(cardBorder).padding(.horizontal, 12)
                    }
                    if let ctxLabel = info.contextLabel, let ctxValue = info.contextValue {
                        HStack {
                            Text(ctxLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(secondaryText)
                            Spacer()
                            Text(ctxValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                .padding(.top, 4)
            }
        }
    }

    private func genericPreview(label: String, title: String, detail: String?, updatedAt: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionKicker(label.uppercased(), color: accentColor)
            previewTitle(title)
            let meta = [detail, updatedAt.map { "updated \(APIDate.timeline($0))" }].compactMap { $0 }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionKicker("COMMAND PALETTE", color: tertiaryText)
            Text("Type to search across Vesper, or press > for commands.")
                .font(.system(size: 12.5))
                .foregroundStyle(secondaryText)
        }
    }

    // MARK: - Subviews

    private func sectionKicker(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func previewTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(primaryText)
            .lineSpacing(3)
            .lineLimit(3)
    }

    private func statusBadge(_ status: String) -> some View {
        let color = statusColor(status)
        return Text(CommandPaletteModel.statusLabel(status))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(isDark ? 0.16 : 0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "in_progress": isDark ? Color(red: 1.0, green: 0.84, blue: 0.04) : Color(red: 0.72, green: 0.50, blue: 0.0)
        case "in_review": accentColor
        case "done": greenColor
        case "blocked", "failed": isDark ? Color(red: 1.0, green: 0.42, blue: 0.40) : Color(red: 0.80, green: 0.16, blue: 0.18)
        default: secondaryText
        }
    }

    private func runStateColor(_ state: String) -> Color {
        switch state {
        case "running", "starting", "queued": greenColor
        case "paused", "waiting": amberColor
        case "failed": Color.red
        default: secondaryText
        }
    }

    private func actionButton(_ action: PalettePreviewAction) -> some View {
        let (fg, bg, border): (Color, Color, Color) = switch action.tone {
        case .primary:
            (
                isDark ? .white : accentColor,
                accentColor.opacity(isDark ? 0.24 : 0.14),
                accentColor.opacity(isDark ? 0.72 : 0.55)
            )
        case .approve:
            (
                isDark ? Color(red: 1.0, green: 0.84, blue: 0.60) : Color(red: 0.60, green: 0.29, blue: 0.05),
                amberColor.opacity(isDark ? 0.18 : 0.16),
                amberColor.opacity(0.6)
            )
        case .danger:
            (
                isDark ? Color(red: 1.0, green: 0.55, blue: 0.52) : Color(red: 0.75, green: 0.15, blue: 0.15),
                Color.red.opacity(isDark ? 0.16 : 0.12),
                Color.red.opacity(0.5)
            )
        case .secondary:
            (
                isDark ? Color(red: 0.90, green: 0.90, blue: 0.92) : primaryText,
                isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.75),
                isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
            )
        }

        return Button(action: action.run) {
            HStack(spacing: 6) {
                Text(action.label)
                    .font(.system(size: 12.5, weight: action.tone == .secondary ? .medium : .semibold))
                Text(action.keys)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .opacity(0.8)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func highlightedText(_ text: String, query: String, baseColor: Color, matchColor: Color) -> Text {
        let parts = CommandPaletteLogic.matchParts(text: text, query: query)
        var attributed = AttributedString()
        for part in parts {
            var run = AttributedString(part.text)
            run.foregroundColor = part.match ? matchColor : baseColor
            if part.match {
                run.font = .system(size: 12.5, weight: .bold)
            }
            attributed.append(run)
        }
        return Text(attributed)
    }
}
