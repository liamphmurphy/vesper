"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState, type MouseEvent } from "react";
import { DropdownMenu } from "radix-ui";
import { useBootstrap, useInbox } from "@/lib/api/hooks";
import { needsYouByTicket, ticketNeedsYou, type NeedsYou } from "@/lib/work-rows";
import { useBoard, useBoardMoves, useTicketEditorDetail, type BoardFilters } from "@/lib/api/board-hooks";
import { BOARD_STATUSES, onlyBlocked, withBoardMoves, type Board, type BoardCard, type BoardStatus } from "@/lib/board";
import { cx } from "@/lib/cx";
import { useCompact } from "@/lib/viewport";
import { ProjectScopeState, useProjectScope } from "@/components/shell/project-scope";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { PRIORITY_NAME, STATUS_NAME } from "@/components/domain/meta";
import { FilterMenu, floatPanel } from "@/components/domain/pickers";
import { EpicCompletion } from "@/components/domain/epic-completion";
import { TicketEditorDialog } from "@/components/domain/ticket-editor-dialog";
import { DependencyMap } from "@/components/domain/dependency-map";
import { useMotionList } from "@/components/ui/motion";
import { Toggle } from "@/components/ui/controls";
import { ticketsHref } from "@/lib/tickets-layout";
import { buildBoardNavModel } from "@/lib/native-shell/models/board";
import { buildBoardExtras, parseBoardToggle } from "@/lib/native-shell/models/tickets-toolbar";
import { useIsNativeShell, useNativeContextMenu } from "@/lib/native-shell/hooks";
import { toast } from "@/lib/toast";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { ChipScroller, TicketsLayoutBar, TicketsTopBar } from "./layout-bar";
import { AssigneeAvatar, EpicChip, StateText } from "./ticket-row";

