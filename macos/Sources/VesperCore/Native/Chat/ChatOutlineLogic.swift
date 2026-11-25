import Foundation

public enum ChatOutlineCategory: String, CaseIterable, Sendable, Identifiable {
    case all
    case bookmarks
    case links
    case checklists
    case code
    case files

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .bookmarks: "Pinned"
        case .links: "Links"
        case .checklists: "Checklists"
        case .code: "Diffs & Code"
        case .files: "Files"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: "list.bullet"
        case .bookmarks: "bookmark.fill"
        case .links: "link"
        case .checklists: "checklist"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .files: "doc.text"
        }
    }
}

public struct ChatOutlineItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var category: ChatOutlineCategory
    public var messageId: String
    public var title: String
    public var subtitle: String?
    public var badge: String?
    public var href: String?

    public init(
        id: String,
        category: ChatOutlineCategory,
        messageId: String,
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        href: String? = nil
    ) {
        self.id = id
        self.category = category
        self.messageId = messageId
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.href = href
    }
}

public enum ChatOutlineLogic {
    private static let richNonCodeFences: Set<String> = [
        "recommend", "gallery", "product", "choices", "dispatch", "workflow-run",
        "research-plan", "chart", "stats", "compare", "timeline", "tree", "graph",
        "plot", "datatable", "kv", "json-tree", "http", "tabs", "details",
        "mermaid", "svg-image", "svg-steps", "app", "pdf", "playground", "canvas",
    ]

