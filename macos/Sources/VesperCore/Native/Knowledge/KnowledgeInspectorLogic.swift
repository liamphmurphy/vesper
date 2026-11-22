import Foundation

/// A markdown heading discovered in a Knowledge page for the right-rail Outline inspector.
public struct KnowledgeOutlineHeading: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(index):\(text)" }
    public var index: Int
    public var level: Int
    public var text: String
    public var segmentIndex: Int
    public var utf16Location: Int
    public var utf16Length: Int

    public init(
        index: Int,
        level: Int,
        text: String,
        segmentIndex: Int,
        utf16Location: Int,
        utf16Length: Int
    ) {
        self.index = index
        self.level = level
        self.text = text
        self.segmentIndex = segmentIndex
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}

/// Pure right-rail / inspector model builders for the native Knowledge screen.
public enum KnowledgeInspectorLogic {
    public static let modelId = "knowledge"
    public static let chatTabId = "chat"
    public static let outlineTabId = "outline"
    public static let linksTabId = "links"
    public static let propertiesTabId = "properties"
    public static let queryTabId = "query"
    public static let historyTabId = "history"
    public static let reviewsTabId = "reviews"
    public static let calendarTabId = "calendar"
    public static let jumpHeadingActionId = "jump_heading"

    public static let customNativeTabIds: Set<String> = [
        linksTabId,
        propertiesTabId,
        queryTabId,
        historyTabId,
        reviewsTabId,
    ]

