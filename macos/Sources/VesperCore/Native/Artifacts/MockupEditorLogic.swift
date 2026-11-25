import Foundation

/// Pure logic for the native SVG mockup editor (`/artifacts/:id?edit=1`): XML/SVG well-formedness
/// validation, bounded undo/redo history with edit coalescing, and the self-contained offline visual
/// SVG canvas document.
public enum MockupEditorLogic {

    /// Validates that `source` is non-empty, well-formed XML, and has `<svg>` as its root element.
    public static func svgValidationError(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The SVG is empty." }
        do {
            let doc = try XMLDocument(xmlString: source, options: [.nodePreserveAll])
            guard let root = doc.rootElement() else {
                return "Not well-formed SVG."
            }
            let local = (root.localName ?? root.name ?? "").lowercased()
            if local != "svg" {
                return "The root element must be <svg>."
            }
            return nil
        } catch {
            let msg = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "Not well-formed SVG." : "Not well-formed SVG: \(msg)"
        }
    }

    /// Bounded undo/redo stack for SVG source strings with optional coalescing keys.
    public struct SourceHistory: Sendable, Equatable {
        public static let maxEntries = 100

        public private(set) var current: String
        private var past: [String] = []
        private var future: [String] = []
        private var lastKey: String?

        public init(initial: String) {
            self.current = initial
        }

        public var canUndo: Bool { !past.isEmpty }
        public var canRedo: Bool { !future.isEmpty }

        public mutating func commit(_ next: String, key: String? = nil) {
            guard next != current else { return }
            if !(key != nil && key == lastKey) {
                past.append(current)
                if past.count > Self.maxEntries { past.removeFirst() }
            }
            lastKey = key
            future.removeAll()
            current = next
        }

        public mutating func undo() -> String? {
            guard let prev = past.popLast() else { return nil }
            future.append(current)
            lastKey = nil
            current = prev
            return current
        }

        public mutating func redo() -> String? {
            guard let next = future.popLast() else { return nil }
            past.append(current)
            lastKey = nil
            current = next
            return current
        }

        public mutating func breakCoalesce() {
            lastKey = nil
        }
    }

