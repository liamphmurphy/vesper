import SwiftUI
import VesperCore

// MARK: - Callout / Admonition View (LAZYAGENTS-322)

struct ChatCalloutView: View {
    @Environment(\.vesperTheme) private var theme

    let callout: ChatCalloutBlock
    var citations: [Int] = []
    var onLinkWithAnchor: ((MarkdownLinkTarget, MarkdownLinkAnchor?) -> Bool)? = nil

    @State private var isCollapsed: Bool

    init(
        callout: ChatCalloutBlock,
        citations: [Int] = [],
        onLinkWithAnchor: ((MarkdownLinkTarget, MarkdownLinkAnchor?) -> Bool)? = nil
    ) {
        self.callout = callout
        self.citations = citations
        self.onLinkWithAnchor = onLinkWithAnchor
        self._isCollapsed = State(initialValue: callout.collapsible && callout.defaultCollapsed)
    }

    private var accentColor: Color {
        switch callout.kind {
        case .note:
            return theme.palette.accent
        case .tip:
            return theme.swiftUIColor("state-done", fallback: .green)
        case .warning:
            return theme.swiftUIColor("state-progress", fallback: .orange)
        case .caveat:
            return theme.swiftUIColor("pill-human-fg", fallback: .yellow)
        case .conflict:
            return theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        }
    }

    var body: some View {
        let accent = accentColor
        VStack(alignment: .leading, spacing: 0) {
            headerRow(accent: accent)
            if !isCollapsed && !callout.body.isEmpty {
                MarkdownView(markdown: callout.body, textStyle: .chat, chat: true, citations: citations, onLinkWithAnchor: onLinkWithAnchor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(theme.mode == .dark ? 0.11 : 0.07))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(theme.mode == .dark ? 0.30 : 0.25))
        )
    }

    @ViewBuilder
    private func headerRow(accent: Color) -> some View {
        let p = theme.palette
        let label = HStack(spacing: 7) {
            Image(systemName: callout.kind.systemImage)
                .imageScale(.small)
                .foregroundStyle(accent)
            Text(callout.title)
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(p.text)
            Spacer(minLength: 4)
            if callout.collapsible {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        if callout.collapsible {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(callout.title), \(isCollapsed ? "collapsed" : "expanded")")
        } else {
            label
        }
    }
}

// MARK: - Interactive Checklist View (LAZYAGENTS-324)

struct ChatChecklistCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let messageId: String
    let checklist: ChatChecklistBlock
    let persistedState: [String: Bool]?

    @State private var localOverrides: [String: Bool] = [:]
    @State private var hoveredIndex: Int?
    @State private var capturingIndex: Int?
    @State private var capturedIndices: Set<Int> = []

    private var effectiveState: [String: Bool] {
        var merged = persistedState ?? [:]
        for (k, v) in localOverrides {
            merged[k] = v
        }
        return merged
    }

    var body: some View {
        let p = theme.palette
        let state = effectiveState
        let doneCount = checklist.completedCount(state: state)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                Text("Checklist")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                Spacer(minLength: 8)
                Text("\(doneCount)/\(checklist.items.count) done")
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(doneCount == checklist.items.count ? theme.swiftUIColor("state-done", fallback: .green) : p.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle().fill(p.rowBorder).frame(height: 1)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(checklist.items) { item in
                    let checked = checklist.isChecked(item, state: state)
                    checklistRow(item: item, checked: checked)
                }
            }
            .padding(.vertical, 6)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func checklistRow(item: ChatChecklistItem, checked: Bool) -> some View {
        let p = theme.palette
        let isHovered = hoveredIndex == item.index
        let isCapturing = capturingIndex == item.index
        let isCaptured = capturedIndices.contains(item.index)

        return HStack(alignment: .top, spacing: 8) {
            Button {
                toggle(item: item, to: !checked)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(checked ? p.accent : p.tertiaryText)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Mark undone: \(item.text)" : "Mark done: \(item.text)")

            Text(item.text)
                .font(.system(size: theme.pointSize(.chat)))
                .foregroundStyle(checked ? p.secondaryText : p.text)
                .strikethrough(checked, color: p.tertiaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { toggle(item: item, to: !checked) }

            HStack(spacing: 6) {
                Button {
                    captureToInbox(item: item)
                } label: {
                    if isCapturing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isCaptured ? "checkmark" : "tray.and.arrow.down")
                            .imageScale(.small)
                            .foregroundStyle(isCaptured ? theme.swiftUIColor("state-done", fallback: .green) : p.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
                .help("Send to Knowledge inbox")
            }
            .opacity(isHovered || isCapturing || isCaptured ? 1 : 0.35)
        }
        .padding(.leading, CGFloat(12 + item.indentLevel * 18))
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(isHovered ? p.surface.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { inside in
            hoveredIndex = inside ? item.index : (hoveredIndex == item.index ? nil : hoveredIndex)
        }
    }

    private func toggle(item: ChatChecklistItem, to newValue: Bool) {
        let key = String(item.index)
        let previous = localOverrides[key]
        localOverrides[key] = newValue
        Task {
            do {
                let res = try await context.store.mutate(
                    API.updateChatMessageChecklist(
                        id: chatId,
                        messageId: messageId,
                        body: API.ChatChecklistUpdate(checked: newValue, index: item.index)
                    ),
                    invalidating: QueryInvalidation(prefixes: [["chats", chatId]])
                )
                localOverrides = res.checklistState
            } catch {
                if let previous {
                    localOverrides[key] = previous
                } else {
                    localOverrides.removeValue(forKey: key)
                }
                context.showToast(ToastItemModel(
                    id: "checklist.err.\(item.index)",
                    title: "Couldn't save checklist state",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }

    private func captureToInbox(item: ChatChecklistItem) {
        capturingIndex = item.index
        let title = String(item.text.prefix(120))
        let body = item.text.count > 120 ? item.text : ""
        Task {
            defer { capturingIndex = nil }
            do {
                let page = try await context.store.mutate(
                    KnowledgeAPI.captureNote(KnowledgePageInput(title: title, bodyMd: body)),
                    invalidating: KnowledgeAPI.invalidation
                )
                capturedIndices.insert(item.index)
                context.showToast(
                    ToastItemModel(id: "checklist.capture.\(page.id)", title: "Saved to Knowledge inbox", tone: .success, actionLabel: "Open"),
                    onEvent: { event in
                        if event == .action { context.navigate("/knowledge/\(page.id)") }
                    }
                )
            } catch {
                context.showToast(ToastItemModel(
                    id: "checklist.capture.err",
                    title: "Couldn't send to Knowledge inbox",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }
}
