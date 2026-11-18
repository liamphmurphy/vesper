"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import { workSettingsHref } from "@/lib/spaces";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, ViewTransition } from "react";
import type { Bootstrap, Ticket } from "@/lib/api/client";
import { useCompact } from "@/lib/viewport";
import { useActivity, useBootstrap, useCosts, useTicket, useTickets, hasLiveRun } from "@/lib/api/hooks";
import { spendLabel } from "@/lib/costs";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { buildTicketToolbar, parseTicketToolbarAction } from "@/lib/native-shell/models/work-toolbars";
import { useNativeTitle } from "../_components/native-title";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton, TextArea } from "@/components/ui/primitives";
import { Sheet } from "@/components/ui/sheet";
import { Markdown } from "@/components/domain/markdown";
import { StartChatButton } from "@/components/domain/start-chat";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { TicketEditorDialog } from "@/components/domain/ticket-editor-dialog";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { Flag } from "@/components/domain/labels";
import { STATUS_NAME } from "@/components/domain/meta";
import { TicketCostChip } from "@/components/domain/cost-chip";
import { TopBar } from "@/components/shell/topbar";
import { BacklinksPanel } from "@/components/domain/backlinks";
import { ContextArtifacts } from "./context-artifacts";
import { Dependencies } from "./dependencies";
import { Criteria } from "./criteria";
import { GateStrip } from "./gates";
import { MetaStrip } from "./meta-strip";
import { CodeSection, Properties } from "./properties";
import { ApprovalBanner, needsDispatch, RunCard } from "./run-parts";
import { RunsHistory } from "./runs-history";
import { ConflictBanner, useTicketSave, type SaveTicket, type TicketSaver } from "./ticket-save";
import { Composer, Timeline } from "./timeline";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { WorkChat, WorkChatSheet } from "@/components/domain/work-chat";
import { WorkNavHeader } from "../../work/work-nav-header";
import { buildTicketNavModel } from "@/lib/native-shell/models/ticket";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";

function TitleEditor({ t, save }: { t: Ticket; save: SaveTicket }) {
  const [editing, setEditing] = useState(false);
  if (!editing) {
    return (
      <h1 className="type-display min-w-0 flex-1">
        <button type="button" onClick={() => setEditing(true)} className="-mx-1 rounded-md px-1 text-left hover:bg-hover" title="Edit title">
          <ViewTransition name={`ticket-title-${t.key}`} share="auto" default="none"><span>{t.title}</span></ViewTransition>
        </button>
        {t.epic_review && <span className="ml-2 inline-block rounded-full bg-pill-review-bg px-2 py-0.5 align-middle text-12 font-medium text-pill-review-fg">Final review</span>}
      </h1>
    );
  }
  const commit = (v: string) => {
    setEditing(false);
    if (v.trim() && v.trim() !== t.title) save({ title: v.trim() }, "title change");
  };
  return (
    <>
      <label htmlFor="title" className="sr-only">
        Title
      </label>
      <input
        id="title"
        autoFocus
        defaultValue={t.title}
        maxLength={300}
        onBlur={(e) => commit(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commit(e.currentTarget.value);
          if (e.key === "Escape") setEditing(false);
        }}
        className="type-display -mx-1 w-full rounded-md border border-accent bg-surface px-1 text-fg outline-none"
      />
    </>
  );
}

function Description({ t, save: saveTicket }: { t: Ticket; save: SaveTicket }) {
  const [draft, setDraft] = useState<string | null>(null);
  if (draft === null) {
    return t.description_md ? (
      <div className="group relative">
        <Markdown className="type-reading text-fg-2">{t.description_md}</Markdown>
        <Button variant="ghost" icon="edit" onClick={() => setDraft(t.description_md)} className="mt-1 h-7 px-2 text-12 text-fg-tertiary">
          Edit description
        </Button>
      </div>
    ) : (
      <button type="button" onClick={() => setDraft("")} className="w-full rounded-md py-1 text-left type-reading text-fg-tertiary hover:text-fg-secondary">
        Add a description…
      </button>
    );
  }
  const save = () => {
    if (draft !== t.description_md) saveTicket({ description_md: draft }, "description edit");
    setDraft(null);
  };
  return (
    <div className="flex flex-col gap-2">
      <label htmlFor="description" className="sr-only">
        Description (markdown)
      </label>
      <TextArea
        id="description"
        autoFocus
        rows={6}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) save();
          if (e.key === "Escape") setDraft(null);
        }}
        placeholder="What needs to happen and why. Markdown works."
      />
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={() => setDraft(null)}>
          Cancel
        </Button>
        <Button variant="primary" onClick={save} hint="⌘↵">
          Save
        </Button>
      </div>
    </div>
  );
}

