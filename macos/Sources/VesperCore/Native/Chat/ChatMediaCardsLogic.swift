import Foundation

// MARK: - Gallery & Product Cards (Web & Article Images)

public struct ChatGalleryItem: Sendable, Equatable, Hashable {
    public var image: String?
    public var url: String?
    public var caption: String?
    public var source: String?

    public init(image: String? = nil, url: String? = nil, caption: String? = nil, source: String? = nil) {
        self.image = image
        self.url = url
        self.caption = caption
        self.source = source
    }
}

public struct ChatGallerySpec: Sendable, Equatable {
    public var title: String?
    public var items: [ChatGalleryItem]

    public init(title: String? = nil, items: [ChatGalleryItem]) {
        self.title = title
        self.items = items
    }

    public static func isGalleryFence(_ info: String?) -> Bool {
        guard let first = info?.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return first.lowercased() == "gallery"
    }

    public static func parse(_ code: String) -> ChatGallerySpec? {
        guard let data = code.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]] else {
            return nil
        }
        var items: [ChatGalleryItem] = []
        for entry in rawItems {
            let image = ChatMediaURL.safeHTTP(entry["image"] as? String)
            let url = ChatMediaURL.safeHTTP(entry["url"] as? String)
            guard image != nil || url != nil else { continue }
            let caption = ChatMediaURL.cleanText((entry["caption"] as? String) ?? (entry["title"] as? String), maxLength: 200)
            let source = ChatMediaURL.cleanText(entry["source"] as? String, maxLength: 80)
            items.append(ChatGalleryItem(image: image, url: url, caption: caption, source: source))
            if items.count >= 12 { break }
        }
        guard !items.isEmpty else { return nil }
        return ChatGallerySpec(title: ChatMediaURL.cleanText(obj["title"] as? String, maxLength: 120), items: items)
    }
}

public struct ChatProductItem: Sendable, Equatable, Hashable {
    public var name: String
    public var url: String?
    public var image: String?
    public var price: String?
    public var rating: String?
    public var badge: String?
    public var description: String?
    public var specs: [String]

    public init(
        name: String,
        url: String? = nil,
        image: String? = nil,
        price: String? = nil,
        rating: String? = nil,
        badge: String? = nil,
        description: String? = nil,
        specs: [String] = []
    ) {
        self.name = name
        self.url = url
        self.image = image
        self.price = price
        self.rating = rating
        self.badge = badge
        self.description = description
        self.specs = specs
    }
}

public struct ChatProductSpec: Sendable, Equatable {
    public var title: String?
    public var items: [ChatProductItem]

    public init(title: String? = nil, items: [ChatProductItem]) {
        self.title = title
        self.items = items
    }

    public static func isProductFence(_ info: String?) -> Bool {
        guard let first = info?.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return first.lowercased() == "product"
    }

    public static func parse(_ code: String) -> ChatProductSpec? {
        guard let data = code.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]] else {
            return nil
        }
        var items: [ChatProductItem] = []
        for entry in rawItems {
            guard let name = ChatMediaURL.cleanText((entry["name"] as? String) ?? (entry["title"] as? String), maxLength: 140) else {
                continue
            }
            let rawSpecs = entry["specs"] as? [Any] ?? []
            let specs = rawSpecs.compactMap { ChatMediaURL.cleanText($0 as? String, maxLength: 60) }.prefix(8)
            items.append(ChatProductItem(
                name: name,
                url: ChatMediaURL.safeHTTP(entry["url"] as? String),
                image: ChatMediaURL.safeHTTP(entry["image"] as? String),
                price: ChatMediaURL.cleanText(entry["price"] as? String, maxLength: 40),
                rating: ChatMediaURL.cleanText(entry["rating"] as? String, maxLength: 32),
                badge: ChatMediaURL.cleanText(entry["badge"] as? String, maxLength: 40),
                description: ChatMediaURL.cleanText(entry["description"] as? String, maxLength: 220),
                specs: Array(specs)
            ))
            if items.count >= 8 { break }
        }
        guard !items.isEmpty else { return nil }
        return ChatProductSpec(title: ChatMediaURL.cleanText(obj["title"] as? String, maxLength: 120), items: items)
    }
}

public enum ChatMediaURL {
    public static func safeHTTP(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let u = URL(string: trimmed),
              let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil else {
            return nil
        }
        return trimmed
    }

    public static func cleanText(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    public static func hostLabel(_ raw: String?) -> String {
        guard let raw, let host = URL(string: raw)?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Composer Quote Formatting

public enum ChatQuoteLogic {
    public static let maxLength = 1500

    /// Formats a message excerpt as a blockquote for the composer, optionally addressed to a persona.
    public static func quoteForComposer(_ body: String, mention: String? = nil) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
        let quoted = clipped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        if let mention = mention?.trimmingCharacters(in: .whitespacesAndNewlines), !mention.isEmpty {
            return "@\(mention) \n\n\(quoted)\n\n"
        }
        return "\(quoted)\n\n"
    }

    /// Derives a concise default ticket title from a chat reply body.
    public static func defaultTicketTitle(from body: String, fallback: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
        for line in lines {
            var s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("```") || s.hasPrefix("<!--") { continue }
            while s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("-") || s.hasPrefix("*") {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if !s.isEmpty {
                return s.count > 80 ? String(s.prefix(79)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : s
            }
        }
        return fallback.isEmpty ? "Follow-up from chat" : fallback
    }
}
