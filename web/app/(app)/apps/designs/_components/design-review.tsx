"use client";

import { useMemo, useState } from "react";
import { useCanvasActions, useCanvasComments } from "@/lib/api/canvas-hooks";
import type { DesignProposal } from "@/lib/api/designs-hooks";
import { cx } from "@/lib/cx";
import { find, labelOf } from "@/lib/designs/edit";
import { applyOps, classify, decide, decideRest, dependencies, preview, resolveBody, undecided, type Change, type ChangeKind, type Decisions, type DesignOp } from "@/lib/designs/review";
import type { Design } from "@/lib/designs/schema";
import { Button } from "@/components/ui/button";
import type { Camera } from "./design-canvas";

// A persona's suggestion as a diff on the canvas (docs/design/designs-review.svg).

export type ReviewMode = "before" | "after" | "diff";
export const KIND_COLOR: Record<ChangeKind, string> = { added: "#4CB782", changed: "#F0BF4C", removed: "#EF6461" };
const KIND_LABEL: Record<ChangeKind, string> = { added: "Added", changed: "Changed", removed: "Removed" };

export type Review = {
  proposal: DesignProposal;
  /** How many suggestions wait, this one included. */
  total: number;
  changes: Change[];
  decisions: Decisions;
  left: number;
  focus?: number;
  setFocus: (i?: number) => void;
  accept: (i: number) => void;
  reject: (i: number, reason?: string) => void;
  /** The resolve body with every undecided change decided one way: Accept all / Reject all in one step. */
  restBody: (state: "accepted" | "rejected") => ReturnType<typeof resolveBody>;
  /** The design with the suggestion applied, minus what was rejected. */
  after: Design;
  body: ReturnType<typeof resolveBody>;
};

/** The review of the oldest pending suggestion: its changes, the person's decisions and the After design. */
export function useReview(draft: Design | undefined, proposals: DesignProposal[] | undefined, active: boolean): Review | undefined {
  const [decided, setDecided] = useState<Record<string, Decisions>>({});
  const [focusBy, setFocusBy] = useState<Record<string, number | undefined>>({});
  const proposal = active ? proposals?.[0] : undefined;
  const ops = useMemo(() => (proposal?.ops ?? []) as DesignOp[], [proposal]);
  const deps = useMemo(() => (proposal?.deps && proposal.deps.length === ops.length ? proposal.deps : dependencies(ops)), [proposal, ops]);
  const changes = useMemo(() => (draft && proposal ? classify(draft, ops, deps) : []), [draft, proposal, ops, deps]);
  const decisions = useMemo(() => (proposal ? (decided[proposal.id] ?? {}) : {}), [decided, proposal]);
  const after = useMemo(() => (draft && proposal ? preview(applyOps(draft, ops, (i) => decisions[i]?.state !== "rejected")) : draft), [draft, proposal, ops, decisions]);
  if (!proposal || !draft || !after) return undefined;
  const set = (f: (d: Decisions) => Decisions) => setDecided((all) => ({ ...all, [proposal.id]: f(all[proposal.id] ?? {}) }));
  return {
    proposal,
    total: proposals?.length ?? 1,
    changes,
    decisions,
    left: undecided(decisions, ops.length).length,
    focus: focusBy[proposal.id],
    setFocus: (i) => setFocusBy((f) => ({ ...f, [proposal.id]: i })),
    accept: (i) => set((d) => decide(deps, d, i, "accepted")),
    reject: (i, reason) => set((d) => decide(deps, d, i, "rejected", reason)),
    restBody: (state) => resolveBody(decideRest(deps, decisions, ops.length, state), ops.length),
    after,
    body: resolveBody(decisions, ops.length),
  };
}

const Pin = ({ n, kind, dim }: { n: number; kind: ChangeKind; dim?: boolean }) => (
  <span aria-hidden className={cx("grid size-[18px] flex-none place-items-center rounded-full text-10 font-bold text-[#0C0B12]", dim && "opacity-50")} style={{ background: KIND_COLOR[kind] }}>
    {n}
  </span>
);

