"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { useMutation, useQueries, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "@/lib/api/client";
import { hasLiveRun, keys, useBootstrap, useBulkUpdate, useCosts, useDecideRunApproval, useDispatch, useEpicCriterionMutations, useEpicOverviews, useInbox, useTickets, useUpdateEpic } from "@/lib/api/hooks";
import { spendLabel } from "@/lib/costs";
import { cx } from "@/lib/cx";
import { approvalId, epicProgress, needsYouByTicket, startReady, ticketNeedsYou, type NeedsYou } from "@/lib/work-rows";
import { Icon } from "@/components/ui/icon";
import { StackedBar } from "@/components/domain/data";
import { StateText } from "@/app/(app)/tickets/_components/ticket-row";
import { useBoard } from "@/lib/api/board-hooks";
import { dueDate } from "@/lib/format";
import { burnUp, isOverdue, ymd } from "@/lib/epics";
import { buildEpicInspectorSections } from "@/lib/native-shell/models/epic-inspector";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { Content } from "@/components/shell/topbar";
import { HealthPill, type EpicOverview } from "@/components/domain/overview";
import { Pill } from "@/components/domain/labels";
import { DependencyMap } from "@/components/domain/dependency-map";
import { WorkDetailHeader, WorkEyebrow, WorkViewTabs } from "@/components/domain/work-detail-header";
import { ticketsHref } from "@/lib/tickets-layout";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { buildEpicDetailNavModel } from "@/lib/native-shell/models/epic-detail";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import { buildEpicToolbar } from "@/lib/native-shell/models/work-toolbars";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { useNativeTitle } from "../../tickets/_components/native-title";

type TicketSummary = Schemas["TicketSummary"];

export function EpicDetailScreen({ epicId }: { epicId: string }) {
  const router = useRouter();
  const query = useEpicOverviews();
  const e = query.data?.find((x) => x.epic.id === epicId);
  const siblingEpics = (query.data ?? []).filter((x) => !e || x.project.key === e.project.key);
  useNativeTitle(e?.epic.name ?? "Epics", e?.project.name);
  useNativeToolbar({ items: e ? buildEpicToolbar() : [], onAction: () => e && router.push(boardHref(e)) });
  return (
    <>
      <NavigatorPortal
        native={{
          model: buildEpicDetailNavModel({
            project: e?.project.key,
            projectName: e?.project.name,
            epics: siblingEpics.map((x) => ({ id: x.epic.id, name: x.epic.name, done: x.epic.tickets_total - x.epic.tickets_open, total: x.epic.tickets_total })),
            epicId,
          }),
          onCommand: (cmd) => handleWorkHeaderCommand(cmd, { project: e?.project.key, push: (href) => router.push(href), onProject: () => {}, onAgent: () => {} }),
        }}
      />
      <div className="flex min-h-0 flex-1">
      <div className="min-w-0 flex-1">
      <Content>
        {query.isError ? (
          <Banner tone="blocked" title="Couldn’t load the epic" actions={<Button onClick={() => query.refetch()}>Retry</Button>}>
            {query.error.message}
          </Banner>
        ) : query.isPending ? (
          <div aria-busy="true" className="space-y-4">
            <Skeleton className="h-32 rounded-xl" />
            <Skeleton className="h-72 rounded-xl" />
          </div>
        ) : !e ? (
          <EmptyState icon="epics" title="Epic not found" actions={<ButtonLink href={ticketsHref("epics")}>All epics</ButtonLink>}>
            It may have been deleted, or the link is wrong.
          </EmptyState>
        ) : (
          <EpicDetail epic={e} />
        )}
      </Content>
      </div>
      {e && <EpicContext epic={e} />}
      </div>
    </>
  );
}

const boardHref = (e: EpicOverview) => ticketsHref("board", { project: e.project.key, epic: e.epic.id });