/** Position within the project's list, for the "3 / 15" pager. */
function usePager(t: Ticket | undefined) {
  const list = useTickets({ project: t?.project.key, view: "all" });
  const tickets = list.data ?? [];
  const keys = tickets.map((x) => x.key);
  const i = t ? keys.indexOf(t.key) : -1;
  return { tickets, index: i, total: keys.length, prev: i > 0 ? keys[i - 1] : undefined, next: i >= 0 && i < keys.length - 1 ? keys[i + 1] : undefined };
}

function DetailSkeleton() {
  return (
    <div aria-busy="true" className="mx-auto flex w-full max-w-[var(--reading-max)] flex-col gap-4 px-7 py-10">
      <Skeleton className="h-7 w-2/3" />
      <Skeleton className="h-3 w-full" />
      <Skeleton className="h-3 w-5/6" />
      <Skeleton className="mt-6 h-3 w-40" />
      {[0, 1, 2].map((i) => (
        <Skeleton key={i} className="h-3 w-1/2" />
      ))}
    </div>
  );
}

/** "Dispatching queues it until X is Done" and similar: why Dispatch now is offered. */
function dispatchHint(t: Ticket) {
  const blockers = t.blocked_by.filter((d) => d.status !== "done");
  if (blockers.length) return `Dispatching queues it until ${blockers.map((d) => d.key).join(", ")} ${blockers.length === 1 ? "is" : "are"} Done.`;
  if (t.run) return `The last run ${t.run.state}. Dispatch again to start a new run.`;
  return `${t.assignee?.name ?? "The agent"} is assigned and waiting for dispatch. Assigning doesn’t start work.`;
}

/** Key, status, blocked badge and priority over the title, with the ticket's actions. */
function Header({ t, save, onEdit }: { t: Ticket; save: SaveTicket; onEdit: () => void }) {
  const [dispatching, setDispatching] = useState(false);
  const blockers = t.blocked_by.filter((d) => d.status !== "done");
  const dispatch = needsDispatch(t);
  return (
    <header className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2 text-13">
        <span className="font-mono text-fg-tertiary">{t.key}</span>
        <span className="inline-flex items-center gap-1.5 rounded-full border border-border px-2 py-0.5 text-fg-2">
          <StatusGlyph state={t.status} size={12} label={false} />
          {STATUS_NAME[t.status]}
        </span>
        {blockers.length > 0 && (
          <a href="#blocked-by" className="rounded-[5px] focus-visible:outline-2">
            <Flag tone="blocked">
              Blocked · {blockers.length} {blockers.length === 1 ? "blocker" : "blockers"}
            </Flag>
          </a>
        )}
        <span className="inline-flex items-center gap-1.5 text-fg-secondary">
          <PriorityGlyph priority={t.priority} />
        </span>
      </div>
      <div className="flex flex-wrap items-start gap-3">
        <TitleEditor t={t} save={save} />
        <div className="flex flex-none flex-wrap items-center gap-2">
          {dispatch && (
            <Button variant="approve" icon="play" disabled={t.project.archived} onClick={() => setDispatching(true)}>
              Dispatch now
            </Button>
          )}
          <StartChatButton attach={{ kind: "ticket", key: t.key }} title={`${t.key} ${t.title}`} project={t.project.key} />
          <Button variant="outline" icon="edit" hint="E" onClick={onEdit} aria-keyshortcuts="E">
            Edit
          </Button>
        </div>
      </div>
      {dispatch && <p className="text-12 text-pill-human-fg">{dispatchHint(t)}</p>}
      {dispatching && <DispatchDialog keys={[t.key]} open onOpenChange={setDispatching} />}
    </header>
  );
}

