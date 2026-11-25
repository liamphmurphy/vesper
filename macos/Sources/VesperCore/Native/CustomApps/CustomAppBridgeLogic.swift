import Foundation

/// Pure logic for running sandboxed Custom Apps natively in SwiftUI without React/Vite:
/// slug validation, sandboxed `srcdoc` CSP HTML generation, host container HTML (with
/// proxy WebSockets, proxy Images, and native WebKit AirPlay/HLS/YouTube/Twitch player),
/// bridge message parsing, video embed resolution, and validation helpers.
public enum CustomAppBridgeLogic: Sendable {
    public static let reservedSlugs: Set<String> = ["new", "api", "slides", "designs", "docs"]
    public static let maxBridgeURLChars = 4000
    public static let maxOSNotifyTitleChars = 120
    public static let maxOSNotifySubtitleChars = 120
    public static let maxOSNotifyBodyChars = 500
    public static let maxOSClipboardChars = 1_000_000
    public static let maxOSFilePickerTitleChars = 120
    public static let maxOSFilePickerExtensions = 20

    public struct NavSpec: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let icon: String?

        public init(id: String, label: String, icon: String? = nil) {
            self.id = id
            self.label = label
            self.icon = icon
        }
    }

    public struct VideoEmbed: Sendable, Equatable {
        public enum Provider: String, Sendable, Equatable {
            case youtube, twitch, local, hls
        }

        public let provider: Provider
        public let embedURL: String
        public let externalURL: String
        public let titleFallback: String
        public let streamId: String?
        public let relayId: String?

        public init(
            provider: Provider,
            embedURL: String,
            externalURL: String,
            titleFallback: String,
            streamId: String? = nil,
            relayId: String? = nil
        ) {
            self.provider = provider
            self.embedURL = embedURL
            self.externalURL = externalURL
            self.titleFallback = titleFallback
            self.streamId = streamId
            self.relayId = relayId
        }
    }

    public enum BridgeMessage: Sendable, Equatable {
        case sql(id: String, query: String, params: [JSONValue])
        case api(id: String, method: String, path: String, body: JSONValue?)
        case mcp(id: String, connector: String, tool: String, arguments: [String: JSONValue])
        case image(id: String, url: String)
        case osNotify(id: String, title: String, subtitle: String?, body: String?, silent: Bool)
        case osClipboardRead(id: String)
        case osClipboardWrite(id: String, text: String)
        case osFilePick(id: String, multiple: Bool, extensions: [String], title: String?)
        case wsOpen(connId: String, url: String, protocols: [String])
        case wsSend(connId: String, data: String)
        case wsClose(connId: String, code: Int?, reason: String?)
        case setNav(items: [NavSpec], activeId: String?)
        case askDock(prompt: String)
        case openURL(url: String)
        case playVideo(url: String, title: String?, theater: Bool?, sidePanel: Bool, externalURL: String?)
        case appError(message: String)
        case playerClosed
        case playerTheaterChanged(theater: Bool)

        public var osCapability: CustomAppOSCapability? {
            switch self {
            case .osNotify: .notifications
            case .osClipboardRead, .osClipboardWrite: .clipboard
            case .osFilePick: .filePicker
            default: nil
            }
        }

        public var osApprovalSummary: String? {
            switch self {
            case .osNotify(_, let title, _, _, _):
                return "Send macOS notification: \u{201C}\(title)\u{201D}"
            case .osClipboardRead:
                return "Read plain text from the macOS clipboard"
            case .osClipboardWrite:
                return "Copy text to the macOS clipboard"
            case .osFilePick(_, let multiple, _, _):
                return multiple
                    ? "Choose files using the macOS file picker"
                    : "Choose a file using the macOS file picker"
            default:
                return nil
            }
        }
    }

    // MARK: - Slug & Input Validation

    public static func validateSlug(_ slug: String) -> String? {
        let s = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^[a-z0-9][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else {
            return "Use 1–48 lowercase letters, digits, or hyphens starting with a letter or digit."
        }
        if reservedSlugs.contains(s) {
            return "\"\(s)\" is a reserved Vesper route."
        }
        return nil
    }

    public static func isValidNixPackage(_ name: String) -> Bool {
        guard name != ".", name != ".." else { return false }
        return name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil
    }

    public static func isValidMountName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9_-]{0,47}$"#, options: .regularExpression) != nil
    }

    public static func isValidHostMountPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("/") || (trimmed.hasPrefix("~/") && trimmed.count > 2)
    }

    public static func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            let s = String(format: "%.1f", kb).replacingOccurrences(of: ".0", with: "")
            return "\(s) KB"
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Theme CSS Variables

    public static func themeVars(from theme: ThemeTokens) -> [String: String] {
        let c = theme.colors
        func pick(_ key: String, fallback: String) -> String {
            let v = c[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? fallback : v
        }
        let dark = theme.mode == .dark
        return [
            "--bg": pick("bg", fallback: dark ? "#141413" : "#faf9f6"),
            "--surface": pick("surface", fallback: dark ? "#1c1b19" : "#ffffff"),
            "--surface-raised": pick("surfaceRaised", fallback: pick("surface", fallback: dark ? "#242320" : "#ffffff")),
            "--surface-sunken": pick("surfaceSunken", fallback: dark ? "#10100f" : "#f3f2ee"),
            "--fg": pick("text", fallback: dark ? "#ecebe7" : "#1a1917"),
            "--fg-2": pick("text2", fallback: dark ? "#c9c8c2" : "#3a3834"),
            "--fg-secondary": pick("textSecondary", fallback: dark ? "#a09f99" : "#5e5c56"),
            "--fg-tertiary": pick("textTertiary", fallback: dark ? "#76756f" : "#86847d"),
            "--border": pick("border", fallback: dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.10)"),
            "--border-subtle": pick("borderSubtle", fallback: dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"),
            "--border-strong": pick("borderStrong", fallback: dark ? "rgba(255,255,255,0.18)" : "rgba(0,0,0,0.18)"),
            "--accent": pick("accent", fallback: "#7c5cff"),
            "--accent-soft": pick("accentSoft", fallback: "rgba(124,92,255,0.16)"),
            "--on-accent": pick("textOnAccent", fallback: "#ffffff"),
            "--hover": pick("hover", fallback: dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"),
            "--selected": pick("selected", fallback: dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.07)"),
            "--font-sans": "-apple-system, BlinkMacSystemFont, \"Inter\", system-ui, sans-serif",
            "--font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
        ]
    }

    public static func formatThemeVarsCSS(_ vars: [String: String]) -> String {
        let lines = vars.keys.sorted().compactMap { key -> String? in
            guard key.hasPrefix("--"), let raw = vars[key] else { return nil }
            let safe = raw.replacingOccurrences(of: #"[;{}\n\r]"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return safe.isEmpty ? nil : "  \(key): \(safe);"
        }
        guard !lines.isEmpty else { return "" }
        return ":root {\n\(lines.joined(separator: "\n"))\n}"
    }

    // MARK: - Sandboxed srcDoc + Host Container HTML

    private static func escapeCloseTag(_ text: String, tagName: String) -> String {
        text.replacingOccurrences(of: "</\(tagName)", with: "<\\/\(tagName)", options: .caseInsensitive)
    }

    public static func buildCustomAppSrcDoc(
        slug: String,
        seq: Int,
        bundleJS: String,
        bundleCSS: String?,
        themeVars: [String: String]
    ) -> String {
        let css = escapeCloseTag(bundleCSS ?? "", tagName: "style")
        let js = escapeCloseTag(bundleJS, tagName: "script")
        let varsCSS = formatThemeVarsCSS(themeVars)
        let metaObj: [String: Any] = ["slug": slug, "seq": seq]
        let metaData = (try? JSONSerialization.data(withJSONObject: metaObj)) ?? Data("{}".utf8)
        let metaJSON = (String(data: metaData, encoding: .utf8) ?? "{}").replacingOccurrences(of: "<", with: "\\u003c")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src blob:; font-src data:;" />
        <style>
        \(varsCSS)
        *, *::before, *::after { box-sizing: border-box; }
        html, body, #root { min-height: 100%; }
        body {
          margin: 0;
          background: var(--bg, #141413);
          color: var(--fg, #ecebe7);
          font-family: var(--font-sans, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          line-height: 1.45;
          -webkit-font-smoothing: antialiased;
        }
        button, input, select, textarea { font: inherit; color: inherit; }
        </style>
        <style>\(css)</style>
        <script>
        (function () {
          window.__VESPER_APP__ = \(metaJSON);
          function sendErr(err) {
            var msg = err && (err.message || (err.reason && (err.reason.message || String(err.reason)))) || String(err || "Unknown error");
            window.parent.postMessage({ channel: "vesper:custom-app", id: "", type: "app-error", payload: { message: String(msg) } }, "*");
          }
          window.addEventListener("error", function (e) { sendErr(e.error || e.message); });
          window.addEventListener("unhandledrejection", function (e) { sendErr(e.reason); });
          window.addEventListener("message", function (e) {
            var m = e && e.data;
            if (!m || typeof m !== "object" || m.type !== "vesper:theme" || !m.vars || typeof m.vars !== "object") return;
            var root = document.documentElement;
            for (var k in m.vars) {
              if (Object.prototype.hasOwnProperty.call(m.vars, k) && k.indexOf("--") === 0 && typeof m.vars[k] === "string") {
                root.style.setProperty(k, m.vars[k]);
              }
            }
          });
        })();
        </script>
        </head>
        <body>
        <div id="root"></div>
        <script type="module">
        \(js)
        </script>
        </body>
        </html>
        """
    }

    /// Tiny self-contained host HTML document loaded in `WKWebView` at the Vesper server origin.
    /// Hosts the sandboxed `<iframe sandbox="allow-scripts">` (opaque origin) plus the host-layer
    /// video player stage (native WebKit AirPlay/HLS/Local `<video>` + YouTube/Twitch embeds)
    /// and same-origin proxy WebSocket/Image relays, forwarding all bridge traffic to Swift.
    public static func buildHostHTML(
        slug: String,
        name: String,
        srcDoc: String,
        themeVars: [String: String]
    ) -> String {
        let varsCSS = formatThemeVarsCSS(themeVars)
        let srcDocJSON = encodeJSONString(srcDoc)
        let titleEsc = escapeHTMLAttr(name)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>
        \(varsCSS)
        *, *::before, *::after { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: var(--bg, #141413); color: var(--fg, #ecebe7); font-family: var(--font-sans, -apple-system, sans-serif); font-size: 13px; }
        #layout { display: flex; flex-direction: column; width: 100%; height: 100%; }
        #layout.side-panel { flex-direction: row; }
        #player { display: none; flex: none; flex-direction: column; border-bottom: 1px solid var(--border-subtle); background: var(--bg); }
        #player.open { display: flex; }
        #player.theater { background: #000; }
        #layout.side-panel #player.open { flex: 1; min-width: 0; border-bottom: 0; background: #000; }
        #player-stage-wrap { display: flex; align-items: center; justify-content: center; background: #000; padding: 12px 16px 0; }
        #player.theater #player-stage-wrap, #layout.side-panel #player-stage-wrap { padding: 0; }
        #layout.side-panel #player-stage-wrap { flex: 1; min-height: 0; }
        #player-box { position: relative; width: 100%; aspect-ratio: 16 / 9; max-width: calc(56dvh * 16 / 9); background: #000; }
        #player.theater #player-box { max-width: calc((100dvh - 7rem) * 16 / 9); }
        #player-box video, #player-box iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
        #player-overlay { position: absolute; inset: 0; display: none; align-items: center; justify-content: center; background: rgba(0,0,0,0.78); color: #fff; padding: 24px; text-align: center; }
        #player-action { position: absolute; left: 12px; top: 12px; display: none; border: 0; border-radius: 8px; background: rgba(0,0,0,0.82); color: #fff; padding: 6px 12px; font-weight: 600; cursor: pointer; }
        #player-bar { display: flex; align-items: center; gap: 8px; padding: 8px 16px; background: var(--bg); }
        #player-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 600; margin: 0; }
        .pbtn { height: 28px; padding: 0 10px; border-radius: 999px; border: 1px solid var(--border-strong); background: transparent; color: var(--fg-secondary); font-size: 12px; font-weight: 500; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 4px; }
        .pbtn:hover { background: var(--hover); color: var(--fg); }
        .pbtn.active { border-color: var(--accent); background: var(--accent-soft); color: var(--fg); }
        #app { flex: 1; width: 100%; height: 100%; border: 0; background: var(--bg); }
        #layout.side-panel #app { flex: none; width: 340px; height: 100%; border-left: 1px solid var(--border-subtle); }
        #layout.side-panel.side-hidden #app { display: none; }
        </style>
        </head>
        <body>
        <div id="layout">
          <section id="player" aria-label="Video player">
            <div id="player-stage-wrap">
              <div id="player-box">
                <div id="player-slot"></div>
                <div id="player-overlay"></div>
                <button id="player-action" type="button"></button>
              </div>
            </div>
            <div id="player-bar">
              <h2 id="player-title"></h2>
              <button id="btn-airplay" class="pbtn" type="button" style="display:none">AirPlay</button>
              <a id="btn-ext" class="pbtn" target="_blank" rel="noopener noreferrer" style="display:none">Open link</a>
              <button id="btn-side" class="pbtn" type="button" style="display:none">Hide chat</button>
              <button id="btn-theater" class="pbtn" type="button">Theater</button>
              <button id="btn-close" class="pbtn" type="button" title="Close (Esc)">✕</button>
            </div>
          </section>
          <iframe id="app" sandbox="allow-scripts" allow="fullscreen" referrerpolicy="no-referrer" title="\(titleEsc)"></iframe>
        </div>
        <script>
        (function () {
          var frame = document.getElementById("app");
          var layout = document.getElementById("layout");
          var playerEl = document.getElementById("player");
          var slotEl = document.getElementById("player-slot");
          var overlayEl = document.getElementById("player-overlay");
          var actionBtn = document.getElementById("player-action");
          var titleEl = document.getElementById("player-title");
          var airPlayBtn = document.getElementById("btn-airplay");
          var extLink = document.getElementById("btn-ext");
          var sideBtn = document.getElementById("btn-side");
          var theaterBtn = document.getElementById("btn-theater");
          var closeBtn = document.getElementById("btn-close");
          var wsConns = new Map();
          var playerOpen = false, theater = false, sideAvailable = false, sideOpen = true;
          var activeVideoEl = null;

          function postSwift(obj) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vesperCustomApp) {
              window.webkit.messageHandlers.vesperCustomApp.postMessage(obj);
            }
          }
          function postToFrame(msg, transfer) {
            if (frame && frame.contentWindow) {
              frame.contentWindow.postMessage(msg, "*", transfer);
            }
          }
          function syncPlayerState() {
            var sideLayout = playerOpen && theater && sideAvailable;
            playerEl.classList.toggle("open", playerOpen);
            playerEl.classList.toggle("theater", theater);
            layout.classList.toggle("side-panel", sideLayout);
            layout.classList.toggle("side-hidden", sideLayout && !sideOpen);
            theaterBtn.classList.toggle("active", theater);
            sideBtn.style.display = (playerOpen && theater && sideAvailable) ? "inline-flex" : "none";
            sideBtn.textContent = sideOpen ? "Hide chat" : "Show chat";
            sideBtn.classList.toggle("active", sideOpen);
            postToFrame({ type: "vesper:player", open: playerOpen, theater: theater, sidePanel: sideLayout && sideOpen });
          }
          function cleanupMedia() {
            if (activeVideoEl) {
              try { activeVideoEl.pause(); activeVideoEl.removeAttribute("src"); activeVideoEl.load(); } catch (_) {}
              activeVideoEl = null;
            }
            slotEl.innerHTML = "";
            overlayEl.style.display = "none";
            actionBtn.style.display = "none";
            airPlayBtn.style.display = "none";
            airPlayBtn.classList.remove("active");
            airPlayBtn.textContent = "AirPlay";
          }
          function closePlayer(notifySwift) {
            cleanupMedia();
            playerOpen = false;
            sideAvailable = false;
            syncPlayerState();
            if (notifySwift) postSwift({ channel: "vesper:custom-app", id: "", type: "player-closed", payload: {} });
          }
          closeBtn.addEventListener("click", function () { closePlayer(true); });
          theaterBtn.addEventListener("click", function () {
            theater = !theater;
            syncPlayerState();
            postSwift({ channel: "vesper:custom-app", id: "", type: "player-theater", payload: { theater: theater } });
          });
          sideBtn.addEventListener("click", function () { sideOpen = !sideOpen; syncPlayerState(); });
          airPlayBtn.addEventListener("click", function () {
            if (activeVideoEl && activeVideoEl.webkitShowPlaybackTargetPicker) activeVideoEl.webkitShowPlaybackTargetPicker();
          });
          window.addEventListener("keydown", function (e) {
            if (e.metaKey || e.ctrlKey || e.altKey || document.fullscreenElement) return;
            if (e.key === "Escape" && playerOpen) {
              e.preventDefault();
              if (theater) { theater = false; syncPlayerState(); postSwift({ channel: "vesper:custom-app", id: "", type: "player-theater", payload: { theater: false } }); }
              else closePlayer(true);
            } else if ((e.key === "t" || e.key === "T") && playerOpen) {
              e.preventDefault();
              theater = !theater;
              syncPlayerState();
              postSwift({ channel: "vesper:custom-app", id: "", type: "player-theater", payload: { theater: theater } });
            }
          });

          window.addEventListener("message", function (e) {
            if (!frame || e.source !== frame.contentWindow) return;
            var d = e.data;
            if (!d || typeof d !== "object" || d.channel !== "vesper:custom-app") return;
            postSwift(d);
          });

          window.__vesperHost = {
            postToFrame: function (msg) { postToFrame(msg); },
            setTheme: function (vars) {
              var root = document.documentElement;
              for (var k in vars) { if (k.indexOf("--") === 0) root.style.setProperty(k, vars[k]); }
              postToFrame({ type: "vesper:theme", vars: vars });
            },
            setNavActive: function (id) { postToFrame({ type: "vesper:nav-select", id: id }); },
            emitSSE: function (ev) { postToFrame({ type: "vesper:sse", event: ev }); },
            openProxyWS: function (connId, slug, wsUrl, protocols, approved) {
              if (wsConns.size >= 8 && !wsConns.has(connId)) {
                postToFrame({ type: "vesper:ws", connId: connId, event: "error", message: "Too many open WebSocket connections (max 8)" });
                postToFrame({ type: "vesper:ws", connId: connId, event: "close", code: 1008, reason: "limit exceeded", wasClean: false });
                return;
              }
              var prev = wsConns.get(connId);
              if (prev) { try { prev.close(1000, "replaced"); } catch (_) {} wsConns.delete(connId); }
              var params = new URLSearchParams({ url: wsUrl });
              if (approved) params.set("approved", "true");
              if (protocols && protocols.length) params.set("protocols", protocols.join(","));
              var proto = window.location.protocol === "https:" ? "wss:" : "ws:";
              var proxyUrl = proto + "//" + window.location.host + "/api/v1/custom-apps/" + encodeURIComponent(slug) + "/ws?" + params.toString();
              try {
                var ws = (protocols && protocols.length) ? new WebSocket(proxyUrl, protocols) : new WebSocket(proxyUrl);
                wsConns.set(connId, ws);
                ws.addEventListener("open", function () { postToFrame({ type: "vesper:ws", connId: connId, event: "open", protocol: ws.protocol || "" }); });
                ws.addEventListener("message", function (ev) {
                  if (typeof ev.data === "string") postToFrame({ type: "vesper:ws", connId: connId, event: "message", data: ev.data });
                  else if (ev.data instanceof Blob) ev.data.text().then(function (t) { postToFrame({ type: "vesper:ws", connId: connId, event: "message", data: t }); });
                });
                ws.addEventListener("error", function () { postToFrame({ type: "vesper:ws", connId: connId, event: "error", message: "WebSocket connection failed" }); });
                ws.addEventListener("close", function (ev) {
                  if (wsConns.get(connId) === ws) wsConns.delete(connId);
                  postToFrame({ type: "vesper:ws", connId: connId, event: "close", code: ev.code || 1000, reason: ev.reason || "", wasClean: ev.wasClean });
                });
              } catch (err) {
                var msg = err && err.message ? err.message : String(err);
                postToFrame({ type: "vesper:ws", connId: connId, event: "error", message: msg });
                postToFrame({ type: "vesper:ws", connId: connId, event: "close", code: 1006, reason: msg, wasClean: false });
              }
            },
            sendProxyWS: function (connId, data) {
              var ws = wsConns.get(connId);
              if (ws && ws.readyState === WebSocket.OPEN) ws.send(data);
            },
            closeProxyWS: function (connId, code, reason) {
              var ws = wsConns.get(connId);
              if (ws) { wsConns.delete(connId); try { ws.close(code || 1000, reason || ""); } catch (_) {} }
            },
            closeAllWS: function () {
              wsConns.forEach(function (ws) { try { ws.close(1001, "app reload"); } catch (_) {} });
              wsConns.clear();
            },
            fetchProxyImage: function (reqId, slug, imageUrl, approved) {
              var params = new URLSearchParams({ url: imageUrl });
              if (approved) params.set("approved", "true");
              fetch("/api/v1/custom-apps/" + encodeURIComponent(slug) + "/image?" + params.toString(), { credentials: "same-origin" })
                .then(function (res) {
                  if (!res.ok) {
                    return res.json().catch(function () { return {}; }).then(function (j) {
                      postToFrame({ type: "vesper:response", id: reqId, ok: false, error: (j && j.message) || ("Image request failed (HTTP " + res.status + ")") });
                    });
                  }
                  var mime = (res.headers.get("content-type") || "image/png").split(";")[0].trim();
                  return res.arrayBuffer().then(function (bytes) {
                    postToFrame({ type: "vesper:response", id: reqId, ok: true, data: { bytes: bytes, mime: mime } }, [bytes]);
                  });
                })
                .catch(function (err) {
                  postToFrame({ type: "vesper:response", id: reqId, ok: false, error: (err && err.message) || String(err) });
                });
            },
            playVideo: function (spec) {
              cleanupMedia();
              titleEl.textContent = spec.title || "";
              if (spec.externalUrl) {
                extLink.href = spec.externalUrl;
                extLink.textContent = spec.externalLabel || "Open link";
                extLink.style.display = "inline-flex";
              } else {
                extLink.style.display = "none";
              }
              if (spec.provider === "hls" || spec.provider === "local") {
                var v = document.createElement("video");
                v.controls = true;
                v.playsInline = true;
                v.title = spec.title || "";
                v.setAttribute("x-webkit-airplay", "allow");
                v.disableRemotePlayback = false;
                activeVideoEl = v;
                v.addEventListener("webkitplaybacktargetavailabilitychanged", function (ev) {
                  airPlayBtn.style.display = ev.availability === "available" ? "inline-flex" : "none";
                });
                v.addEventListener("webkitcurrentplaybacktargetiswirelesschanged", function () {
                  var w = Boolean(v.webkitCurrentPlaybackTargetIsWireless);
                  airPlayBtn.classList.toggle("active", w);
                  airPlayBtn.textContent = w ? "AirPlaying" : "AirPlay";
                });
                if (spec.provider === "hls") {
                  v.addEventListener("error", function () {
                    overlayEl.textContent = "Stream playback stopped. Close and reopen it, or switch to the standard player.";
                    overlayEl.style.display = "flex";
                  });
                  v.addEventListener("playing", function () { overlayEl.style.display = "none"; actionBtn.style.display = "none"; });
                }
                v.src = spec.embedUrl;
                slotEl.appendChild(v);
                v.load();
                v.muted = false;
                var p = v.play();
                if (p && p.catch) {
                  p.catch(function () {
                    v.muted = true;
                    var p2 = v.play();
                    if (p2 && p2.then) {
                      p2.then(function () {
                        actionBtn.textContent = "Unmute";
                        actionBtn.style.display = "inline-flex";
                        actionBtn.onclick = function () { v.muted = false; v.play(); actionBtn.style.display = "none"; };
                      }).catch(function () {
                        actionBtn.textContent = "Play";
                        actionBtn.style.display = "inline-flex";
                        actionBtn.onclick = function () { v.muted = false; v.play(); actionBtn.style.display = "none"; };
                      });
                    }
                  });
                }
              } else {
                var ifr = document.createElement("iframe");
                ifr.src = spec.embedUrl;
                ifr.title = spec.title || "";
                ifr.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
                ifr.allowFullscreen = true;
                ifr.referrerPolicy = "strict-origin-when-cross-origin";
                slotEl.appendChild(ifr);
              }
              playerOpen = true;
              if (typeof spec.theater === "boolean") theater = spec.theater;
              sideAvailable = Boolean(spec.sidePanel);
              if (sideAvailable) sideOpen = true;
              syncPlayerState();
            },
            closeVideo: function () { closePlayer(false); }
          };

          frame.srcdoc = \(srcDocJSON);
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func encodeJSONString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8),
              arr.count >= 2 else { return "\"\"" }
        let inner = String(arr.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }

    private static func escapeHTMLAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - URL & Video Embed Resolution

    public static func parseSafeURL(_ raw: String?, allowedSchemes: Set<String>) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxBridgeURLChars,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), allowedSchemes.contains(scheme),
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              let url = comps.url else { return nil }
        return url.absoluteString
    }

    public static func parseSafeExternalURL(_ raw: String?) -> String? {
        parseSafeURL(raw, allowedSchemes: ["https", "http"])
    }

    public static func parseSafeHttpsURL(_ raw: String?) -> String? {
        parseSafeURL(raw, allowedSchemes: ["https"])
    }

    public static func parseSafeWssURL(_ raw: String?) -> String? {
        parseSafeURL(raw, allowedSchemes: ["wss"])
    }

    private static let uuidPattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#

    public static func localMediaId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.range(of: "^vesper-media:\(uuidPattern)$", options: .regularExpression) != nil else { return nil }
        return String(s.dropFirst("vesper-media:".count))
    }

    public static func hlsRelayStreamId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.range(of: "^vesper-hls:\(uuidPattern)$", options: .regularExpression) != nil else { return nil }
        return String(s.dropFirst("vesper-hls:".count))
    }

    public static func localMediaEmbed(rawURL: String, slug: String) -> VideoEmbed? {
        guard let id = localMediaId(rawURL), validateSlug(slug) == nil else { return nil }
        return VideoEmbed(
            provider: .local,
            embedURL: "/api/v1/custom-apps/\(slug)/media/\(id)/content",
            externalURL: "",
            titleFallback: "Downloaded video"
        )
    }

    private static let ytHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com", "youtu.be", "www.youtu.be",
    ]
    private static let twitchHosts: Set<String> = ["twitch.tv", "www.twitch.tv", "m.twitch.tv", "clips.twitch.tv"]
    private static let twitchReserved: Set<String> = [
        "directory", "videos", "downloads", "jobs", "p", "settings", "subscriptions",
        "wallet", "inventory", "drops", "search", "turbo", "login", "signup",
        "friends", "messages", "moderator", "popout", "embed", "u",
    ]

    public static func resolveVideoEmbed(rawURL: String, parentHost: String = "localhost") -> VideoEmbed? {
        guard let safe = parseSafeExternalURL(rawURL),
              let comps = URLComponents(string: safe),
              let host = comps.host?.lowercased() else { return nil }
        let segments = comps.path.split(separator: "/").map(String.init)
        let query = Dictionary((comps.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let v = item.value else { return nil }
            return (item.name, v)
        }, uniquingKeysWith: { first, _ in first })

        if ytHosts.contains(host) {
            var id = ""
            if host.hasSuffix("youtu.be") {
                id = segments.first ?? ""
            } else if comps.path == "/watch" {
                id = query["v"] ?? ""
            } else if segments.count >= 2, ["shorts", "live", "embed"].contains(segments[0]) {
                id = segments[1]
            }
            guard id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            let start = parseTimestampSeconds(query["t"] ?? query["start"])
            let startSuffix = start.map { $0 > 0 ? "&start=\($0)" : "" } ?? ""
            let extSuffix = start.map { $0 > 0 ? "&t=\($0)s" : "" } ?? ""
            return VideoEmbed(
                provider: .youtube,
                embedURL: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&rel=0\(startSuffix)",
                externalURL: "https://www.youtube.com/watch?v=\(id)\(extSuffix)",
                titleFallback: "YouTube video"
            )
        }

        if twitchHosts.contains(host) {
            let parent = parentHost.range(of: #"^[a-zA-Z0-9.-]+$"#, options: .regularExpression) != nil ? parentHost : "localhost"
            let encParent = parent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "localhost"
            if host == "clips.twitch.tv", let slug = segments.first,
               slug.range(of: #"^[A-Za-z0-9_-]{4,120}$"#, options: .regularExpression) != nil {
                let enc = slug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? slug
                return VideoEmbed(provider: .twitch, embedURL: "https://clips.twitch.tv/embed?clip=\(enc)&parent=\(encParent)&autoplay=true", externalURL: safe, titleFallback: "Twitch clip")
            }
            if segments.count == 3, segments[1] == "clip",
               segments[0].range(of: #"^[a-zA-Z0-9_]{2,25}$"#, options: .regularExpression) != nil,
               segments[2].range(of: #"^[A-Za-z0-9_-]{4,120}$"#, options: .regularExpression) != nil {
                let enc = segments[2].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? segments[2]
                return VideoEmbed(provider: .twitch, embedURL: "https://clips.twitch.tv/embed?clip=\(enc)&parent=\(encParent)&autoplay=true", externalURL: safe, titleFallback: "Twitch clip")
            }
            if segments.count == 2, segments[0] == "videos",
               segments[1].range(of: #"^\d{4,16}$"#, options: .regularExpression) != nil {
                let vod = segments[1]
                return VideoEmbed(provider: .twitch, embedURL: "https://player.twitch.tv/?video=\(vod)&parent=\(encParent)&autoplay=true", externalURL: "https://www.twitch.tv/videos/\(vod)", titleFallback: "Twitch video")
            }
            if segments.count == 1,
               segments[0].range(of: #"^[a-zA-Z0-9_]{2,25}$"#, options: .regularExpression) != nil,
               !twitchReserved.contains(segments[0].lowercased()) {
                let ch = segments[0].lowercased()
                let enc = ch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ch
                return VideoEmbed(provider: .twitch, embedURL: "https://player.twitch.tv/?channel=\(enc)&parent=\(encParent)&autoplay=true", externalURL: "https://www.twitch.tv/\(enc)", titleFallback: "\(segments[0]) on Twitch")
            }
        }
        return nil
    }

    private static func parseTimestampSeconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.range(of: #"^\d+s?$"#, options: .regularExpression) != nil {
            return Int(s.replacingOccurrences(of: "s", with: ""))
        }
        guard let regex = try? NSRegularExpression(pattern: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func num(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: s) else { return 0 }
            return Int(s[r]) ?? 0
        }
        let total = num(1) * 3600 + num(2) * 60 + num(3)
        return total > 0 ? total : nil
    }

    public static func externalLinkLabel(provider: VideoEmbed.Provider, externalURL: String) -> String {
        if provider == .youtube { return "Open on YouTube" }
        if provider == .twitch { return "Open on Twitch" }
        if let host = URL(string: externalURL)?.host?.lowercased() {
            if host == "twitch.tv" || host.hasSuffix(".twitch.tv") { return "Open on Twitch" }
            if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { return "Open on YouTube" }
        }
        return "Open link"
    }

    // MARK: - Bridge Message Parsing

    public static func parseBridgeMessage(_ raw: Any) -> BridgeMessage? {
        guard let dict = raw as? [String: Any],
              (dict["channel"] as? String) == "vesper:custom-app",
              let type = dict["type"] as? String else { return nil }
        let id = (dict["id"] as? String) ?? ""
        let payload = (dict["payload"] as? [String: Any]) ?? [:]

        switch type {
        case "sql":
            guard !id.isEmpty, let query = payload["query"] as? String else { return nil }
            let params = (payload["params"] as? [Any])?.map(JSONValue.fromAny) ?? []
            return .sql(id: id, query: query, params: params)
        case "api":
            guard !id.isEmpty, let path = payload["path"] as? String else { return nil }
            let method = ((payload["method"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }) ?? "GET"
            let body = payload["body"].map(JSONValue.fromAny)
            return .api(id: id, method: method, path: path, body: body)
        case "mcp":
            guard !id.isEmpty, let connector = payload["connector"] as? String, let tool = payload["tool"] as? String else { return nil }
            let rawArgs = (payload["arguments"] as? [String: Any]) ?? [:]
            var args: [String: JSONValue] = [:]
            for (k, v) in rawArgs { args[k] = JSONValue.fromAny(v) }
            return .mcp(id: id, connector: connector, tool: tool, arguments: args)
        case "image":
            guard !id.isEmpty, let url = parseSafeHttpsURL(payload["url"] as? String) else { return nil }
            return .image(id: id, url: url)
        case "os-notify":
            guard !id.isEmpty, let rawTitle = payload["title"] as? String else { return nil }
            let title = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxOSNotifyTitleChars))
            guard !title.isEmpty else { return nil }
            let sub = (payload["subtitle"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxOSNotifySubtitleChars)) }
            let body = (payload["body"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxOSNotifyBodyChars)) }
            let silent = (payload["silent"] as? Bool) ?? false
            return .osNotify(id: id, title: title, subtitle: (sub?.isEmpty == false) ? sub : nil, body: (body?.isEmpty == false) ? body : nil, silent: silent)
        case "os-clipboard-read":
            guard !id.isEmpty else { return nil }
            return .osClipboardRead(id: id)
        case "os-clipboard-write":
            guard !id.isEmpty, let text = payload["text"] as? String, text.count <= maxOSClipboardChars else { return nil }
            return .osClipboardWrite(id: id, text: text)
        case "os-file-pick":
            guard !id.isEmpty else { return nil }
            let rawExts = (payload["extensions"] as? [Any]) ?? []
            var seen = Set<String>()
            var exts: [String] = []
            for item in rawExts {
                guard let s = item as? String else { continue }
                let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    .drop(while: { $0 == "." }).lowercased()
                guard cleaned.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil,
                      seen.insert(cleaned).inserted else { continue }
                exts.append(cleaned)
                if exts.count >= maxOSFilePickerExtensions { break }
            }
            let title = (payload["title"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxOSFilePickerTitleChars)) }
            return .osFilePick(id: id, multiple: (payload["multiple"] as? Bool) ?? false, extensions: exts, title: (title?.isEmpty == false) ? title : nil)
        case "ws-open":
            guard let connId = payload["connId"] as? String, !connId.isEmpty,
                  let url = parseSafeWssURL(payload["url"] as? String) else { return nil }
            let protos = (payload["protocols"] as? [String]) ?? []
            return .wsOpen(connId: connId, url: url, protocols: protos)
        case "ws-send":
            guard let connId = payload["connId"] as? String, !connId.isEmpty,
                  let data = payload["data"] as? String else { return nil }
            return .wsSend(connId: connId, data: data)
        case "ws-close":
            guard let connId = payload["connId"] as? String, !connId.isEmpty else { return nil }
            return .wsClose(connId: connId, code: payload["code"] as? Int, reason: payload["reason"] as? String)
        case "set-nav":
            let rawItems = (payload["items"] as? [[String: Any]]) ?? []
            let items: [NavSpec] = rawItems.compactMap { item in
                guard let iid = item["id"] as? String, !iid.isEmpty,
                      let label = item["label"] as? String, !label.isEmpty else { return nil }
                return NavSpec(id: iid, label: label, icon: item["icon"] as? String)
            }
            return .setNav(items: items, activeId: payload["activeId"] as? String)
        case "ask-dock":
            guard let prompt = payload["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .askDock(prompt: prompt)
        case "open-url":
            guard let url = parseSafeExternalURL(payload["url"] as? String) else { return nil }
            return .openURL(url: url)
        case "play-video":
            guard let url = payload["url"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let title = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let extURL = parseSafeExternalURL(payload["externalUrl"] as? String)
            return .playVideo(
                url: url,
                title: title,
                theater: payload["theater"] as? Bool,
                sidePanel: (payload["sidePanel"] as? Bool) ?? false,
                externalURL: extURL
            )
        case "app-error":
            let msg = (payload["message"] as? String) ?? "Unknown error"
            return .appError(message: msg)
        case "player-closed":
            return .playerClosed
        case "player-theater":
            return .playerTheaterChanged(theater: (payload["theater"] as? Bool) ?? false)
        default:
            return nil
        }
    }

    public static func withCustomAppContext(
        _ body: String,
        slug: String,
        name: String,
        seq: Int,
        activeNav: String?,
        error: String?
    ) -> String {
        var parts = ["Viewing Custom App \"\(name)\" (/apps/\(slug), version v\(seq))."]
        if let activeNav, !activeNav.isEmpty { parts.append("Active nav view: \(activeNav).") }
        if let error, !error.isEmpty { parts.append("Latest runtime error in sandbox: \(error)") }
        let suffix = "\n\n<!-- vesper:custom-app-context -->\n" + parts.joined(separator: "\n")
        return body.hasSuffix(suffix) ? body : body + suffix
    }
}

private extension JSONValue {
    static func fromAny(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let s as String: return .string(s)
        case let arr as [Any]: return .array(arr.map(fromAny))
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = fromAny(v) }
            return .object(out)
        default:
            return .string(String(describing: raw))
        }
    }
}