function EpicDetail({ epic: e }: { epic: EpicOverview }) {
  const [tab, setTab] = useState("overview");
  const today = ymd(new Date());
  const overdue = isOverdue(e, today);
  const tickets = useTickets({ epic: e.epic.id, view: "all" });
  // Tickets whose run waits on the person, from the same queue as the Inbox.
  const inbox = useInbox(e.project.key);
  const needs = useMemo(() => needsYouByTicket(inbox.data), [inbox.data]);
  const waiting = (tickets.data ?? []).filter((t) => Boolean(ticketNeedsYou(t, needs.get(t.key))));
  return (
    <article className="mx-auto max-w-[820px] space-y-6">
      <WorkDetailHeader
        eyebrow={
          <WorkEyebrow
            items={[
              { label: e.project.name, href: `/tickets?project=${encodeURIComponent(e.project.key)}` },
              { label: "Epics", href: ticketsHref("epics", { project: e.project.key }) },
            ]}
          />
        }
        title={<h1 className="type-title text-fg">{e.epic.name}</h1>}
        meta={
          <>
            <HealthPill health={e.epic.health} />
            <Pill tone={e.epic.status === "done" ? "done" : "neutral"}>{e.epic.status === "done" ? "Done" : "Open"}</Pill>
            <span aria-hidden className="text-fg-tertiary">·</span>
            <span className={overdue ? "text-pill-blocked-fg" : "text-fg-secondary"}>
              {e.target_date ? `${overdue ? "Overdue · " : "Target "}${dueDate(e.target_date)}` : "No target date"}
            </span>
            <span aria-hidden className="text-fg-tertiary">·</span>
            <span className="text-fg-secondary">{e.owner ? `Owner ${e.owner.name}` : "No owner"}</span>
          </>
        }
        notice={
          <div className="flex flex-col gap-2 pt-0.5">
            <p className="whitespace-pre-line text-14 leading-relaxed text-fg-2">
              {e.objective || "No objective has been written yet."}
            </p>
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-12 text-fg-secondary">
              <Link href={boardHref(e)} className="text-accent hover:underline">Board filtered to this epic</Link>
              <Link href={`/tickets?view=all&epic=${e.epic.id}&project=${encodeURIComponent(e.project.key)}`} className="hover:text-fg hover:underline">Ticket list ↗</Link>
              <Link href={`/plans?epic=${e.epic.id}&project=${encodeURIComponent(e.project.key)}${e.source ? `&artifact=${e.source.id}` : ""}`} className="hover:text-fg hover:underline">Plan with an agent ↗</Link>
            </div>
          </div>
        }
      />

      <EpicProgressBar epicId={e.epic.id} tickets={tickets.data} needs={needs} />

      {waiting.length > 0 && <NeedsYouBanner tickets={waiting} needs={needs} />}

      <WorkViewTabs
        label="Epic views"
        value={tab}
        onChange={setTab}
        items={[
          { key: "overview", label: "Overview", count: e.epic.tickets_total },
          { key: "map", label: "Map" },
        ]}
      />
      {tab === "map" ? <DependencyMap key={e.epic.id} project={e.project.key} epic={e.epic.id} /> : <>
      <section aria-label="Tickets" className="space-y-2.5">
        <h2 className="flex items-center gap-2 text-11 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
          Tickets <span className="font-mono font-normal">{e.epic.tickets_open} open of {e.epic.tickets_total}</span>
        </h2>
        {tickets.isError ? (
          <p role="alert" className="text-12 text-pill-blocked-fg">Couldn’t load tickets: {tickets.error.message}</p>
        ) : tickets.isPending ? (
          <Skeleton className="h-24 rounded-xl" />
        ) : (
          <TicketChecklist tickets={tickets.data} needs={needs} />
        )}
      </section>

      <StartReady key={e.epic.id} epic={e} />

      </>}
    </article>
  );
}

/**
 * The epic's companion, like the run page's: a Context tab with the acceptance criteria and the done
 * gate, then specs and details with the burn-up; and the work chat.
 */
