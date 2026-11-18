"use client";

import Link from "next/link";
import { createPortal } from "react-dom";
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { useCanvasActions, useCanvasComments, useChatCanvas, useChatCanvases } from "@/lib/api/canvas-hooks";
import { useChatMessages, useSendChatMessage } from "@/lib/api/hooks";
import type { Schemas } from "@/lib/api/client";
import { rangeToSource, setHighlight, sourceOffsetAt, sourceToRanges } from "@/lib/canvas-dom";
import { cx } from "@/lib/cx";
import { diffLines } from "@/lib/diff";
import { sanitizeSvg } from "@/lib/svg-sanitize";
import { parseSvg } from "@/lib/svg-edit";
import { useCanvasPanel } from "@/lib/use-canvas-panel";
import { CodeFence } from "@/components/domain/code-fence";
import type { Slot } from "@/lib/canvas-source";
import { Markdown, MarkdownSlots } from "@/components/domain/markdown";
import { MockupCanvas, renderNode, useSourceHistory, viewBoxOf } from "@/components/domain/mockup-canvas";
import { svgSize } from "@/lib/mockup-review";
import { Button, IconButton } from "@/components/ui/button";
import { CanvasBoard } from "./canvas-board";
import { LoadingLines } from "@/components/ui/loading";

type Canvas = Schemas["ChatCanvas"];
type Comment = Schemas["ChatCanvasComment"];
type Actions = ReturnType<typeof useCanvasActions>;
type View = "preview" | "changes" | "source" | "edit";
/** What a new comment will be on. */
export type Target = { kind: "text"; start: number; end: number; quote: string } | { kind: "svg"; vid: string; point: { x: number; y: number }; label: string };
type Toolbar = { start: number; end: number; quote: string; top: number; left: number };

/** Width of a document page on the fullscreen board. */
const TEXT_PAGE = 820;

const QUICK = [
  ["Rewrite", "Rewrite this passage."],
  ["Shorter", "Make this shorter."],
  ["Explain", "Explain this passage."],
] as const;

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** The chat's canvases and the jump to the newest card (or fullscreen when it has none): the header button and its native twin. */
export function useCanvasEntry(chatId: string, live: boolean) {
  const panel = useCanvasPanel();
  // Designs have their own cards and open beside the chat.
  const canvases = (useChatCanvases(chatId, live).data?.canvases ?? []).filter((c) => c.kind !== "design");
  const go = () => {
    const card = Array.from(document.querySelectorAll<HTMLElement>("[data-canvas-card]")).at(-1);
    const id = card?.dataset.canvasCard;
    if (card && id) {
      panel.show(id);
      card.scrollIntoView({ block: "nearest", behavior: "smooth" });
    } else if (canvases.length) panel.openFull(canvases[canvases.length - 1].id);
  };
  return { count: canvases.length, go };
}

/** Header entry point, once the chat has a canvas: goes to the newest card, or fullscreen if it has none. */
export function CanvasButton({ chatId, live }: { chatId: string; live: boolean }) {
  const { count, go } = useCanvasEntry(chatId, live);
  if (!count) return null;
  return (
    <button type="button" aria-label={`Canvas, ${count} open`} onClick={go} className="inline-flex h-[30px] flex-none items-center gap-1.5 rounded-md border border-btn-secondary-border bg-btn-secondary px-3 text-13 text-fg transition-colors hover:bg-hover">
      Canvas
      <span className="text-fg-tertiary">{count}</span>
    </button>
  );
}

function useParsedSvg(source: string) {
  const prefix = `cv-${useId().replace(/\W/g, "")}-`;
  return useMemo(() => {
    const doc = parseSvg(source);
    return doc ? sanitizeSvg(doc.documentElement, prefix) : null;
  }, [source, prefix]);
}

type Box = { left: number; top: number; width: number; height: number };

