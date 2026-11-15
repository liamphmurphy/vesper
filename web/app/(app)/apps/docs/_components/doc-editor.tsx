"use client";

import { EditorContent, useEditor, useEditorState, type Editor } from "@tiptap/react";
import type { AnyExtension } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import { Placeholder } from "@tiptap/extensions";
import type { EditorView } from "@tiptap/pm/view";
import { forwardRef, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { docExtensions, parseDoc, serializeDoc } from "@/lib/doc-markdown";
import { setHighlight } from "@/lib/canvas-dom";
import { cx } from "@/lib/cx";
import { ApiError } from "@/lib/api/client";

export type SaveState = "saved" | "unsaved" | "saving" | "conflict" | "error";

/** A passage the person picked: its text and roughly where it is (0 to 1 down the document). */
export type Picked = { quote: string; at: number };

export type DocEditorHandle = {
  /** The text currently visible, including edits waiting to save. */
  getMarkdown: () => string | undefined;
  /** Saves pending edits now, so a comment or request sees them. */
  flush: () => Promise<void>;
  /** After a conflict: write the person's text over `seq`, or take the current version. */
  keepMine: (seq: number) => Promise<void>;
  takeTheirs: (seq: number, body: string) => void;
};

/** Whether two Markdown texts are the same document as the editor writes it. */
function same(md: string, saved: string): boolean {
  if (md.trim() === saved.trim()) return true;
  try {
    return md.trim() === serializeDoc(parseDoc(saved)).trim();
  } catch {
    return false;
  }
}

/** How long typing has to pause before the document saves. */
const SAVE_AFTER_MS = 1500;

const QUICK = [
  ["Shorter", "Make this shorter."],
  ["Rewrite", "Rewrite this passage."],
] as const;

/**
 * The document as a page you type on. It reads and writes the canvas's
 * Markdown, saving a version when typing pauses; while the persona's turn
 * runs it is read-only, so an edit never lands under the person's cursor.
 */
export const DocEditor = forwardRef<DocEditorHandle, {
  body: string;
  seq: number;
  locked: boolean;
  persona: string;
  highlights: { quote: string; active: boolean }[];
  onSave: (body: string, baseSeq: number) => Promise<number>;
  onState: (s: SaveState, message?: string) => void;
  onAsk: (instruction: string, after: string) => void;
  onPick: (p: Picked, message?: string) => void;
  /** More editor behaviour, e.g. Knowledge's live [[link]] preview. Read once, on mount. */
  extensions?: AnyExtension[];
  /** What an empty first line invites; Docs use it for the title. */
  firstLine?: string;
}>(function DocEditor({ body, seq, locked, persona, highlights, onSave, onState, onAsk, onPick, extensions = [], firstLine = "Title" }, ref) {
  // What the editor's text was last saved (or loaded) as.
  const based = useRef({ seq, body });
  // Edits since the last save; a save only clears the ones it carried.
  const edits = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const inflight = useRef<Promise<void>>(Promise.resolve());
  const conflicted = useRef(false);
  const props = useRef({ onSave, onState, onAsk, persona });
  useLayoutEffect(() => {
    props.current = { onSave, onState, onAsk, persona };
  });
  const first = persona.split(/\s+/)[0] || persona;
  const ed = useRef<Editor | null>(null);

  // Options never change after the first render: the editor would otherwise
  // re-apply its state on every render, and a click landing in between loses
  // its place. Everything that changes is read through refs.
  const [options] = useState(() => ({
    immediatelyRender: false,
    extensions: [...docExtensions(), Markdown, ...extensions, Placeholder.configure({ placeholder: ({ pos }: { pos: number }) => (pos === 0 ? firstLine : `Write, or type @${props.current.persona.split(/\s+/)[0]} and what you'd like`) })],
    content: body,
    contentType: "markdown" as const,
    editable: !locked,
    editorProps: {
      attributes: { "aria-label": "Document", "data-testid": "doc-editor", spellcheck: "true" },
      handleKeyDown: (view: EditorView, e: KeyboardEvent) => (e.key === "Enter" && !e.shiftKey ? mention(view) : false),
    },
    onCreate: ({ editor: made }: { editor: Editor }) => {
      ed.current = made;
    },
    onUpdate: ({ editor: e }: { editor: Editor }) => {
      // Opening a document can tidy it (a paragraph after a closing table);
      // that isn't the person's edit and saves nothing.
      if (!edits.current && same(e.getMarkdown(), based.current.body)) return;
      edits.current++;
      props.current.onState("unsaved");
      clearTimeout(timer.current);
      timer.current = setTimeout(() => void save(), SAVE_AFTER_MS);
    },
  }));
  const editor = useEditor(options);

  // "@Maya tighten this section" on a line of its own, then Enter: the line
  // goes, and the persona gets the instruction with where it was.
  function mention(view: EditorView): boolean {
    const { $from, empty } = view.state.selection;
    if (!empty || $from.parent.type.name !== "paragraph") return false;
    const m = $from.parent.textContent.match(/^@(\S+)\s+([\s\S]+)$/);
    const name = props.current.persona.split(/\s+/)[0].toLowerCase();
    if (!m || m[1].toLowerCase().replace(/[.,:;!?]+$/, "") !== name) return false;
    const before = $from.before();
    let after = "";
    view.state.doc.nodesBetween(0, before, (n) => {
      if (n.isTextblock && n.textContent.trim()) after = n.textContent.trim();
    });
    view.dispatch(view.state.tr.delete(before, $from.after()));
    props.current.onAsk(m[2].trim(), after);
    return true;
  }

  function save(): Promise<void> {
    clearTimeout(timer.current);
    inflight.current = inflight.current.then(async () => {
      const editor = ed.current;
      if (!editor || !edits.current || conflicted.current) return;
      const carried = edits.current;
      const md = editor.getMarkdown();
      if (same(md, based.current.body)) {
        edits.current -= carried;
        if (!edits.current) props.current.onState("saved");
        return;
      }
      props.current.onState("saving");
      try {
        const next = await props.current.onSave(md, based.current.seq);
        based.current = { seq: next, body: md };
        edits.current -= carried;
        props.current.onState(edits.current ? "unsaved" : "saved");
        if (edits.current) timer.current = setTimeout(() => void save(), SAVE_AFTER_MS);
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          conflicted.current = true;
          props.current.onState("conflict");
        } else props.current.onState("error", e instanceof Error ? e.message : undefined);
      }
    });
    return inflight.current;
  }

  useImperativeHandle(ref, () => ({
    getMarkdown: () => ed.current?.getMarkdown(),
    flush: save,
    keepMine: async (latest) => {
      conflicted.current = false;
      based.current = { ...based.current, seq: latest };
      edits.current = Math.max(edits.current, 1);
      await save();
    },
    takeTheirs: (latest, text) => {
      clearTimeout(timer.current);
      conflicted.current = false;
      edits.current = 0;
      ed.current?.commands.setContent(text, { contentType: "markdown", emitUpdate: false });
      based.current = { seq: latest, body: text };
      props.current.onState("saved");
    },
  }));

  // A version from elsewhere (the persona, a review, another tab) replaces
  // the text, unless the person has edits it would throw away.
  useEffect(() => {
    if (!editor || seq === based.current.seq) return;
    if (edits.current) {
      if (seq > based.current.seq) {
        conflicted.current = true;
        props.current.onState("conflict");
      }
      return;
    }
    editor.commands.setContent(body, { contentType: "markdown", emitUpdate: false });
    based.current = { seq, body };
  }, [editor, seq, body]);

  useEffect(() => {
    editor?.setEditable(!locked, false);
  }, [editor, locked]);

  // Leaving the page saves what's pending.
  useEffect(() => {
    const leave = (e: BeforeUnloadEvent) => {
      if (!edits.current) return;
      void save();
      e.preventDefault();
    };
    window.addEventListener("beforeunload", leave);
    return () => {
      window.removeEventListener("beforeunload", leave);
      if (edits.current) void save();
    };
    // save reads refs only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editor]);

  useCommentHighlights(editor, highlights);

  return (
    <div className="flex min-h-0 flex-col">
      {editor && !locked && <Toolbar editor={editor} disabled={false} />}
      <div className="relative">
        <div className="doc-page mx-auto w-full max-w-[720px] px-8 pb-24 pt-10 max-sm:px-5">
          <EditorContent editor={editor} />
        </div>
        {editor && !locked && <SelectionMenu editor={editor} persona={first} onPick={onPick} />}
      </div>
    </div>
  );
});

function Toolbar({ editor, disabled }: { editor: Editor; disabled: boolean }) {
  const s = useEditorState({
    editor,
    selector: ({ editor: e }) => ({
      h1: e.isActive("heading", { level: 1 }),
      h2: e.isActive("heading", { level: 2 }),
      h3: e.isActive("heading", { level: 3 }),
      bold: e.isActive("bold"),
      italic: e.isActive("italic"),
      strike: e.isActive("strike"),
      code: e.isActive("code"),
      link: e.isActive("link"),
      bullet: e.isActive("bulletList"),
      ordered: e.isActive("orderedList"),
      task: e.isActive("taskList"),
      quote: e.isActive("blockquote"),
      block: e.isActive("codeBlock"),
      undo: e.can().undo(),
      redo: e.can().redo(),
    }),
  });
  const run = () => editor.chain().focus();
  const link = () => {
    const prev = editor.getAttributes("link").href as string | undefined;
    const href = window.prompt("Link address", prev ?? "https://");
    if (href === null) return;
    if (!href.trim()) run().extendMarkRange("link").unsetLink().run();
    else run().extendMarkRange("link").setLink({ href: href.trim() }).run();
  };
  const b = (label: string, on: boolean, act: () => void, glyph: ReactNode, off = false) => (
    <button
      type="button"
      aria-label={label}
      title={label}
      aria-pressed={on}
      disabled={disabled || off}
      onMouseDown={(e) => e.preventDefault()}
      onClick={act}
      className={cx("grid h-7 min-w-7 place-items-center rounded-md px-1.5 text-13 text-fg-secondary transition-colors hover:bg-hover hover:text-fg disabled:opacity-40", on && "bg-selected text-fg")}
    >
      {glyph}
    </button>
  );
  const sep = <span aria-hidden className="mx-1 h-[18px] w-px bg-border-strong" />;
  return (
    <div role="toolbar" aria-label="Formatting" className="sticky top-0 z-10 flex flex-wrap items-center gap-0.5 border-b border-border-subtle bg-bg/95 px-4 py-1.5 backdrop-blur">
      {b("Undo", false, () => run().undo().run(), "↶", !s.undo)}
      {b("Redo", false, () => run().redo().run(), "↷", !s.redo)}
      {sep}
      {b("Title", s.h1, () => run().toggleHeading({ level: 1 }).run(), "H1")}
      {b("Heading", s.h2, () => run().toggleHeading({ level: 2 }).run(), "H2")}
      {b("Subheading", s.h3, () => run().toggleHeading({ level: 3 }).run(), "H3")}
      {sep}
      {b("Bold", s.bold, () => run().toggleBold().run(), <b>B</b>)}
      {b("Italic", s.italic, () => run().toggleItalic().run(), <i className="font-serif">I</i>)}
      {b("Strikethrough", s.strike, () => run().toggleStrike().run(), <s>S</s>)}
      {b("Inline code", s.code, () => run().toggleCode().run(), <span className="font-mono text-12">{"<>"}</span>)}
      {b("Link", s.link, link, "🔗")}
      {sep}
      {b("Bulleted list", s.bullet, () => run().toggleBulletList().run(), "•≡")}
      {b("Numbered list", s.ordered, () => run().toggleOrderedList().run(), "1≡")}
      {b("Checklist", s.task, () => run().toggleTaskList().run(), "☑")}
      {b("Quote", s.quote, () => run().toggleBlockquote().run(), "❝")}
      {b("Code block", s.block, () => run().toggleCodeBlock().run(), <span className="font-mono text-12">{"{ }"}</span>)}
      {b("Table", false, () => run().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run(), "▦")}
      {b("Divider", false, () => run().setHorizontalRule().run(), "―")}
    </div>
  );
}

/** Over a selection: comment on it, or ask the persona to change it. */
function SelectionMenu({ editor, persona, onPick }: { editor: Editor; persona: string; onPick: (p: Picked, message?: string) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [asking, setAsking] = useState("");
  const [open, setOpen] = useState(false);
  const sel = useEditorState({
    editor,
    selector: ({ editor: e }) => {
      const { from, to, empty } = e.state.selection;
      return { from, to, empty, focused: e.isFocused };
    },
  });
  const [pos, setPos] = useState<{ top: number; left: number }>();
  useLayoutEffect(() => {
    const host = box.current?.parentElement;
    if (sel.empty || !host) {
      setPos(undefined);
      setOpen(false);
      setAsking("");
      return;
    }
    const a = editor.view.coordsAtPos(sel.from);
    const o = host.getBoundingClientRect();
    setPos({ top: a.top - o.top - 42, left: Math.max(8, Math.min(a.left - o.left, o.width - 360)) });
  }, [editor, sel.from, sel.to, sel.empty]);
  const picked = (): Picked => ({ quote: editor.state.doc.textBetween(sel.from, sel.to, " ").trim(), at: sel.from / Math.max(1, editor.state.doc.content.size) });
  const item = "rounded-md px-2 py-1 text-13 text-fg-2 hover:bg-hover hover:text-fg";
  const visible = !!pos && (sel.focused || open);
  return (
    <div ref={box} data-testid="doc-selection-menu" hidden={!visible} style={pos} className="absolute z-20 flex items-center gap-0.5 rounded-lg border border-border-strong bg-surface-raised p-1 shadow-[var(--shadow-float)]" onMouseDown={(e) => !(e.target instanceof HTMLInputElement) && e.preventDefault()}>
      {open ? (
        <form
          className="flex items-center gap-1"
          onSubmit={(e) => {
            e.preventDefault();
            if (!asking.trim()) return;
            onPick(picked(), asking.trim());
            setOpen(false);
            setAsking("");
          }}
        >
          <input autoFocus aria-label={`Ask ${persona} about this`} value={asking} onChange={(e) => setAsking(e.target.value)} onKeyDown={(e) => e.key === "Escape" && setOpen(false)} placeholder={`Ask ${persona} to…`} className="h-7 w-[240px] rounded-md border border-border bg-surface-sunken px-2 text-13 text-fg focus:border-accent focus:outline-none" />
          <button type="submit" className={cx(item, "font-semibold text-accent")}>Send</button>
        </form>
      ) : (
        <>
          <button type="button" className={item} onClick={() => onPick(picked())}>Comment</button>
          {QUICK.map(([label, message]) => (
            <button key={label} type="button" className={item} onClick={() => onPick(picked(), message)}>{label}</button>
          ))}
          <button type="button" className={cx(item, "font-semibold text-accent")} onClick={() => setOpen(true)}>✦ Ask {persona}…</button>
        </>
      )}
    </div>
  );
}

/** Text with Markdown's inline syntax taken out, as the editor shows it. */
const plain = (md: string) => md.replace(/\]\([^)\n]*\)/g, "").replace(/[*_~`[\]]/g, "").replace(/\s+/g, " ").trim();

/** Where some shown text is in the editor, searched block by block. */
function findText(editor: Editor, text: string): Range | undefined {
  const want = plain(text).slice(0, 80);
  if (!want) return undefined;
  let found: Range | undefined;
  editor.state.doc.descendants((node, pos) => {
    if (found) return false;
    if (!node.isTextblock) return true;
    let s = "";
    const at: number[] = [];
    node.forEach((child, offset) => {
      const t = child.isText ? child.text ?? "" : " ";
      for (let i = 0; i < t.length; i++) at.push(pos + 1 + offset + i);
      s += t;
    });
    const i = s.replace(/\s/g, " ").indexOf(want);
    if (i < 0) return false;
    const from = editor.view.domAtPos(at[i]);
    const to = editor.view.domAtPos(at[i + want.length - 1] + 1);
    const r = document.createRange();
    r.setStart(from.node, from.offset);
    r.setEnd(to.node, to.offset);
    found = r;
    return false;
  });
  return found;
}

/** Comments' passages, painted over the editor with the canvas's highlight styles. */
function useCommentHighlights(editor: Editor | null, highlights: { quote: string; active: boolean }[]) {
  const spec = JSON.stringify(highlights);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!editor) return;
    const bump = () => setTick((t) => t + 1);
    editor.on("update", bump);
    return () => void editor.off("update", bump);
  }, [editor]);
  useLayoutEffect(() => {
    if (!editor) return;
    const list = JSON.parse(spec) as { quote: string; active: boolean }[];
    const ranges = (xs: typeof list) => xs.flatMap((h) => findText(editor, h.quote) ?? []);
    setHighlight("canvas-comment", ranges(list));
    setHighlight("canvas-comment-active", ranges(list.filter((h) => h.active)));
  }, [editor, spec, tick]);
  useLayoutEffect(() => () => {
    setHighlight("canvas-comment", []);
    setHighlight("canvas-comment-active", []);
  }, []);
}
