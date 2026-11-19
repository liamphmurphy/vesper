"use client";

import { useState } from "react";
import type { ActivityEvent, Ticket } from "@/lib/api/client";
import { useAddCriterion, useDeleteCriterion, useUpdateCriterion } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, ago } from "@/lib/format";
import { IconButton } from "@/components/ui/button";
import { ActorAvatar } from "./timeline";
import { hoverReveal } from "@/lib/reveal";

/** Who last checked each criterion and when, from criterion_checked events (oldest first). */
export function checkedBy(events: ActivityEvent[] | undefined) {
  const m = new Map<string, ActivityEvent>();
  for (const e of events ?? []) {
    const id = (e.payload as { criterion_id?: unknown }).criterion_id;
    if (typeof id !== "string") continue;
    if (e.verb === "criterion_checked") m.set(id, e);
    else if (e.verb === "criterion_unchecked") m.delete(id);
  }
  return m;
}

export function Criteria({ t, events }: { t: Ticket; events?: ActivityEvent[] }) {
  const checks = checkedBy(events);
  const add = useAddCriterion(t.key);
  const update = useUpdateCriterion(t.key);
  const remove = useDeleteCriterion(t.key);
  const [draft, setDraft] = useState("");
  const done = t.criteria.filter((c) => c.done).length;

  return (
    <section className="flex flex-col gap-2.5 rounded-xl border border-border-subtle bg-surface/50 px-4 py-3.5">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-11 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
          Acceptance criteria
        </h2>
        {t.criteria.length > 0 && (
          <span className={cx("font-mono text-11", done === t.criteria.length ? "text-state-done" : "text-fg-tertiary")}>
            {done}/{t.criteria.length}
          </span>
        )}
      </div>
      <ul className="flex flex-col">
        {t.criteria.map((c) => (
          <li key={c.id} className="group flex min-h-8 items-center gap-3 rounded-md">
            <input
              id={`crit-${c.id}`}
              type="checkbox"
              checked={c.done}
              onChange={(e) => update.mutate({ id: c.id, done: e.target.checked })}
              className="size-3.5 flex-none accent-[var(--state-done)]"
            />
            <label htmlFor={`crit-${c.id}`} className={cx("flex-1 py-1 text-14", c.done ? "text-fg-tertiary line-through" : "text-fg-2")}>
              {c.text}
            </label>
            {c.done && checks.get(c.id) && <CheckedBy e={checks.get(c.id)!} />}
            <IconButton
              icon="x"
              label={`Remove criterion: ${c.text}`}
              size={24}
              onClick={() => remove.mutate(c.id)}
              className={cx(hoverReveal(), "focus-visible:opacity-100")}
            />
          </li>
        ))}
      </ul>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (!draft.trim()) return;
          add.mutate(draft, { onSuccess: () => setDraft("") });
        }}
        className="flex items-center gap-3"
      >
        <span aria-hidden className="size-3.5 flex-none rounded-[3px] border border-dashed border-border-strong" />
        <label htmlFor="new-criterion" className="sr-only">
          Add a criterion
        </label>
        <input
          id="new-criterion"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Add a criterion and press Enter"
          className="h-8 flex-1 bg-transparent text-14 text-fg outline-none placeholder:text-fg-tertiary"
        />
      </form>
      {add.isError && <p className="text-12 text-pill-blocked-fg">{add.error.message}</p>}
    </section>
  );
}

function CheckedBy({ e }: { e: ActivityEvent }) {
  return (
    <span className="flex flex-none items-center gap-1.5 text-12 text-fg-tertiary">
      <ActorAvatar actor={e.actor} />
      <span>
        <span className="sr-only">Checked by </span>
        {e.actor.name}
        {" · "}
        <time dateTime={e.created_at} title={absoluteTime(e.created_at)}>
          {ago(e.created_at)}
        </time>
      </span>
    </span>
  );
}
