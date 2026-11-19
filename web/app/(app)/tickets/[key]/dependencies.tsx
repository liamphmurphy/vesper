"use client";
import Link from "next/link";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas, type Ticket } from "@/lib/api/client";
import { hasLiveRun, keys as queryKeys } from "@/lib/api/hooks";
import { Button, IconButton } from "@/components/ui/button";
import { TextInput } from "@/components/ui/primitives";
import { StatusGlyph } from "@/components/domain/glyphs";
import { STATUS_NAME } from "@/components/domain/meta";
import { cx } from "@/lib/cx";
import { hoverReveal } from "@/lib/reveal";

type Dep = Schemas["TicketDependency"];
const KEY = /^[A-Za-z][A-Za-z0-9]*-\d+$/;

/** Set a ticket's blockers (PUT /tickets/{key}/dependencies, checked against its dependency_revision). */
function putBlockers(key: string, revision: number, blockedBy: string[]) {
  return unwrap(api.PUT("/tickets/{key}/dependencies", { params: { path: { key } }, body: { revision, blocked_by: blockedBy } }));
}

export function useDependencyChange(t: Ticket) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (c: { list: "blocked_by" | "blocks"; op: "add" | "remove"; key: string }) => {
      if (c.list === "blocked_by") {
        const keys = t.blocked_by.map((d) => d.key);
        return putBlockers(t.key, t.dependency_revision, c.op === "add" ? [...keys, c.key] : keys.filter((k) => k !== c.key));
      }
      // "Blocks" lives on the other ticket: read its blockers and revision first.
      const other = await unwrap(api.GET("/tickets/{key}", { params: { path: { key: c.key } } }));
      const keys = other.blocked_by.map((d) => d.key);
      return putBlockers(other.key, other.dependency_revision, c.op === "add" ? [...keys, t.key] : keys.filter((k) => k !== t.key));
    },
    // The saved ticket carries the new dependency_revision; cache it before the
    // buttons re-enable so a quick second edit doesn't send a stale revision.
    onSuccess: (saved) => qc.setQueryData(queryKeys.ticket(saved.key), saved),
    onSettled: () =>
      Promise.all(["tickets", "planning", "inbox", "bootstrap", "dashboard", "agent-overviews", "boards"].map((key) => qc.invalidateQueries({ queryKey: [key] }))),
  });
}

/**
 * Blocked by / Blocks in the side panel. Each list shows the linked tickets'
 * status and edits in place: adding to "Blocks" adds this ticket as a blocker
 * of the other one.
 */
export function Dependencies({ ticket: t }: { ticket: Ticket }) {
  const change = useDependencyChange(t);
  const live = hasLiveRun(t);
  return (
    <div className="flex flex-col gap-5">
      <DepList
        id="blocked-by"
        title="Blocked by"
        items={t.blocked_by}
        exclude={[t.key, ...t.blocked_by.map((d) => d.key)]}
        disabled={live || change.isPending}
        disabledReason={live ? "Finish or cancel the active run before changing what blocks this ticket" : undefined}
        onAdd={(key) => change.mutate({ list: "blocked_by", op: "add", key })}
        onRemove={(key) => change.mutate({ list: "blocked_by", op: "remove", key })}
      />
      <DepList
        id="blocks"
        title="Blocks"
        items={t.blocks}
        exclude={[t.key, ...t.blocks.map((d) => d.key)]}
        disabled={change.isPending}
        onAdd={(key) => change.mutate({ list: "blocks", op: "add", key })}
        onRemove={(key) => change.mutate({ list: "blocks", op: "remove", key })}
      />
      {change.isError && (
        <p role="alert" className="px-2 text-12 text-pill-blocked-fg">
          {change.error.message}
        </p>
      )}
    </div>
  );
}

function DepList({
  id,
  title,
  items,
  exclude,
  disabled,
  disabledReason,
  onAdd,
  onRemove,
}: {
  id: string;
  title: string;
  items: Dep[];
  exclude: string[];
  disabled: boolean;
  disabledReason?: string;
  onAdd: (key: string) => void;
  onRemove: (key: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [search, setSearch] = useState("");
  const q = search.trim();
  const candidates = useQuery({
    queryKey: ["tickets", "dependency-search", q],
    enabled: adding && q.length >= 2,
    queryFn: () => unwrap(api.GET("/tickets", { params: { query: { q, view: "all" } } })),
  });
  const add = (key: string) => {
    const k = key.trim().toUpperCase();
    if (k && !exclude.includes(k)) onAdd(k);
    setSearch("");
    setAdding(false);
  };
  const shown = (candidates.data?.tickets ?? []).filter((c) => !exclude.includes(c.key)).slice(0, 6);

  return (
    <section id={id} aria-labelledby={`${id}-title`} className="flex scroll-mt-16 flex-col gap-1.5">
      <div className="flex items-center justify-between px-2">
        <h2 id={`${id}-title`} className="text-13 text-fg-tertiary">
          {title}
          {items.length > 0 && <span className="ml-1.5 font-mono">{items.length}</span>}
        </h2>
        <Button variant="ghost" icon="plus" disabled={disabled} title={disabledReason} aria-expanded={adding} onClick={() => setAdding((v) => !v)} className="h-6 px-1.5 text-12">
          Add<span className="sr-only"> to {title}</span>
        </Button>
      </div>
      {items.length === 0 && !adding && <p className="px-2 text-12 text-fg-tertiary">{title === "Blocks" ? "Doesn’t block other tickets." : "No blockers."}</p>}
      <ul className="flex flex-col">
        {items.map((d) => (
          <li key={d.key} className="group flex min-h-8 items-center gap-2 rounded-md px-2 hover:bg-hover">
            <StatusGlyph state={d.status} size={12} surface="var(--bg-panel)" label={false} />
            <Link href={`/tickets/${d.key}`} className="flex min-w-0 flex-1 items-baseline gap-2 text-13">
              <span className="flex-none font-mono text-12 text-fg-secondary">{d.key}</span>
              <span className="truncate text-fg-2" title={d.title}>
                {d.title}
              </span>
            </Link>
            <span className="flex-none text-12 text-fg-tertiary">{STATUS_NAME[d.status]}</span>
            <IconButton
              icon="x"
              size={22}
              label={`Remove ${d.key} from ${title}`}
              disabled={disabled}
              onClick={() => onRemove(d.key)}
              className={cx(hoverReveal(), "focus-visible:opacity-100")}
            />
          </li>
        ))}
      </ul>
      {adding && (
        <div className="flex flex-col gap-1 px-2">
          <TextInput
            autoFocus
            aria-label={`Add a ticket to ${title}`}
            placeholder="Search tickets or type a key"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") setAdding(false);
              if (e.key === "Enter") {
                e.preventDefault();
                if (KEY.test(q)) add(q);
                else if (shown[0]) add(shown[0].key);
              }
            }}
          />
          {shown.map((c) => (
            <button key={c.key} type="button" onClick={() => add(c.key)} className="flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-13 hover:bg-hover">
              <StatusGlyph state={c.status} size={12} label={false} />
              <span className="font-mono text-12 text-fg-tertiary">{c.key}</span>
              <span className="truncate">{c.title}</span>
            </button>
          ))}
          {q.length >= 2 && candidates.isSuccess && shown.length === 0 && !KEY.test(q) && <p className="px-2 text-12 text-fg-tertiary">No tickets match “{q}”.</p>}
          <p className="text-12 text-fg-tertiary">A dispatched ticket queues until its blockers are Done.</p>
        </div>
      )}
    </section>
  );
}