export function BoardScreen() {
  const bootstrap = useBootstrap();
  const router = useRouter();
  const params = useSearchParams();
  // The layout bar's picker owns the project; ?project= wins, then the remembered one.
  const scope = useProjectScope("required");
  const project = scope.status === "ready" ? scope.project : undefined;
  const filters: BoardFilters = {
    epic: params.get("epic") || undefined,
    assignee: params.get("assignee") || undefined,
    include_canceled: params.get("include_canceled") === "true",
  };
  // Client-side: the board returns open columns complete, so filtering loses nothing.
  const blockedOnly = params.get("blocked") === "true";
  const epics = bootstrap.data?.epics.filter((e) => e.project_id === project?.id) ?? [];
  function setParam(name: string, value: string) {
    // These filters only fetch client data. Native history integrates with
    // useSearchParams without an asynchronous server navigation per input.
    const next = new URLSearchParams(window.location.search);
    if (project) next.set("project", project.key);
    if (value) next.set(name, value); else next.delete(name);
    window.history.replaceState(null, "", ticketsHref("board", next));
  }
  const map = params.get("tab") === "map";
  const ticketKey = params.get("ticket") || undefined;
  const editor = useTicketEditorDetail(ticketKey);
  // Only a failed first load closes the editor; a failed background refetch keeps the draft.
  const loadFailed = editor.isError && !editor.data;
  function setTicket(key?: string) {
    const next = new URLSearchParams(window.location.search);
    if (key) next.set("ticket", key); else next.delete("ticket");
    window.history.replaceState(null, "", ticketsHref("board", next));
  }
  const compact = useCompact();
  const native = useIsNativeShell();
  const boardToggles = project && !native && (
    <>
      <Toggle label="Show canceled" checked={filters.include_canceled} onChange={(on) => setParam("include_canceled", on ? "true" : "")} />
      <Toggle label="Blocked only" checked={blockedOnly} onChange={(on) => setParam("blocked", on ? "true" : "")} />
    </>
  );
  const compactBoardFilters = project && (
    <>
      <FilterMenu label="Epic" value={filters.epic ?? ""} onChange={(v) => setParam("epic", v)}
        options={[{ value: "", label: "All epics" }, ...epics.map((e) => ({ value: e.id, label: e.name }))]} />
      <FilterMenu label="Assignee" value={filters.assignee ?? ""} onChange={(v) => setParam("assignee", v)}
        options={[{ value: "", label: "All assignees" }, ...(bootstrap.data?.agents ?? []).map((a) => ({ value: a.handle, label: `@${a.handle}` }))]} />
      {boardToggles}
    </>
  );
  return (
    <div data-testid="board-screen" className="flex min-h-0 flex-1 flex-col">
      <NavigatorPortal
        native={{
          model: buildBoardNavModel({
            header: {
              active: "tickets",
              project: project?.key,
              projects: bootstrap.data?.projects,
              agents: bootstrap.data?.agents,
              agent: filters.assignee ?? "",
              allowAllProjects: false,
              hideNewTicket: true,
            },
            epics: project ? epics : undefined,
            epic: filters.epic,
          }),
          onCommand: (cmd) => {
            const ctx = {
              project: project?.key,
              push: (href: string) => router.push(href),
              onProject: (v: string) => router.push(ticketsHref("board", v ? { project: v } : undefined)),
              onAgent: (v: string) => setParam("assignee", v),
            };
            if (handleWorkHeaderCommand(cmd, ctx)) return;
            if (cmd.type === "nav.activate") setParam("epic", cmd.itemId.startsWith("epic:") ? cmd.itemId.slice(5) : "");
          },
        }}
      />
      {!compact && <TicketsTopBar layout="board"
        action={{ label: "New ticket", primary: true, href: project ? `/tickets/new?project=${encodeURIComponent(project.key)}` : "/tickets/new" }}
        extra={project ? buildBoardExtras({ showCanceled: !!filters.include_canceled, blockedOnly }) : undefined}
        onExtra={(id) => {
          const t = parseBoardToggle(id);
          if (t?.type === "canceled") setParam("include_canceled", filters.include_canceled ? "" : "true");
          else if (t?.type === "blocked") setParam("blocked", blockedOnly ? "" : "true");
        }}
      />}
      <TicketsLayoutBar layout="board" />
      {compact && compactBoardFilters && <ChipScroller label="Board filters">{compactBoardFilters}</ChipScroller>}
      {/* The board's views, with its filters at the row's end (the top bar holds only the header). */}
      {project && <div className="flex flex-wrap items-center gap-x-5 gap-y-2 border-b border-border px-5 py-2 text-14">
        <nav aria-label="Board views" className="flex gap-5">
          <button aria-current={!map ? "page" : undefined} className={!map ? "font-semibold text-accent" : ""} onClick={() => setParam("tab", "")}>Board</button>
          <button aria-current={map ? "page" : undefined} className={map ? "font-semibold text-accent" : ""} onClick={() => setParam("tab", "map")}>Map</button>
        </nav>
        {!compact && <div role="group" aria-label="Board filters" className="ml-auto flex flex-wrap items-center gap-3">{boardToggles}</div>}
      </div>}
      {!project ? <ProjectScopeState base="/tickets" scope={scope} />
        : map ? <div className="p-5"><DependencyMap key={JSON.stringify([project.key, filters])} project={project.key} epic={filters.epic} assignee={filters.assignee} includeCanceled={filters.include_canceled} onOpen={setTicket} /></div>
        : <BoardView key={JSON.stringify([project.key, filters])} project={project.key} filters={filters} blockedOnly={blockedOnly} onOpen={setTicket} />}
      {ticketKey && loadFailed && <div role="alert" className="mx-5 mb-4 flex items-start justify-between gap-4 rounded-lg border border-state-blocked bg-surface p-3 text-14">
        <span>Couldn&apos;t open {ticketKey}: {editor.error.message}</span>
        <button type="button" aria-label="Dismiss ticket error" onClick={() => setTicket()}>×</button>
      </div>}
      {ticketKey && !loadFailed && bootstrap.data && <TicketEditorDialog key={ticketKey} ticketKey={ticketKey} detail={editor.data} bootstrap={bootstrap.data}
        onClose={() => setTicket()} onReload={async () => { const r = await editor.refetch(); return r.isError ? undefined : r.data; }} />}
    </div>
  );
}

