import Foundation
import JavaScriptCore

/// One highlighted token with Shiki's colours for the light and dark themes ("#RRGGBB").
public struct CodeToken: Sendable, Equatable {
    public var content: String
    public var light: String?
    public var dark: String?

    public init(content: String, light: String?, dark: String?) {
        self.content = content
        self.light = light
        self.dark = dark
    }
}

/// Shiki, as the web runs it (web/lib/highlight.ts: the JavaScript regex engine, github-light and
/// github-dark, the same languages), in JavaScriptCore off the main thread. The script is
/// `Resources/shiki/shiki.js`, built by `macos/scripts/build-shiki-bundle.mjs`.
public actor CodeHighlighter {
    public static let shared = CodeHighlighter()

    private let scriptURL: URL?
    private var context: JSContext?
    /// Why highlighting is off (the script is missing or threw), once a load has failed.
    public private(set) var loadError: String?
    private var cache: [Key: [[CodeToken]]] = [:]
    private var cacheOrder: [Key] = []
    private static let cacheLimit = 200

    private struct Key: Hashable {
        var code: String
        var language: String
    }

    public init(scriptURL: URL? = CodeHighlighter.bundledScript()) {
        self.scriptURL = scriptURL
    }

    /// Tokens for each line of `code` (lines split on "\n", highlighted as one snippet so
    /// multi-line strings and comments work), or nil for a language the web doesn't highlight or
    /// when the script can't run. Results are cached per (code, language); both themes' colours
    /// come back at once, so the mode needs no key.
    public func highlight(_ code: String, language: String) -> [[CodeToken]]? {
        let key = Key(code: code, language: language)
        if let hit = cache[key] { return hit }
        guard let context = loadedContext(),
              let api = context.objectForKeyedSubscript("VesperShiki"),
              let json = api.invokeMethod("highlight", withArguments: [code, language])?.toString(),
              let data = json.data(using: .utf8),
              let lines = try? JSONSerialization.jsonObject(with: data) as? [[[Any]]]
        else { return nil }
        let lineCount = code.components(separatedBy: "\n").count
        var tokens = lines.map { line in
            line.map { t in CodeToken(content: t.first as? String ?? "", light: t.count > 1 ? t[1] as? String : nil, dark: t.count > 2 ? t[2] as? String : nil) }
        }
        // lib/highlight.ts gives every input line an array, even when Shiki returned fewer.
        if tokens.count < lineCount { tokens += Array(repeating: [], count: lineCount - tokens.count) }
        remember(key, tokens)
        return tokens
    }

    /// The languages the bundle highlights (Shiki ids, as `MarkdownSource.language(fromFence:)` returns).
    public func languages() -> [String] {
        loadedContext()?.objectForKeyedSubscript("VesperShiki")?.objectForKeyedSubscript("languages")?.toArray()?.compactMap { $0 as? String } ?? []
    }

    private func remember(_ key: Key, _ tokens: [[CodeToken]]) {
        cache[key] = tokens
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Loads the script on first use (about a quarter of a second); a failure leaves code plain
    /// (`loadError` says why) rather than retrying for every block.
    private func loadedContext() -> JSContext? {
        if let context { return context }
        if loadError != nil { return nil }
        guard let scriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8), let context = JSContext() else {
            loadError = "Shiki bundle missing (\(scriptURL?.path ?? "not found"))"
            return nil
        }
        context.evaluateScript(source, withSourceURL: scriptURL)
        guard context.exception == nil, context.objectForKeyedSubscript("VesperShiki")?.isObject == true else {
            loadError = context.exception?.toString() ?? "VesperShiki missing"
            return nil
        }
        self.context = context
        return context
    }

    /// `Resources/shiki/shiki.js` in VesperCore's resource bundle, wherever it is: the app's
    /// Contents/Resources (scripts/build-app.sh copies it there) or next to the executable or test
    /// bundle in a SwiftPM build. Not `Bundle.module`, whose accessor traps when the bundle is
    /// missing instead of returning nil.
    public static func bundledScript() -> URL? {
        let name = "Vesper_VesperCore.bundle"
        var dirs: [URL] = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        // Tests: the .xctest bundle sits next to the resource bundle in the build directory.
        dirs += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for dir in dirs {
            let bundleURL = dir.appendingPathComponent(name)
            if let bundle = Bundle(url: bundleURL), let url = bundle.url(forResource: "shiki", withExtension: "js", subdirectory: "shiki") { return url }
            // A bundle without Info.plist (SwiftPM on some versions) still holds the file.
            let flat = bundleURL.appendingPathComponent("shiki/shiki.js")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }
}

/// The palette colours code tokens are drawn in: the page's chart colours (`--viz-*`), as
/// `useVizPalette` reads them, with lib/chat-svg.ts's defaults.
public struct CodePalette: Sendable, Equatable {
    public var ink: String
    public var muted: String
    /// `--viz-1` … `--viz-8`.
    public var series: [String]

    public init(ink: String, muted: String, series: [String]) {
        self.ink = ink
        self.muted = muted
        self.series = series
    }

    /// lib/chat-svg.ts `VIZ_LIGHT` / `VIZ_DARK`.
    public static let light = CodePalette(ink: "#17151F", muted: "#55526A", series: ["#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300", "#6250D6", "#E34948"])
    public static let dark = CodePalette(ink: "#EEEDF3", muted: "#A4A1B3", series: ["#3987E5", "#D95926", "#199E70", "#C98500", "#D55181", "#008300", "#9085E9", "#E66767"])

    /// The page's palette from its tokens, falling back per colour to the mode's defaults.
    public init(theme: ThemeTokens) {
        let fallback = theme.mode == .dark ? CodePalette.dark : CodePalette.light
        let pick = { (name: String, value: String) in theme.colors["viz-\(name)"].flatMap { RGBA(hex: $0) != nil ? $0 : nil } ?? value }
        self.init(
            ink: pick("ink", fallback.ink),
            muted: pick("muted", fallback.muted),
            series: fallback.series.enumerated().map { pick(String($0.offset + 1), $0.element) }
        )
    }

    /// web/lib/code-colors.ts `tokenColor`: Shiki's colour re-hued onto the palette, greys to ink or muted.
    public func color(for source: String?) -> String {
        guard let source, source.count == 7, let rgba = RGBA(hex: source) else { return ink }
        let (h, s, l) = Self.hsl(rgba)
        if s < 0.2 { return l < 0.65 ? muted : ink }
        let slot = h < 15 || h >= 345 ? 7 : h < 45 ? 1 : h < 75 ? 3 : h < 160 ? 2 : h < 195 ? 5 : h < 255 ? 0 : h < 290 ? 6 : 4
        return series[slot]
    }

    /// lib/persona-ui.ts `hexToHsl`.
    static func hsl(_ c: RGBA) -> (h: Double, s: Double, l: Double) {
        let maxC = max(c.red, c.green, c.blue)
        let minC = min(c.red, c.green, c.blue)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        if d == 0 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == c.red { h = ((c.green - c.blue) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == c.green { h = (c.blue - c.red) / d + 2 }
        else { h = (c.red - c.green) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }
}
