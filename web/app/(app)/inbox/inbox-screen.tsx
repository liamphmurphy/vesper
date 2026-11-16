"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useAgentOverviews, useBootstrap, useInbox } from "@/lib/api/hooks";
import { AgentAvatar } from "@/components/domain/avatars";
import { rememberProject, useRememberedProject } from "@/components/shell/project-scope";
import { openShortcuts } from "@/components/shell/shortcuts";
import { TopBar } from "@/components/shell/topbar";
import { Segmented } from "@/components/ui/controls";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Kbd, Skeleton } from "@/components/ui/primitives";
import { useMotionList } from "@/components/ui/motion";
import { cx } from "@/lib/cx";
import { duration } from "@/lib/format";
import { KIND, groupItems, isOpen, openHref, longWait, nextSelection, step, waited, type Sort, type View } from "@/lib/inbox";
import { DetailPane, type PaneActions } from "./detail-pane";
import { FilterMenu } from "@/components/domain/pickers";
import { useCompact } from "@/lib/viewport";
import { CompactInbox } from "./compact-inbox";

type Item = Schemas["InboxItem"];

export const PILL: Record<string, string> = {
  human: "bg-pill-human-bg text-pill-human-fg",
  blocked: "bg-pill-blocked-bg text-pill-blocked-fg",
  info: "bg-pill-review-bg text-pill-review-fg",
};

function isTyping(el: EventTarget | null) {
  return (
    el instanceof HTMLElement &&
    (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.getAttribute("role") === "combobox")
  );
}

function Row({ item, selected, sent, onSelect }: { item: Item; selected: boolean; sent: boolean; onSelect: () => void }) {
  const kind = KIND[item.kind] ?? { label: item.kind, tone: "info" };
  return (
    <li data-motion-key={item.id}>
      <button
        type="button"
        data-inbox-row={item.id}
        onClick={onSelect}
        aria-current={selected ? "true" : undefined}
        tabIndex={selected ? 0 : -1}
        className={cx(
          "relative flex min-h-[60px] w-full items-center gap-3 border-b border-border-subtle px-5 py-2.5 text-left outline-none focus-visible:bg-hover",
          selected ? "bg-selected" : "hover:bg-row-hover",
        )}
      >
        {selected && <span aria-hidden className="absolute inset-y-0 left-0 w-0.5 bg-accent" />}
        {item.agent ? (
          <AgentAvatar name={item.agent.name} colorIndex={item.agent.color_index} label={false} size="md" />
        ) : (
          <span aria-hidden className="grid size-6 flex-none place-items-center rounded-md bg-track text-fg-tertiary">
            <Icon name="inbox" size={13} />
          </span>
        )}
        <span className="flex min-w-0 flex-1 flex-col gap-1">
          <span className="flex min-w-0 items-center gap-2 text-13">
            <span className={cx("flex-none rounded-[4px] px-1.5 py-px text-12 font-medium", PILL[kind.tone])}>{kind.label}</span>
            {(item.ticket_key || item.project) && (
              <span className="flex-none font-mono text-12 text-fg-tertiary">{item.ticket_key || item.project}</span>
            )}
            <span className="truncate font-semibold text-fg">{item.title}</span>
          </span>
          <span className="truncate text-13 text-fg-tertiary">
            {item.agent && <span className="text-fg-secondary">{item.agent.name} · </span>}
            {item.summary}
          </span>
        </span>
        {sent ? (
          <span className="flex-none text-12 font-medium text-accent">Sent</span>
        ) : (
          <span
            title={new Date(item.created_at).toLocaleString()}
            className={cx("flex-none text-12", longWait(item.created_at) ? "text-pill-human-fg" : "text-fg-tertiary")}
          >
            {waited(item.created_at)}
          </span>
        )}
      </button>
    </li>
  );
}