/** The pages a suggestion touches, by name, for the chat card. */
export function suggestionPages(draft: Design, proposal: DesignProposal): string[] {
  const ops = proposal.ops as DesignOp[];
  const deps = proposal.deps && proposal.deps.length === ops.length ? proposal.deps : dependencies(ops);
  const ids = new Set(classify(draft, ops, deps).flatMap((c) => c.page ?? []));
  return draft.pages.filter((p) => ids.has(p.id)).map((p) => p.name);
}

/** Which change ‹ › lands on: the next (or previous) one after the focused change, wrapping round. */
export function stepChange(review: Review, dir: 1 | -1): Change | undefined {
  const m = review.changes.length;
  if (!m) return undefined;
  const at = review.changes.findIndex((c) => c.i === review.focus);
  return review.changes[at < 0 ? (dir > 0 ? 0 : m - 1) : (at + dir + m) % m];
}

/** The one control over the frame while reviewing: Before / After / Diff and ‹ n of m › between the changes. */
export function ReviewPill({ review, mode, onMode, onStep, onClose, busy }: { review: Review; mode: ReviewMode; onMode: (m: ReviewMode) => void; onStep: (dir: 1 | -1) => void; onClose: () => void; busy: boolean }) {
  const m = review.changes.length;
  const at = review.changes.findIndex((c) => c.i === review.focus);
  const arrow = "grid size-6 place-items-center rounded-full text-15 text-fg-2 hover:bg-hover disabled:opacity-40";
  return (
    <div role="region" aria-label="Review" data-testid="review-pill" className="pointer-events-auto flex items-center gap-1 rounded-full border border-border-float bg-surface-raised p-1 text-13 shadow-[var(--shadow-float)]">
      <div role="group" aria-label="View" className="flex rounded-full bg-surface p-0.5">
        {(["before", "after", "diff"] as const).map((v) => (
          <button key={v} type="button" aria-pressed={mode === v} onClick={() => onMode(v)} className={cx("rounded-full px-2.5 py-0.5", mode === v ? "bg-selected font-semibold text-fg" : "text-fg-secondary hover:bg-hover")}>
            {v[0].toUpperCase() + v.slice(1)}
          </button>
        ))}
      </div>
      <span aria-hidden className="mx-1 h-4 w-px bg-border" />
      <button type="button" aria-label="Previous change" className={arrow} disabled={!m} onClick={() => onStep(-1)}>‹</button>
      <span data-testid="review-step" className="min-w-[52px] text-center tabular-nums text-fg" aria-live="polite">
        {at < 0 ? `${m} ${m === 1 ? "change" : "changes"}` : `${at + 1} of ${m}`}
      </span>
      <button type="button" aria-label="Next change" className={arrow} disabled={!m} onClick={() => onStep(1)}>›</button>
      <button type="button" aria-label="Close review" disabled={busy} className="grid size-6 place-items-center rounded-full text-11 text-fg-tertiary hover:bg-hover hover:text-fg disabled:opacity-40" onClick={onClose}>✕</button>
    </div>
  );
}

