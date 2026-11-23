import Foundation

/// Pure logic for the native Chat Code Review inspector (`chat.code`), matching `web/lib/code-review.ts`.
public enum ChatCodeReviewLogic {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case branch
        case turn

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .branch: "Branch"
            case .turn: "Last turn"
            }
        }
    }

    public enum CommentSide: String, Sendable, Equatable, Hashable {
        case new
        case old
    }

    public struct LineComment: Sendable, Equatable, Identifiable {
        public let path: String
        public let line: Int
        public let side: CommentSide
        public let code: String
        public var body: String

        public var id: String { "\(side.rawValue):\(path):\(line)" }

        public init(path: String, line: Int, side: CommentSide, code: String, body: String) {
            self.path = path
            self.line = line
            self.side = side
            self.code = code
            self.body = body
        }
    }

    public struct FileGroup: Sendable, Equatable, Identifiable {
        public let dir: String
        public let files: [API.ChatCodeChange]
        public var id: String { dir }
    }

    public static func commentKey(path: String, line: Int, side: CommentSide) -> String {
        "\(side.rawValue):\(path):\(line)"
    }

    public static func repoName(_ url: String) -> String {
        var out = url
        if out.hasPrefix("https://github.com/") {
            out = String(out.dropFirst("https://github.com/".count))
        } else if out.hasPrefix("git@github.com:") {
            out = String(out.dropFirst("git@github.com:".count))
        }
        if out.hasSuffix(".git") {
            out = String(out.dropLast(4))
        }
        return out
    }

    public static func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    public static func totals(for files: [API.ChatCodeChange]) -> (additions: Int, deletions: Int) {
        files.reduce(into: (0, 0)) { acc, file in
            acc.0 += file.additions
            acc.1 += file.deletions
        }
    }

    public static func groupedFiles(_ files: [API.ChatCodeChange]) -> [FileGroup] {
        var byDir: [String: [API.ChatCodeChange]] = [:]
        for file in files {
            let dir: String
            if let slash = file.path.lastIndex(of: "/") {
                dir = String(file.path[..<slash])
            } else {
                dir = ""
            }
            byDir[dir, default: []].append(file)
        }
        return byDir.keys.sorted().map { dir in
            FileGroup(dir: dir, files: (byDir[dir] ?? []).sorted { $0.path < $1.path })
        }
    }

    /// Formats pending line comments into a single review message anchored to `file:line`,
    /// matching `web/lib/code-review.ts:reviewMessage`.
    public static func reviewMessage(comments: [LineComment], branch: String?) -> String {
        let kept = comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty else { return "" }
        let sorted = kept.sorted { a, b in
            if a.path != b.path { return a.path < b.path }
            return a.line < b.line
        }
        let parts: [String] = sorted.map { c in
            let whereStr = "`\(c.path):\(c.line)`\(c.side == .old ? " (removed line)" : "")"
            let trimmedCode = c.code.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = trimmedCode.isEmpty ? "" : "\n  > \(String(trimmedCode.prefix(200)))"
            let indentedBody = c.body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "\n  ")
            return "- \(whereStr)\(quote)\n  \(indentedBody)"
        }
        let n = kept.count
        let subject = branch.map { !($0.isEmpty) ? "`\($0)`" : "your changes" } ?? "your changes"
        return "Review of \(subject) (\(n) \(n == 1 ? "comment" : "comments")). Please address each:\n\n\(parts.joined(separator: "\n"))"
    }

    public static func lastTurnChanges(
        messages: [API.ChatMessage],
        review: API.CodeReview?,
        primaryRepo: String?
    ) -> [API.ChatCodeChange] {
        guard let last = messages.last(where: { $0.role == .assistant && !($0.codeChanges ?? []).isEmpty }),
              let changes = last.codeChanges else {
            return []
        }
        guard let review else { return changes }
        return changes.filter { change in
            if let repo = change.repository, !repo.isEmpty {
                return repo == review.repository
            }
            return review.repository == primaryRepo
        }
    }

    public static func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            let s = String(format: "%.1f", kb)
            return "\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s) KB"
        }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}