function EpicHeader({ summary }: { summary: NonNullable<Board["epic"]> }) {
  const { epic } = summary;
  return (
    <section aria-label="Epic summary" className="mb-4 space-y-3 rounded-lg border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="text-15 font-semibold">{epic.name}</h1>
        <span className="rounded-full bg-accent-soft px-2 py-0.5 text-12 text-accent">{{ on_track: "On track", at_risk: "At risk", off_track: "Off track" }[epic.health]}</span>
      </div>
      {summary.objective && <p className="text-12 text-fg-secondary">{summary.objective}</p>}
      <EpicCompletion summary={summary} />
    </section>
  );
}

export function BoardView({ project, filters, blockedOnly, onOpen }: { project: string; filters: BoardFilters; blockedOnly: boolean; onOpen: (key: string) => void }) {
  const query = useBoard(project, filters);
  // Cards whose run waits on the person show it the way the list does.
  const inbox = useInbox(project);
  const needs = needsYouByTicket(inbox.data);
  const moves = useBoardMoves();
  const dragging = useRef<string | null>(null);
  const columns = useRef<HTMLDivElement>(null);
  // Dropped cards are already under the pointer; only the others need to glide.
  const landing = useRef<string | null>(null);
  useMotionList(columns, landing);
  const [over, setOver] = useState<BoardStatus>();
  // Compact: one column per screen, snapped; the pager follows the scroll and scrolls to a column.
  const compact = useCompact();
  const [page, setPage] = useState(0);
  const pager = useRef<HTMLDivElement>(null);
  useEffect(() => {
    pager.current?.children[page]?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [page]);
  function showColumn(i: number) {
    const el = columns.current;
    if (el) el.scrollTo({ left: i * el.clientWidth, behavior: "smooth" });
    setPage(i);
  }
  const statuses = filters.include_canceled ? [...BOARD_STATUSES, "canceled" as const] : BOARD_STATUSES;
  const moved = query.data && withBoardMoves(query.data, Object.values(moves.pending));
  const board = moved && (blockedOnly ? onlyBlocked(moved) : moved);
  return (
    <div className="flex min-h-0 flex-1 flex-col p-5 max-sm:p-3">
      {moves.error && <div role="alert" className="mb-4 flex items-start justify-between gap-4 rounded-lg border border-state-blocked bg-surface p-3 text-14">
        <span>{moves.error}</span><button type="button" aria-label="Dismiss move error" onClick={moves.dismissError}>×</button>
      </div>}
      <p role="status" className="sr-only">{moves.notice ?? (Object.keys(moves.pending).length ? "Moving ticket…" : "")}</p>
      {query.isPending && <p role="status" className="text-14 text-fg-secondary">Loading board…</p>}
      {query.isError && <div role="alert" className="mb-4 text-14">Couldn&apos;t load board: {query.error.message} <button type="button" onClick={() => void query.refetch()} className="underline">Retry</button></div>}
      {board?.epic && <EpicHeader summary={board.epic} />}
      {board && compact && <div ref={pager} role="group" aria-label="Status pager" className="-mx-3 mb-3 flex gap-1.5 overflow-x-auto px-3 [scrollbar-width:none]">
        {statuses.map((status, i) => {
          const column = board.columns.find((c) => c.status === status);
          return <button key={status} type="button" aria-current={i === page || undefined} onClick={() => showColumn(i)}
            className={cx("flex h-[32px] flex-none items-center gap-1.5 rounded-full border px-3 text-13", i === page ? "border-border-float bg-selected font-medium text-fg" : "border-border-strong text-fg-secondary")}>
            <StatusGlyph state={status} label={false} />{STATUS_NAME[status]}<span className="font-mono text-11 text-fg-tertiary">{column?.count ?? 0}</span>
          </button>;
        })}
      </div>}
      {board && <div ref={columns} aria-label="Board columns"
        onScroll={compact ? (e) => setPage(Math.round(e.currentTarget.scrollLeft / Math.max(1, e.currentTarget.clientWidth))) : undefined}
        className={cx("relative flex min-h-0 flex-1 overflow-auto pb-3", compact ? "snap-x snap-mandatory [scrollbar-width:none]" : "gap-2")}>
        {statuses.map((status) => {
          const column = board.columns.find((c) => c.status === status);
          return <section key={status} aria-label={STATUS_NAME[status]} data-testid={`column-${status}`}
            className={cx("rounded-lg border p-2 transition-colors duration-(--motion-fast)", compact ? "w-full flex-none snap-start" : "min-w-[220px] flex-1", over === status ? "border-accent bg-accent-soft" : "border-transparent bg-surface-sunken")}
            onDragOver={(e) => { if (dragging.current) { e.preventDefault(); e.dataTransfer.dropEffect = "move"; setOver(status); } }}
            onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOver(undefined); }}
            onDrop={(e) => {
              e.preventDefault();
              const key = dragging.current;
              dragging.current = null;
              setOver(undefined);
              const card = query.data?.columns.flatMap((c) => c.cards).find((c) => c.key === key);
              if (card && card.status !== status) landing.current = card.key;
              if (card) void moves.move(card, status);
            }}>
            <header className="mb-3 flex items-center gap-2 px-1 pt-1 text-12">
              <StatusGlyph state={status} label={false} /><h2 className="font-semibold">{STATUS_NAME[status]}</h2>
              <span className="ml-auto whitespace-nowrap text-fg-tertiary">{column?.count ?? 0} · {column?.points ?? 0} pts</span>
            </header>
            <div className="space-y-2">
              {column?.cards.map((card) => <TicketCard key={card.key} card={card} needs={ticketNeedsYou(card, needs.get(card.key))} showEpic={!filters.epic} statuses={statuses} pending={!!moves.pending[card.key]} onOpen={() => onOpen(card.key)}
                onMove={(target) => void moves.move(card, target)}
                onDragStart={() => { dragging.current = card.key; }}
                onDragEnd={() => { dragging.current = null; setOver(undefined); }} />)}
              {!column?.cards.length && <p className="p-1 text-12 text-fg-tertiary">No tickets</p>}
              {column?.truncated && <p className="px-1 py-2 text-12 text-fg-tertiary">Showing {column.cards.length} most recent of {column.count}</p>}
            </div>
          </section>;
        })}
      </div>}
    </div>
  );
}