/** Rendered from the sanitized tree, not an <img>, so elements can be targeted. */
function SvgView({ source, title, threads, selected, activeId, onPick, onPin }: {
  source: string;
  title: string;
  threads?: Comment[];
  selected?: string;
  activeId?: string;
  onPick?: (t: Target) => void;
  onPin?: (id: string) => void;
}) {
  const san = useParsedSvg(source);
  const wrap = useRef<HTMLDivElement>(null);
  const [boxes, setBoxes] = useState<Record<string, Box>>({});
  const vids = useMemo(() => [...new Set([...(threads ?? []).filter((c) => !c.target_lost).map((c) => c.anchor.vid), selected].filter(Boolean) as string[])], [threads, selected]);
  // Percentages of the drawing, so pins stay put as the pane resizes.
  useLayoutEffect(() => {
    const host = wrap.current;
    if (!host) return;
    const o = host.getBoundingClientRect();
    const next: Record<string, Box> = {};
    for (const vid of vids) {
      const r = host.querySelector(`[data-vid="${CSS.escape(vid)}"]`)?.getBoundingClientRect();
      if (r && o.width && o.height) next[vid] = { left: ((r.left - o.left) / o.width) * 100, top: ((r.top - o.top) / o.height) * 100, width: (r.width / o.width) * 100, height: (r.height / o.height) * 100 };
    }
    setBoxes(next);
  }, [vids, source]);
  if (!san?.tree) return <p role="alert" className="text-12 text-pill-blocked-fg">This SVG couldn&apos;t be displayed. Its source is under Source.</p>;
  const vb = viewBoxOf(san.tree.attrs);
  const { width: _w, height: _h, x: _x, y: _y, ...rootAttrs } = san.tree.attrs;
  void [_w, _h, _x, _y];
  const click = (e: ReactMouseEvent<SVGSVGElement>) => {
    const el = (e.target as Element).closest?.("[data-vid]");
    const vid = el?.getAttribute("data-vid");
    if (!vid || !onPick) return;
    const r = e.currentTarget.getBoundingClientRect();
    onPick({ kind: "svg", vid, point: { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) }, label: el?.textContent?.trim().slice(0, 40) || `<${el?.localName}>` });
  };
  const sel = selected ? boxes[selected] : undefined;
  return (
    <div className="flex flex-col gap-2">
      {san.skipped > 0 && (
        <p className="text-12 text-fg-tertiary">
          {san.skipped} element{san.skipped === 1 ? "" : "s"} can&apos;t be shown here. They&apos;re kept in the source.
        </p>
      )}
      <div className="rounded-lg bg-white p-2">
        <div ref={wrap} className="relative">
          <svg {...rootAttrs} viewBox={`${vb.x} ${vb.y} ${vb.w} ${vb.h}`} role="img" aria-label={title} data-testid="canvas-svg" onClick={click} className={cx("mx-auto block h-auto w-full", onPick && "cursor-crosshair")} style={{ aspectRatio: `${vb.w} / ${vb.h}` }}>
            {san.tree.children.map(renderNode)}
          </svg>
          {sel && <div aria-hidden className="pointer-events-none absolute rounded-sm outline outline-2 outline-accent" style={{ left: `${sel.left}%`, top: `${sel.top}%`, width: `${sel.width}%`, height: `${sel.height}%` }} />}
          {threads?.map((c, i) => {
            const b = c.anchor.vid ? boxes[c.anchor.vid] : undefined;
            if (!b || c.target_lost) return null;
            return (
              <button key={c.id} type="button" aria-label={`Comment ${i + 1}`} data-testid="canvas-pin" onClick={() => onPin?.(c.id)} style={{ left: `${b.left + b.width}%`, top: `${b.top}%` }}
                className={cx("absolute grid size-5 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full text-11 font-bold shadow", c.id === activeId ? "bg-accent text-on-accent" : c.status === "draft" ? "bg-accent/80 text-on-accent" : "bg-fg-secondary text-surface")}>
                {i + 1}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** Rendered Markdown a person can select in; comments are painted over it. */
function TextPreview({ c, threads, activeId, pending, commentable, slots, onToolbar, onActivate }: {
  c: Canvas;
  threads: Comment[];
  activeId?: string;
  pending?: { start: number; end: number };
  commentable: boolean;
  slots?: Slot[];
  onToolbar: (t: Toolbar | null) => void;
  onActivate: (id: string | undefined) => void;
}) {
  const host = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const root = host.current;
    if (!root) return;
    const paint = (list: Comment[]) => list.flatMap((t) => (t.target_lost || t.anchor.start == null || t.anchor.end == null ? [] : sourceToRanges(root, c.body, t.anchor.start, t.anchor.end)));
    // Anchors describe the current version; an older one shows no marks.
    const current = commentable ? threads.filter((t) => t.status !== "resolved") : [];
    setHighlight("canvas-comment", paint(current));
    const active = sourceToRanges(root, c.body, pending?.start ?? 0, pending?.end ?? 0);
    setHighlight("canvas-comment-active", [...active, ...paint(current.filter((t) => t.id === activeId))]);
  }, [c.body, threads, activeId, pending, commentable]);
  // A layout effect: the next canvas paints in its own, and this must run first.
  useLayoutEffect(() => () => {
    setHighlight("canvas-comment", []);
    setHighlight("canvas-comment-active", []);
  }, []);
  const settle = (e: ReactMouseEvent | React.KeyboardEvent) => {
    const root = host.current;
    if (!root || !commentable || (e.target as Element).closest?.("[data-canvas-thread]")) return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount || !root.contains(sel.anchorNode)) {
      onToolbar(null);
      if ("clientX" in e) {
        const at = sourceOffsetAt(e.clientX, e.clientY, c.body);
        const hit = at === null ? undefined : threads.find((t) => !t.target_lost && t.status !== "resolved" && t.anchor.start != null && t.anchor.end != null && t.anchor.start <= at && at < t.anchor.end);
        onActivate(hit?.id);
      }
      return;
    }
    const range = sel.getRangeAt(0);
    const src = rangeToSource(root, range, c.body);
    if (!src) return onToolbar(null);
    const r = range.getBoundingClientRect();
    const o = root.getBoundingClientRect();
    // Measured on screen, placed inside content a board may have scaled.
    const k = root.offsetWidth / o.width;
    onToolbar({ ...src, quote: sel.toString().trim().slice(0, 140), top: (r.bottom - o.top) * k + 6, left: Math.max(0, Math.min((r.left - o.left) * k, root.offsetWidth - 300)) });
  };
  return (
    <div ref={host} data-testid="canvas-text" className="relative" onMouseUp={settle} onKeyUp={settle}>
      <Markdown sourceSpans slots={slots} className="type-reading text-fg-2">{c.body}</Markdown>
    </div>
  );
}

function Changes({ chatId, c }: { chatId: string; c: Canvas }) {
  const prev = useChatCanvas(chatId, c.viewing_seq > 1 ? c.id : undefined, c.viewing_seq - 1);
  if (c.viewing_seq <= 1) return <p className="text-12 text-fg-tertiary">This is the first version.</p>;
  if (prev.isError) return <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(prev.error)}</p>;
  if (!prev.data || prev.data.viewing_seq !== c.viewing_seq - 1) return <LoadingLines lines={3} />;
  if (c.kind === "svg") {
    return (
      <div className="flex flex-col gap-3">
        <h3 className="type-micro uppercase text-fg-tertiary">Before · v{c.viewing_seq - 1}</h3>
        <SvgView source={prev.data.body} title={`${c.title}, before`} />
        <h3 className="type-micro uppercase text-fg-tertiary">After · v{c.viewing_seq}</h3>
        <SvgView source={c.body} title={`${c.title}, after`} />
      </div>
    );
  }
  return (
    <div data-testid="canvas-diff" className="overflow-x-auto rounded-lg border border-border bg-surface font-mono text-12 leading-relaxed">
      {diffLines(prev.data.body, c.body).map((l, i) => (
        <div key={i} className={cx("whitespace-pre-wrap px-3", l.op === "add" && "bg-pill-done-bg text-pill-done-fg", l.op === "del" && "bg-pill-blocked-bg text-pill-blocked-fg", l.op === "same" && "text-fg-secondary")}>
          <span aria-hidden className="mr-2 inline-block w-3 select-none opacity-70">{l.op === "add" ? "+" : l.op === "del" ? "−" : " "}</span>
          <span className="sr-only">{l.op === "add" ? "Added: " : l.op === "del" ? "Removed: " : ""}</span>
          {l.text || " "}
        </div>
      ))}
    </div>
  );
}

function Editor({ c, actions, onDone }: { c: Canvas; actions: Actions; onDone: () => void }) {
  const [draft, setDraft] = useState(c.body);
  const history = useSourceHistory(draft, setDraft);
  const save = () => actions.save.mutate({ base_seq: c.viewing_seq, body: draft, note: "Edited by hand" }, { onSuccess: onDone });
  return (
    <div className="flex h-full min-h-[320px] flex-col gap-2">
      {c.kind === "svg" ? (
        <MockupCanvas source={draft} history={history} zoom="fit" alt={c.title} inspectorSide={false} />
      ) : (
        <textarea aria-label="Canvas text" value={draft} onChange={(e) => setDraft(e.target.value)} className="min-h-0 flex-1 resize-none rounded-lg border border-border bg-surface p-3 font-mono text-13 leading-relaxed text-fg focus:border-accent focus:outline-none" />
      )}
      {actions.save.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(actions.save.error)}</p>}
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onDone}>Cancel</Button>
        <Button variant="primary" disabled={actions.save.isPending || draft === c.body} onClick={save}>Save version</Button>
      </div>
    </div>
  );
}

