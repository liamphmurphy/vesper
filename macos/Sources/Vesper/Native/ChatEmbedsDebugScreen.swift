import SwiftUI
import VesperCore

/// /native-debug/embeds, behind `NativeDebug`: every chat embed kind through `EmbeddedBlockView`,
/// repeated down a lazy list so the app web view pool (create, reuse, snapshot, evict) and the render
/// cache can be watched while scrolling. Paste an assistant message's id to try Save to Library. Not a
/// product screen.
struct ChatEmbedsDebugScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var messageID = ""
    @State private var cacheCount = 0

    private struct Sample: Identifiable {
        var id: Int
        var title: String
        var kind: EmbeddedBlockKind
        var source: String
    }

    /// Six rounds of every sample, so more app blocks pass by than the pool has views.
    private static let rows: [Sample] = (0..<6).flatMap { round in
        samples.enumerated().map { i, s in
            Sample(id: round * samples.count + i, title: "\(s.title) · round \(round + 1)", kind: s.kind, source: s.source)
        }
    }

    var body: some View {
        let pool = AppWebViewPool.shared
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("App pool: \(pool.live.count) live · \(pool.createdCount)/\(pool.capacity) views · \(pool.idleCount) idle · \(pool.snapshotCount) snapshots · \(pool.parked.count) parked")
                    Text("Render cache: \(cacheCount) entries")
                    HStack {
                        TextField("Assistant message id (for Save to Library)", text: $messageID)
                            .textFieldStyle(.roundedBorder)
                        Button("Clear render cache") {
                            EmbedRenderCache.shared.removeAll()
                            cacheCount = 0
                        }
                        .buttonStyle(.vesper())
                    }
                }
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.secondaryText)

                ForEach(Self.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).vesperText(.heading, theme)
                        EmbeddedBlockView(
                            kind: row.kind, source: row.source,
                            messageID: messageID.isEmpty ? nil : messageID, info: row.kind.rawValue, index: row.id
                        )
                    }
                    .id(row.id)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task {
            context.chrome = NativeChrome(title: "Chat embeds", subtitle: context.match.path)
            // The cache is shared and has no observer; a light poll keeps the header honest.
            while !Task.isCancelled {
                cacheCount = EmbedRenderCache.shared.count
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static let samples: [(title: String, kind: EmbeddedBlockKind, source: String)] = [
        ("Display math", .math, #"\int_0^1 x^2\,dx = \tfrac{1}{3} \qquad \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}"#),
        ("Math with matrices", .math, #"A = \begin{pmatrix} a & b \\ c & d \end{pmatrix},\quad \det A = ad - bc"#),
        ("Bad TeX (shows its source)", .math, #"\frac{1}{"#),
        ("Mermaid flowchart", .mermaid, """
        flowchart LR
          A[Request] --> B{Cached?}
          B -- yes --> C[Serve image]
          B -- no --> D[Render off-screen]
          D --> E[(PDF cache)]
          E --> C
        """),
        ("Mermaid sequence", .mermaid, """
        sequenceDiagram
          participant T as Transcript
          participant R as Renderer
          T->>R: render(key, job)
          R-->>T: vector PDF
        """),
        ("Broken mermaid (shows code)", .mermaid, "flowchart LR\n  A --> \n  ((("),
        ("Themed svg-image", .svgImage, """
        <svg viewBox="0 0 680 160" font-family="system-ui, sans-serif"><title>Render once, then cache</title>
        <defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="var(--viz-line)"/></marker></defs>
        <rect x="24" y="48" width="180" height="64" rx="8" fill="var(--viz-1-soft)" stroke="var(--viz-1)" stroke-width="1.5"/>
        <text x="114" y="85" text-anchor="middle" font-size="13" fill="var(--viz-ink)">Fence</text>
        <rect x="250" y="48" width="180" height="64" rx="8" fill="var(--viz-panel)" stroke="var(--viz-line)" stroke-width="1.5"/>
        <text x="340" y="85" text-anchor="middle" font-size="13" fill="var(--viz-ink)">Off-screen WKWebView</text>
        <rect x="476" y="48" width="180" height="64" rx="8" fill="var(--viz-3-soft)" stroke="var(--viz-3)" stroke-width="1.5"/>
        <text x="566" y="85" text-anchor="middle" font-size="13" fill="var(--viz-ink)">Vector image</text>
        <path d="M204,80 L248,80" stroke="var(--viz-line)" stroke-width="1.5" marker-end="url(#a)"/>
        <path d="M430,80 L474,80" stroke="var(--viz-line)" stroke-width="1.5" marker-end="url(#a)"/>
        </svg>
        """),
        ("Plain svg-image (white background in every theme)", .svgImage, """
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><title>Sun</title><rect width="240" height="120" fill="#bde0fe"/><circle cx="60" cy="60" r="36" fill="#ffb703"/><text x="120" y="66" font-family="system-ui" font-size="14">plain colours</text></svg>
        """),
        ("svg-image that can't draw (shows source)", .svgImage, "<svg><g></svg"),
        ("svg-steps", .svgSteps, """
        <svg viewBox="0 0 680 140" font-family="system-ui, sans-serif"><title>Pool lifecycle</title>
        <rect x="24" y="40" width="190" height="60" rx="8" fill="var(--viz-panel)" stroke="var(--viz-line)" stroke-width="1.5"/>
        <text x="119" y="75" text-anchor="middle" font-size="13" fill="var(--viz-ink)">Scrolls on: acquire</text>
        <rect data-step="2" x="245" y="40" width="190" height="60" rx="8" fill="var(--viz-2-soft)" stroke="var(--viz-2)" stroke-width="1.5"/>
        <text data-step="2" x="340" y="75" text-anchor="middle" font-size="13" fill="var(--viz-ink)">Scrolls off: snapshot</text>
        <rect data-step="3" x="466" y="40" width="190" height="60" rx="8" fill="var(--viz-3-soft)" stroke="var(--viz-3)" stroke-width="1.5"/>
        <text data-step="3" x="561" y="75" text-anchor="middle" font-size="13" fill="var(--viz-ink)">View back to the pool</text>
        </svg>
        1. A block on screen takes a view.
        2. Leaving the screen, it's snapshotted.
        3. Its view is blanked and reused.
        """),
        ("App: counter", .app, """
        <!doctype html><button id="b">Clicked 0 times</button>
        <script>let n=0;b.onclick=()=>{b.textContent=`Clicked ${++n} times`}</script>
        """),
        ("App: network is blocked", .app, """
        <p id="out">Trying fetch, XHR, an image and a navigation…</p>
        <script>
        const out=document.getElementById("out"); const log=(s)=>{out.innerHTML+="<br>"+s};
        fetch("https://example.com/?leak=1").then(()=>log("fetch: REACHED (bad)")).catch(()=>log("fetch: blocked"));
        try{const x=new XMLHttpRequest();x.open("GET","https://example.com/");x.onload=()=>log("xhr: REACHED (bad)");x.onerror=()=>log("xhr: blocked");x.send()}catch(e){log("xhr: blocked")}
        const i=new Image();i.onload=()=>log("image: REACHED (bad)");i.onerror=()=>log("image: blocked");i.src="https://example.com/x.png";
        setTimeout(()=>{location.href="https://example.com/?leak=2";setTimeout(()=>log("navigation: blocked (still here)"),500)},300);
        log("window.open: "+(window.open("https://example.com")?"OPENED (bad)":"blocked"));
        log("webkit bridge: "+(window.webkit&&window.webkit.messageHandlers&&Object.keys(window.webkit.messageHandlers).length?"VISIBLE (bad)":"none"));
        </script>
        """),
        ("App: tall content (clamped to 720)", .app, """
        <div id="list"></div><script>for(let i=1;i<=80;i++){const p=document.createElement("p");p.textContent="Row "+i;list.appendChild(p)}</script>
        """),
    ]
}