/** Below the meta strip on compact screens: the wide layout's side panel, as one column. */
function CompactDetails({ t, boot, saver }: { t: Ticket; boot: Bootstrap; saver: TicketSaver }) {
  return (
    <section aria-label="Details" className="flex flex-col gap-6 border-t border-border-subtle pt-6">
      <Properties t={t} boot={boot} save={saver.save} error={saver.error} />
      <Dependencies ticket={t} />
      {t.run && hasLiveRun(t) && <RunCard t={t} run={t.run} />}
      <RunsHistory t={t} />
      <div id="code" className="scroll-mt-16">
        <CodeSection t={t} />
      </div>
      <section className="flex flex-col gap-2 px-1">
        <h2 className="text-13 text-fg-tertiary">Backlinks</h2>
        <BacklinksPanel kind="ticket" id={t.id} compact />
      </section>
    </section>
  );
}

/**
 * Compact ticket detail (DESIGN.md §3 Responsive): one column with a back bar, the key and title,
 * then the meta strip, criteria, description and activity. Comment and Start run are pinned to the
 * bottom edge; the tab bar is hidden here (lib/tab-bar.ts).
 */
function CompactTicket({ t, boot, saver, reloading, activity, onEdit }: { t: Ticket; boot: Bootstrap; saver: TicketSaver; reloading: boolean; activity: ReturnType<typeof useActivity>; onEdit: () => void }) {
  const [commenting, setCommenting] = useState(false);
  const [chatting, setChatting] = useState(false);
  const [dispatching, setDispatching] = useState(false);
  const dispatch = needsDispatch(t) && !t.project.archived;
  return (
    <>
      <div className="flex flex-col gap-6 px-4 pb-[calc(88px+env(safe-area-inset-bottom,0px))] pt-4">
        {t.project.archived && <Banner tone="human" title="This space’s work is archived">History is preserved. Restore the work on the space’s page before starting new work.</Banner>}
        <header className="flex flex-col gap-2">
          <div className="flex items-center gap-2 text-13">
            <span className="font-mono text-fg-tertiary">{t.key}</span>
            {t.blocked_by.some((d) => d.status !== "done") && (
              <a href="#blocked-by"><Flag tone="blocked">Blocked</Flag></a>
            )}
            <span className="flex-1" />
            <IconButton icon="edit" label="Edit ticket" onClick={onEdit} />
          </div>
          <TitleEditor t={t} save={saver.save} />
        </header>
        {saver.conflict && <ConflictBanner what={saver.conflict.what} reloading={reloading} onReapply={saver.reapply} onKeep={saver.keepLatest} />}
        <MetaStrip t={t} boot={boot} save={saver.save} />
        {saver.error && <p role="alert" className="text-12 text-pill-blocked-fg">{saver.error}</p>}
        {needsDispatch(t) && <p className="text-12 text-pill-human-fg">{dispatchHint(t)}</p>}
        <GateStrip t={t} />
        {t.approvals.map((ap) => (
          <div key={ap.id} id={`approval-${ap.id}`} className="scroll-mt-16">
            <ApprovalBanner t={t} ap={ap} />
          </div>
        ))}
        <Criteria t={t} events={activity.data} />
        <section className="flex flex-col gap-2">
          <h2 className="type-heading">Description</h2>
          <Description t={t} save={saver.save} />
        </section>
        <div id="mockups" className="scroll-mt-16">
          <ContextArtifacts t={t} />
        </div>
        <section className="flex flex-col gap-4">
          <h2 className="type-heading">Activity</h2>
          {activity.data ? <Timeline events={activity.data} ticketKey={t.key} boot={boot} run={t.run} /> : <Skeleton className="h-3 w-1/2" />}
        </section>
        <CompactDetails t={t} boot={boot} saver={saver} />
      </div>
      <div role="group" aria-label="Ticket actions" className="fixed inset-x-0 bottom-0 z-30 flex gap-2 border-t border-border-subtle bg-sidebar px-4 pt-3 pb-[calc(12px+env(safe-area-inset-bottom,0px))]">
        <Button variant="outline" icon="msg" onClick={() => setCommenting(true)} className="h-[44px] flex-1 justify-center">
          Comment
        </Button>
        <button type="button" aria-label="Chat with your persona about this ticket" onClick={() => setChatting(true)}
          className="grid size-[44px] flex-none place-items-center rounded-md border border-border-strong bg-btn-outline text-fg-2 hover:bg-hover">
          <Icon name="bulb" size={18} />
        </button>
        <Button variant="approve" icon="play" disabled={!dispatch} onClick={() => setDispatching(true)} className="h-[44px] flex-1 justify-center">
          Start run
        </Button>
      </div>
      <Sheet open={commenting} onOpenChange={setCommenting} title="Comment">
        <div className="px-2">
          <Composer ticketKey={t.key} autoFocus onDone={() => setCommenting(false)} />
        </div>
      </Sheet>
      {dispatching && <DispatchDialog keys={[t.key]} open onOpenChange={setDispatching} />}
      <WorkChatSheet subject={{ kind: "ticket", key: t.key, title: t.title }} open={chatting} onOpenChange={setChatting} />
    </>
  );
}