function EpicContext({ epic: e }: { epic: EpicOverview }) {
  const tickets = useTickets({ epic: e.epic.id, view: "all" });
  const board = useBoard(e.project.key, { epic: e.epic.id, include_canceled: false });
  const updateEpic = useUpdateEpic(e.epic.id);
  const mutations = useEpicCriterionMutations(e.epic.id);
  const summary = board.data?.epic;
  const criteria = summary ? [...summary.criteria].sort((a, b) => a.position - b.position) : [];
  const blockers = summary?.done_blockers;
  const gated = blockers ? blockers.open_tickets.length > 0 || blockers.unchecked_criteria.length > 0 : false;
  const closed = e.epic.status === "done";
  const blockerParts: string[] = [];
  if (blockers?.open_tickets.length) blockerParts.push(`Open: ${blockers.open_tickets.join(", ")}`);
  if (blockers?.unchecked_criteria.length) {
    blockerParts.push(`${blockers.unchecked_criteria.length} unchecked criteria`);
  }
  const burn = tickets.data ? burnUp(tickets.data, { start: e.start_date, today: ymd(new Date()) }) : undefined;
  const sections = buildEpicInspectorSections({
    status: e.epic.status,
    pointsDone: e.epic.points_done,
    pointsTotal: e.epic.points_total,
    criteriaDone: e.epic.criteria_done,
    criteriaTotal: e.epic.criteria_total,
    criteria: criteria.map((c) => ({ id: c.id, text: `${c.position}. ${c.text}`, done: c.done })),
    canMarkDone: !closed && criteria.length > 0 && !gated && !updateEpic.isPending,
    canToggleStatus: !!summary && (criteria.length > 0 || closed),
    blockerNote: !closed && gated ? blockerParts.join(" · ") : undefined,
    ownerName: e.owner?.name ?? "Unassigned",
    schedule: `${e.start_date ? dueDate(e.start_date) : "No start"} → ${e.target_date ? dueDate(e.target_date) : "No target"}`,
    source: e.source ? { title: e.source.title, href: e.source.href } : undefined,
    requiresMockup: e.epic.requires_mockup,
    agentHours: `${(e.agent_seconds / 3600).toFixed(1)}h`,
    burnUpPoints:
      burn && burn.scope > 0
        ? burn.points.map((pt) => ({ label: dueDate(pt.date), value: pt.done, secondary: burn.scope }))
        : [],
    burnUpSummary:
      burn && burn.scope > 0
        ? `${burn.done} / ${burn.scope} pts (${Math.round((burn.done / burn.scope) * 100)}%)`
        : undefined,
  });

  return (
    <CompanionDock
      app="epic"
      tabs={[
        {
          id: "context",
          label: "Context",
          icon: "sidebar",
          native: {
            kind: "native",
            sections,
            onToggle: (fieldId, checked) => {
              if (fieldId === "requires_mockup") {
                updateEpic.mutate({ requires_mockup: checked });
              } else if (fieldId.startsWith("criterion:")) {
                mutations.update.mutate({ id: fieldId.slice("criterion:".length), done: checked });
              }
            },
            onAction: (actionId) => {
              if (actionId === "mark_epic_done") updateEpic.mutate({ status: "done" });
              else if (actionId === "reopen_epic") updateEpic.mutate({ status: "open" });
            },
          },
        },
        { id: "chat", label: "Chat", icon: "msg", native: { kind: "companion" } },
      ]}
    />
  );
}