    /// Extracts ordered headings across prose segments, skipping headings inside fenced code blocks.
    public static func extractHeadings(from segments: [KnowledgeDocumentSegment]) -> [KnowledgeOutlineHeading] {
        var headings: [KnowledgeOutlineHeading] = []
        for (segIdx, segment) in segments.enumerated() {
            guard case .prose(let prose) = segment else { continue }
            let ns = prose.text as NSString
            for token in KnowledgeMarkdownSyntax.scan(prose.text) {
                guard case .heading(let level) = token.kind else { continue }
                guard token.contentRange.location >= 0,
                      token.contentRange.location + token.contentRange.length <= ns.length else { continue }
                let text = ns.substring(with: token.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                headings.append(KnowledgeOutlineHeading(
                    index: headings.count,
                    level: level,
                    text: text,
                    segmentIndex: segIdx,
                    utf16Location: token.range.location,
                    utf16Length: token.range.length
                ))
            }
        }
        return headings
    }

    public static func extractHeadings(from markdown: String) -> [KnowledgeOutlineHeading] {
        extractHeadings(from: KnowledgeEditorDocument(markdown: markdown).segments)
    }

    /// Parses the leading heading index from an outline row id (`"<index>:<text>"`).
    public static func parseHeadingIndex(from itemId: String) -> Int? {
        guard let colon = itemId.firstIndex(of: ":") else { return nil }
        return Int(itemId[..<colon])
    }

    /// True when the page renders in the native markdown editor and supports a live heading outline.
    public static func supportsMarkdownOutline(page: KnowledgePage?, query: [String: String] = [:]) -> Bool {
        guard let page else { return true }
        let target = KnowledgeShellLogic.editorTarget(for: page, query: query)
        switch target {
        case .deck, .design, .pdf:
            return false
        case .hostedPage:
            if page.kind == .document, let canvasId = page.canvasId, !canvasId.isEmpty {
                return false
            }
            return true
        }
    }

    /// Builds declarative `InspectorSection`s for the Outline tab, matching the web Knowledge outline format.
    public static func buildOutlineSections(headings: [KnowledgeOutlineHeading]) -> [InspectorSection] {
        guard !headings.isEmpty else {
            return [
                InspectorSection(
                    id: "outline",
                    title: "Outline",
                    emptyText: "No headings yet. Start a line with # to add one.",
                    items: []
                )
            ]
        }
        let topLevel = headings.map(\.level).min() ?? 1
        let rows = headings.map { heading in
            let depth = max(0, heading.level - topLevel)
            let title = depth > 0
                ? "\(String(repeating: "  ", count: depth))↳ \(heading.text)"
                : heading.text
            return NavItem(
                id: heading.id,
                title: title,
                trailing: "H\(heading.level)"
            )
        }
        return [
            InspectorSection(
                id: "outline",
                title: "Outline",
                aside: String(headings.count),
                items: [
                    InspectorItem(
                        id: "headings",
                        kind: .list,
                        actionId: jumpHeadingActionId,
                        rows: rows
                    )
                ]
            )
        ]
    }

    /// Human-readable Knowledge screen label passed to `knowledge.chat` when not viewing a specific page.
    public static func screenLabel(for destination: KnowledgeDestination) -> String {
        switch destination {
        case .home: return "Home"
        case .graph: return "Graph"
        case .connect: return "Connect"
        case .search: return "Search"
        case .start(let kind):
            switch kind {
            case .document: return "Documents"
            case .deck: return "Decks"
            case .design: return "Designs"
            }
        case .page: return "Page"
        case .legacyWiki: return "Wiki"
        }
    }

    /// Parses the `chatId` carried by `knowledge.chat`'s `generalChat` panel event payload.
    public static func parseGeneralChatId(from payloadJson: String?) -> String? {
        guard let payloadJson,
              let data = payloadJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chatId = obj["chatId"] as? String,
              !chatId.isEmpty else {
            return nil
        }
        return chatId
    }

    /// Builds the complete `InspectorModel` for the current Knowledge destination.
    public static func buildInspectorModel(
        destination: KnowledgeDestination,
        loadedPage: KnowledgePage?,
        headings: [KnowledgeOutlineHeading],
        query: [String: String] = [:],
        generalChatId: String? = nil,
        open: Bool,
        activeTabId: String
    ) -> InspectorModel {
        let tabs: [InspectorTab]
        if case .page = destination {
            let showOutline = supportsMarkdownOutline(page: loadedPage, query: query)
            let pendingReviews = loadedPage.map { page in
                KnowledgePanelsLogic.pendingChanges(in: page).filter { !$0.isStale }.count
            } ?? 0
            var pageTabs: [InspectorTab] = [
                InspectorTab(
                    id: chatTabId,
                    label: "Chat",
                    icon: "msg",
                    kind: .native,
                    width: .regular
                )
            ]
            if showOutline {
                pageTabs.append(InspectorTab(
                    id: outlineTabId,
                    label: "Outline",
                    icon: "outline",
                    kind: .native,
                    width: .regular,
                    sections: buildOutlineSections(headings: headings)
                ))
            }
            pageTabs.append(contentsOf: [
                InspectorTab(id: linksTabId, label: "Links", icon: "link", kind: .native, width: .regular),
                InspectorTab(id: propertiesTabId, label: "Properties", icon: "sliders", kind: .native, width: .regular),
                InspectorTab(id: queryTabId, label: "Query", icon: "table", kind: .native, width: .regular),
                InspectorTab(id: historyTabId, label: "History", icon: "history", kind: .native, width: .regular),
                InspectorTab(
                    id: reviewsTabId,
                    label: "Reviews",
                    icon: "reviews",
                    kind: .native,
                    width: .regular,
                    unread: pendingReviews > 0 ? true : nil
                ),
                InspectorTab(
                    id: calendarTabId,
                    label: "Calendar",
                    icon: "calendar",
                    kind: .native,
                    width: .regular
                ),
            ])
            tabs = pageTabs
        } else {
            tabs = [
                InspectorTab(
                    id: chatTabId,
                    label: "Chat",
                    icon: "msg",
                    kind: .native,
                    width: .regular
                ),
                InspectorTab(
                    id: calendarTabId,
                    label: "Calendar",
                    icon: "calendar",
                    kind: .native,
                    width: .regular
                ),
            ]
        }

        let resolvedActiveId: String
        if tabs.contains(where: { $0.id == activeTabId }) {
            resolvedActiveId = activeTabId
        } else {
            resolvedActiveId = tabs.first?.id ?? chatTabId
        }

        return InspectorModel(
            id: modelId,
            open: open,
            activeTabId: resolvedActiveId,
            tabs: tabs
        )
    }
}