/** Nothing waits on you: say so, and show what is still running. */
export function AllClear({ project, done, onShowDone }: { project: string; done: number; onShowDone: () => void }) {
  const overviews = useAgentOverviews();
  const running = (overviews.data?.agents ?? [])
    .flatMap((o) => o.assignments.map((w) => ({ ...w, agent: o.agent })))
    .filter((w) => !project || w.ticket.key.startsWith(`${project}-`));
  return (
    <div className="flex flex-1 flex-col items-center gap-3 px-6 py-14 text-center">
      <span className="grid size-12 place-items-center rounded-full border border-state-done/50 bg-state-done/10 text-state-done">
        <Icon name="check" size={22} />
      </span>
      <h2 className="type-title text-fg">All clear</h2>
      <p className="text-13 text-fg-secondary">
        No approvals, questions, mockups, proposals or failed runs need you in {project || "All spaces"}.
      </p>
      {done > 0 && (
        <button type="button" onClick={onShowDone} className="text-13 text-accent hover:underline">
          {done} done · Show done
        </button>
      )}
      <section
        aria-label="Still running"
        className="mt-4 w-full max-w-[580px] overflow-hidden rounded-xl border border-border bg-surface text-left"
      >
        <h3 className="border-b border-border-subtle bg-surface-sunken px-5 py-2 text-12 font-medium text-fg-secondary">
          Still running <span className="font-mono text-fg-tertiary">{running.length}</span>
        </h3>
        {overviews.isPending ? (
          <Skeleton className="m-4 h-8" />
        ) : running.length === 0 ? (
          <p className="px-5 py-4 text-13 text-fg-tertiary">
            No runs in progress.{" "}
            <Link href="/tickets?layout=board" className="text-accent hover:underline">
              Dispatch a ready ticket from the Board.
            </Link>
          </p>
        ) : (
          <ul>
            {running.map((w) => (
              <li key={w.run_id} className="border-b border-border-subtle last:border-b-0">
                <Link href={`/runs/${w.run_id}`} className="flex min-h-[44px] items-center gap-3 px-5 py-2 text-13 hover:bg-hover">
                  <AgentAvatar name={w.agent.name} colorIndex={w.agent.color_index} label={false} />
                  <span className="w-28 flex-none truncate font-mono text-12 text-fg-tertiary">{w.ticket.key}</span>
                  <span className="min-w-0 flex-1 truncate text-fg">
                    {w.ticket.title} <span className="text-fg-tertiary">· {w.agent.name}</span>
                  </span>
                  <span className="flex-none text-12 text-fg-tertiary">
                    {w.state === "queued" ? "queued" : `${w.state.replaceAll("_", " ")} ${duration(w.started_at)}`}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        <Link href="/runs" className="block border-t border-border-subtle px-5 py-2.5 text-13 text-accent hover:underline">
          View all runs →
        </Link>
      </section>
    </div>
  );
}

/** Compact screens get the card list and approval sheet (compact-inbox.tsx); the rest the list and pane. */
export function InboxScreen() {
  return useCompact() ? <CompactInbox /> : <DesktopInbox />;
}

function DesktopInbox() {
  const router = useRouter();
  const { data: bootstrap } = useBootstrap();
  const remembered = useRememberedProject();
  // The filter follows the global project switcher; "" is All projects.
  const project = remembered ?? "";
  const [view, setView] = useState<View>("open");
  const [sort, setSort] = useState<Sort>("oldest");
  // The selection and its slot, so focus can take the same slot when the item leaves.
  const [sel, setSel] = useState<{ id?: string; index: number }>({ index: 0 });
  const [sent, setSent] = useState<ReadonlySet<string>>(new Set());
  const inbox = useInbox(project || undefined, remembered !== undefined);
  const all = useMemo(() => inbox.data ?? [], [inbox.data]);
  const groups = useMemo(() => groupItems(all, view, sort), [all, view, sort]);
  const ids = useMemo(() => groups.flatMap((g) => g.items.map((i) => i.id)), [groups]);
  const openCount = all.filter(isOpen).length;
  const doneCount = all.length - openCount;

  // Keep the selection in the same slot when the selected item leaves the
  // list (resolved, marked done): the next item, or the previous when it was last.
  const current = nextSelection(ids, sel.id, sel.index);
  const at = current ? ids.indexOf(current) : 0;
  if (current !== sel.id || at !== sel.index) setSel({ id: current, index: at });
  const item = all.find((i) => i.id === current);
  const focusRow = (id: string) => document.querySelector<HTMLElement>(`[data-inbox-row="${CSS.escape(id)}"]`)?.focus();
  // When the focused row or pane unmounts, focus falls to <body>: hand it to the selected row.
  useEffect(() => {
    if (current && (!document.activeElement || document.activeElement === document.body)) focusRow(current);
  }, [current]);

  const select = (id: string | undefined, focus = true) => {
    setSel({ id, index: id ? ids.indexOf(id) : 0 });
    if (id && focus) focusRow(id);
  };
  const backToList = () => current && focusRow(current);
  const actions = useRef<PaneActions>({});
  const rows = useRef<HTMLDivElement>(null);
  useMotionList(rows);
  const register = useCallback((a: PaneActions) => {
    actions.current = a;
  }, []);
  const markSent = (id: string) => setSent((s) => new Set(s).add(id));

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target) || document.querySelector('[role="dialog"]')) return;
      const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      if (k === "j" || k === "k") {
        e.preventDefault();
        select(step(ids, current, k === "j" ? 1 : -1));
        return;
      }
      if (!item) return;
      if (k === "Enter") {
        // From the list (or nowhere): open the item. Buttons and links in the pane keep Enter.
        const t = e.target;
        if (t === document.body || (t instanceof HTMLElement && t.closest("[data-inbox-row]"))) {
          e.preventDefault();
          openHref(item.href, router.push);
        }
        return;
      }
      const run = { a: actions.current.approve, d: actions.current.deny, r: actions.current.focus, e: actions.current.done }[k];
      if (run) {
        e.preventDefault();
        run();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const setProject = (key: string) => {
    rememberProject(key || null);
    setSel({ index: 0 });
  };

  return (
    <>
      <TopBar
        crumbs={[
          {
            label: (
              <>
                Inbox{" "}
                <span className="ml-1 font-normal text-fg-tertiary">
                  {openCount ? `${openCount} waiting on you` : "Nothing waiting on you"}
                </span>
              </>
            ),
          },
        ]}
        actions={
          <Button variant="outline" onClick={openShortcuts}>
            <Kbd>?</Kbd> Shortcuts
          </Button>
        }
      />
      <div className="flex min-h-0 flex-1 flex-wrap">
        <section aria-label="Inbox" className="flex min-w-0 flex-[2_1_480px] flex-col">
          <div className="flex flex-wrap items-center gap-3 border-b border-border px-5 py-2.5">
            <Segmented
              label="Show"
              small
              value={view}
              onChange={(v) => {
                setView(v);
                setSel({ index: 0 });
              }}
              options={[
                { value: "open", label: <>Open <span className="font-mono text-fg-tertiary">{openCount}</span></> },
                { value: "done", label: <>Done <span className="font-mono text-fg-tertiary">{doneCount}</span></> },
              ]}
            />
            <FilterMenu quiet label="Sort" value={sort} onChange={(v) => setSort(v as Sort)}
              options={[{ value: "oldest", label: "Longest wait first" }, { value: "newest", label: "Newest first" }]} />
            <span className="ml-auto flex items-center gap-1.5 text-12 text-fg-tertiary">
              Project
              <FilterMenu label="Filter space" value={project} onChange={setProject}
                options={[{ value: "", label: "All" }, ...(bootstrap?.projects ?? []).filter((p) => !p.archived).map((p) => ({ value: p.key, label: p.name }))]} />
            </span>
          </div>
          {inbox.isPending ? (
            <div aria-busy="true" className="space-y-3 p-5">
              {[0, 1, 2].map((i) => (
                <Skeleton key={i} className="h-[60px]" />
              ))}
            </div>
          ) : inbox.isError ? (
            <div role="alert" className="flex items-center gap-3 p-6 text-pill-blocked-fg">
              Couldn’t load your inbox. <Button onClick={() => inbox.refetch()}>Retry</Button>
            </div>
          ) : groups.length === 0 ? (
            view === "open" ? (
              <AllClear project={project} done={doneCount} onShowDone={() => setView("done")} />
            ) : (
              <div className="flex flex-col items-center gap-3 px-6 py-14 text-center">
                <h2 className="type-heading">Nothing done yet</h2>
                <p className="text-13 text-fg-secondary">Items you resolve or mark done appear here until they change again.</p>
                <Button variant="outline" onClick={() => setView("open")}>
                  Show open
                </Button>
              </div>
            )
          ) : (
            <div ref={rows} key={`${view}:${project}`} className="relative min-h-0 flex-1 overflow-y-auto">
              {groups.map((g) => (
                <div key={g.key} role="group" aria-label={g.label}>
                  <h2 className="flex h-[33px] items-center gap-2 bg-surface-sunken px-5 text-12 font-medium text-fg-secondary">
                    {g.label} <span className="font-mono text-11 text-fg-tertiary">{g.items.length}</span>
                  </h2>
                  <ul>
                    {g.items.map((i) => (
                      <Row key={i.id} item={i} selected={i.id === current} sent={sent.has(i.id)} onSelect={() => select(i.id, false)} />
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          )}
          <div aria-hidden className="hidden flex-wrap items-center gap-x-4 gap-y-1 border-t border-border px-5 py-2 text-12 text-fg-tertiary md:flex">
            <span><Kbd>J</Kbd> <Kbd>K</Kbd> move</span>
            <span><Kbd>A</Kbd> approve</span>
            <span><Kbd>D</Kbd> deny</span>
            <span><Kbd>R</Kbd> reply</span>
            <span><Kbd>E</Kbd> done</span>
            <span><Kbd>↵</Kbd> open</span>
            <span><Kbd>?</Kbd> all shortcuts</span>
          </div>
        </section>
        {item && <DetailPane key={item.id} item={item} register={register} onSent={markSent} onLeave={backToList} />}
      </div>
    </>
  );
}
