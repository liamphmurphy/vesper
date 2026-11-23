import SwiftUI
import VesperCore

/// Native Thread Outline inspector tab: indexes bookmarked messages, links, checklists,
/// diffs/code blocks, and files/canvases for fast jumping inside long conversations.
struct ChatOutlineInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let onJumpToMessage: @MainActor (String) -> Void

    @State private var selectedCategory: ChatOutlineCategory = .all
    @State private var query = ""

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }

    private var canvasesRequest: APIRequest<API.ChatCanvases> {
        API.listChatCanvases(id: chatId)
    }

    var body: some View {
        let p = theme.palette
        let messages = context.store.entry(messagesRequest).data?.messages ?? []
        let canvases = context.store.entry(canvasesRequest).data?.canvases ?? []
        let allItems = ChatOutlineLogic.build(messages: messages, canvases: canvases)
        let counts = ChatOutlineLogic.counts(allItems)
        let visible = ChatOutlineLogic.filter(allItems, category: selectedCategory, query: query)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                    TextField("Filter pins, links, checklists, diffs…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: theme.pointSize(.small)))
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(ChatOutlineCategory.allCases) { cat in
                            let count = counts[cat] ?? 0
                            let active = selectedCategory == cat
                            Button {
                                selectedCategory = cat
                            } label: {
                                HStack(spacing: 4) {
                                    Text(cat.label)
                                    if count > 0 {
                                        Text("\(count)")
                                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                            .opacity(0.75)
                                    }
                                }
                                .font(.system(size: theme.pointSize(.micro), weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? p.accent : p.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(active ? p.selected : p.surface, in: Capsule())
                                .overlay(Capsule().stroke(active ? p.accent : p.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)

            Divider()

            if visible.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(p.tertiaryText)
                    Text(allItems.isEmpty
                         ? "Bookmarks, links, checklists, diffs, and files from this conversation will appear here."
                         : "No matching items in this thread.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visible) { item in
                            Button {
                                onJumpToMessage(item.messageId)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.category.systemImage)
                                        .font(.system(size: 11))
                                        .foregroundStyle(item.category == .bookmarks ? p.accent : p.tertiaryText)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                                            .foregroundStyle(p.text)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(p.tertiaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if let badge = item.badge, !badge.isEmpty {
                                        Text(badge)
                                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                            .foregroundStyle(p.secondaryText)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .background(p.surface.opacity(0.01))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task(id: chatId) {
            context.store.load(messagesRequest)
            context.store.load(canvasesRequest)
        }
    }
}