/** Done, running, needs you and the rest as one segmented bar, with counts and spend so far. */
function EpicProgressBar({ epicId, tickets, needs }: { epicId: string; tickets?: TicketSummary[]; needs: ReadonlyMap<string, NeedsYou> }) {
  const p = epicProgress(tickets ?? [], needs);
  const spend = useCosts({ epic: epicId });
  const parts = [
    { value: p.done, label: "done", color: "var(--state-done)" },
    { value: p.running, label: "running", color: "var(--state-progress)" },
    { value: p.needs, label: "need you", color: "var(--state-human)" },
    { value: p.open, label: "open", color: "var(--track)" },
  ];
  return (
    <section aria-label="Epic progress" className="space-y-2">
      <StackedBar segments={parts} height={8} />
      <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-12 text-fg-secondary">
        {parts.map((s) => (
          <span key={s.label} className="flex items-center gap-1.5">
            <span aria-hidden className="size-2 rounded-full" style={{ background: s.color }} />
            <span className={cx("font-mono", s.label === "need you" && s.value > 0 ? "text-pill-human-fg" : "text-fg")}>{s.value}</span> {s.label}
          </span>
        ))}
        <span className="ml-auto" title="Spend on this epic's runs, sub agents included">
          {spend.data ? <><span className="font-mono text-fg">{spendLabel(spend.data.total.cost_micros, spend.data.unpriced_runs)}</span> spent so far</> : spend.isError ? "Spend unavailable" : "…"}
        </span>
      </p>
    </section>
  );
}

/** Tickets in the epic whose run waits on the person, answerable inline. */
function NeedsYouBanner({ tickets, needs }: { tickets: TicketSummary[]; needs: ReadonlyMap<string, NeedsYou> }) {
  return (
    <section aria-label="Needs you" className="rounded-xl border border-state-human/50 bg-pill-human-bg/40 p-3">
      <h2 className="mb-1 px-1 text-11 font-medium uppercase tracking-[0.06em] text-pill-human-fg">
        Needs you <span className="font-mono">{tickets.length}</span>
      </h2>
      <ul>
        {tickets.map((t) => <NeedsYouItem key={t.key} t={t} needs={needs.get(t.key)!} />)}
      </ul>
    </section>
  );
}

function NeedsYouItem({ t, needs }: { t: TicketSummary; needs: NeedsYou }) {
  const decide = useDecideRunApproval(needs.run_id ?? "");
  const approval = approvalId(needs);
  return (
    <li className="flex flex-wrap items-center gap-3 rounded-lg px-1 py-1.5">
      <span className="font-mono text-12 text-fg-tertiary">{t.key}</span>
      <span className="flex min-w-0 flex-1 flex-col">
        <Link href={`/tickets/${encodeURIComponent(t.key)}`} className="truncate text-13 font-medium hover:underline">{t.title}</Link>
        <StateText t={t} needs={needs} className="text-12" />
      </span>
      {decide.isError && <span role="alert" className="text-12 text-pill-blocked-fg">{decide.error.message}</span>}
      {decide.isSuccess ? (
        <span role="status" className="text-12 text-fg-secondary">Approved</span>
      ) : approval && (
        <Button variant="approve" disabled={decide.isPending} onClick={() => decide.mutate({ id: approval, decision: "approve" })} aria-label={`Approve ${t.key}`}>
          {decide.isPending ? "Approving…" : "Approve"}
        </Button>
      )}
      <ButtonLink variant="approve-outline" href={needs.href} aria-label={`Open what ${t.key} needs`}>Open</ButtonLink>
    </li>
  );
}

const CHECKLIST_ORDER: TicketSummary["status"][] = ["in_progress", "in_review", "todo", "backlog", "done", "canceled"];