function statusLabel(c: Comment) {
  return c.status === "draft" ? "Draft" : c.status === "addressed" ? "Addressed" : c.status === "resolved" ? "Resolved" : "Open";
}

function Thread({ c, n, replies, active, agent, readOnly, actions, onActivate }: { c: Comment; n: number; replies: Comment[]; active: boolean; agent: string; readOnly: boolean; actions: Actions; onActivate: () => void }) {
  const [replying, setReplying] = useState(false);
  const [reply, setReply] = useState("");
  const who = (x: Comment) => (x.author_type === "user" ? "You" : agent);
  const target = c.anchor.vid ? (c.anchor.label ? `“${c.anchor.label}”` : `<${c.anchor.tag}>`) : c.anchor.quote ? `“${c.anchor.quote.length > 90 ? `${c.anchor.quote.slice(0, 90)}…` : c.anchor.quote}”` : undefined;
  const link = "text-accent hover:underline disabled:opacity-50";
  const submitReply = async () => {
    await actions.add.mutateAsync({ parent_id: c.id, body: reply });
    await actions.send.mutateAsync({ comment_ids: [c.id], message: reply });
    setReply("");
    setReplying(false);
  };
  return (
    <li data-testid="canvas-comment" data-canvas-thread aria-current={active || undefined} onClick={onActivate} className={cx("flex flex-col gap-1.5 rounded-lg border bg-surface p-2.5 text-13", active ? "border-accent" : "border-border")}>
      <div className="flex items-center gap-1.5 text-12 text-fg-tertiary">
        <span className="grid size-4 flex-none place-items-center rounded-full bg-fg-secondary text-10 font-bold text-surface">{n}</span>
        <span className="font-semibold text-fg-2">{who(c)}</span>
        <span className="ml-auto">{statusLabel(c)}</span>
      </div>
      {c.target_lost && (c.status === "draft" || c.status === "open") ? <p className="text-12 italic text-fg-tertiary">Original target removed</p> : target && <p className="truncate text-12 text-fg-tertiary">{target}</p>}
      <p className="whitespace-pre-wrap text-fg">{c.body}</p>
      {c.suggestion != null && (
        <p className="rounded bg-pill-done-bg px-2 py-1 text-pill-done-fg"><span className="sr-only">Suggested: </span>{c.suggestion}</p>
      )}
      {replies.map((r) => (
        <p key={r.id} className="whitespace-pre-wrap border-l-2 border-border pl-2 text-fg-2"><span className="font-semibold">{who(r)}:</span> {r.body}</p>
      ))}
      {replying && (
        <div className="flex flex-col gap-1">
          <textarea aria-label="Reply" autoFocus rows={2} value={reply} onChange={(e) => setReply(e.target.value)} className="w-full rounded border border-border bg-surface-sunken p-1.5 text-13 text-fg focus:border-accent focus:outline-none" />
          <div className="flex justify-end gap-2">
            <button type="button" className={link} onClick={() => setReplying(false)}>Cancel</button>
            <button type="button" className={link} disabled={!reply.trim() || readOnly || actions.add.isPending || actions.send.isPending} onClick={() => void submitReply()}>Send reply</button>
          </div>
        </div>
      )}
      {!replying && (
        <div className="flex flex-wrap gap-x-3 text-12">
          {c.status === "draft" && <button type="button" className={link} onClick={() => actions.remove.mutate(c.id)}>Delete</button>}
          {c.suggestion != null && c.status !== "resolved" && !c.target_lost && <button type="button" className={link} disabled={readOnly || actions.apply.isPending} onClick={() => actions.apply.mutate(c.id)}>Apply</button>}
          {c.status !== "draft" && c.status !== "resolved" && <button type="button" className={link} disabled={readOnly} onClick={() => setReplying(true)}>Reply</button>}
          {(c.status === "addressed" || c.status === "resolved") && <button type="button" className={link} onClick={() => actions.setStatus.mutate({ id: c.id, status: "open" })}>Reopen</button>}
          {(c.status === "open" || c.status === "addressed") && <button type="button" className={link} onClick={() => actions.setStatus.mutate({ id: c.id, status: "resolved" })}>Resolve</button>}
        </div>
      )}
    </li>
  );
}