    /// Self-contained offline HTML+JS visual SVG editor hosted in a sandboxed WKWebView.
    /// Zero network access (strict CSP), whitelist-sanitized SVG rendering, direct drag-translate,
    /// inline text editing, shape insertion, z-order, duplicate, delete, and property editing.
    public static func visualCanvasHTML(dark: Bool) -> String {
        let theme = dark ? "dark" : "light"
        return """
        <!doctype html>
        <html lang="en" data-theme="\(theme)">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
        <style>
          *, *::before, *::after { box-sizing: border-box; }
          :root {
            --bg: #f6f7f9; --surface: #ffffff; --sunken: #eceef2; --border: #d9dce3;
            --text: #18181b; --muted: #6b7280; --accent: #3b82f6;
          }
          :root[data-theme="dark"] {
            --bg: #141418; --surface: #1d1d24; --sunken: #18181f; --border: #2e2e38;
            --text: #f4f4f5; --muted: #9ca3af; --accent: #60a5fa;
          }
          html, body { margin: 0; height: 100%; overflow: hidden; background: var(--bg); color: var(--text); font: 12px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; }
          #app { display: flex; flex-direction: column; height: 100%; }
          #bar {
            display: flex; align-items: center; gap: 6px; padding: 6px 10px;
            background: var(--surface); border-bottom: 1px solid var(--border); flex-wrap: wrap;
          }
          .sep { width: 1px; height: 18px; background: var(--border); margin: 0 2px; }
          button {
            appearance: none; border: 1px solid var(--border); background: var(--surface); color: var(--text);
            border-radius: 5px; padding: 3px 8px; font: 11.5px/1.3 -apple-system, sans-serif; cursor: pointer;
          }
          button:hover:not(:disabled) { border-color: var(--accent); }
          button:disabled { opacity: 0.4; cursor: default; }
          #main { flex: 1; min-height: 0; display: flex; }
          #stage {
            flex: 1; min-width: 0; overflow: auto; display: flex; align-items: center; justify-content: center; padding: 20px;
            background-color: var(--sunken);
            background-image: conic-gradient(var(--border) 25%, transparent 0 50%, var(--border) 0 75%, transparent 0);
            background-size: 16px 16px;
          }
          #svg-wrap { position: relative; background: #ffffff; box-shadow: 0 2px 12px rgba(0,0,0,0.12); line-height: 0; }
          #svg-wrap svg { display: block; user-select: none; }
          #inspector {
            width: 220px; flex-shrink: 0; border-left: 1px solid var(--border); background: var(--surface);
            padding: 10px; overflow-y: auto; display: flex; flex-direction: column; gap: 8px;
          }
          #inspector h4 { margin: 0; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
          .field { display: flex; align-items: center; gap: 6px; }
          .field label { width: 58px; font-size: 11px; color: var(--muted); flex-shrink: 0; }
          .field input {
            flex: 1; min-width: 0; border: 1px solid var(--border); border-radius: 4px; padding: 3px 6px;
            background: var(--bg); color: var(--text); font: 11.5px ui-monospace, Menlo, monospace;
          }
          .empty { color: var(--muted); font-size: 11.5px; line-height: 1.5; }
          #inline-edit {
            position: absolute; display: none; z-index: 10; border: 1.5px solid var(--accent);
            border-radius: 3px; padding: 2px 4px; background: #ffffff; color: #111827; font-size: 14px;
          }
        </style>
        </head>
        <body>
        <div id="app">
          <div id="bar">
            <button data-add="rect">+ Rect</button>
            <button data-add="ellipse">+ Ellipse</button>
            <button data-add="line">+ Line</button>
            <button data-add="text">+ Text</button>
            <span class="sep"></span>
            <button id="btn-dup" disabled>Duplicate</button>
            <button id="btn-fwd" disabled>Forward</button>
            <button id="btn-bwd" disabled>Backward</button>
            <button id="btn-del" disabled>Delete</button>
            <span style="margin-left:auto;color:var(--muted);font-size:11px">Click to select · Drag to move · Double-click text to edit</span>
          </div>
          <div id="main">
            <div id="stage">
              <div id="svg-wrap">
                <input id="inline-edit" type="text" />
              </div>
            </div>
            <aside id="inspector"><div class="empty">Select an element on the canvas to edit its properties.</div></aside>
          </div>
        </div>
        <script>
        (() => {
          const NS = "http://www.w3.org/2000/svg";
          const XLINK = "http://www.w3.org/1999/xlink";
          const ALLOWED_TAGS = new Set([
            "svg","g","rect","circle","ellipse","line","polyline","polygon","path","text","tspan","title","desc",
            "defs","linearGradient","radialGradient","stop","clipPath","mask","pattern","symbol","use","image","marker"
          ]);
          const TEXT_TAGS = new Set(["text","tspan","title","desc"]);
          const ALLOWED_ATTRS = new Set([
            "x","y","x1","y1","x2","y2","cx","cy","r","rx","ry","fx","fy","width","height","d","points","transform",
            "viewBox","preserveAspectRatio","fill","stroke","opacity","stroke-width","stroke-dasharray","stroke-linecap",
            "stroke-linejoin","fill-opacity","stroke-opacity","fill-rule","clip-rule","font-family","font-size","font-weight",
            "font-style","text-anchor","dominant-baseline","letter-spacing","offset","stop-color","stop-opacity",
            "gradientUnits","gradientTransform","spreadMethod","dx","dy","id","clip-path","mask","marker-start",
            "marker-mid","marker-end","patternUnits","patternTransform","clipPathUnits","maskUnits","markerWidth",
            "markerHeight","refX","refY","orient","data-vid","href","rotate","display","visibility"
          ]);
          const GEOM = {
            rect: ["x","y","width","height","rx"],
            ellipse: ["cx","cy","rx","ry"],
            circle: ["cx","cy","r"],
            line: ["x1","y1","x2","y2"],
            text: ["x","y","font-size"],
            image: ["x","y","width","height"],
          };
          const TRANSLATE = /^\\s*translate\\(\\s*([-+]?[\\d.]+(?:e[-+]?\\d+)?)(?:[\\s,]+([-+]?[\\d.]+(?:e[-+]?\\d+)?))?\\s*\\)\\s*/i;
          const DATA_IMG = /^data:image\\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\\s]*$/;
          const ID_RE = /^[A-Za-z_][\\w.:-]*$/;
          const URL_REF = /^url\\(\\s*#([A-Za-z_][\\w.:-]*)\\s*\\)$/i;

          let currentSource = "";
          let currentZoom = "fit";
          let customScale = null;
          let selectedPath = null;
          let svgEl = null;
          let outlineEl = null;
          let drag = null;

          const wrap = document.getElementById("svg-wrap");
          const stage = document.getElementById("stage");
          const inspector = document.getElementById("inspector");
          const inlineEdit = document.getElementById("inline-edit");
          const btnDup = document.getElementById("btn-dup");
          const btnFwd = document.getElementById("btn-fwd");
          const btnBwd = document.getElementById("btn-bwd");
          const btnDel = document.getElementById("btn-del");

          function post(msg) {
            try { window.webkit.messageHandlers.vesperMockup.postMessage(msg); } catch {}
          }

          function parseDoc(src) {
            const doc = new DOMParser().parseFromString(src, "image/svg+xml");
            if (doc.getElementsByTagName("parsererror").length) return null;
            const root = doc.documentElement;
            return root && root.localName === "svg" && root.namespaceURI === NS ? doc : null;
          }

          function serializeDoc(doc) {
            return new XMLSerializer().serializeToString(doc);
          }

          function findByPath(doc, path) {
            let n = doc.documentElement;
            if (!path) return n;
            for (const seg of path.split(".")) {
              const i = Number(seg);
              n = n && Number.isInteger(i) ? (n.childNodes[i] || null) : null;
              if (!n) return null;
            }
            return n && n.nodeType === 1 ? n : null;
          }

          function pathOf(doc, el) {
            const segs = [];
            let n = el;
            while (n !== doc.documentElement) {
              const p = n.parentNode;
              if (!p || p === doc) return null;
              segs.unshift(Array.prototype.indexOf.call(p.childNodes, n));
              n = p;
            }
            return segs.join(".");
          }

          function translateEl(el, dx, dy) {
            dx = Math.round(dx * 2) / 2;
            dy = Math.round(dy * 2) / 2;
            if (!dx && !dy) return;
            const cur = el.getAttribute("transform") || "";
            const m = TRANSLATE.exec(cur);
            let tx = dx, ty = dy, rest = cur.trim();
            if (m) { tx += Number(m[1]); ty += Number(m[2] || 0); rest = cur.slice(m[0].length).trim(); }
            const fmt = (v) => String(+v.toFixed(2) || 0);
            const next = (tx || ty) ? `translate(${fmt(tx)} ${fmt(ty)})${rest ? " " + rest : ""}` : rest;
            if (next) el.setAttribute("transform", next); else el.removeAttribute("transform");
          }

          function textHolder(el) {
            for (const c of el.childNodes) if (c.nodeType === 1 && c.localName === "tspan") return c;
            return el;
          }

          function cleanAttrValue(name, raw) {
            if (raw.replace(/[\\s\\u0000-\\u001f]/g, "").toLowerCase().includes("javascript:")) return null;
            if (name === "id") return ID_RE.test(raw) ? "mk-" + raw : null;
            if (name === "href") {
              if (DATA_IMG.test(raw)) return raw;
              return raw.startsWith("#") && ID_RE.test(raw.slice(1)) ? "#mk-" + raw.slice(1) : null;
            }
            if (/url\\(/i.test(raw)) {
              const m = URL_REF.exec(raw.trim());
              return m ? `url(#mk-${m[1]})` : null;
            }
            return raw;
          }

          function cloneSanitized(srcNode, path, parentTag) {
            if (srcNode.nodeType === 3 || srcNode.nodeType === 4) {
              if (!parentTag || !TEXT_TAGS.has(parentTag) || !srcNode.nodeValue) return null;
              return document.createTextNode(srcNode.nodeValue);
            }
            if (srcNode.nodeType !== 1) return null;
            const tag = srcNode.localName || "";
            if (srcNode.namespaceURI !== NS || !ALLOWED_TAGS.has(tag)) return null;
            const el = document.createElementNS(NS, tag);
            if (path) el.setAttribute("data-path", path);
            for (const a of Array.from(srcNode.attributes || [])) {
              const key = !a.namespaceURI ? a.name : (a.namespaceURI === XLINK && a.localName === "href" ? "href" : null);
              if (!key || !ALLOWED_ATTRS.has(key)) continue;
              const cleaned = cleanAttrValue(key, a.value);
              if (cleaned !== null) el.setAttribute(key, cleaned);
            }
            for (let i = 0; i < srcNode.childNodes.length; i++) {
              const c = cloneSanitized(srcNode.childNodes[i], path ? `${path}.${i}` : String(i), tag);
              if (c) el.appendChild(c);
            }
            return el;
          }

          function viewBoxOf(el) {
            const vb = (el.getAttribute("viewBox") || "").trim().split(/[\\s,]+/).map(Number);
            if (vb.length === 4 && vb.every(Number.isFinite) && vb[2] > 0 && vb[3] > 0) return { x: vb[0], y: vb[1], w: vb[2], h: vb[3] };
            const w = parseFloat(el.getAttribute("width") || "1280") || 1280;
            const h = parseFloat(el.getAttribute("height") || "800") || 800;
            return { x: 0, y: 0, w, h };
          }

          function currentScaleFor(vb) {
            if (customScale !== null) return customScale;
            if (currentZoom === "fit") {
              const availW = Math.max(240, stage.clientWidth - 40);
              const availH = Math.max(200, stage.clientHeight - 40);
              return Math.min(availW / vb.w, availH / vb.h, 1);
            }
            return currentZoom === "200" ? 2 : 1;
          }

          function applyZoom() {
            if (!svgEl) return;
            const vb = viewBoxOf(svgEl);
            const scale = currentScaleFor(vb);
            svgEl.style.width = Math.round(vb.w * scale) + "px";
            svgEl.style.height = Math.round(vb.h * scale) + "px";
            updateOutline();
          }

          stage.addEventListener("wheel", (e) => {
            if (!(e.metaKey || e.ctrlKey) || !svgEl) return;
            e.preventDefault();
            const vb = viewBoxOf(svgEl);
            const scale = e.deltaMode === 1 ? 16 : 1;
            const expArg = Math.max(-0.5, Math.min(0.5, -e.deltaY * scale * 0.0035));
            const next = Math.max(0.1, Math.min(8, currentScaleFor(vb) * Math.exp(expArg)));
            customScale = next;
            applyZoom();
          }, { passive: false });

          function updateOutline() {
            if (!outlineEl || !svgEl) return;
            if (!selectedPath) { outlineEl.style.display = "none"; return; }
            const target = svgEl.querySelector(`[data-path="${selectedPath}"]`);
            if (!target || typeof target.getBBox !== "function") { outlineEl.style.display = "none"; return; }
            try {
              const b = target.getBBox();
              outlineEl.setAttribute("x", String(b.x - 2));
              outlineEl.setAttribute("y", String(b.y - 2));
              outlineEl.setAttribute("width", String(Math.max(4, b.width + 4)));
              outlineEl.setAttribute("height", String(Math.max(4, b.height + 4)));
              const t = target.getAttribute("transform");
              if (t) outlineEl.setAttribute("transform", t); else outlineEl.removeAttribute("transform");
              outlineEl.style.display = "";
            } catch {
              outlineEl.style.display = "none";
            }
          }

          function mutate(fn, key) {
            const doc = parseDoc(currentSource);
            if (!doc) return;
            const el = selectedPath ? findByPath(doc, selectedPath) : null;
            const nextSel = fn(doc, el);
            if (nextSel === false) return;
            if (typeof nextSel === "string" || nextSel === null) selectedPath = nextSel;
            currentSource = serializeDoc(doc);
            render();
            post({ type: "commit", source: currentSource, key: key || null });
          }

          function renderInspector(doc) {
            const el = doc && selectedPath ? findByPath(doc, selectedPath) : null;
            const hasSel = !!el && el !== doc.documentElement;
            btnDup.disabled = !hasSel;
            btnFwd.disabled = !hasSel;
            btnBwd.disabled = !hasSel;
            btnDel.disabled = !hasSel;
            inspector.innerHTML = "";
            if (!hasSel) {
              inspector.innerHTML = '<div class="empty">Select an element on the canvas to edit its properties.</div>';
              return;
            }
            const h = document.createElement("h4");
            h.textContent = "<" + el.localName + ">";
            inspector.appendChild(h);

            const attrs = [...(GEOM[el.localName] || []), "fill", "stroke", "stroke-width", "opacity"];
            if (el.localName === "text") {
              addField("text", textHolder(el).textContent || "", (v) => {
                mutate((d, target) => { if (!target) return false; textHolder(target).textContent = v; }, "text:" + selectedPath);
              });
            }
            for (const name of attrs) {
              addField(name, el.getAttribute(name) || "", (v) => {
                mutate((d, target) => {
                  if (!target) return false;
                  if (v === "") target.removeAttribute(name); else target.setAttribute(name, v);
                }, `attr:${selectedPath}:${name}`);
              });
            }
          }

          function addField(label, val, onChange) {
            const row = document.createElement("div");
            row.className = "field";
            const lbl = document.createElement("label");
            lbl.textContent = label;
            const inp = document.createElement("input");
            inp.value = val;
            inp.addEventListener("input", () => onChange(inp.value));
            row.append(lbl, inp);
            inspector.appendChild(row);
          }

          function render() {
            const doc = parseDoc(currentSource);
            while (wrap.firstChild && wrap.firstChild !== inlineEdit) wrap.removeChild(wrap.firstChild);
            if (!doc) { svgEl = null; outlineEl = null; renderInspector(null); return; }
            svgEl = cloneSanitized(doc.documentElement, "", null);
            if (!svgEl) return;
            outlineEl = document.createElementNS(NS, "rect");
            outlineEl.setAttribute("fill", "none");
            outlineEl.setAttribute("stroke", "#3b82f6");
            outlineEl.setAttribute("stroke-width", "1.5");
            outlineEl.setAttribute("stroke-dasharray", "4 2");
            outlineEl.setAttribute("pointer-events", "none");
            outlineEl.style.display = "none";
            svgEl.appendChild(outlineEl);
            wrap.insertBefore(svgEl, inlineEdit);
            attachCanvasEvents();
            applyZoom();
            renderInspector(doc);
          }

          function attachCanvasEvents() {
            if (!svgEl) return;
            svgEl.addEventListener("pointerdown", (e) => {
              inlineEdit.style.display = "none";
              const target = e.target && e.target.closest ? e.target.closest("[data-path]") : null;
              if (!target || target === svgEl) { selectedPath = null; updateOutline(); renderInspector(parseDoc(currentSource)); return; }
              selectedPath = target.getAttribute("data-path");
              updateOutline();
              renderInspector(parseDoc(currentSource));
              const ctm = svgEl.getScreenCTM();
              if (!ctm) return;
              const inv = ctm.inverse();
              drag = { path: selectedPath, target, inv, sx: e.clientX, sy: e.clientY, orig: target.getAttribute("transform") || "", dx: 0, dy: 0, moved: false };
              svgEl.setPointerCapture(e.pointerId);
            });
            svgEl.addEventListener("pointermove", (e) => {
              if (!drag) return;
              const p0 = new DOMPoint(drag.sx, drag.sy).matrixTransform(drag.inv);
              const p1 = new DOMPoint(e.clientX, e.clientY).matrixTransform(drag.inv);
              const dx = p1.x - p0.x, dy = p1.y - p0.y;
              if (!drag.moved && Math.hypot(dx, dy) < 2) return;
              drag.moved = true; drag.dx = dx; drag.dy = dy;
              const next = `translate(${dx.toFixed(1)} ${dy.toFixed(1)})${drag.orig ? " " + drag.orig : ""}`;
              drag.target.setAttribute("transform", next);
              updateOutline();
            });
            svgEl.addEventListener("pointerup", () => {
              if (!drag) return;
              const d = drag; drag = null;
              if (d.moved) mutate((_, el) => { if (!el) return false; translateEl(el, d.dx, d.dy); });
            });
            svgEl.addEventListener("dblclick", (e) => {
              const target = e.target && e.target.closest ? e.target.closest("[data-path]") : null;
              if (!target || target.localName !== "text") return;
              const path = target.getAttribute("data-path");
              const rect = target.getBoundingClientRect();
              const wrapRect = wrap.getBoundingClientRect();
              inlineEdit.style.left = Math.max(0, rect.left - wrapRect.left - 4) + "px";
              inlineEdit.style.top = Math.max(0, rect.top - wrapRect.top - 4) + "px";
              inlineEdit.style.width = Math.max(120, rect.width + 24) + "px";
              inlineEdit.value = target.textContent || "";
              inlineEdit.style.display = "block";
              inlineEdit.focus();
              inlineEdit.select();
              inlineEdit.onkeydown = (ke) => {
                if (ke.key === "Enter") {
                  inlineEdit.style.display = "none";
                  mutate((d) => { const el = findByPath(d, path); if (!el) return false; textHolder(el).textContent = inlineEdit.value; });
                } else if (ke.key === "Escape") {
                  inlineEdit.style.display = "none";
                }
              };
              inlineEdit.onblur = () => {
                if (inlineEdit.style.display === "none") return;
                inlineEdit.style.display = "none";
                mutate((d) => { const el = findByPath(d, path); if (!el) return false; textHolder(el).textContent = inlineEdit.value; });
              };
            });
          }

          document.querySelectorAll("[data-add]").forEach((btn) => {
            btn.addEventListener("click", () => {
              const kind = btn.getAttribute("data-add");
              mutate((doc) => {
                const vb = viewBoxOf(doc.documentElement);
                const cx = Math.round(vb.x + vb.w / 2), cy = Math.round(vb.y + vb.h / 2);
                const el = doc.createElementNS(NS, kind);
                if (kind === "rect") { el.setAttribute("x", cx - 80); el.setAttribute("y", cy - 50); el.setAttribute("width", "160"); el.setAttribute("height", "100"); el.setAttribute("rx", "6"); el.setAttribute("fill", "#F3F4F6"); el.setAttribute("stroke", "#9CA3AF"); }
                else if (kind === "ellipse") { el.setAttribute("cx", cx); el.setAttribute("cy", cy); el.setAttribute("rx", "80"); el.setAttribute("ry", "50"); el.setAttribute("fill", "#F3F4F6"); el.setAttribute("stroke", "#9CA3AF"); }
                else if (kind === "line") { el.setAttribute("x1", cx - 80); el.setAttribute("y1", cy); el.setAttribute("x2", cx + 80); el.setAttribute("y2", cy); el.setAttribute("stroke", "#9CA3AF"); el.setAttribute("stroke-width", "2"); }
                else { el.setAttribute("x", cx - 24); el.setAttribute("y", cy); el.setAttribute("fill", "#111827"); el.setAttribute("font-size", "16"); el.setAttribute("font-family", "sans-serif"); el.textContent = "Text"; }
                doc.documentElement.appendChild(doc.createTextNode("\\n  "));
                doc.documentElement.appendChild(el);
                return pathOf(doc, el);
              });
            });
          });

          btnDup.addEventListener("click", () => mutate((doc, el) => {
            if (!el || !el.parentNode) return false;
            const copy = el.cloneNode(true);
            copy.removeAttribute("id"); copy.removeAttribute("data-vid");
            translateEl(copy, 16, 16);
            el.parentNode.insertBefore(copy, el.nextSibling);
            return pathOf(doc, copy);
          }));
          btnFwd.addEventListener("click", () => mutate((doc, el) => {
            if (!el || !el.parentNode) return false;
            let next = el.nextSibling; while (next && next.nodeType !== 1) next = next.nextSibling;
            if (!next) return false;
            el.parentNode.insertBefore(el, next.nextSibling);
            return pathOf(doc, el);
          }));
          btnBwd.addEventListener("click", () => mutate((doc, el) => {
            if (!el || !el.parentNode) return false;
            let prev = el.previousSibling; while (prev && prev.nodeType !== 1) prev = prev.previousSibling;
            if (!prev) return false;
            el.parentNode.insertBefore(el, prev);
            return pathOf(doc, el);
          }));
          btnDel.addEventListener("click", () => mutate((_, el) => {
            if (!el || !el.parentNode) return false;
            el.parentNode.removeChild(el);
            return null;
          }));

          window.__vesperSetSource = (src) => { if (src !== currentSource) { currentSource = src; render(); } };
          window.__vesperSetZoom = (z) => { currentZoom = z; customScale = null; applyZoom(); };
          window.__vesperSetTheme = (dark) => { document.documentElement.dataset.theme = dark ? "dark" : "light"; };
          window.addEventListener("resize", applyZoom);
          post({ type: "ready" });
        })();
        </script>
        </body>
        </html>
        """
    }
}