/** The epic's tickets as a checklist: done ones ticked, current state on the right. */
function TicketChecklist({ tickets, needs }: { tickets: TicketSummary[]; needs: ReadonlyMap<string, NeedsYou> }) {
  if (!tickets.length) return <EmptyState compact icon="tickets" title="No tickets in this epic yet">Add tickets to the epic and they&apos;re checked off here as they finish.</EmptyState>;
  const sorted = [...tickets].sort((a, b) =>
    Number(Boolean(ticketNeedsYou(b, needs.get(b.key)))) - Number(Boolean(ticketNeedsYou(a, needs.get(a.key)))) ||
    CHECKLIST_ORDER.indexOf(a.status) - CHECKLIST_ORDER.indexOf(b.status));
  return (
    <ul aria-label="Ticket checklist" className="divide-y divide-border-row overflow-hidden rounded-xl border border-border bg-surface">
      {sorted.map((t) => {
        const done = t.status === "done";
        const itemNeeds = ticketNeedsYou(t, needs.get(t.key));
        return (
          <li key={t.id} className="relative flex min-h-10 items-center gap-3 px-3.5 py-1.5 hover:bg-row-hover">
            <span
              role="img"
              aria-label={done ? "Done" : t.status === "canceled" ? "Canceled" : "Not done"}
              className={cx("grid size-4 flex-none place-items-center rounded-[5px] border", done ? "border-state-done bg-state-done text-on-accent" : "border-border-strong")}
            >
              {done && <Icon name="check" size={11} strokeWidth={2.2} />}
            </span>
            <span className="w-[72px] flex-none truncate font-mono text-12 text-fg-tertiary">{t.key}</span>
            <Link
              href={`/tickets/${encodeURIComponent(t.key)}`}
              className={cx("min-w-0 flex-1 truncate text-13 font-medium after:absolute after:inset-0", (done || t.status === "canceled") && "text-fg-secondary", t.status === "canceled" && "line-through")}
            >
              {t.title}
            </Link>
            {t.assignee && <span className="hidden text-12 text-fg-tertiary sm:inline">{t.assignee.name}</span>}
            <span className="w-10 flex-none text-right font-mono text-12 text-fg-tertiary">{t.estimate_points != null ? `${t.estimate_points} pt` : "—"}</span>
            <StateText t={t} needs={itemNeeds} className="w-[200px] flex-none text-right max-sm:w-[110px]" />
          </li>
        );
      })}
    </ul>
  );
}

/**
 * Start ready: queue the open tickets with every blocker done (existing
 * assignments are kept; unassigned ones go to the chosen main agent) and say
 * what is still blocked. Blocked tickets are started later, from here or the
 * ticket, once their blockers finish.
 */
