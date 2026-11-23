import Foundation

/// Pure geometry, routing and file-classification rules for `/artifacts/:id` and
/// `/artifacts/:id/review` (port of `web/lib/mockup-review.ts` and `artifact-screen.tsx`).
public enum ArtifactDetailLogic {
    public enum MockupZoomMode: String, Sendable, CaseIterable, Equatable {
        case fit
        case actual = "100"
        case double = "200"

        public var label: String {
            switch self {
            case .fit: "Fit"
            case .actual: "100%"
            case .double: "200%"
            }
        }
    }

    public enum MockupReviewMode: String, Sendable, CaseIterable, Equatable {
        case single
        case side
        case swipe

        public var label: String {
            switch self {
            case .single: "Single"
            case .side: "Side by side"
            case .swipe: "Swipe"
            }
        }
    }

    public enum MockupReviewTool: String, Sendable, Equatable {
        case pan
        case pin
    }

    public struct MockupSize: Sendable, Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct MockupCamera: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var scale: Double

        public init(x: Double, y: Double, scale: Double) {
            self.x = x
            self.y = y
            self.scale = scale
        }
    }

    public struct MockupFraction: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public static let minScale: Double = 0.05
    public static let maxScale: Double = 8.0
    public static let fitPad: Double = 32.0
    public static let zoomStep: Double = 1.25
    public static let panStep: Double = 48.0
    public static let defaultSize = MockupSize(width: 1280, height: 800)

    /// Wiki pages live at `/wiki/<path>`; `/artifacts/:id` still renders them when `?versions=1`.
    public static func wikiRedirectPath(type: API.ArtifactType, path: String?, showVersions: Bool) -> String? {
        guard type == .note, let path, !path.isEmpty, !showVersions else { return nil }
        let encoded = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "/wiki/\(encoded)"
    }

    public static func contentPath(artifactId: String, versionId: String, download: Bool = false) -> String {
        let base = "/api/v1/artifacts/\(APIPath.escape(artifactId))/versions/\(APIPath.escape(versionId))/content"
        return download ? "\(base)?download=1" : base
    }

    public static func isImage(contentType: String) -> Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    public static func isInlineVideo(contentType: String) -> Bool {
        contentType.lowercased() == "video/mp4"
    }

    public static func isPDF(contentType: String, filename: String? = nil) -> Bool {
        let lower = contentType.lowercased()
        if lower == "application/pdf" || lower.hasPrefix("application/pdf;") { return true }
        if let filename, filename.lowercased().hasSuffix(".pdf") { return true }
        return false
    }

    /// Picks the default comparison version: chosen if valid, else the version just before `primary`,
    /// else the newest other version.
    public static func compareVersion(
        primary: API.ArtifactVersion,
        versions: [API.ArtifactVersion],
        chosenId: String?
    ) -> API.ArtifactVersion? {
        let others = versions.filter { $0.id != primary.id }
        guard !others.isEmpty else { return nil }
        if let chosenId, let match = others.first(where: { $0.id == chosenId }) {
            return match
        }
        return others.first(where: { $0.seq < primary.seq }) ?? others.first
    }

    // MARK: Mockup SVG geometry

    /// Extracts intrinsic dimensions from root `<svg>` width/height or `viewBox`, falling back to 1280×800.
    public static func svgSize(_ source: String) -> MockupSize {
        guard let tagRange = source.range(of: #"<svg\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else {
            return defaultSize
        }
        let tag = String(source[tagRange])

        func attr(_ name: String) -> String? {
            let pattern = #"\s"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
                return nil
            }
            for idx in 1...2 {
                if let r = Range(match.range(at: idx), in: tag) {
                    return String(tag[r])
                }
            }
            return nil
        }

        func length(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: #"^\d+(?:\.\d+)?(?:\s*px)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return nil
            }
            let numStr = trimmed.lowercased().replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)
            guard let val = Double(numStr), val > 0, val.isFinite else { return nil }
            return val
        }

        var vbSize: MockupSize?
        if let vb = attr("viewBox") {
            let nums = vb
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .compactMap { Double($0) }
            if nums.count == 4, nums.allSatisfy(\.isFinite), nums[2] > 0, nums[3] > 0 {
                vbSize = MockupSize(width: nums[2], height: nums[3])
            }
        }

        let w = length(attr("width"))
        let h = length(attr("height"))
        switch (w, h) {
        case let (.some(width), .some(height)):
            return MockupSize(width: width, height: height)
        case let (.some(width), .none):
            let height = vbSize.map { width * $0.height / $0.width } ?? defaultSize.height
            return MockupSize(width: width, height: height)
        case let (.none, .some(height)):
            let width = vbSize.map { height * $0.width / $0.height } ?? defaultSize.width
            return MockupSize(width: width, height: height)
        case (.none, .none):
            return vbSize ?? defaultSize
        }
    }

    public static func clampScale(_ scale: Double) -> Double {
        min(maxScale, max(minScale, scale))
    }

    public static func fitView(drawing: MockupSize, viewport: MockupSize, pad: Double = fitPad) -> MockupCamera {
        guard drawing.width > 0, drawing.height > 0, viewport.width > 0, viewport.height > 0 else {
            return MockupCamera(x: 0, y: 0, scale: 1)
        }
        let scale = clampScale(min((viewport.width - 2 * pad) / drawing.width, (viewport.height - 2 * pad) / drawing.height))
        return MockupCamera(
            x: (viewport.width - drawing.width * scale) / 2,
            y: (viewport.height - drawing.height * scale) / 2,
            scale: scale
        )
    }

    public static func actualView(drawing: MockupSize, viewport: MockupSize, pad: Double = fitPad) -> MockupCamera {
        func axis(_ d: Double, _ v: Double) -> Double {
            d <= v - 2 * pad ? (v - d) / 2 : pad
        }
        return MockupCamera(x: axis(drawing.width, viewport.width), y: axis(drawing.height, viewport.height), scale: 1)
    }

    public static func zoomAt(_ camera: MockupCamera, factor: Double, px: Double, py: Double) -> MockupCamera {
        let scale = clampScale(camera.scale * factor)
        let k = scale / camera.scale
        return MockupCamera(
            x: px - (px - camera.x) * k,
            y: py - (py - camera.y) * k,
            scale: scale
        )
    }

    public static func panBy(_ camera: MockupCamera, dx: Double, dy: Double) -> MockupCamera {
        MockupCamera(x: camera.x + dx, y: camera.y + dy, scale: camera.scale)
    }

    public static func toFraction(camera: MockupCamera, drawing: MockupSize, px: Double, py: Double) -> MockupFraction? {
        guard drawing.width > 0, drawing.height > 0, camera.scale > 0 else { return nil }
        let x = (px - camera.x) / (drawing.width * camera.scale)
        let y = (py - camera.y) / (drawing.height * camera.scale)
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return MockupFraction(x: x, y: y)
    }

    public static func fromFraction(camera: MockupCamera, drawing: MockupSize, fraction: MockupFraction) -> (x: Double, y: Double) {
        (
            x: camera.x + fraction.x * drawing.width * camera.scale,
            y: camera.y + fraction.y * drawing.height * camera.scale
        )
    }

    public static func round4(_ n: Double) -> Double {
        (n * 10_000).rounded() / 10_000
    }

    // MARK: - Sidebar NavModel

    public static let navId = "artifact-detail"
    public static let backToLibraryAction = "back-library"
    public static let versionPrefix = "ver:"
    public static let linkPrefix = "link:"

    public static func navModel(
        artifact: API.Artifact?,
        selectedVersionId: String?,
        backlinks: API.Backlinks? = nil
    ) -> NavModel {
        let title = artifact.map { LibraryLogic.artifactTitle(title: $0.title, displayId: $0.displayId) } ?? "Artifact"
        var sections: [NavSection] = []

        if let artifact {
            let versions = artifact.versions.sorted { $0.seq > $1.seq }
            let versionItems = versions.map { v -> NavItem in
                let tone: Tone? = v.review.map { rev in
                    switch rev.state {
                    case .approved: .done
                    case .changesRequested: .human
                    default: .neutral
                    }
                }
                return NavItem(
                    id: "\(versionPrefix)\(v.id)",
                    title: v.label.isEmpty ? "v\(v.seq)" : v.label,
                    subtitle: v.note.isEmpty ? nil : v.note,
                    status: tone,
                    trailing: v.id == artifact.currentVersion.id ? "Current" : nil
                )
            }
            sections.append(NavSection(
                id: "versions",
                title: "Versions",
                items: versionItems,
                badge: versionItems.isEmpty ? nil : NavBadge(text: "\(versionItems.count)"),
                emptyText: "No versions."
            ))

            let linked = (backlinks?.linked ?? []).compactMap { mention -> NavItem? in
                guard let href = mention.source.href, !href.isEmpty else { return nil }
                return NavItem(
                    id: "\(linkPrefix)\(href)",
                    title: mention.source.title,
                    subtitle: mention.source.displayId,
                    icon: "link",
                    href: href
                )
            }
            if !linked.isEmpty {
                sections.append(NavSection(
                    id: "backlinks",
                    title: "Referenced by",
                    items: linked,
                    badge: NavBadge(text: "\(linked.count)")
                ))
            }
        } else {
            sections.append(NavSection(id: "loading", items: [], emptyText: "Loading\u{2026}"))
        }

        let activeVerId = selectedVersionId ?? artifact?.currentVersion.id
        return NavModel(
            id: navId,
            title: title,
            actions: [NavAction(id: backToLibraryAction, label: "Back to Library", icon: "chevl")],
            sections: sections,
            selectedId: activeVerId.map { "\(versionPrefix)\($0)" }
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case backToLibrary
        case selectVersion(String)
        case openLink(String, newTab: Bool)
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, backToLibraryAction, _, _):
            return .backToLibrary
        case .navActivate(navId, let itemId, let newTab):
            if itemId.hasPrefix(versionPrefix) {
                return .selectVersion(String(itemId.dropFirst(versionPrefix.count)))
            }
            if itemId.hasPrefix(linkPrefix) {
                return .openLink(String(itemId.dropFirst(linkPrefix.count)), newTab: newTab)
            }
            return nil
        default:
            return nil
        }
    }
}