/** Numbered pins and outlines over the canvas, in screen space (the canvas's camera maps page to screen). */
export function ReviewOverlay({ review, mode, page, camera }: { review: Review; mode: ReviewMode; page: string; camera: Camera }) {
  const toScreen = (b: { x: number; y: number; w: number; h: number }) => ({ x: b.x * camera.z + camera.x, y: b.y * camera.z + camera.y, w: b.w * camera.z, h: b.h * camera.z });
  return (
    <svg aria-hidden className="pointer-events-none absolute inset-0 z-[5] h-full w-full" data-testid="review-overlay">
      <defs>
        <pattern id="review-strike" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
          <path d="M0 0V8" stroke="#EF6461" strokeWidth="2" strokeOpacity="0.5" />
        </pattern>
      </defs>
      {review.changes.map((c) => {
        if (!c.box || c.page !== page) return null;
        const b = toScreen(c.box);
        const color = KIND_COLOR[c.kind];
        const dim = !!review.decisions[c.i];
        const focus = review.focus === c.i;
        // An added layer isn't there to outline in Before, a removed one is gone in After.
        const outline = mode === "diff" || (mode === "before" && c.kind !== "added") || (mode === "after" && c.kind !== "removed");
        return (
          <g key={c.i} data-pin={c.i + 1} data-kind={c.kind} opacity={dim ? 0.45 : 1}>
            {outline && (
              <rect x={b.x - 2} y={b.y - 2} width={b.w + 4} height={b.h + 4} rx={3} fill={c.kind === "removed" && mode === "diff" ? "url(#review-strike)" : "none"} stroke={color} strokeWidth={focus ? 2.5 : 1.5} strokeDasharray={c.kind === "removed" ? "4 3" : undefined} />
            )}
            <circle cx={b.x + b.w + 2} cy={b.y - 2} r={11} fill={color} stroke={focus ? "var(--color-fg)" : "none"} strokeWidth={2} />
            <text x={b.x + b.w + 2} y={b.y + 2} fontSize={11} fontWeight={700} textAnchor="middle" fill="#0C0B12">
              {c.i + 1}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

/** The side list: one card per change with its why, Accept / Reject / Discuss. */
export function ReviewPanel({ review, design, chatId, canvasId, seq, persona, error, busy, onFocus, onDone }: { review: Review; design: Design; chatId: string; canvasId: string; seq: number; persona: string; error?: string; busy: boolean; onFocus: (c: Change) => void; onDone: (body?: Review["body"]) => void }) {
  const [tab, setTab] = useState<"changes" | "comments">("changes");
  const all = review.left === review.changes.length;
  const pages = design.pages.filter((p) => review.changes.some((c) => c.page === p.id)).map((p) => p.name);
  const comments = useCanvasComments(chatId, canvasId).data?.comments ?? [];
  const tabs = [
    { id: "changes", label: "Changes", n: review.changes.length },
    { id: "comments", label: "Comments", n: comments.filter((c) => !c.parent_id).length },
  ] as const;
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="review-panel">
      <div className="flex-none px-4 pt-3">
        <p className="text-13 font-semibold text-fg">{persona}’s suggestion</p>
        <p className="mt-0.5 text-12 text-fg-secondary" data-testid="review-status">
          {review.left} of {review.changes.length} left
          {pages.length > 0 && ` · ${pages.join(", ")}`}
          {review.total > 1 ? ` · suggestion 1 of ${review.total}` : ""}
        </p>
        <ul aria-label="Legend" className="mt-1.5 flex items-center gap-3 text-11 text-fg-tertiary">
          {(Object.keys(KIND_COLOR) as ChangeKind[]).map((k) => (
            <li key={k} className="flex items-center gap-1">
              <span aria-hidden className="size-2.5 rounded-[2px]" style={{ background: KIND_COLOR[k] }} />
              {KIND_LABEL[k]}
            </li>
          ))}
        </ul>
      </div>
      <div role="tablist" aria-label="Review" className="flex gap-4 border-b border-border-subtle px-4 pt-3">
        {tabs.map((t) => (
          <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)} className={cx("-mb-px flex items-center gap-1.5 border-b-2 pb-2 text-13", tab === t.id ? "border-accent font-semibold text-fg" : "border-transparent text-fg-tertiary")}>
            {t.label}
            <span className="rounded-full bg-hover px-1.5 text-10 text-fg-secondary">{t.n}</span>
          </button>
        ))}
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto p-3">
        {tab === "changes" ? (
          <>
            {review.proposal.summary && <p className="mb-3 text-13 text-fg-secondary" data-testid="review-summary">{review.proposal.summary}</p>}
            <ol className="flex flex-col gap-2">
              {review.changes.map((c) => (
                <ChangeCard key={c.i} c={c} review={review} design={design} chatId={chatId} canvasId={canvasId} seq={seq} persona={persona} busy={busy} onFocus={onFocus} />
              ))}
            </ol>
          </>
        ) : (
          <CommentList comments={comments} design={design} />
        )}
      </div>
      <div className="flex-none border-t border-border-subtle px-4 py-3" data-testid="review-actions">
        {error && <p role="alert" className="mb-2 text-12 text-pill-blocked-fg">{error}</p>}
        <p className="mb-2 text-11 text-fg-tertiary">The accepted changes become one version. Rejected ones, with your reasons, go back to {persona}.</p>
        {review.left > 0 ? (
          // One click settles everything still open and applies: deciding change by change is optional.
          <span className="flex flex-wrap items-center gap-1.5">
            <Button variant="primary" disabled={busy} onClick={() => onDone(review.restBody("accepted"))}>{busy ? "Applying…" : `${all ? "Accept all" : "Accept the rest"} (${review.left})`}</Button>
            <Button variant="outline" disabled={busy} onClick={() => onDone(review.restBody("rejected"))}>{all ? "Reject all" : "Reject the rest"}</Button>
          </span>
        ) : (
          <Button variant="primary" disabled={busy} onClick={() => onDone()}>{busy ? "Applying…" : "Done"}</Button>
        )}
      </div>
    </div>
  );
}

function ChangeCard({ c, review, design, chatId, canvasId, seq, persona, busy, onFocus }: { c: Change; review: Review; design: Design; chatId: string; canvasId: string; seq: number; persona: string; busy: boolean; onFocus: (c: Change) => void }) {
  const d = review.decisions[c.i];
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [discussing, setDiscussing] = useState(false);
  const focus = review.focus === c.i;
  return (
    <li data-testid={`review-change-${c.i + 1}`} data-state={d?.state ?? "pending"} className={cx("rounded-[10px] border bg-surface-raised p-3", focus ? "border-accent" : "border-border-subtle", d && "opacity-70", c.needs.length > 0 && "ml-4")}>
      <button type="button" className="flex w-full items-start gap-2 text-left" onClick={() => onFocus(c)} aria-label={`Show change ${c.i + 1} on the canvas`}>
        <Pin n={c.i + 1} kind={c.kind} dim={!!d} />
        <span className="min-w-0 flex-1">
          <span className="block text-13 font-semibold text-fg">{c.title}</span>
          {c.why && <span className="mt-0.5 block text-12 text-fg-secondary" data-testid="change-why">{c.why}</span>}
          {c.needs.length > 0 && <span className="mt-0.5 block text-11 text-fg-tertiary">Needs change {c.needs.map((n) => n + 1).join(", ")}</span>}
        </span>
      </button>
      {d ? (
        <div className="mt-2 flex items-center gap-2 pl-[26px] text-12">
          <span className={d.state === "accepted" ? "text-[#6FCF97]" : "text-pill-blocked-fg"}>{d.state === "accepted" ? "✓ Accepted" : "✗ Rejected"}{d.reason ? `: ${d.reason}` : ""}</span>
          {d.state === "rejected" ? (
            <button type="button" className="text-accent hover:underline" disabled={busy} onClick={() => review.accept(c.i)}>Accept instead</button>
          ) : (
            <button type="button" className="text-accent hover:underline" disabled={busy} onClick={() => setRejecting(true)}>Reject instead</button>
          )}
        </div>
      ) : null}
      {(!d || rejecting) && (
        <div className="mt-2 flex flex-wrap items-center gap-1.5 pl-[26px]">
          {rejecting ? (
            <form
              className="flex w-full flex-col gap-1.5"
              onSubmit={(e) => {
                e.preventDefault();
                review.reject(c.i, reason);
                setRejecting(false);
                setReason("");
              }}
            >
              <input autoFocus aria-label={`Why reject change ${c.i + 1}? (optional)`} placeholder="Reason (optional)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} onKeyDown={(e) => e.key === "Escape" && setRejecting(false)} className="h-[28px] rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none" />
              <span className="flex gap-1.5">
                <Button type="submit" variant="outline" disabled={busy}>Reject</Button>
                <Button variant="ghost" onClick={() => setRejecting(false)}>Cancel</Button>
              </span>
            </form>
          ) : (
            <>
              <Button variant="primary" disabled={busy} onClick={() => review.accept(c.i)}>Accept</Button>
              <Button variant="outline" disabled={busy} onClick={() => setRejecting(true)}>Reject</Button>
            </>
          )}
          {!rejecting && c.target && <Button variant="ghost" aria-expanded={discussing} onClick={() => setDiscussing((x) => !x)}>Discuss</Button>}
        </div>
      )}
      {d && c.target && <div className="mt-1 pl-[26px]"><Button variant="ghost" aria-expanded={discussing} onClick={() => setDiscussing((x) => !x)}>Discuss</Button></div>}
      {discussing && c.target && <Thread chatId={chatId} canvasId={canvasId} seq={seq} node={c.target} design={design} persona={persona} />}
    </li>
  );
}

/** A node's comment thread: the person's note goes to the persona, who answers in the thread. */
function Thread({ chatId, canvasId, seq, node, design, persona }: { chatId: string; canvasId: string; seq: number; node: string; design: Design; persona: string }) {
  const comments = useCanvasComments(chatId, canvasId, true).data?.comments ?? [];
  const actions = useCanvasActions(chatId, canvasId);
  const [body, setBody] = useState("");
  const [error, setError] = useState<string>();
  const here = comments.filter((c) => c.anchor.node === node);
  const root = here.find((c) => !c.parent_id);
  const thread = root ? comments.filter((c) => c.id === root.id || c.parent_id === root.id) : [];
  const label = find(design, node)?.node;
  const send = async () => {
    const text = body.trim();
    if (!text) return;
    setError(undefined);
    try {
      const made = await actions.add.mutateAsync(root ? { body: text, parent_id: root.id } : { body: text, seq, node, point: { x: 0.5, y: 0.5 } });
      await actions.send.mutateAsync({ comment_ids: [made.id] });
      setBody("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn’t send the comment.");
    }
  };
  return (
    <div className="mt-2 flex flex-col gap-2 border-t border-border-subtle pt-2 pl-[26px]" data-testid="review-thread">
      {thread.map((c) => (
        <p key={c.id} className="text-12 text-fg-2">
          <span className="font-semibold text-fg">{c.author_type === "user" ? "You" : persona}</span> {c.body}
        </p>
      ))}
      <textarea aria-label={`Comment on ${label ? labelOf(label) : "this layer"}`} rows={2} value={body} onChange={(e) => setBody(e.target.value)} placeholder={root ? "Reply…" : `Ask ${persona} about this…`} className="w-full resize-none rounded-md border border-border-strong bg-surface p-1.5 text-13 text-fg focus:border-accent focus:outline-none" />
      {error && <p role="alert" className="text-12 text-pill-blocked-fg">{error}</p>}
      <Button variant="outline" className="self-start" disabled={!body.trim() || actions.add.isPending || actions.send.isPending} onClick={() => void send()}>Send</Button>
    </div>
  );
}

function CommentList({ comments, design }: { comments: { id: string; parent_id?: string | null; author_type: string; body: string; anchor: { node?: string } }[]; design: Design }) {
  const roots = comments.filter((c) => !c.parent_id);
  if (!roots.length) return <p className="text-13 text-fg-tertiary">No comments yet. Discuss a change to start a thread on its layer.</p>;
  return (
    <ul className="flex flex-col gap-3">
      {roots.map((r) => (
        <li key={r.id} className="rounded-[10px] border border-border-subtle bg-surface-raised p-3 text-13">
          <span className="text-11 text-fg-tertiary">{r.anchor.node ? (find(design, r.anchor.node) ? labelOf(find(design, r.anchor.node)!.node) : "a layer") : "Design"}</span>
          {[r, ...comments.filter((c) => c.parent_id === r.id)].map((c) => (
            <p key={c.id} className="mt-1 text-fg-2">
              <span className="font-semibold text-fg">{c.author_type === "user" ? "You" : "Persona"}</span> {c.body}
            </p>
          ))}
        </li>
      ))}
    </ul>
  );
}