/** Compact top bar: back to the project's tickets, the ticket's place in it, and copy link. */
function CompactTopBar({ t, ticketKey, pager, onCopy, copied }: { t?: Ticket; ticketKey: string; pager: ReturnType<typeof usePager>; onCopy: () => void; copied: boolean }) {
  const router = useRouter();
  return (
    <header className="flex h-[48px] items-center gap-1 border-b border-border-subtle px-1.5">
      <Link href={t ? `/tickets?project=${t.project.key}` : "/tickets"} aria-label="Back to tickets" className="grid size-[44px] place-items-center rounded-full text-fg-secondary active:bg-hover">
        <Icon name="chev" size={18} className="rotate-90" />
      </Link>
      <span className="min-w-0 flex-1 truncate text-13 text-fg-2">{t ? t.project.name : "Tickets"}</span>
      <IconButton icon="chev" label="Previous ticket" size={44} disabled={!pager.prev} onClick={() => pager.prev && router.push(`/tickets/${pager.prev}`)} className="rotate-180" />
      <IconButton icon="chev" label="Next ticket" size={44} disabled={!pager.next} onClick={() => pager.next && router.push(`/tickets/${pager.next}`)} />
      <IconButton icon={copied ? "check" : "link"} label={copied ? "Link copied" : `Copy link to ${ticketKey}`} size={44} onClick={onCopy} />
    </header>
  );
}