function Composer({ target, readOnly, actions, seq, onDone }: { target: Target; readOnly: boolean; actions: Actions; seq: number; onDone: () => void }) {
  const [body, setBody] = useState("");
  const payload = (): Schemas["NewChatCanvasComment"] => (target.kind === "text" ? { seq, body, start: target.start, end: target.end } : { seq, body, vid: target.vid, point: target.point });
  const busy = actions.add.isPending || actions.send.isPending;
  const batch = () => actions.add.mutate(payload(), { onSuccess: onDone });
  const now = async () => {
    const c = await actions.add.mutateAsync(payload());
    await actions.send.mutateAsync({ comment_ids: [c.id] });
    onDone();
  };
  return (
    <div data-testid="canvas-composer" data-canvas-thread className="flex flex-col gap-1.5 rounded-lg border border-accent bg-surface p-2.5">
      <p className="truncate text-12 text-fg-tertiary">On {target.kind === "text" ? `“${target.quote}”` : `“${target.label}”`}</p>
      <textarea aria-label="Comment" autoFocus rows={3} value={body} onChange={(e) => setBody(e.target.value)} className="w-full rounded border border-border bg-surface-sunken p-1.5 text-13 text-fg focus:border-accent focus:outline-none" />
      {(actions.add.isError || actions.send.isError) && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(actions.add.error ?? actions.send.error)}</p>}
      <div className="flex flex-wrap justify-end gap-1.5">
        <Button variant="secondary" onClick={onDone}>Cancel</Button>
        <Button variant="secondary" disabled={!body.trim() || busy} onClick={batch}>Add to batch</Button>
        <Button variant="primary" disabled={!body.trim() || busy || readOnly} onClick={() => void now()}>Send now</Button>
      </div>
    </div>
  );
}