function StartReady({ epic }: { epic: EpicOverview }) {
  const [agentId, setAgentId] = useState("");
  const bootstrap = useBootstrap();
  const agents = (bootstrap.data?.agents ?? []).filter((a) => a.kind === "main");
  const selectedAgent = agents.find((a) => a.id === agentId) ?? agents[0];
  const bulk = useBulkUpdate();
  const dispatch = useDispatch();
  const qc = useQueryClient();
  const start = useMutation({
    mutationFn: async ({ ticketKeys, unassignedKeys, assignee }: { ticketKeys: string[]; unassignedKeys: string[]; assignee?: string }) => {
      if (unassignedKeys.length) {
        if (!assignee) throw new Error("Choose a persona that takes tickets for the unassigned ones.");
        await bulk.mutateAsync({ keys: unassignedKeys, patch: { assignee_agent_id: assignee } });
      }
      return dispatch.mutateAsync(ticketKeys);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["epics"] }),
  });
  // The overview only contains a sample of tickets. Fetch the whole epic.
  const list = useTickets({ epic: epic.epic.id, view: "all" });
  const remaining = (list.data ?? []).filter((t) => t.status !== "done" && t.status !== "canceled");
  // Details tell which tickets already have a live run.
  const details = useQueries({ queries: remaining.map((t) => ({
    queryKey: keys.ticket(t.key),
    queryFn: () => unwrap(api.GET("/tickets/{key}", { params: { path: { key: t.key } } })),
  })) });
  const loading = list.isPending || details.some((q) => q.isPending);
  const failed = list.isError || details.some((q) => q.isError);
  const incomplete = !!list.data && list.data.length < epic.counts.total;
  const live = new Set(details.flatMap((q) => (q.data && hasLiveRun(q.data) ? [q.data.key] : [])));
  const { ready, blocked } = startReady(remaining, live);
  const detail = new Map(details.flatMap((q) => (q.data ? [[q.data.key, q.data] as const] : [])));
  const dispatchKeys = ready.map((t) => t.key);
  const unassignedKeys = ready.filter((t) => !(detail.get(t.key) ?? t).assignee).map((t) => t.key);
  const unassigned = unassignedKeys.length;
  return (
    <section aria-label="Start ready" className="space-y-3 rounded-xl border border-border bg-surface-raised p-4 shadow-sm">
      <div className="flex flex-wrap items-start gap-3">
        <div className="min-w-0 flex-1 space-y-1">
          <h2 className="text-14 font-medium">
            {loading ? "Checking which tickets can start…" : ready.length ? `${ready.length} ${ready.length === 1 ? "ticket is" : "tickets are"} ready to start` : "Nothing is ready to start"}
          </h2>
          <p className="text-12 text-fg-secondary">
            Starts only tickets whose blockers are done. Existing agent assignments are kept; runs begin as runner slots free up.
          </p>
        </div>
        <Button variant="approve" disabled={epic.epic.status === "done" || loading || failed || incomplete || !dispatchKeys.length || start.isPending || (unassigned > 0 && !selectedAgent)}
          onClick={() => start.mutate({ ticketKeys: dispatchKeys, unassignedKeys, assignee: selectedAgent?.id })}>
          {start.isPending ? "Starting…" : loading ? "Loading tickets…" : `${unassigned ? "Assign & start ready" : "Start ready"} (${dispatchKeys.length})`}
        </Button>
      </div>
      {unassigned > 0 && (
        <label className="flex flex-wrap items-center gap-2 text-12 text-fg-secondary">
          Agent for unassigned tickets
          <select aria-label="Persona for unassigned tickets" value={selectedAgent?.id ?? ""}
            disabled={start.isPending || bootstrap.isPending}
            onChange={(e) => { setAgentId(e.target.value); start.reset(); }}
            className="h-[30px] rounded-md border border-border-strong bg-surface px-2 text-fg">
            {!agents.length && <option value="">No persona takes tickets yet</option>}
            {agents.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
          </select>
          <span>{unassigned} {unassigned === 1 ? "ticket" : "tickets"} will be assigned to {selectedAgent?.name ?? "the agent you choose"} first.</span>
        </label>
      )}
      {!loading && blocked.length > 0 && (
        <div className="text-12 text-fg-secondary">
          <p>Still blocked, so not started:</p>
          <ul className="mt-1 space-y-0.5">
            {blocked.map((t) => (
              <li key={t.key}>
                <Link href={`/tickets/${encodeURIComponent(t.key)}`} className="font-mono text-fg-tertiary hover:text-fg">{t.key}</Link>{" "}
                {t.title} <span className="text-pill-blocked-fg">· blocked by {t.unmet_dependencies}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {!loading && live.size > 0 && <p className="text-12 text-fg-tertiary">{live.size} already {live.size === 1 ? "has a run" : "have runs"}.</p>}
      {unassigned > 0 && !bootstrap.isPending && !agents.length && <p role="alert" className="text-12 text-pill-blocked-fg">{bootstrap.isError ? "Couldn’t load personas. Refresh to try again." : "Turn on Takes tickets for a persona to assign and start these tickets."}</p>}
      {start.isError && <p role="alert" className="text-12 text-pill-blocked-fg">Couldn’t start the tickets: {start.error.message}{bulk.isSuccess && " Agent assignments were saved; retry to start."}</p>}
      {failed && <p role="alert" className="text-12 text-pill-blocked-fg">Couldn’t load all ticket details. Refresh to try again.</p>}
      {incomplete && <p role="alert" className="text-12 text-pill-blocked-fg">The ticket list is incomplete. Open the ticket list to start tickets in smaller batches.</p>}
      {start.isSuccess && <p role="status" className="text-12 text-fg-secondary">{start.data} epic tickets queued. Follow their progress above.</p>}
    </section>
  );
}