    public static func build(
        messages: [API.ChatMessage],
        canvases: [API.ChatCanvasSummary] = []
    ) -> [ChatOutlineItem] {
        var items: [ChatOutlineItem] = []
        var seenLinks: Set<String> = []
        let canvasById = Dictionary(canvases.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        for m in messages where m.role != .system {
            let author = m.role == .user ? "You" : (m.persona?.name ?? "Assistant")

            if m.bookmarked == true {
                items.append(ChatOutlineItem(
                    id: "bm:\(m.id)",
                    category: .bookmarks,
                    messageId: m.id,
                    title: previewLine(m.bodyMd),
                    subtitle: author,
                    badge: "Pinned"
                ))
            }

            for att in m.attachments ?? [] {
                let ext = att.contentType.split(separator: "/").last.map { String($0).uppercased() } ?? "FILE"
                items.append(ChatOutlineItem(
                    id: "att:\(m.id):\(att.id)",
                    category: .files,
                    messageId: m.id,
                    title: att.filename,
                    subtitle: author,
                    badge: ext
                ))
            }

            for ch in m.codeChanges ?? [] {
                items.append(ChatOutlineItem(
                    id: "chg:\(m.id):\(ch.path)",
                    category: .code,
                    messageId: m.id,
                    title: ch.path,
                    subtitle: "\(author) · \(ch.status.rawValue)",
                    badge: "+\(ch.additions) -\(ch.deletions)"
                ))
            }

            let parsed = ChatTranscriptLogic.parseMessage(m.bodyMd, extractSources: m.role == .assistant)
            var segIdx = 0
            for seg in parsed.segments {
                defer { segIdx += 1 }
                switch seg {
                case .checklist(let block):
                    let done = block.items.filter { item in
                        if let persisted = m.checklistState?[String(item.index)] { return persisted }
                        return item.defaultChecked
                    }.count
                    let firstText = block.items.first?.text ?? "Checklist"
                    items.append(ChatOutlineItem(
                        id: "chk:\(m.id):\(segIdx)",
                        category: .checklists,
                        messageId: m.id,
                        title: firstText,
                        subtitle: "\(author) · \(done)/\(block.items.count) completed",
                        badge: "\(done)/\(block.items.count)"
                    ))
                case .diff(let spec):
                    items.append(ChatOutlineItem(
                        id: "diff:\(m.id):\(segIdx)",
                        category: .code,
                        messageId: m.id,
                        title: spec.title ?? "Diff",
                        subtitle: author,
                        badge: "diff"
                    ))
                case .codeGroup(let spec):
                    items.append(ChatOutlineItem(
                        id: "cg:\(m.id):\(segIdx)",
                        category: .code,
                        messageId: m.id,
                        title: spec.title ?? "Code group",
                        subtitle: author,
                        badge: "\(spec.tabs.count) files"
                    ))
                case .canvas(let cid):
                    let canvas = canvasById[cid]
                    let isDesign = canvas.map { $0.kind == .design } ?? false
                    items.append(ChatOutlineItem(
                        id: "canvas:\(m.id):\(cid):\(segIdx)",
                        category: .files,
                        messageId: m.id,
                        title: canvas?.title ?? "Canvas",
                        subtitle: author,
                        badge: isDesign ? "Design" : "Doc"
                    ))
                case .recommend(let cards):
                    for card in cards where seenLinks.insert(card.url).inserted {
                        items.append(ChatOutlineItem(
                            id: "link:\(m.id):\(card.url)",
                            category: .links,
                            messageId: m.id,
                            title: ChatMediaURL.hostLabel(card.url),
                            subtitle: card.note.isEmpty ? card.url : card.note,
                            badge: "Recommend",
                            href: card.url
                        ))
                    }
                case .gallery(let spec):
                    for entry in spec.items {
                        guard let u = entry.url ?? entry.image, seenLinks.insert(u).inserted else { continue }
                        items.append(ChatOutlineItem(
                            id: "link:\(m.id):\(u)",
                            category: .links,
                            messageId: m.id,
                            title: entry.caption ?? ChatMediaURL.hostLabel(u),
                            subtitle: entry.source ?? ChatMediaURL.hostLabel(u),
                            badge: "Image",
                            href: u
                        ))
                    }
                case .product(let spec):
                    for entry in spec.items {
                        guard let u = entry.url ?? entry.image, seenLinks.insert(u).inserted else { continue }
                        items.append(ChatOutlineItem(
                            id: "link:\(m.id):\(u)",
                            category: .links,
                            messageId: m.id,
                            title: entry.name,
                            subtitle: [entry.price, ChatMediaURL.hostLabel(u)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            badge: "Product",
                            href: u
                        ))
                    }
                case .markdown(let text):
                    extractCodeFencesAndLinks(
                        from: text,
                        messageId: m.id,
                        author: author,
                        seenLinks: &seenLinks,
                        items: &items
                    )
                default:
                    break
                }
            }

            for source in parsed.sources where !source.url.isEmpty && seenLinks.insert(source.url).inserted {
                items.append(ChatOutlineItem(
                    id: "src:\(m.id):\(source.url)",
                    category: .links,
                    messageId: m.id,
                    title: source.title.isEmpty ? ChatMediaURL.hostLabel(source.url) : source.title,
                    subtitle: ChatMediaURL.hostLabel(source.url),
                    badge: source.number.map { "[\($0)]" },
                    href: source.url
                ))
            }
        }

        return items
    }

    public static func filter(
        _ items: [ChatOutlineItem],
        category: ChatOutlineCategory,
        query: String
    ) -> [ChatOutlineItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if category != .all && item.category != category { return false }
            guard !q.isEmpty else { return true }
            return item.title.lowercased().contains(q)
                || (item.subtitle?.lowercased().contains(q) ?? false)
                || (item.badge?.lowercased().contains(q) ?? false)
        }
    }

    public static func counts(_ items: [ChatOutlineItem]) -> [ChatOutlineCategory: Int] {
        var out: [ChatOutlineCategory: Int] = [:]
        for cat in ChatOutlineCategory.allCases { out[cat] = 0 }
        out[.all] = items.count
        for item in items {
            out[item.category, default: 0] += 1
        }
        return out
    }

    private static func previewLine(_ md: String) -> String {
        let stripped = ChatInspectorLogic.strippedPromptPreview(md, limit: 100)
        return stripped.isEmpty ? "Message" : stripped
    }

    private static func extractCodeFencesAndLinks(
        from md: String,
        messageId: String,
        author: String,
        seenLinks: inout Set<String>,
        items: inout [ChatOutlineItem]
    ) {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inFence = false
        var fenceIdx = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    inFence = true
                    let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
                    if !info.isEmpty && !richNonCodeFences.contains(info) {
                        items.append(ChatOutlineItem(
                            id: "mdcode:\(messageId):\(fenceIdx)",
                            category: .code,
                            messageId: messageId,
                            title: "\(info) snippet",
                            subtitle: author,
                            badge: info
                        ))
                        fenceIdx += 1
                    }
                } else {
                    inFence = false
                }
                continue
            }
            if inFence { continue }
            guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#) else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let url = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if seenLinks.insert(url).inserted {
                    items.append(ChatOutlineItem(
                        id: "mdlink:\(messageId):\(url)",
                        category: .links,
                        messageId: messageId,
                        title: label.isEmpty ? ChatMediaURL.hostLabel(url) : label,
                        subtitle: ChatMediaURL.hostLabel(url),
                        href: url
                    ))
                }
            }
        }
    }
}
