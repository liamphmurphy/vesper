"use client";

import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { ApiError } from "@/lib/api/client";
import { memoryKeys, useChatRunEvents, useDeleteMemory, useMemory, useUpdateMemory } from "@/lib/api/hooks";
import { memoryNotices, type MemoryNotice } from "@/lib/memory-ui";
import { cx } from "@/lib/cx";
import { Icon } from "@/components/ui/icon";

type Done = "undone" | "forgotten" | "restored";

const linkBtn = "text-12 text-accent hover:underline disabled:opacity-50";

function Notice({ n }: { n: MemoryNotice }) {
  const router = useRouter();
  const [done, setDone] = useState<Done | null>(null);
  const del = useDeleteMemory();
  const update = useUpdateMemory();
  // A memory forgotten since (here, in the manager or by a later turn) no longer offers actions.
  const live = useMemory(n.kind === "forgotten" || done ? undefined : n.id);
  const gone = live.error instanceof ApiError && live.error.status === 404;
  const busy = del.isPending || update.isPending;
  const err = del.error ?? update.error;
  const quoted = `“${n.title}”`;

  let text: string;
  let muted = true;
  if (done === "undone") text = "Not saved. I won’t remember this.";
  else if (done === "forgotten" || n.kind === "forgotten") text = `Forgot 1 memory: ${quoted}`;
  else if (done === "restored") text = `Restored the earlier version: “${n.previous?.title ?? n.title}”`;
  else if (gone) text = `${n.kind === "saved" ? "Saved" : "Updated"} ${quoted}, since forgotten.`;
  else {
    muted = false;
    // A space's memory is named, so it's clear the fact stays there.
    const where = live.data?.space_name ? `${live.data.space_name} memory` : "memory";
    text = `${n.kind === "saved" ? `Saved to ${where}` : `Updated ${where}`}: ${quoted}`;
  }
  const actionable = !muted && !done;
  return (
    <div
      data-testid="memory-notice"
      className={cx(
        "relative flex max-w-[min(720px,100%)] flex-wrap items-center gap-x-3 gap-y-1 overflow-hidden rounded-lg py-2 pl-4 pr-3",
        muted ? "border border-border bg-surface" : "bg-accent/10",
      )}
    >
      <span aria-hidden className={cx("absolute inset-y-0 left-0 w-[3px]", muted ? "bg-fg-tertiary" : "bg-accent")} />
      <Icon name="bookmark" size={14} className={muted ? "text-fg-tertiary" : "text-accent"} />
      <span className={cx("min-w-0 flex-1 text-12", muted ? "text-fg-secondary" : "text-fg")}>{text}</span>
      {actionable && (
        <span className="flex items-center gap-3">
          <button type="button" className={linkBtn} onClick={() => router.push(`/settings?section=memory&id=${encodeURIComponent(n.id)}`)}>
            View
          </button>
          {n.kind === "saved" && (
            <>
              <button type="button" className={linkBtn} disabled={busy} onClick={() => del.mutateAsync(n.id).then(() => setDone("undone"), () => undefined)}>
                Undo
              </button>
              <button type="button" className={linkBtn} disabled={busy} onClick={() => del.mutateAsync(n.id).then(() => setDone("forgotten"), () => undefined)}>
                Forget
              </button>
            </>
          )}
          {n.kind === "updated" && n.previous && (
            <button
              type="button"
              className={linkBtn}
              disabled={busy}
              title="Puts back the earlier title, summary and type"
              onClick={() =>
                update
                  .mutateAsync({ id: n.id, patch: { title: n.previous!.title, summary: n.previous!.summary, ...(n.previous!.type ? { type: n.previous!.type } : {}) } })
                  .then(() => setDone("restored"), () => undefined)
              }
            >
              Undo
            </button>
          )}
        </span>
      )}
      {err && (
        <p role="alert" className="basis-full text-12 text-pill-blocked-fg">
          {err instanceof Error ? err.message : "Couldn’t change the memory."}
        </p>
      )}
    </div>
  );
}

/** What the assistant saved, updated or forgot during a turn, under its reply (mockup frame 3c). */
export function MemoryNotices({ runId, since, until }: { runId?: string; since?: string; until?: string }) {
  const q = useChatRunEvents(runId, true, false);
  const notices = useMemo(() => memoryNotices(q.data, since, until), [q.data, since, until]);
  // The assistant changed memory: refresh the header count, the panel and earlier notices
  // (one it has since forgotten turns into "since forgotten").
  const qc = useQueryClient();
  const seen = notices.map((n) => n.key).join(",");
  useEffect(() => {
    if (seen) void qc.invalidateQueries({ queryKey: memoryKeys.all });
  }, [seen, qc]);
  if (notices.length === 0) return null;
  return (
    <div className="flex w-full flex-col items-start gap-1.5" aria-label="Memory changes">
      {notices.map((n) => (
        <Notice key={n.key} n={n} />
      ))}
    </div>
  );
}