export function Rail({ inline, threads, replies, resolved, target, activeId, setActive, agent, readOnly, actions, seq, onComposerDone, numberOf }: {
  inline: boolean;
  threads: Comment[];
  replies: Map<string, Comment[]>;
  resolved: Comment[];
  target: Target | null;
  activeId?: string;
  setActive: (id: string) => void;
  agent: string;
  readOnly: boolean;
  actions: Actions;
  seq: number;
  onComposerDone: () => void;
  numberOf: (c: Comment) => number;
}) {
  const card = (c: Comment) => <Thread key={c.id} c={c} n={numberOf(c)} replies={replies.get(c.id) ?? []} active={c.id === activeId} agent={agent} readOnly={readOnly} actions={actions} onActivate={() => setActive(c.id)} />;
  return (
    <aside aria-label="Comments" className={cx("flex flex-none flex-col gap-2 border-border-subtle p-3", inline ? "border-t" : "max-md:border-t md:w-[300px] md:overflow-y-auto md:border-l")}>
      {target && <Composer key={target.kind === "text" ? `${target.start}-${target.end}` : target.vid} target={target} readOnly={readOnly} actions={actions} seq={seq} onDone={onComposerDone} />}
      <ol className="flex flex-col gap-2">{threads.map(card)}</ol>
      {resolved.length > 0 && (
        <details className="text-12 text-fg-tertiary">
          <summary className="cursor-pointer">{resolved.length} resolved</summary>
          <ol className="mt-2 flex flex-col gap-2">{resolved.map(card)}</ol>
        </details>
      )}
    </aside>
  );
}

