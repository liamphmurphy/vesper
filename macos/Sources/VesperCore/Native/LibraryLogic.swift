import Foundation

/// The Library's rules: tabs and navigator, uploads, reference images, tile captions and the
/// Links queue. The Swift port of web/lib/library-ui.ts and the helpers the web Library screen
/// used (lib/files.ts, lib/chat-video.ts, lib/chat-audio.ts, lib/native-shell/models/library.ts).
public enum LibraryLogic {
    // MARK: Source, tabs and the sidebar navigator

    /// "yours": the person's keepsakes from chats; "projects": what agents wrote, shared with the workspace.
    public enum Source: String, Sendable { case yours, projects }

    public static let navigatorId = "library"
    public static let sourcePickerId = "source"
    public static let searchId = "library-search"

    public struct Tab: Sendable, Equatable {
        public let key: String
        public let label: String
        /// The item kind the tab lists; nil for Links and Fridge, which draw their own lists.
        public let kind: API.LibraryItemKind?
    }

    public static let keepsakeTabs: [Tab] = [
        Tab(key: "images", label: "Images", kind: .image),
        Tab(key: "videos", label: "Videos", kind: .video),
        Tab(key: "audio", label: "Audio", kind: .audio),
        Tab(key: "files", label: "Files", kind: .file),
        Tab(key: "exports", label: "Exports", kind: .export),
        Tab(key: "diagrams", label: "Diagrams", kind: .diagram),
        Tab(key: "documents", label: "Documents", kind: .document),
        Tab(key: "links", label: "Links", kind: nil),
        Tab(key: "fridge", label: "Fridge", kind: nil),
    ]

    /// The tab a `?tab=` names; an unknown or missing one is Images.
    public static func tab(_ key: String?) -> Tab {
        keepsakeTabs.first { $0.key == key } ?? keepsakeTabs[0]
    }

    public static func sourceHref(_ source: Source) -> String {
        source == .yours ? "/library" : "/library?source=projects"
    }

    private static func sourcePicker(_ source: Source) -> NavPicker {
        NavPicker(id: sourcePickerId, value: source.rawValue, options: [
            NavPickerOption(value: "yours", label: "Yours"),
            NavPickerOption(value: "projects", label: "From spaces"),
        ])
    }

    public static func keepsakesNavigator(tab: String) -> NavModel {
        NavModel(
            id: navigatorId, title: "Library", picker: sourcePicker(.yours),
            sections: [NavSection(id: "tabs", items: keepsakeTabs.map { NavItem(id: $0.key, title: $0.label) })],
            selectedId: tab)
    }

    /// The artifact types "From spaces" filters by, in the web's order.
    public static let artifactTabs: [(key: String, label: String)] = [
        ("all", "All"), ("prd", "PRDs"), ("spec", "Specs"), ("adr", "ADRs"), ("report", "Agent reports"),
        ("design", "Designs"), ("mockup", "Mockups"), ("note", "Wiki pages"),
    ]

    public static func artifactCount(_ counts: API.ArtifactCounts, _ key: String) -> Int? {
        switch key {
        case "all": counts.all
        case "prd": counts.prd
        case "spec": counts.spec
        case "adr": counts.adr
        case "report": counts.report
        case "design": counts.design
        case "mockup": counts.mockup
        case "note": counts.note
        default: nil
        }
    }

    /// The "From spaces" filters: what each row of the navigator selects, with counts once known.
    public static func projectDocsNavigator(type: String, counts: API.ArtifactCounts?, search: String, projectAction: NavAction) -> NavModel {
        NavModel(
            id: navigatorId, title: "Library", actions: [projectAction], picker: sourcePicker(.projects),
            search: NavSearch(id: searchId, placeholder: "Search titles and contents", value: search),
            sections: [NavSection(id: "types", items: artifactTabs.map { tab in
                NavItem(id: tab.key, title: tab.label, trailing: counts.flatMap { artifactCount($0, tab.key) }.map(String.init))
            })],
            selectedId: type)
    }

