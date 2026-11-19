"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import { workSettingsHref } from "@/lib/spaces";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, ViewTransition } from "react";
import type { Bootstrap, Schemas, Ticket } from "@/lib/api/client";
import { useCompact } from "@/lib/viewport";
import { useActivity, useBacklinks, useBootstrap, useCosts, useLinkMention, useTicket, useTicketRuns, useTickets, hasLiveRun } from "@/lib/api/hooks";
import { ago, duration, dueDate, runCost, timelineTime } from "@/lib/format";
import { ESTIMATE_SCALE } from "@/lib/ticket-draft";
import { runStateTone, ticketStatusTone } from "@/lib/native-shell/models/common";
import { buildTicketInspectorSections } from "@/lib/native-shell/models/ticket-inspector";
import { spendLabel } from "@/lib/costs";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { buildTicketToolbar, parseTicketToolbarAction } from "@/lib/native-shell/models/work-toolbars";
import { useNativeTitle } from "../_components/native-title";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton, TextArea } from "@/components/ui/primitives";
import { Sheet } from "@/components/ui/sheet";
import { AgentAvatar } from "@/components/domain/avatars";
import { Markdown } from "@/components/domain/markdown";
import { StartChatButton } from "@/components/domain/start-chat";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { TicketEditorDialog } from "@/components/domain/ticket-editor-dialog";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { Flag, SmallPill } from "@/components/domain/labels";
import { PRIORITY_NAME, PRIORITY_ORDER, STATUS_NAME, STATUS_ORDER } from "@/components/domain/meta";
import { WORK_COLUMN, WorkDetailHeader, WorkEyebrow, WorkViewTabs, type EyebrowItem } from "@/components/domain/work-detail-header";
import { BacklinksPanel } from "@/components/domain/backlinks";
import { ContextArtifacts } from "./context-artifacts";
import { Dependencies, useDependencyChange } from "./dependencies";
import { Criteria } from "./criteria";
import { GateStrip } from "./gates";
import { MetaStrip } from "./meta-strip";
import { CodeSection, Properties } from "./properties";
import { ApprovalBanner, needsDispatch, RUN_STATE, RunCard } from "./run-parts";
import { RunsHistory } from "./runs-history";
import { ConflictBanner, useTicketSave, type SaveTicket, type TicketSaver } from "./ticket-save";
import { Composer, Timeline } from "./timeline";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { WorkChat, WorkChatSheet } from "@/components/domain/work-chat";
import { buildTicketNavModel } from "@/lib/native-shell/models/ticket";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";