/** One canvas: inline in a chat card (a fixed height, comments under their passages) or fullscreen (comments alongside). */
/** `page` lays it out like fullscreen, for a page of its own (a document in the Docs app). */
export function CanvasView({ chatId, canvasId, live, readOnly, agent, page, onCollapse, onFullscreen, onExitFullscreen, onClose }: { chatId: string; canvasId: string; live: boolean; readOnly: boolean; agent: string; page?: boolean; onCollapse?: () => void; onFullscreen?: () => void; onExitFullscreen?: () => void; onClose?: () => void }) {
  // Undefined follows the current version as the agent revises it.
  const [seq, setSeq] = useState<number>();
  const [view, setView] = useState<View>("preview");
  const [target, setTarget] = useState<Target | null>(null);
  const [toolbar, setToolbar] = useState<Toolbar | null>(null);
  const [activeId, setActiveId] = useState<string>();
  const q = useChatCanvas(chatId, canvasId, seq, live);
  const comments = useCanvasComments(chatId, canvasId, live).data?.comments;
  const actions = useCanvasActions(chatId, canvasId);
  const c = q.data;
  const viewing = c?.viewing_seq;
  const isCurrent = !!c && viewing === c.seq;
  const note = c?.versions.find((v) => v.seq === viewing)?.note;
  const step = (to: number) => {
    setTarget(null);
    setToolbar(null);
    setSeq(c && to >= c.seq ? undefined : to);
  };
  const { open, resolved, replies } = useMemo(() => {
    const replies = new Map<string, Comment[]>();
    const top: Comment[] = [];
    for (const x of comments ?? []) {
      if (x.parent_id) replies.set(x.parent_id, [...(replies.get(x.parent_id) ?? []), x]);
      else top.push(x);
    }
    return { open: top.filter((x) => x.status !== "resolved"), resolved: top.filter((x) => x.status === "resolved"), replies };
  }, [comments]);
  const drafts = open.filter((x) => x.status === "draft");
  const numberOf = (x: Comment) => [...open, ...resolved].findIndex((y) => y.id === x.id) + 1;
  // Agent edits shouldn't land under someone's cursor: canvases are read-only during a turn.
  const locked = readOnly || live;
  const canComment = isCurrent && !readOnly && view === "preview";
  const inline = !onExitFullscreen && !page;
  // Inline, text comments sit under their passage; anything without a place there goes below.
  const flowing = inline && c?.kind === "text" && isCurrent;
  const anchored = useMemo(() => (flowing ? open.filter((x) => !x.target_lost && x.anchor.end != null) : []), [flowing, open]);
  const inFlowComposer = flowing && canComment && target?.kind === "text";
  const slotSpec = anchored.map((x) => `${x.id}:${x.anchor.end}`).join() + (inFlowComposer ? `|${target.end}` : "");
  const slots = useMemo<Slot[]>(() => {
    if (!flowing) return [];
    const out: Slot[] = slotSpec.split("|")[0].split(",").filter(Boolean).map((p) => ({ id: p.split(":")[0], offset: Number(p.split(":")[1]) }));
    const composer = slotSpec.split("|")[1];
    if (composer) out.push({ id: "composer", offset: Number(composer) });
    return out;
  }, [flowing, slotSpec]);
  const threadCard = (x: Comment) => <Thread key={x.id} c={x} n={numberOf(x)} replies={replies.get(x.id) ?? []} active={x.id === activeId} agent={agent} readOnly={locked} actions={actions} onActivate={() => setActiveId(x.id)} />;
  const renderSlot = (id: string): ReactNode => {
    if (id === "composer") return inFlowComposer && c ? <div className="my-2"><Composer key={`${target.start}-${target.end}`} target={target} readOnly={locked} actions={actions} seq={c.seq} onDone={() => setTarget(null)} /></div> : null;
    const x = anchored.find((t) => t.id === id);
    return x ? <ol className="my-2">{threadCard(x)}</ol> : null;
  };
  const railThreads = open.filter((x) => !anchored.includes(x));
  const railTarget = canComment && !inFlowComposer ? target : null;
  const showRail = !!c && view === "preview" && (railThreads.length > 0 || resolved.length > 0 || !!railTarget);
  const quick = async (t: Toolbar, message: string) => {
    if (!c) return;
    setToolbar(null);
    const made = await actions.add.mutateAsync({ seq: c.seq, body: message, start: t.start, end: t.end });
    await actions.send.mutateAsync({ comment_ids: [made.id], message });
  };
  const tab = (v: View, label: string, disabled = false) => (
    <button type="button" role="tab" aria-selected={view === v} disabled={disabled} className={cx("rounded px-1.5 disabled:opacity-40", view === v ? "bg-surface text-fg" : "hover:text-fg")} onClick={() => setView(v)}>
      {label}
    </button>
  );
  // Fullscreen shows the preview on a board at its natural size; other tabs stay plain.
  const onBoard = !inline && view === "preview" && !!c && !q.isError;
  const board = (content: ReactNode) => {
    if (!onBoard || !c) return content;
    if (c.kind === "svg") return <CanvasBoard width={svgSize(c.body).w + 16} selectable={false}>{content}</CanvasBoard>;
    return <CanvasBoard width={TEXT_PAGE} selectable><div className="rounded-lg border border-border bg-surface p-10 shadow-[var(--shadow-float)]">{content}</div></CanvasBoard>;
  };
  const failure = actions.apply.error ?? actions.restore.error ?? actions.promote.error ?? actions.setStatus.error ?? actions.remove.error ?? (target ? null : (actions.send.error ?? actions.add.error));
  return (
    <>
      <div className="flex items-center gap-2 border-b border-border-subtle px-4 py-2.5">
        <h2 className="min-w-0 flex-1 truncate text-14 font-semibold text-fg">{c?.title ?? "Canvas"}</h2>
        {drafts.length > 0 && (
          <Button variant="primary" disabled={locked || actions.send.isPending} onClick={() => actions.send.mutate({ comment_ids: drafts.map((d) => d.id) })}>
            Send {drafts.length} comment{drafts.length === 1 ? "" : "s"}
          </Button>
        )}
        {c?.promoted_artifact_id ? (
          <Link href={`/artifacts/${c.promoted_artifact_id}`} className="text-12 text-accent hover:underline">Open artifact</Link>
        ) : (
          c && <Button variant="secondary" disabled={actions.promote.isPending} onClick={() => actions.promote.mutate()}>Save as artifact</Button>
        )}
        {onFullscreen && <IconButton icon="expand" label="Fullscreen" onClick={onFullscreen} />}
        {onExitFullscreen && <IconButton icon="shrink" label="Exit fullscreen" onClick={onExitFullscreen} />}
        {onCollapse && <IconButton icon="chevronUp" label="Collapse canvas" onClick={onCollapse} />}
        {onClose && <IconButton icon="x" label="Close canvas" onClick={onClose} />}
      </div>
      <div className="flex items-center gap-2 border-b border-border-row px-4 py-1.5 text-12 text-fg-tertiary">
        {c && viewing !== undefined && (
          <span className="flex items-center gap-1">
            <button type="button" aria-label="Previous version" disabled={viewing <= 1} className="rounded px-1 hover:text-fg disabled:opacity-40" onClick={() => step(viewing - 1)}>‹</button>
            <span data-testid="canvas-version">v{viewing} of {c.seq}</span>
            <button type="button" aria-label="Next version" disabled={viewing >= c.seq} className="rounded px-1 hover:text-fg disabled:opacity-40" onClick={() => step(viewing + 1)}>›</button>
          </span>
        )}
        {c && !isCurrent && (
          <button type="button" className="text-accent hover:underline disabled:opacity-50" disabled={locked || actions.restore.isPending} onClick={() => actions.restore.mutate(viewing!, { onSuccess: () => setSeq(undefined) })}>Restore</button>
        )}
        {live && <span>Agent is working…</span>}
        {note && !live && <span className="min-w-0 flex-1 truncate">{note}</span>}
        <span role="tablist" aria-label="Canvas view" className="ml-auto flex items-center gap-0.5">
          {tab("preview", "Preview")}
          {tab("changes", "Changes")}
          {tab("source", "Source")}
          {tab("edit", "Edit", locked || !isCurrent)}
        </span>
      </div>
      {failure && <p role="alert" className="border-b border-border-row px-4 py-1 text-12 text-pill-blocked-fg">{errorText(failure)}</p>}
      <div className={cx("min-h-0 flex-1", inline ? "overflow-y-auto" : "flex overflow-hidden max-md:flex-col max-md:overflow-y-auto")}>
        <div className={cx("relative min-w-0 flex-1", onBoard ? "max-md:min-h-[60vh]" : "p-4", !inline && !onBoard && "md:overflow-auto")}>
          {canComment && !target && !open.length && !resolved.length && <p className={cx("text-12 text-fg-tertiary", onBoard ? "pointer-events-none absolute left-4 top-3 z-10" : "mb-3")}>{c?.kind === "svg" ? "Click an element to comment on it." : "Select text to comment on it."}</p>}
          {q.isError ? (
            <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(q.error)}</p>
          ) : !c ? (
            <LoadingLines lines={4} />
          ) : c.kind === "deck" ? (
            <p className="text-13 text-fg-secondary">
              This is a slide deck.{" "}
              <Link href={`/apps/slides/${canvasId}`} className="text-accent hover:underline">
                Open it in Slides
              </Link>{" "}
              to edit, present or export it.
            </p>
          ) : view === "edit" && isCurrent && !locked ? (
            <Editor key={c.seq} c={c} actions={actions} onDone={() => setView("preview")} />
          ) : view === "changes" ? (
            <Changes chatId={chatId} c={c} />
          ) : view === "source" ? (
            <CodeFence code={c.body} info={c.kind === "svg" ? "html" : "markdown"} />
          ) : (
            board(c.kind === "svg" ? (
            <SvgView source={c.body} title={c.title} threads={isCurrent ? open : []} activeId={activeId} selected={target?.kind === "svg" ? target.vid : undefined} onPick={canComment ? setTarget : undefined} onPin={setActiveId} />
          ) : (
            <div className="relative">
              <MarkdownSlots.Provider value={renderSlot}>
                <TextPreview c={c} threads={open} activeId={activeId} pending={target?.kind === "text" ? target : undefined} commentable={canComment} slots={slots} onToolbar={setToolbar} onActivate={setActiveId} />
              </MarkdownSlots.Provider>
              {toolbar && canComment && (
                <div role="toolbar" aria-label="Selection" data-testid="canvas-toolbar" style={{ top: toolbar.top, left: toolbar.left }} className="absolute z-10 flex gap-0.5 rounded-lg border border-border-float bg-surface-raised p-1 text-13 shadow-[var(--shadow-float)]" onMouseUp={(e) => e.stopPropagation()}>
                  <button type="button" className="rounded px-2 py-0.5 font-semibold text-fg hover:bg-hover" onClick={() => { setTarget({ kind: "text", start: toolbar.start, end: toolbar.end, quote: toolbar.quote }); setToolbar(null); }}>Comment</button>
                  {QUICK.map(([label, message]) => (
                    <button key={label} type="button" disabled={locked} className="rounded px-2 py-0.5 text-fg hover:bg-hover disabled:opacity-40" onClick={() => void quick(toolbar, message)}>{label}</button>
                  ))}
                </div>
              )}
            </div>
            ))
          )}
        </div>
        {showRail && (
          <Rail inline={inline} threads={railThreads} replies={replies} resolved={resolved} target={railTarget} activeId={activeId} setActive={setActiveId} agent={agent} readOnly={locked} actions={actions} seq={c.seq} onComposerDone={() => setTarget(null)} numberOf={numberOf} />
        )}
      </div>
    </>
  );
}