    /// `/library?source=projects` with the filters that are set (type "all" and empty values are left out).
    public static func projectDocsHref(type: String?, q: String?, project: String?, id: String?) -> String {
        var items = [URLQueryItem(name: "source", value: "projects")]
        if let type, !type.isEmpty, type != "all" { items.append(URLQueryItem(name: "type", value: type)) }
        if let q, !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let project, !project.isEmpty { items.append(URLQueryItem(name: "project", value: project)) }
        if let id, !id.isEmpty { items.append(URLQueryItem(name: "id", value: id)) }
        var comps = URLComponents()
        comps.queryItems = items
        return "/library?" + (comps.percentEncodedQuery ?? "")
    }

    // MARK: Uploads

    /// The server's Library upload limit.
    public static let uploadMaxBytes = 25 * 1024 * 1024
    public static let uploadImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    /// What the server refuses outright: executables, installers and disk images. It checks the bytes too.
    public static let deniedExtensions = [
        ".exe", ".dll", ".msi", ".scr", ".com", ".pif", ".bat", ".cmd", ".vbs", ".lnk", ".app", ".apk", ".ipa", ".dmg",
        ".iso", ".img", ".vhd", ".vhdx", ".jar",
    ]

    /// Why a picked file can't be uploaded, or nil (web `checkLibraryUpload`).
    public static func checkUpload(name: String, type: String, size: Int) -> String? {
        let lower = name.lowercased()
        if deniedExtensions.contains(where: { lower.hasSuffix($0) }) {
            return "\(name) isn\u{2019}t kept: executables and disk images aren\u{2019}t allowed."
        }
        let pictureExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp"]
        if pictureExtensions.contains(where: { lower.hasSuffix($0) }), !uploadImageTypes.contains(type) {
            return "\(name) isn\u{2019}t a PNG, JPEG, GIF or WebP image."
        }
        if size <= 0 { return "\(name) is empty." }
        if size > uploadMaxBytes { return "\(name) is over 25 MB." }
        return nil
    }

    // MARK: Reference images

    /// The badge for a current reference image: "You" or the persona's name; nil when it isn't one.
    public static func referenceBadge(_ item: API.LibraryItem) -> String? {
        if item.reference == .`self` { return "You" }
        if item.reference == .persona, item.referencePersonaId != nil { return item.referencePersonaName ?? "Persona" }
        return nil
    }

    /// "Your reference" or "Gwen's reference" for the open image; nil when it isn't one.
    public static func referenceCaption(_ item: API.LibraryItem) -> String? {
        guard let who = referenceBadge(item) else { return nil }
        return who == "You" ? "Your reference" : "\(who)'s reference"
    }

    public struct ReferenceChoice: Sendable, Equatable {
        public let key: String
        public let label: String
        public let role: API.LibraryReferenceRole
        public let personaId: String?
    }

    /// The "Use as reference" menu: the person first, then each persona, leaving out what the item
    /// already stands for.
    public static func referenceChoices(_ item: API.LibraryItem, personas: [(id: String, name: String)]) -> [ReferenceChoice] {
        var out: [ReferenceChoice] = []
        if item.reference != .`self` { out.append(ReferenceChoice(key: "self", label: "Use as my reference", role: .`self`, personaId: nil)) }
        for persona in personas {
            if item.reference == .persona, item.referencePersonaId == persona.id { continue }
            out.append(ReferenceChoice(key: "persona:\(persona.id)", label: "Use as \(persona.name)'s reference", role: .persona, personaId: persona.id))
        }
        return out
    }

    // MARK: Tiles

    /// What the item is called in "Remove this … from your Library?".
    public static func noun(_ kind: API.LibraryItemKind) -> String {
        switch kind {
        case .diagram: "diagram"
        case .video: "video"
        case .audio: "audio file"
        case .file: "file"
        case .export: "export"
        case .document: "document"
        case .link: "link"
        default: "image"
        }
    }

    /// The confirmation's explanation: a persona's item stays in its chat.
    public static func removeExplanation(_ item: API.LibraryItem) -> String? {
        item.source == .upload ? nil : "It stays in its chat while that chat exists."
    }

    /// The server's per-request cap for `POST /library/bulk-delete`.
    public static let bulkDeleteLimit = 500

    /// Splits IDs into unique, non-empty batches within the bulk-delete request cap.
    public static func bulkDeleteBatches(_ ids: [String], maxBatchSize: Int = bulkDeleteLimit) -> [[String]] {
        let limit = max(1, maxBatchSize)
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        return stride(from: 0, to: unique.count, by: limit).map { start in
            Array(unique[start..<min(start + limit, unique.count)])
        }
    }

