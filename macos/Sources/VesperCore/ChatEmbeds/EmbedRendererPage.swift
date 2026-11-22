import Foundation

/// The page the native chat's off-screen renderer loads to draw embeds once: KaTeX for math, mermaid
/// for diagrams (added on first use), and `<img>` for SVG. Everything it runs is bundled
/// (`Resources/embeds`, built by macos/scripts/build-embeds-bundle.mjs); its CSP lets it load nothing
/// from the network. Agent text reaches it only as JSON arguments, never spliced into script.
public enum EmbedRendererPage {
    /// Nothing remote: fonts and images only from `data:`, no connections, frames, forms or plugins.
    /// Scripts are inline (the page's glue and KaTeX) or evaluated by the shell (mermaid).
    public static let csp = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval'",
        "style-src 'unsafe-inline'",
        "font-src data:",
        "img-src data:",
        "connect-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    /// `MAX_SOURCE` in mermaid-fence.tsx: a longer fence stays code.
    public static let mermaidMaxSource = 20_000

    /// The page, with KaTeX's script and stylesheet inline. nil when the bundle is missing.
    public static func html(resources: URL? = bundledDirectory()) -> String? {
        guard let resources,
              let katexJS = try? String(contentsOf: resources.appendingPathComponent("katex.js"), encoding: .utf8),
              let katexCSS = try? String(contentsOf: resources.appendingPathComponent("katex.css"), encoding: .utf8)
        else { return nil }
        // "</" can't end the inline elements early: the bundled files never contain "</script" or
        // "</style", and the build would have to change for them to.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>\(katexCSS)</style>
        <style>
        html,body{margin:0;padding:0;background:transparent}
        #stage{position:absolute;left:0;top:0;display:inline-block}
        #stage img{display:block}
        #stage .katex-display{margin:0}
        #stage .katex{white-space:nowrap}
        #measure{position:absolute;left:-10000px;top:0}
        </style>
        <script>\(katexJS)</script>
        <script>\(glue)</script>
        </head><body><div id="stage"></div><div id="measure"></div></body></html>
        """
    }

    /// The bundled mermaid script, evaluated into the page the first time a diagram needs it.
    public static func mermaidScript(resources: URL? = bundledDirectory()) -> String? {
        guard let resources else { return nil }
        return try? String(contentsOf: resources.appendingPathComponent("mermaid.js"), encoding: .utf8)
    }

    /// The page's API, called with `callAsyncJavaScript` and JSON arguments. Each returns the stage's
    /// size in CSS pixels (and math's ascent) once it's laid out, or `{error}`.
    static let glue = #"""
    window.VesperEmbeds = (() => {
      const stage = () => document.getElementById("stage");
      const size = (el) => { const r = el.getBoundingClientRect(); return { width: Math.ceil(r.width), height: Math.ceil(r.height) }; };
      const ready = () => (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
      return {
        async math(tex, display, color, fontSize, background) {
          const s = stage();
          document.body.style.background = background || "transparent";
          s.style.color = color;
          s.style.fontSize = fontSize + "px";
          s.style.padding = "0";
          try {
            katex.render(tex, s, { displayMode: display, throwOnError: true, trust: false, strict: "ignore", maxSize: 50, maxExpand: 1000, output: "html" });
          } catch (e) {
            s.textContent = "";
            return { error: String(e && e.message || e) };
          }
          // A zero-size box on the baseline gives the ascent for setting the image inline.
          const mark = document.createElement("span");
          mark.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline";
          (s.querySelector(".katex") || s).appendChild(mark);
          await ready();
          const out = size(s);
          out.ascent = mark.getBoundingClientRect().top - s.getBoundingClientRect().top;
          mark.remove();
          return out;
        },
        async svg(url, width, height, background) {
          const s = stage();
          document.body.style.background = background || "transparent";
          s.style.color = "";
          s.style.padding = "0";
          s.textContent = "";
          const img = new Image();
          img.width = width;
          img.height = height;
          img.src = url;
          try { await img.decode(); } catch (e) { return { error: "This SVG couldn't be displayed." }; }
          s.appendChild(img);
          return size(s);
        },
        async mermaid(code, config, id) {
          if (!window.mermaid) return { error: "mermaid isn't loaded" };
          const m = window.mermaid;
          try {
            m.initialize(JSON.parse(config));
            const { svg } = await m.render(id, code, document.getElementById("measure"));
            return { svg };
          } catch (e) {
            document.getElementById("measure").textContent = "";
            return { error: String(e && e.message || e) };
          }
        },
        clear() { stage().textContent = ""; document.getElementById("measure").textContent = ""; },
      };
    })();
    """#

    /// mermaid's configuration for a palette: mermaid-fence.tsx's `initialize` call, so diagrams look
    /// as they do on the web (strict security, the base theme recoloured, no HTML labels).
    public static func mermaidConfig(_ p: VizPalette) -> String {
        var vars: [String: Any] = [
            "darkMode": p.isDark,
            "background": p.surface, "primaryColor": p.panel, "primaryTextColor": p.ink,
            "primaryBorderColor": p.series[0], "secondaryColor": p.panel, "secondaryTextColor": p.ink,
            "secondaryBorderColor": p.series[1], "tertiaryColor": p.surface, "tertiaryTextColor": p.ink,
            "tertiaryBorderColor": p.line, "lineColor": p.line, "textColor": p.ink,
            "mainBkg": p.panel, "nodeBorder": p.series[0], "clusterBkg": p.surface, "clusterBorder": p.line,
            "edgeLabelBackground": p.surface, "actorBkg": p.panel, "actorTextColor": p.ink,
            "actorBorder": p.line, "actorLineColor": p.line, "signalColor": p.ink, "signalTextColor": p.ink,
            "labelBoxBkgColor": p.panel, "labelBoxBorderColor": p.line, "labelTextColor": p.ink,
            "loopTextColor": p.ink, "noteBkgColor": p.panel, "noteTextColor": p.ink, "noteBorderColor": p.line,
        ]
        for (i, c) in p.series.enumerated() { vars["pie\(i + 1)"] = c }
        let config: [String: Any] = [
            "startOnLoad": false, "securityLevel": "strict", "theme": "base", "themeVariables": vars,
            "suppressErrorRendering": true, "htmlLabels": false,
            "flowchart": ["htmlLabels": false, "useMaxWidth": false], "sequence": ["useMaxWidth": false],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `Resources/embeds` in VesperCore's resource bundle, found the way `CodeHighlighter.bundledScript`
    /// finds Shiki (the app's Contents/Resources, or next to the executable or test bundle).
    public static func bundledDirectory() -> URL? {
        guard let shiki = CodeHighlighter.bundledScript() else { return nil }
        let dir = shiki.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("embeds", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("katex.js").path) ? dir : nil
    }
}

/// One piece of math to draw: its TeX, display or inline, and the colour and size of the text around
/// it (baked into the image, so they're part of the cache key).
public struct MathRenderRequest: Sendable, Hashable {
    public var tex: String
    public var display: Bool
    /// "#RRGGBB".
    public var color: String
    /// The surrounding text's point size; KaTeX sets math at 1.21 times it, as on the web.
    public var fontSize: Double

    public init(tex: String, display: Bool, color: String, fontSize: Double) {
        self.tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.display = display
        self.color = RGBA(hex: color) != nil ? color : "#000000"
        self.fontSize = max(6, min(fontSize, 96))
    }

    /// Cached per message like the other embeds; math in markdown outside a message uses "".
    public func cacheKey(messageID: String = "") -> EmbedCacheKey {
        EmbedCacheKey(kind: .math, messageID: messageID, theme: "\(color.lowercased())@\(fontSize)", source: tex, variant: display ? "display" : "inline")
    }
}