function TitleEditor({ t, save }: { t: Ticket; save: SaveTicket }) {
  const [editing, setEditing] = useState(false);
  if (!editing) {
    return (
      <h1 className="type-title min-w-0 flex-1 text-fg">
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
        className="type-title -mx-1 w-full rounded-md border border-accent bg-surface px-1 text-fg outline-none"
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

/** Unified editorial ticket header: eyebrow, editable title, single calm meta line, and inline view tabs. */
function Header({
  t,
  save,
  onEdit,
  tab,
  onTabChange,
  runsCount,
  activityCount,
}: {
  t: Ticket;
  save: SaveTicket;
  onEdit: () => void;
  tab: "overview" | "runs" | "activity";
  onTabChange: (next: "overview" | "runs" | "activity") => void;
  runsCount?: number;
  activityCount?: number;
}) {
  const [dispatching, setDispatching] = useState(false);
  const blockers = t.blocked_by.filter((d) => d.status !== "done");
  const dispatch = needsDispatch(t);
  const eyebrow: EyebrowItem[] = [
    { label: t.project.key, href: `/tickets?project=${encodeURIComponent(t.project.key)}`, mono: true },
    ...(t.epic ? [{ label: `${t.epic.name} ↗`, href: `/epics/${encodeURIComponent(t.epic.id)}`, accent: true }] : []),
    { label: t.key, mono: true },
  ];
  return (
    <>
      <WorkDetailHeader
        eyebrow={<WorkEyebrow items={eyebrow} />}
        title={<TitleEditor t={t} save={save} />}
        actions={
          <>
            {dispatch && (
              <Button variant="approve" icon="play" disabled={t.project.archived} onClick={() => setDispatching(true)}>
                Dispatch now
              </Button>
            )}
            <StartChatButton attach={{ kind: "ticket", key: t.key }} title={`${t.key} ${t.title}`} project={t.project.key} />
            <Button variant="outline" icon="edit" hint="E" onClick={onEdit} aria-keyshortcuts="E">
              Edit
            </Button>
          </>
        }
        meta={
          <>
            <span className="inline-flex items-center gap-1.5 rounded-full border border-border bg-surface px-2 py-0.5 text-fg-2">
              <StatusGlyph state={t.status} size={12} label={false} />
              {STATUS_NAME[t.status]}
            </span>
            {t.assignee && (
              <span className="inline-flex items-center gap-1.5 font-medium text-fg">
                <AgentAvatar name={t.assignee.name} colorIndex={t.assignee.color_index} label={false} size="sm" />
                {t.assignee.name}
              </span>
            )}
            <span aria-hidden className="text-fg-tertiary">·</span>
            <span className="inline-flex items-center gap-1.5 text-fg-secondary">
              <PriorityGlyph priority={t.priority} />
            </span>
            {t.estimate_points != null && (
              <>
                <span aria-hidden className="text-fg-tertiary">·</span>
                <span className="font-mono text-fg-tertiary">{t.estimate_points} pts</span>
              </>
            )}
            {blockers.length > 0 && (
              <a href="#blocked-by" className="rounded-[5px] focus-visible:outline-2">
                <Flag tone="blocked">
                  Blocked · {blockers.length} {blockers.length === 1 ? "blocker" : "blockers"}
                </Flag>
              </a>
            )}
          </>
        }
        notice={dispatch ? <p className="text-12 text-pill-human-fg">{dispatchHint(t)}</p> : undefined}
        tabs={
          <WorkViewTabs
            label="Ticket views"
            value={tab}
            onChange={(k) => onTabChange(k as "overview" | "runs" | "activity")}
            items={[
              { key: "overview", label: "Overview" },
              { key: "runs", label: "Runs", count: runsCount },
              { key: "activity", label: "Activity", count: activityCount },
            ]}
          />
        }
      />
      {dispatching && <DispatchDialog keys={[t.key]} open onOpenChange={setDispatching} />}
    </>
  );
}

/** Compact one-row link card to the ticket's latest run, matching Run Detail's calm surface grammar. */
function LatestRunRow({ t }: { t: Ticket }) {
  const run = t.run;
  if (!run) return null;
  const st = RUN_STATE[run.state];
  return (
    <Link
      href={`/runs/${run.id}`}
      className="flex items-center gap-3 rounded-xl border border-border bg-surface px-4 py-3 transition-colors hover:border-border-hover hover:bg-hover/40"
    >
      <AgentAvatar name={run.agent.name} colorIndex={run.agent.color_index} label={false} size="sm" />
      <div className="flex min-w-0 flex-1 flex-col gap-0.5 leading-tight">
        <span className="flex flex-wrap items-center gap-2 text-13 font-medium text-fg">
          <span>Latest run · {run.agent.name}</span>
          <SmallPill tone={st.tone}>{st.label}</SmallPill>
        </span>
        <span className="truncate font-mono text-11 text-fg-tertiary">
          Run {run.id.slice(0, 8)} · {duration(run.started_at, run.ended_at)} · {run.tool_calls} step{run.tool_calls === 1 ? "" : "s"} · {runCost(run.cost_usd, run.cost_source)}
        </span>
      </div>
      <span className="flex-none text-12 font-medium text-accent">Open run →</span>
    </Link>
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
  const [tab, setTab] = useState<"overview" | "runs" | "activity">("overview");
  const ticketRuns = useTicketRuns(ticketKey, hasLiveRun(t));
  const saver = useTicketSave(t);

  const cost = useCosts({ ticket: ticketKey }).data;
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
    return missing ? (
      <EmptyState icon="tickets" title={`${ticketKey} doesn't exist`} actions={<ButtonLink href="/tickets" variant="outline">All tickets</ButtonLink>}>
        It may have been moved, or the link has a typo.
      </EmptyState>
    ) : (
      <div className="p-6">
        <Banner tone="blocked" title="Couldn't load this ticket">
          {ticket.error.message}
        </Banner>
      </div>
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
      />
      {!t || !boot.data ? (
        <DetailSkeleton />
      ) : (
        <div className="flex flex-1 flex-wrap">
          <article className="flex min-w-0 flex-[999_1_480px] justify-center py-6">
            <div className={`${WORK_COLUMN} flex flex-col gap-6`}>
              {t.project.archived && <Banner tone="human" title="This space’s work is archived" actions={<ButtonLink href={workSettingsHref(t.project)} variant="outline">Open the space</ButtonLink>}>History is preserved. Restore the work on the space’s page before starting new work.</Banner>}
              <Header
                t={t}
                save={saver.save}
                onEdit={() => setEditing(true)}
                tab={tab}
                onTabChange={setTab}
                runsCount={ticketRuns.data?.runs.length}
                activityCount={activity.data?.length}
              />
              {tab === "runs" ? (
                <div className="flex flex-col gap-4">
                  {t.run && hasLiveRun(t) && <RunCard t={t} run={t.run} />}
                  <RunsHistory t={t} />
                </div>
              ) : tab === "activity" ? (
                <section className="flex flex-col gap-4">
                  {activity.data ? (
                    <Timeline events={activity.data} ticketKey={t.key} boot={boot.data} run={t.run} />
                  ) : (
                    <Skeleton className="h-3 w-1/2" />
                  )}
                  <Composer ticketKey={t.key} />
                </section>
              ) : (
                <>
                  <GateStrip t={t} />
                  {t.approvals.map((ap) => (
                    <div key={ap.id} id={`approval-${ap.id}`} className="scroll-mt-16">
                      <ApprovalBanner t={t} ap={ap} />
                    </div>
                  ))}
                  <Description t={t} save={saver.save} />
                  <Criteria t={t} events={activity.data} />
                  <LatestRunRow t={t} />
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
                </>
              )}
            </div>
          </article>
          {/* The ticket's companion: Properties and Chat, in the shell's right-hand column. */}
          <TicketCompanion
            t={t}
            boot={boot.data}
            saver={saver}
            reloading={ticket.isFetching}
            runs={ticketRuns.data?.runs ?? []}
            runsHasMore={!!ticketRuns.data?.has_more}
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

function TicketCompanion({
  t,
  boot,
  saver,
  reloading,
  runs,
  runsHasMore,
}: {
  t: Ticket;
  boot: Bootstrap;
  saver: TicketSaver;
  reloading: boolean;
  runs: Schemas["Run"][];
  runsHasMore: boolean;
}) {
  const backlinks = useBacklinks("ticket", t.id);
  const linkMention = useLinkMention();
  const depChange = useDependencyChange(t);

  const epics = boot.epics.filter((e) => e.project_id === t.project.id);
  const closed = t.status === "done" || t.status === "canceled";
  const scale: number[] = [...ESTIMATE_SCALE];
  if (t.estimate_points != null && !scale.includes(t.estimate_points)) scale.push(t.estimate_points);
  scale.sort((a, b) => a - b);

  const priced = runs.filter((r) => r.cost_source && r.cost_source !== "unknown");
  const totalCost = priced.reduce((sum, r) => sum + r.cost_usd, 0);
  const partialCost = runsHasMore || priced.length < runs.length || priced.some((r) => r.cost_source === "partial");
  const runsSummary =
    priced.length > 0
      ? `${runs.length}${runsHasMore ? "+" : ""} · ${partialCost ? "≥ " : ""}$${totalCost.toFixed(2)}`
      : runs.length > 0
        ? `${runs.length}${runsHasMore ? "+" : ""}`
        : undefined;

  const mapMention = (m: Schemas["Mention"]) => {
    const s = m.source;
    const raw = s.kind === "artifact" && s.artifact_type === "note" ? (s.path ?? s.title) : s.title;
    const name = s.kind === "comment" ? "Comment" : raw;
    return {
      id: `${m.source_kind}:${m.source_id}`,
      sourceKind: m.source_kind,
      sourceId: m.source_id,
      title: s.display_id && s.kind !== "agent" ? `${s.display_id} · ${name}` : name,
      href: s.href ?? undefined,
    };
  };

  const agentOptions = [
    { value: "", label: "Unassigned" },
    ...boot.agents.filter((a) => a.kind === "main").map((a) => ({ value: a.id, label: a.name })),
  ];
  const assigneeBadge = needsDispatch(t)
    ? { text: "Not dispatched", tone: "human" as const }
    : t.run?.state === "queued"
      ? { text: "Queued", tone: "neutral" as const }
      : undefined;

  const sections = buildTicketInspectorSections({
    status: t.status,
    statusOptions: STATUS_ORDER.map((s) => ({ value: s, label: STATUS_NAME[s] })),
    priority: t.priority,
    priorityOptions: PRIORITY_ORDER.map((p) => ({ value: p, label: PRIORITY_NAME[p] })),
    assignee: t.assignee?.id ?? "",
    assigneeOptions: agentOptions,
    assigneeBadge,
    reviewer: t.reviewer?.id ?? "",
    reviewerOptions: [{ value: "", label: "No reviewer" }, ...boot.users.map((u) => ({ value: u.id, label: u.name }))],
    epic: t.epic?.id ?? "",
    epicOptions: [{ value: "", label: "No epic" }, ...epics.map((e) => ({ value: e.id, label: e.name }))],
    spaceName: t.project.name,
    mockupFromEpic: t.mockup_gate.from_epic ? (t.epic?.name ?? "epic") : undefined,
    requiresMockup: t.requires_mockup,
    estimate: t.estimate_points != null ? String(t.estimate_points) : "",
    estimateOptions: [{ value: "", label: "Unestimated" }, ...scale.map((p) => ({ value: String(p), label: `${p} pts` }))],
    estimateDisabled: closed,
    estimateNote: closed ? "Closed tickets can’t be re-estimated." : t.estimate ? `Legacy note: ${t.estimate}` : undefined,
    dueDate: t.due_date ?? "",
    selectedLabels: t.labels.map((l) => ({ id: l.id, name: l.name, color: l.color })),
    allLabels: boot.labels.map((l) => ({ id: l.id, name: l.name })),
    blockedBy: t.blocked_by.map((d) => ({
      key: d.key,
      title: d.title,
      statusLabel: STATUS_NAME[d.status],
      statusTone: ticketStatusTone(d.status),
    })),
    blocks: t.blocks.map((d) => ({
      key: d.key,
      title: d.title,
      statusLabel: STATUS_NAME[d.status],
      statusTone: ticketStatusTone(d.status),
    })),
    canEditBlockedBy: !hasLiveRun(t) && !depChange.isPending,
    runs: runs.map((r) => {
      const st = RUN_STATE[r.state];
      const when = r.ended_at ? `${timelineTime(r.started_at)} · ${duration(r.started_at, r.ended_at)}` : `Started ${ago(r.started_at)}`;
      return {
        id: r.id,
        handle: r.agent.handle,
        stateLabel: st.label,
        stateTone: runStateTone(r.state),
        subtitle: `${when} · ${r.model}`,
        cost: runCost(r.cost_usd, r.cost_source),
      };
    }),
    runsSummary,
    code:
      t.branch || t.pr
        ? {
            branch: t.branch,
            prNumber: t.pr?.number,
            prState: t.pr ? t.pr.state[0].toUpperCase() + t.pr.state.slice(1) : undefined,
            prUrl: t.pr?.url,
            diff: t.pr?.additions != null ? `+${t.pr.additions} −${t.pr.deletions ?? 0}` : undefined,
            closedUnmerged: t.pr?.closed_unmerged,
            synced: t.pr?.synced_at ? `Synced ${ago(t.pr.synced_at)}` : undefined,
          }
        : undefined,
    linkedMentions: backlinks.data ? backlinks.data.linked.map(mapMention) : undefined,
    unlinkedMentions: backlinks.data
      ? backlinks.data.unlinked.filter((m) => m.source_kind === "artifact" || m.source_kind === "ticket").map(mapMention)
      : undefined,
    error: saver.error,
  });

  const subject = { kind: "ticket" as const, key: t.key, title: t.title };
  return (
    <CompanionDock
      app="ticket"
      tabs={[
        {
          id: "properties",
          label: "Properties",
          icon: "sliders",
          native: {
            kind: "native",
            sections,
            onChange: (fieldId, value) => {
              if (fieldId === "status") {
                const next = value as Ticket["status"];
                saver.save({ status: next }, `Status → ${STATUS_NAME[next] ?? next}`);
              } else if (fieldId === "priority") {
                const next = value as Ticket["priority"];
                saver.save({ priority: next }, `Priority → ${PRIORITY_NAME[next] ?? next}`);
              } else if (fieldId === "assignee_agent_id") {
                const name = boot.agents.find((a) => a.id === value)?.name ?? "Unassigned";
                saver.save({ assignee_agent_id: value || null }, `Persona → ${name}`);
              } else if (fieldId === "reviewer_user_id") {
                const name = boot.users.find((u) => u.id === value)?.name ?? "none";
                saver.save({ reviewer_user_id: value || null }, `Reviewer → ${name}`);
              } else if (fieldId === "epic_id") {
                const name = epics.find((e) => e.id === value)?.name ?? "none";
                saver.save({ epic_id: value || null }, `Epic → ${name}`);
              } else if (fieldId === "estimate_points") {
                saver.save({ estimate_points: value ? Number(value) : null }, value ? `Estimate → ${value}` : "Estimate cleared");
              } else if (fieldId === "due_date") {
                const trimmed = value.trim();
                saver.save({ due_date: trimmed || null }, trimmed ? `Due → ${dueDate(trimmed)}` : "Due date cleared");
              }
            },
            onToggle: (fieldId, checked) => {
              if (fieldId === "requires_mockup") {
                saver.save({ requires_mockup: checked }, checked ? "Mockup → required" : "Mockup → not required");
              }
            },
            onAction: (actionId, itemId, menuItemId) => {
              if (actionId === "labels") {
                const current = t.labels.map((l) => l.id);
                if (itemId) {
                  saver.save({ label_ids: current.filter((id) => id !== itemId) }, "Labels");
                } else if (menuItemId) {
                  const next = current.includes(menuItemId)
                    ? current.filter((id) => id !== menuItemId)
                    : [...current, menuItemId];
                  saver.save({ label_ids: next }, "Labels");
                }
              } else if (actionId === "remove_blocked_by" && itemId && (menuItemId === "remove" || !menuItemId)) {
                depChange.mutate({ list: "blocked_by", op: "remove", key: itemId });
              } else if (actionId === "remove_blocks" && itemId && (menuItemId === "remove" || !menuItemId)) {
                depChange.mutate({ list: "blocks", op: "remove", key: itemId });
              } else if (actionId === "link_mention" && itemId) {
                const sep = itemId.indexOf(":");
                if (sep <= 0) return;
                const kind = itemId.slice(0, sep);
                const sourceId = itemId.slice(sep + 1);
                if (kind === "artifact" || kind === "ticket") {
                  linkMention.mutate({ target_kind: "ticket", target_id: t.id, source_kind: kind, source_id: sourceId });
                }
              }
            },
          },
          content: (
            <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-4 py-5">
              {saver.conflict && (
                <ConflictBanner what={saver.conflict.what} reloading={reloading} onReapply={saver.reapply} onKeep={saver.keepLatest} />
              )}
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
            </div>
          ),
        },
        { id: "chat", label: "Chat", icon: "msg", native: { kind: "companion", subject }, content: <WorkChat subject={subject} /> },
      ]}
    />
  );
}