/** Talking to the agent without leaving fullscreen: its latest reply and a message box. */
function FullscreenChat({ chatId, live, readOnly }: { chatId: string; live: boolean; readOnly: boolean }) {
  const [text, setText] = useState("");
  const send = useSendChatMessage(chatId);
  const messages = useChatMessages(chatId).data?.messages;
  const reply = messages?.findLast((m) => m.role === "assistant")?.body_md.replace(/^ {0,3}(`{3,}|~{3,})[\s\S]*?^ {0,3}\1\s*$/gm, "").trim();
  const disabled = live || readOnly || send.isPending;
  const submit = () => {
    if (!text.trim() || disabled) return;
    send.mutate({ body: text }, { onSuccess: () => setText("") });
  };
  return (
    <div className="flex flex-none flex-col gap-2 border-t border-border-subtle p-3">
      {reply && <div data-testid="canvas-latest-reply" className="max-h-24 overflow-y-auto text-13"><Markdown className="text-fg-2">{reply}</Markdown></div>}
      {send.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(send.error)}</p>}
      <div className="flex items-end gap-2">
        <textarea aria-label="Message from fullscreen" rows={1} value={text} disabled={readOnly} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }} placeholder="Message" className="min-w-0 flex-1 resize-none rounded-lg border border-border bg-surface p-2 text-14 text-fg focus:border-accent focus:outline-none" />
        <Button variant="primary" disabled={disabled || !text.trim()} onClick={submit}>Send</Button>
      </div>
    </div>
  );
}

const noSubscribe = () => () => {};

/** The desktop dock's Canvas tab: the canvas in the dock's width, with Fullscreen to take it over the window and Close to put it back in its card. */
export function CanvasDock({ chatId, live, readOnly, agent }: { chatId: string; live: boolean; readOnly: boolean; agent: string }) {
  const panel = useCanvasPanel();
  const canvases = useChatCanvases(chatId, live).data?.canvases;
  const id = panel.focus ?? canvases?.at(-1)?.id;
  // While it's over the window (CanvasFullscreen) it shows only there.
  if (!id || panel.maximized) return null;
  return (
    <section aria-label="Canvas" data-testid="canvas-dock" className="flex min-h-0 flex-1 flex-col bg-surface-sunken">
      <CanvasView key={id} chatId={chatId} canvasId={id} live={live} readOnly={readOnly} agent={agent} onFullscreen={() => panel.maximize(id)} onClose={panel.exitFull} />
    </section>
  );
}

/**
 * A canvas over the whole browser window, with the conversation reduced to a message box; on
 * desktop it's taken there from the dock's Canvas tab and Exit goes back to it. `inline` fills
 * the compact panel sheet instead, where Exit closes the canvas.
 */
export function CanvasFullscreen({ chatId, live, readOnly, agent, inline }: { chatId: string; live: boolean; readOnly: boolean; agent: string; inline?: boolean }) {
  const panel = useCanvasPanel();
  const canvases = useChatCanvases(chatId, live).data?.canvases;
  const id = panel.focus ?? canvases?.at(-1)?.id;
  const mounted = useSyncExternalStore(noSubscribe, () => true, () => false);
  const exitFull = inline ? panel.exitFull : panel.restore;
  const exit = useRef(exitFull);
  useEffect(() => {
    exit.current = exitFull;
  });
  useEffect(() => {
    // In the panel sheet, Escape closes the sheet (chat-panel-host), not the canvas.
    if (inline) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !(e.target as Element).closest?.("input, textarea, select")) exit.current();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [inline]);
  if (!id || !mounted) return null;
  const body = (
    <>
      <CanvasView key={id} chatId={chatId} canvasId={id} live={live} readOnly={readOnly} agent={agent} onExitFullscreen={exitFull} />
      <FullscreenChat chatId={chatId} live={live} readOnly={readOnly} />
    </>
  );
  // `inline` fills the panel sheet (chat-panel-host), which is already full height.
  if (inline) return <section aria-label="Canvas" data-testid="canvas-fullscreen" className="flex min-h-0 flex-1 flex-col bg-surface-sunken">{body}</section>;
  // On body, so no layout around the chat can contain it.
  return createPortal(
    <section role="dialog" aria-modal="true" aria-label="Canvas" data-testid="canvas-fullscreen" className="fixed inset-0 z-[100] flex flex-col bg-surface-sunken">
      {body}
    </section>,
    document.body,
  );
}