/** A board card: the list row's content (status, key, title, state, epic, agent) stacked, plus the move menu. */
function TicketCard({ card, needs, showEpic, statuses, pending, onOpen, onMove, onDragStart, onDragEnd }: {
  card: BoardCard; needs?: NeedsYou; showEpic: boolean; statuses: BoardStatus[]; pending: boolean; onOpen: () => void; onMove: (status: BoardStatus) => void; onDragStart: () => void; onDragEnd: () => void;
}) {
  const [menu, setMenu] = useState(false);
  const [lifted, setLifted] = useState(false);
  const href = `/tickets/${encodeURIComponent(card.key)}`;
  // Plain clicks open the editor; modified clicks keep normal link behavior.
  const open = (e: MouseEvent) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); onOpen(); };
  // In the Mac app, right-clicking the card (its links included) shows its actions as an AppKit menu.
  const self = useRef<HTMLElement>(null);
  const copy = (text: string, title: string) => { void navigator.clipboard?.writeText(text).then(() => toast({ title, tone: "success" })); };
  useNativeContextMenu(self, () => [
    { id: "open", label: "Open", onSelect: onOpen },
    { id: "open-tab", label: "Open in new tab", onSelect: () => window.open(href, "_blank") },
    { id: "sep-move", separator: true },
    { id: "move", label: "Move to", disabled: pending, children: statuses.map((status) => ({
      id: `move:${status}`, label: STATUS_NAME[status], checked: status === card.status, disabled: status === card.status, onSelect: () => onMove(status),
    })) },
    { id: "sep-copy", separator: true },
    { id: "copy-link", label: "Copy link", icon: "link", onSelect: () => copy(new URL(href, window.location.href).href, "Link copied") },
    { id: "copy-key", label: `Copy ${card.key}`, onSelect: () => copy(card.key, `${card.key} copied`) },
  ], { links: "menu" });
  return <article ref={self} tabIndex={0} data-ticket-key={card.key} data-motion-key={card.key} data-needs-you={needs ? true : undefined} aria-label={`Ticket ${card.key}`} aria-busy={pending} draggable={!pending}
    onDragStart={(e) => { e.dataTransfer.setData("text/plain", card.key); e.dataTransfer.effectAllowed = "move"; onDragStart(); requestAnimationFrame(() => setLifted(true)); /* After the browser captures the drag image. */ }} onDragEnd={() => { setLifted(false); onDragEnd(); }}
    onClick={(e) => { if (!(e.target as HTMLElement).closest("a,button,[role=menu]")) onOpen(); }}
    onKeyDown={(e) => { if (e.target === e.currentTarget && !pending) {
      if (e.key === "Enter") { e.preventDefault(); onOpen(); } else if (e.key === " ") { e.preventDefault(); setMenu(true); }
    } }}
    className={cx("rounded-lg border p-3 outline-offset-2 transition-[opacity,scale] duration-(--motion-fast)", needs ? "border-state-human/60 bg-surface-raised shadow-sm" : "border-border bg-surface", lifted && "scale-[0.98] opacity-40", pending ? "opacity-60" : "cursor-grab hover:border-border-strong")}>
    <div className="mb-1.5 flex items-center gap-2 text-11">
      <StatusGlyph state={card.status} />
      <Link href={href} onClick={open} className="font-mono text-fg-tertiary hover:text-fg">{card.key}</Link>
      {card.priority !== "none" && <PriorityGlyph priority={card.priority} />}
      <span className="sr-only">{PRIORITY_NAME[card.priority]}</span>
      <span className="ml-auto flex-none"><AssigneeAvatar assignee={card.assignee} /></span>
    </div>
    <Link href={href} onClick={open} className="mb-1.5 block text-13 font-medium leading-snug hover:underline">{card.title}</Link>
    <StateText t={card} needs={needs} className="mb-2 block text-12" />
    <div className="flex flex-wrap items-center gap-2 text-11 text-fg-secondary">
      {showEpic && <EpicChip epic={card.epic} />}
      {card.estimate_points != null && <span className="font-mono">{card.estimate_points} pt</span>}
      {card.criteria_total > 0 && <span className="font-mono text-fg-tertiary" aria-label={`${card.criteria_done} of ${card.criteria_total} criteria met`}>{card.criteria_done}/{card.criteria_total}</span>}
      {needs && <Link href={needs.href} className="inline-flex h-[24px] items-center rounded-md border border-pill-human-bg px-2 text-12 font-medium text-pill-human-fg hover:bg-pill-human-bg" aria-label={`Open what ${card.key} needs`}>Open</Link>}
      <DropdownMenu.Root open={menu} onOpenChange={setMenu}>
        <DropdownMenu.Trigger asChild><button type="button" disabled={pending} aria-label={`Move ${card.key} to…`} className="ml-auto rounded px-2 py-0.5 text-16 leading-none hover:bg-hover disabled:opacity-50">⋯</button></DropdownMenu.Trigger>
        <DropdownMenu.Portal><DropdownMenu.Content aria-label={`Move ${card.key}`} align="end" sideOffset={4} className={cx(floatPanel, "w-44")} onClick={(e) => e.stopPropagation()}>
          <DropdownMenu.Label className="px-2 py-1 text-11 uppercase text-fg-tertiary">Move to…</DropdownMenu.Label>
          {statuses.map((status) => <DropdownMenu.Item key={status} disabled={status === card.status || pending} onSelect={() => onMove(status)} className="flex cursor-default items-center gap-2 rounded-md px-2 py-1.5 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50">
            <StatusGlyph state={status} label={false} />{STATUS_NAME[status]}{status === card.status && <span className="ml-auto">✓</span>}
          </DropdownMenu.Item>)}
        </DropdownMenu.Content></DropdownMenu.Portal>
      </DropdownMenu.Root>
    </div>
  </article>;
}
