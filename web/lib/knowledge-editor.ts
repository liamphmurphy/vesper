import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection, type Selection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import type { Node as PMNode } from "@tiptap/pm/model";
import { defaultLabel, parseWikiLinks } from "./wikilinks";

// Live preview of Obsidian syntax in the Docs editor: [[links]] and ![[embeds]]
// read as titles and inline previews, #tags as pills and ^block ids fade.
// The Markdown stays exactly as typed. ⌘/Ctrl-click a link to open it.

const PATTERN = /(!?\[\[[^\]\n]+\]\])|(?<![\w/#])(#[\p{L}\p{N}_/-]*\p{L}[\p{L}\p{N}_/-]*)|(\s\^[A-Za-z0-9-]+\s*$)/gu;

function decorate(doc: PMNode, selection: Selection, focused: boolean, opts: KnowledgeSyntaxOptions): DecorationSet {
  const out: Decoration[] = [];
  doc.descendants((node, pos, parent) => {
    if (!node.isText || !node.text) return;
    if (parent?.type.name === "codeBlock" || node.marks.some((m) => m.type.name === "code")) return;
    for (const m of node.text.matchAll(PATTERN)) {
      const from = pos + (m.index ?? 0);
      const to = from + m[0].length;
      if (m[1]) {
        const raw = m[1];
        const ref = parseWikiLinks(raw)[0];
        if (!ref) continue;
        const cls = ref.embed ? "kn-embed" : opts.isResolved(ref.target) ? "kn-link" : "kn-link kn-unresolved";
        const editing = focused && selection.from <= to && selection.to >= from;
        const preview = ref.embed ? opts.preview(ref.raw) : undefined;
        if (preview) {
          out.push(
            Decoration.widget(to, () => preview.mount(), {
              key: `${from}:${preview.key}`,
              side: 1,
              destroy: preview.destroy,
              ignoreSelection: true,
              stopEvent: preview.stopEvent,
            }),
          );
        } else if (!ref.embed && !editing) {
          const label = defaultLabel({ ...ref, target: opts.title(ref.target) ?? ref.target });
          out.push(Decoration.widget(from, (view) => {
            const el = document.createElement("span");
            el.className = cls;
            el.textContent = label;
            el.setAttribute("data-target", raw);
            el.title = ref.target;
            el.addEventListener("mousedown", (event) => {
              if (event.metaKey || event.ctrlKey) return;
              event.preventDefault();
              view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from + 2)));
              view.focus();
            });
            return el;
          }, { key: `${from}:${raw}:${label}:${cls}`, side: -1 }));
        }
        if (!editing && (preview || !ref.embed)) {
          out.push(Decoration.inline(from, to, { class: "kn-source-hidden" }));
          continue;
        }
        out.push(Decoration.inline(from, to, { class: cls, "data-target": m[1] }));
      } else if (m[2]) out.push(Decoration.inline(from, to, { class: "kn-tag" }));
      else if (m[3]) out.push(Decoration.inline(from, to, { class: "kn-block" }));
    }
  });
  return DecorationSet.create(doc, out);
}

export type KnowledgeSyntaxOptions = {
  /** Whether a link target names a page that exists; unresolved links fade. */
  isResolved: (target: string) => boolean;
  title: (target: string) => string | undefined;
  /** Resolved previews are mounted only by ProseMirror, then disposed with the widget. */
  preview: (raw: string) => { key: string; mount: () => HTMLElement; destroy: (node: Node) => void; stopEvent?: (event: Event) => boolean } | undefined;
  /** Refresh previews after the server resolves an embed added by an edit. */
  subscribe: (refresh: () => void) => () => void;
  /** ⌘/Ctrl-click on a [[link]] or ![[embed]], with the link as written. */
  onOpen: (raw: string) => void;
};

export const KnowledgeSyntax = Extension.create<KnowledgeSyntaxOptions>({
  name: "knowledgeSyntax",
  addOptions() {
    return { isResolved: () => true, title: () => undefined, preview: () => undefined, subscribe: () => () => {}, onOpen: () => {} };
  },
  addProseMirrorPlugins() {
    const opts = this.options;
    let focused = false;
    const key = new PluginKey("knowledgeSyntax");
    return [
      new Plugin({
        key,
        state: {
          init: (_, state) => decorate(state.doc, state.selection, focused, opts),
          apply: (tr, old) => (tr.docChanged || tr.selectionSet || tr.getMeta(key) ? decorate(tr.doc, tr.selection, focused, opts) : old),
        },
        view(view) {
          const unsubscribe = opts.subscribe(() => view.dispatch(view.state.tr.setMeta(key, true)));
          return { destroy: unsubscribe };
        },
        props: {
          handleDOMEvents: {
            focus(view) {
              focused = true;
              view.dispatch(view.state.tr.setMeta(key, true));
              return false;
            },
            blur(view) {
              focused = false;
              view.dispatch(view.state.tr.setMeta(key, true));
              return false;
            },
          },
          decorations(state) {
            return key.getState(state);
          },
          handleClick(_view, _pos, event) {
            const el = (event.target as HTMLElement | null)?.closest?.("[data-target]");
            if (!el || !(event.metaKey || event.ctrlKey)) return false;
            opts.onOpen(el.getAttribute("data-target") ?? "");
            return true;
          },
        },
      }),
    ];
  },
});

/** The page a [[link]] as written points at: its target before # and |. */
export function linkTarget(raw: string): { target: string; anchor?: string } {
  const inner = raw.replace(/^!?\[\[/, "").replace(/\]\]$/, "").split("|")[0];
  const [target, anchor] = inner.split("#");
  return { target: target.trim(), anchor: anchor?.trim() || undefined };
}