    /// Confirmation copy for removing one or more Library items.
    public static func removeConfirmation(_ items: [API.LibraryItem]) -> (title: String, body: String?)? {
        guard let first = items.first else { return nil }
        if items.count == 1 {
            return ("Remove this \(noun(first.kind)) from your Library?", removeExplanation(first))
        }
        let body = items.contains { $0.source != .upload }
            ? "Items from chats stay in their chats while those chats exist."
            : nil
        return ("Remove \(items.count) items from your Library?", body)
    }

    /// Confirmation copy for deleting one or more Fridge moments.
    public static func deleteMomentsConfirmation(count: Int) -> (title: String, body: String)? {
        guard count > 0 else { return nil }
        if count == 1 {
            return ("Delete this moment?", "Its persona will no longer remember it.")
        }
        return ("Delete \(count) moments?", "Their personas will no longer remember them.")
    }

    /// "PY", "ZIP", "CSV": a file's type as the badge on its tile.
    public static func typeBadge(_ filename: String) -> String {
        let ext = filename.contains(".") ? String(filename.split(separator: ".", omittingEmptySubsequences: false).last ?? "") : ""
        return String((ext.isEmpty ? "FILE" : ext).prefix(4)).uppercased()
    }

    /// The one line under a file's name: "112 lines · 4 KB".
    public static func fileMeta(_ item: API.LibraryItem) -> String {
        [item.detail ?? "", formatBytes(item.sizeBytes)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The dialog's caption: "photo.png · 1.2 MB · 0:42 · Oct 30 · Your reference".
    public static func detailCaption(_ item: API.LibraryItem, now: Date = Date()) -> String {
        var parts = ["\(item.filename) · \(formatBytes(item.sizeBytes))"]
        if let ms = item.durationMs, ms > 0 { parts.append(clock(ms)) }
        parts.append(APIDate.timeline(item.createdAt, now: now))
        if let caption = referenceCaption(item) { parts.append(caption) }
        return parts.joined(separator: " · ")
    }

    /// The empty state under each kind's tab.
    public static func emptyText(_ kind: API.LibraryItemKind) -> String {
        switch kind {
        case .document: "Workflows with an Add to library step save their results here."
        case .video: "When a persona that can code renders a video in a chat, it\u{2019}s added here once it\u{2019}s finished."
        case .file: "No files yet. When a persona that can code hands you a file (a script, a zip, a spreadsheet), it\u{2019}s kept here. You can also upload one."
        case .export: "No exports yet. Export a deck, design or document and choose Save to Library to keep the copy here."
        case .audio: "When a persona that can code renders audio in a chat, it\u{2019}s added here once it\u{2019}s finished. You can also upload an MP3, WAV, OGG or M4A file, like a voice memo."
        case .diagram: "When a persona draws an SVG diagram in a chat, choose Save to Library on it to keep it here."
        default: "When a persona that can generate images makes one in a chat, it\u{2019}s added here. You can also upload your own, like a photo of yourself to use as your reference."
        }
    }

    /// Where an export's app lives, to link back to its source.
    public static func exportApp(_ kind: API.LibraryExportSource.Kind) -> (label: String, href: String) {
        switch kind.rawValue {
        case "slides": ("Slides", "/apps/slides")
        case "designs": ("Designs", "/apps/designs")
        default: ("Docs", "/apps/docs")
        }
    }

    /// "edited since", "source deleted" or "up to date".
    public static func exportSourceNote(_ status: API.LibraryExportSource.Status) -> String {
        switch status.rawValue {
        case "changed": "edited since"
        case "deleted": "source deleted"
        default: "up to date"
        }
    }

    public static func isPDF(_ contentType: String?) -> Bool {
        (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == "application/pdf"
    }

    /// The item's content and its download, as API paths.
    public static func contentPath(_ id: String, download: Bool = false) -> String {
        "/api/v1/library/\(id)/content" + (download ? "?download=true" : "")
    }

    public static func posterPath(_ id: String) -> String { "/api/v1/library/\(id)/poster" }

    // MARK: Formatting

    /// "512 B", "17 KB", "1.2 MB" (web lib/files.ts `formatBytes`).
    public static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    /// "0:42", "12:05", "1:02:03" (web lib/chat-video.ts `clock`).
    public static func clock(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60
        let ss = String(format: "%02d", s % 60)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
    }

    /// "MP3", "WAV": the file's extension, else its MIME subtype (web lib/chat-audio.ts `audioFormat`).
    public static func audioFormat(contentType: String, filename: String) -> String {
        let ext = filename.split(separator: ".", omittingEmptySubsequences: false).last.map { String($0).uppercased() }
        if let ext, filename.contains("."), ext.count <= 4 { return ext }
        return (contentType.hasPrefix("audio/") ? String(contentType.dropFirst(6)) : contentType).uppercased()
    }

    /// The bars a waveform draws, 0.08…1: the server's peaks resampled to `count`, or a flat line for a
    /// format it can't decode (web lib/chat-audio.ts `waveBars`).
    public static func waveBars(_ peaks: [Int]?, count: Int = 64) -> [Double] {
        guard let peaks, !peaks.isEmpty, count > 0 else { return Array(repeating: 0.08, count: max(0, count)) }
        return (0..<count).map { i in
            let from = i * peaks.count / count
            let to = max(from + 1, (i + 1) * peaks.count / count)
            let top = peaks[from..<min(to, peaks.count)].max() ?? 0
            return max(0.08, Double(top) / 255)
        }
    }

    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    /// The next playback speed after `rate`, wrapping around.
    public static func nextSpeed(_ rate: Double) -> Double {
        let i = speeds.firstIndex(of: rate) ?? -1
        return speeds[(i + 1) % speeds.count]
    }

    // MARK: Links

    public enum LinkQueue: String, Sendable, CaseIterable { case toRead = "to_read", done }
    public enum LinkFilter: String, Sendable, CaseIterable { case all, video, page }

    public static func isDone(_ item: API.LibraryItem) -> Bool { item.linkStatus == .done }

    /// The links one queue shows, filtered to videos or pages.
    public static func links(_ items: [API.LibraryItem], queue: LinkQueue, filter: LinkFilter) -> [API.LibraryItem] {
        items.filter { item in
            (queue == .done) == isDone(item) && (filter == .all || (filter == .video) == (item.videoId != nil))
        }
    }

    public static func linkCount(_ items: [API.LibraryItem], queue: LinkQueue) -> Int {
        items.filter { (queue == .done) == isDone($0) }.count
    }

    /// A saved summary as it reads on the card: without its trailing "Sources:" list (a heading whose
    /// following lines all carry a link) or the [1]-style markers pointing into it (web `summaryText`,
    /// for the common shape of that list).
    public static func summaryText(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let heading = #"^\s*(?:#{1,6}\s+)?[*_]*(?:web\s+)?(?:sources?|references?|links?|urls?)(?:\s+(?:i\s+)?(?:used|consulted))?[*_]*\s*:?\s*[*_]*\s*$"#
        if let start = lines.lastIndex(where: { $0.range(of: heading, options: [.regularExpression, .caseInsensitive]) != nil }) {
            let rest = lines[(start + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let body = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty, rest.allSatisfy({ $0.contains("http://") || $0.contains("https://") || $0.contains("[[") }), !body.isEmpty {
                lines = Array(lines[..<start])
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.range(of: #"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil {
                    lines.removeLast()
                }
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #" ?\[\d{1,2}\](?![(:])"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "youtube.com" from a URL, without "www." (web lib/web-search.ts `hostOf`).
    public static func host(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Artifacts ("From spaces")

    /// "ADR-012 · Postgres partitioning" for numbered types (web `artifactTitle`).
    public static func artifactTitle(title: String, displayId: String?) -> String {
        if let displayId, !displayId.isEmpty { return "\(displayId) · \(title)" }
        return title
    }

    /// "PDF", "PNG" from a content type or filename (web lib/files.ts `fileKind`).
    public static func fileKind(contentType: String, filename: String?) -> String {
        if let filename, filename.contains("."), let ext = filename.split(separator: ".", omittingEmptySubsequences: false).last, !ext.isEmpty {
            return ext.uppercased()
        }
        let subtype = contentType.split(separator: "/").dropFirst().first.map(String.init) ?? "file"
        return String(subtype.split(whereSeparator: { $0 == "+" || $0 == ";" }).first ?? "file").uppercased()
    }

    /// A list row's second line: "v3 · 9 sections", "Generated · 5 sections", "PNG · 17 KB" (web `artifactMeta`).
    public static func artifactMeta(_ a: API.ArtifactSummary) -> String {
        let c = a.content
        let what = c.kind.rawValue == "file"
            ? "\(fileKind(contentType: c.contentType, filename: c.filename)) · \(formatBytes(c.sizeBytes))"
            : "\(c.sections) \(c.sections == 1 ? "section" : "sections")"
        let version = a.type == .report && a.author.type.rawValue == "agent" ? "Generated" : a.versionLabel
        return [version ?? "", what].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The outline sections a preview lists: H2s when the doc has a single H1 title, else the top level.
    public static func visibleOutline(_ outline: [API.OutlineSection]) -> [API.OutlineSection] {
        let h1s = outline.filter { $0.level == 1 }.count
        let level = h1s <= 1 && outline.contains { $0.level == 2 } ? 2 : 1
        return outline.filter { $0.level == level }
    }

    /// The types an artifact can be uploaded as, with their labels.
    public static let uploadTypes: [(type: API.ArtifactType, label: String)] = [
        (.prd, "PRD"), (.spec, "Spec"), (.adr, "ADR"), (.report, "Report"), (.design, "Design"), (.mockup, "Mockup (.svg)"),
    ]

    /// The best guess of an artifact's type from its filename; people can change it before uploading.
    public static func guessType(name: String, mime: String) -> API.ArtifactType {
        let n = name.lowercased()
        func has(_ pattern: String) -> Bool { n.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\bprd\b|requirements"#) { return .prd }
        if has(#"\badr\b|decision"#) { return .adr }
        if has("report|summary|analysis") { return .report }
        if mime.hasPrefix("image/") || has(#"\.(fig|sketch|pdf)$"#) { return .design }
        return .spec
    }

    public static func isSVGFile(name: String, mime: String) -> Bool {
        mime == "image/svg+xml" || name.lowercased().hasSuffix(".svg")
    }

    /// A new mockup's starting SVG: a 1280×800 wireframe titled `title` (web lib/mockup.ts `blankWireframe`).
    public static func blankWireframe(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = escapeXML(trimmed.isEmpty ? "Untitled mockup" : trimmed)
        func bar(_ x: Int, _ y: Int, _ w: Int) -> String {
            "    <rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"12\" rx=\"6\" fill=\"#D9DCE3\"/>"
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1280" height="800" viewBox="0 0 1280 800" font-family="Inter, Helvetica, Arial, sans-serif">
          <rect width="1280" height="800" fill="#F6F7F9"/>
          <!-- Header -->
          <rect width="1280" height="64" fill="#FFFFFF"/>
          <line x1="0" y1="64" x2="1280" y2="64" stroke="#D9DCE3"/>
          <text x="24" y="40" font-size="20" font-weight="600" fill="#1F2430">\(t)</text>
          <rect x="1124" y="18" width="132" height="28" rx="6" fill="#4547C9"/>
          <!-- Sidebar -->
          <rect y="65" width="240" height="735" fill="#FFFFFF"/>
          <line x1="240" y1="65" x2="240" y2="800" stroke="#D9DCE3"/>
          <g>
        \(bar(24, 96, 140))
        \(bar(24, 132, 110))
        \(bar(24, 168, 150))
        \(bar(24, 204, 100))
          </g>
          <!-- Content -->
          <rect x="272" y="96" width="420" height="28" rx="6" fill="#C5C9D3"/>
          <rect x="272" y="156" width="480" height="180" rx="12" fill="#FFFFFF" stroke="#D9DCE3"/>
          <rect x="776" y="156" width="480" height="180" rx="12" fill="#FFFFFF" stroke="#D9DCE3"/>
          <rect x="272" y="360" width="984" height="400" rx="12" fill="#FFFFFF" stroke="#D9DCE3"/>
          <g>
        \(bar(296, 392, 360))
        \(bar(296, 432, 520))
        \(bar(296, 472, 440))
          </g>
        </svg>

        """
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