export function TicketScreen({ ticketKey }: { ticketKey: string }) {
  const router = useRouter();
  const compact = useCompact();
  const ticket = useTicket(ticketKey);
  const activity = useActivity(ticketKey, hasLiveRun(ticket.data));
  const boot = useBootstrap();
  const t = ticket.data;
  useRecordVisit(t ? { id: `ticket-${t.key}`, title: t.title, meta: t.key, href: `/tickets/${t.key}`, kind: "Tickets" } : undefined);
  const pager = usePager(t);
  const [copied, setCopied] = useState(false);
  const [editing, setEditing] = useState(false);
  const saver = useTicketSave(t);

  // In the Mac app the header row is the window title and toolbar (the web's top bar, below, isn't drawn).
  const native = useIsNativeShell();
  const cost = useCosts({ ticket: ticketKey }, native).data;
  const copyLink = () => {
    void navigator.clipboard.writeText(window.location.href);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  useNativeTitle(ticketKey, t ? [t.project.name, t.epic?.name].filter(Boolean).join(" · ") : undefined);
  useNativeToolbar({
    items: buildTicketToolbar({
      cost: cost && cost.total.runs > 0 ? spendLabel(cost.total.cost_micros, cost.unpriced_runs) : undefined,
      pager: { index: pager.index, total: pager.total },
      hasPrev: !!pager.prev,
      hasNext: !!pager.next,
      copied,
    }),
    onAction: (id) => {
      const a = parseTicketToolbarAction(id);
      if (a === "prev" && pager.prev) router.push(`/tickets/${pager.prev}`);
      else if (a === "next" && pager.next) router.push(`/tickets/${pager.next}`);
      else if (a === "copy") copyLink();
      else if (a === "cost" && t) router.push(`/reports?tab=costs&project=${encodeURIComponent(t.project.key)}`);
    },
  });

  // J/K step through the project's tickets; E opens the editor.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const el = e.target as HTMLElement;
      if (e.metaKey || e.ctrlKey || e.altKey || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.isContentEditable) return;
      if (document.querySelector("[role=dialog], [role=menu]")) return;
      if (e.key === "j" && pager.next) router.push(`/tickets/${pager.next}`);
      if (e.key === "k" && pager.prev) router.push(`/tickets/${pager.prev}`);
      if (e.key === "e") {
        e.preventDefault();
        setEditing(true);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [pager.next, pager.prev, router]);

  if (ticket.isError) {
    const missing = "status" in ticket.error && ticket.error.status === 404;
    return (
      <>
        {!native && <TopBar crumbs={[{ label: "Tickets", href: "/tickets" }, { label: ticketKey, mono: true }]} />}
        {missing ? (
          <EmptyState icon="tickets" title={`${ticketKey} doesn't exist`} actions={<ButtonLink href="/tickets" variant="outline">All tickets</ButtonLink>}>
            It may have been moved, or the link has a typo.
          </EmptyState>
        ) : (
          <div className="p-6">
            <Banner tone="blocked" title="Couldn't load this ticket">
              {ticket.error.message}
            </Banner>
          </div>
        )}
      </>
    );
  }

  if (compact) {
    return (
      <>
        <CompactTopBar t={t} ticketKey={ticketKey} pager={pager} onCopy={copyLink} copied={copied} />
        {!t || !boot.data ? <DetailSkeleton /> : <CompactTicket t={t} boot={boot.data} saver={saver} reloading={ticket.isFetching} activity={activity} onEdit={() => setEditing(true)} />}
        {editing && t && boot.data && (
          <TicketEditorDialog
            ticketKey={t.key}
            detail={t}
            bootstrap={boot.data}
            onClose={() => setEditing(false)}
            onReload={async () => {
              const r = await ticket.refetch();
              return r.isError ? undefined : r.data;
            }}
          />
        )}
      </>
    );
  }

  return (
    <>
      <NavigatorPortal
        native={{
          model: buildTicketNavModel({ project: t?.project.key, siblings: pager.tickets, statusNames: STATUS_NAME, ticketKey }),
          onCommand: (cmd) => handleWorkHeaderCommand(cmd, { project: t?.project.key, push: (href) => router.push(href), onProject: () => {}, onAgent: () => {} }),
        }}
      >
        <nav aria-label="Work" className="work-nav">
          <WorkNavHeader active="tickets" project={t?.project.key} />
          <div className="work-nav-list">
            {pager.tickets.map((sib) => (
              <Link
                key={sib.key}
                href={`/tickets/${encodeURIComponent(sib.key)}`}
                aria-current={sib.key === ticketKey ? "true" : undefined}
              >
                <strong className="flex items-center gap-1.5 truncate">
                  <StatusGlyph state={sib.status} label={false} />
                  <span className="font-mono text-11 text-fg-tertiary">{sib.key}</span>
                  <span className="truncate">{sib.title}</span>
                </strong>
              </Link>
            ))}
          </div>
        </nav>
      </NavigatorPortal>
      {!native && <TopBar
        crumbs={
          t
            ? [
                { label: t.project.name, swatch: t.project.color, href: `/tickets?project=${t.project.key}` },
                ...(t.epic ? [{ label: t.epic.name }] : []),
                { label: t.key, mono: true },
              ]
            : [{ label: "Tickets", href: "/tickets" }, { label: ticketKey, mono: true }]
        }
        actions={
          <>
            {t && <TicketCostChip ticketKey={t.key} project={t.project.key} />}
            {pager.total > 0 && pager.index >= 0 && (
              <span className="font-mono text-12 text-fg-tertiary" aria-label={`Ticket ${pager.index + 1} of ${pager.total}`}>
                {pager.index + 1} / {pager.total}
              </span>
            )}
            <IconButton icon="chev" label="Previous ticket (K)" bordered disabled={!pager.prev} onClick={() => pager.prev && router.push(`/tickets/${pager.prev}`)} className="rotate-180" />
            <IconButton icon="chev" label="Next ticket (J)" bordered disabled={!pager.next} onClick={() => pager.next && router.push(`/tickets/${pager.next}`)} />
            <IconButton
              icon={copied ? "check" : "link"}
              label={copied ? "Link copied" : "Copy link"}
              onClick={() => {
                void navigator.clipboard.writeText(window.location.href);
                setCopied(true);
                setTimeout(() => setCopied(false), 1500);
              }}
            />
          </>
        }
      />}
      {!t || !boot.data ? (
        <DetailSkeleton />
      ) : (
        <div className="flex flex-1 flex-wrap">
          <article className="flex min-w-0 flex-[999_1_480px] justify-center px-7 py-8 max-sm:px-4">
            <div className="flex w-full max-w-[700px] flex-col gap-7">
              {t.project.archived && <Banner tone="human" title="This space’s work is archived" actions={<ButtonLink href={workSettingsHref(t.project)} variant="outline">Open the space</ButtonLink>}>History is preserved. Restore the work on the space’s page before starting new work.</Banner>}
              <Header t={t} save={saver.save} onEdit={() => setEditing(true)} />
              <GateStrip t={t} />
              {t.approvals.map((ap) => (
                <div key={ap.id} id={`approval-${ap.id}`} className="scroll-mt-16">
                  <ApprovalBanner t={t} ap={ap} />
                </div>
              ))}
              <Description t={t} save={saver.save} />
              <Criteria t={t} events={activity.data} />
              <div id="mockups" className="scroll-mt-16">
                <ContextArtifacts t={t} />
              </div>
              <section className="flex flex-col gap-4">
                <h2 className="type-heading">Activity</h2>
                {activity.data ? (
                  <Timeline events={activity.data} ticketKey={t.key} boot={boot.data} run={t.run} />
                ) : (
                  <Skeleton className="h-3 w-1/2" />
                )}
                <Composer ticketKey={t.key} />
              </section>
            </div>
          </article>
          {/* The ticket's companion: Properties and Chat, in the shell's right-hand column. */}
          <CompanionDock
            app="ticket"
            tabs={[
              {
                id: "properties",
                label: "Properties",
                icon: "sliders",
                content: (
                  <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-4 py-5">
                    {saver.conflict && (
                      <ConflictBanner what={saver.conflict.what} reloading={ticket.isFetching} onReapply={saver.reapply} onKeep={saver.keepLatest} />
                    )}
                    <Properties t={t} boot={boot.data} save={saver.save} error={saver.error} />
                    <Dependencies ticket={t} />
                    {t.run && hasLiveRun(t) && <RunCard t={t} run={t.run} />}
                    <RunsHistory t={t} />
                    <div id="code" className="scroll-mt-16">
                      <CodeSection t={t} />
                    </div>
                    <section className="flex flex-col gap-2 px-1">
                      <h2 className="text-13 text-fg-tertiary">Backlinks</h2>
                      <BacklinksPanel kind="ticket" id={t.id} compact />
                    </section>
                  </div>
                ),
              },
              { id: "chat", label: "Chat", icon: "msg", content: <WorkChat subject={{ kind: "ticket", key: t.key, title: t.title }} /> },
            ]}
          />
        </div>
      )}
      {editing && t && boot.data && (
        <TicketEditorDialog
          ticketKey={t.key}
          detail={t}
          bootstrap={boot.data}
          onClose={() => setEditing(false)}
          onReload={async () => {
            const r = await ticket.refetch();
            return r.isError ? undefined : r.data;
          }}
        />
      )}
    </>
  );
}
