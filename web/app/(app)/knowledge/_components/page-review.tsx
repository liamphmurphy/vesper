"use client";

import { useState } from "react";
import { cx } from "@/lib/cx";
import { useResolveReview, type Page, type PageChange, type Review } from "@/lib/api/knowledge-hooks";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";

const pending = (c: PageChange) => c.state === "pending";

/** Every undecided change across a page's reviews, flattened with where it came from. */
export function undecided(page: Page): { review: Review; change: PageChange }[] {
  return page.reviews.flatMap((review) => (review.changes ?? []).filter(pending).map((change) => ({ review, change })));
}

/** The bar over a page with persona changes to review: how many, and decide the rest at once. */
export function ReviewBar({ page, persona, direct }: { page: Page; persona: string; direct: boolean }) {
  const resolve = useResolveReview(page.id);
  const left = undecided(page);
  const stale = page.reviews.flatMap((r) => r.changes ?? []).filter((c) => c.state === "stale").length;
  if (!left.length) return null;
  const decideAll = (accept: boolean) => {
    for (const r of page.reviews) {
      const decisions = (r.changes ?? []).filter(pending).map((c) => ({ index: c.index as number, accept }));
      if (decisions.length) resolve.mutate({ version: r.id, decisions });
    }
  };
  return (
    <div className="mx-4 mt-3 flex items-center gap-3 rounded-xl border border-state-human/35 bg-pill-human-bg px-4 py-2.5 print:hidden">
      <Icon name="bulb" size={15} className="text-state-human" />
      <p className="flex-1 text-13 text-fg">
        <b>
          {persona} {direct ? "made" : "suggested"} {left.length} {left.length === 1 ? "change" : "changes"}
        </b>
        {direct && <span className="text-fg-secondary"> · applied, reviewed afterwards</span>}
        {stale > 0 && <span className="text-state-human"> · {stale} stale</span>}
      </p>
      {resolve.error && <span className="text-12 text-state-blocked">{resolve.error.message}</span>}
      <Button onClick={() => decideAll(false)} disabled={resolve.isPending}>
        {direct ? "Undo rest" : "Reject rest"}
      </Button>
      <Button variant="primary" onClick={() => decideAll(true)} disabled={resolve.isPending}>
        {direct ? "Keep rest" : "Accept rest"}
      </Button>
    </div>
  );
}

/** The changes themselves, one card each: what it was, what it becomes, why, and accept or reject with a reason. */
export function ReviewList({ page, direct }: { page: Page; direct: boolean }) {
  const items = page.reviews.flatMap((review) => (review.changes ?? []).map((change) => ({ review, change })));
  if (!items.some((i) => pending(i.change) || i.change.state === "stale")) return null;
  return (
    <section aria-label="Changes to review" className="mb-8 space-y-3 print:hidden">
      {items
        .filter((i) => pending(i.change) || i.change.state === "stale")
        .map(({ review, change }) => (
          <ChangeCard key={`${review.id}:${change.index}`} pageId={page.id} review={review} change={change} direct={direct} />
        ))}
    </section>
  );
}

function ChangeCard({ pageId, review, change, direct }: { pageId: string; review: Review; change: PageChange; direct: boolean }) {
  const resolve = useResolveReview(pageId);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const decide = (accept: boolean) => resolve.mutate({ version: review.id, decisions: [{ index: change.index as number, accept, reason: accept ? undefined : reason.trim() || undefined }] });
  const n = (change.index as number) + 1;
  if (change.state === "stale")
    return (
      <div className="flex gap-3 rounded-xl border border-state-progress/45 bg-pill-human-bg p-4">
        <Icon name="alert" size={15} className="mt-0.5 text-state-progress" />
        <div className="text-13">
          <p className="font-semibold text-fg">Change {n} is stale: you edited this passage after it was suggested</p>
          <p className="mt-1 text-fg-secondary">Your text was kept. The persona gets the change back with this note so it can try again against your version.</p>
        </div>
      </div>
    );
  const property = change.kind && change.kind !== "body";
  return (
    <div className="rounded-xl border border-border bg-surface p-4">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1 text-15 leading-relaxed">
          {property && <p className="mb-1 text-12 font-semibold text-fg-tertiary">{change.key ? `Property ${change.key}` : "Properties"}</p>}
          {change.before && <p className="whitespace-pre-wrap rounded bg-pill-blocked-bg px-1 text-pill-blocked-fg line-through decoration-pill-blocked-fg/70">{change.before}</p>}
          {change.after && <p className="mt-1 whitespace-pre-wrap rounded bg-pill-done-bg px-1 text-pill-done-fg">{change.after}</p>}
          <p className="mt-2 text-12 italic text-fg-tertiary">
            {n} · {change.why ? `Why: ${change.why}` : "No reason given"}
          </p>
        </div>
        <div className="flex flex-none gap-1.5">
          <button aria-label={direct ? "Keep" : "Accept"} title={direct ? "Keep" : "Accept"} disabled={resolve.isPending} onClick={() => decide(true)} className="grid size-8 place-items-center rounded-lg border border-border-strong bg-surface text-state-done hover:bg-hover">
            <Icon name="check" size={15} />
          </button>
          <button
            aria-label={direct ? "Undo" : "Reject"}
            title={direct ? "Undo" : "Reject with a reason"}
            disabled={resolve.isPending}
            onClick={() => setRejecting((r) => !r)}
            className={cx("grid size-8 place-items-center rounded-lg border border-border-strong bg-surface text-state-blocked hover:bg-hover", rejecting && "bg-selected")}
          >
            <Icon name="x" size={15} />
          </button>
        </div>
      </div>
      {rejecting && (
        <div className="mt-3 flex items-center gap-2 rounded-lg bg-surface-raised p-3">
          <input
            autoFocus
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && decide(false)}
            placeholder="Why? The persona reads this in the page's chat"
            aria-label="Reason"
            className="h-8 flex-1 rounded-md border border-accent bg-surface-sunken px-2.5 text-13 text-fg outline-none"
          />
          <Button onClick={() => decide(false)} disabled={resolve.isPending}>
            {direct ? "Undo" : "Reject"}
          </Button>
        </div>
      )}
      {resolve.error && <p className="mt-2 text-12 text-state-blocked">{resolve.error.message}</p>}
    </div>
  );
}
