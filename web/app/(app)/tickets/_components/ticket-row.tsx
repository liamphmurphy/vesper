"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, ViewTransition, type MouseEvent, type RefObject } from "react";
import type { TicketStatus, TicketSummary } from "@/lib/api/client";
import { useUpdateTicket } from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useNativeContextMenu } from "@/lib/native-shell/hooks";
import { toast } from "@/lib/toast";
import { cx } from "@/lib/cx";
import { shortAgo } from "@/lib/format";
import { stateText, type NeedsYou } from "@/lib/work-rows";
import { Icon } from "@/components/ui/icon";
import { AgentAvatar, UnassignedAvatar } from "@/components/domain/avatars";
import { PersonaAvatar } from "@/components/domain/persona-avatar";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { LabelChip } from "@/components/domain/labels";
import { STATUS_NAME, STATUS_ORDER } from "@/components/domain/meta";
import { hoverReveal } from "@/lib/reveal";

export type Density = "comfortable" | "compact";

function useTicketRowContextMenu(
  rowRef: RefObject<HTMLDivElement | null>,
  t: TicketSummary,
  needs?: NeedsYou,
  onStart?: () => void,
) {
  const router = useRouter();
  const update = useUpdateTicket(t.key);
  const ticketHref = `/tickets/${encodeURIComponent(t.key)}`;
  const copy = (text: string, title: string) => {
    void navigator.clipboard?.writeText(text).then(() => toast({ title, tone: "success" }));
  };

  useNativeContextMenu(
    rowRef,
    () => [
      {
        id: "open",
        label: needs ? "Open what it needs" : "Open ticket",
        icon: "tickets",
        onSelect: () => router.push(needs?.href ?? ticketHref),
      },
      {
        id: "open-tab",
        label: "Open in new tab",
        icon: "external",
        onSelect: () => window.open(ticketHref, "_blank"),
      },
      ...(onStart ? [{ id: "start", label: "Start run", icon: "play", onSelect: onStart }] : []),
      { id: "sep-status", separator: true },
      {
        id: "status",
        label: "Set status",
        icon: "sliders",
        disabled: update.isPending,
        children: STATUS_ORDER.map((status: TicketStatus) => ({
          id: `status:${status}`,
          label: STATUS_NAME[status],
          checked: status === t.status,
          disabled: status === t.status || update.isPending,
          onSelect: () => {
            update.mutate(
              { status },
              {
                onSuccess: () => toast({ title: `${t.key} → ${STATUS_NAME[status]}`, tone: "success" }),
                onError: (e) =>
                  toast({
                    title: `Couldn’t update ${t.key}`,
                    description: e instanceof Error ? e.message : undefined,
                    tone: "error",
                  }),
              },
            );
          },
        })),
      },
      { id: "sep-copy", separator: true },
      { id: "copy-key", label: `Copy ${t.key}`, icon: "copy", onSelect: () => copy(t.key, `${t.key} copied`) },
      {
        id: "copy-link",
        label: "Copy link",
        icon: "link",
        onSelect: () => copy(new URL(ticketHref, window.location.href).href, "Link copied"),
      },
    ],
    { links: "menu" },
  );
}

/** Criteria done/total with a small progress bar (green when complete). */
export function CriteriaProgress({ done, total, compact }: { done: number; total: number; compact?: boolean }) {
  if (total === 0) return <span className="text-fg-tertiary" aria-label="No criteria">–</span>;
  const pct = Math.round((done / total) * 100);
  return (
    <span className="flex items-center gap-2" title={`${done} of ${total} criteria done`}>
      <span className="font-mono text-12 text-fg-secondary">
        {done}/{total}
      </span>
      {!compact && (
        <span aria-hidden className="h-1 w-10 overflow-hidden rounded-full bg-border-strong">
          <span className={cx("block h-full rounded-full", done === total ? "bg-state-done" : "bg-accent")} style={{ width: `${pct}%` }} />
        </span>
      )}
    </span>
  );
}

/** The current state: amber when the ticket's run waits on the person, red when blocked. */
export function StateText({ t, needs, className }: { t: TicketSummary; needs?: NeedsYou; className?: string }) {
  const s = stateText(t, needs);
  return (
    <span
      data-state-text
      title={s.text}
      className={cx("truncate text-13", s.tone === "human" ? "text-pill-human-fg" : s.tone === "blocked" ? "text-pill-blocked-fg" : "text-fg-tertiary", className)}
    >
      {s.text}
    </span>
  );
}

/** The epic a ticket belongs to, as a quiet chip. */
export function EpicChip({ epic }: { epic?: TicketSummary["epic"] }) {
  if (!epic) return null;
  return (
    <span title={`Epic: ${epic.name}`} className="inline-flex h-[20px] max-w-[160px] items-center gap-1 rounded-full bg-surface-sunken px-2 text-12 text-fg-secondary">
      <Icon name="epics" size={11} className="flex-none text-fg-tertiary" />
      <span className="truncate">{epic.name}</span>
    </span>
  );
}

/** Match a ticket/run assignee to its PersonaAvatar when available, falling back to AgentAvatar. */
export function AgentOrPersonaAvatar({
  agent,
  size = "sm",
}: {
  agent: { id?: string; handle?: string; name: string; color_index: number };
  size?: "sm" | "md";
}) {
  const personas = usePersonas();
  const match = personas.data?.personas.find(
    (p) =>
      (agent.id && p.id === agent.id) ||
      (agent.handle && p.id === agent.handle) ||
      p.name.toLowerCase() === agent.name.toLowerCase(),
  );
  if (match) {
    return (
      <PersonaAvatar
        name={match.name}
        color={match.color}
        src={match.avatar_url ?? undefined}
        characterSvg={match.character_svg ?? undefined}
        size={size === "md" ? 24 : 20}
      />
    );
  }
  return <AgentAvatar name={agent.name} colorIndex={agent.color_index} label={false} size={size} />;
}

/** The ticket's agent as an avatar, its name on hover and for screen readers. */
export function AssigneeAvatar({ assignee, size }: { assignee?: TicketSummary["assignee"]; size?: "sm" | "md" }) {
  return assignee ? (
    <span title={assignee.name} className="flex flex-none items-center">
      <AgentOrPersonaAvatar agent={assignee} size={size} />
      <span className="sr-only">{assignee.name}</span>
    </span>
  ) : (
    <span title="Unassigned" className="flex flex-none items-center">
      <UnassignedAvatar size={size === "md" ? 24 : undefined} />
      <span className="sr-only">Unassigned</span>
    </span>
  );
}

/**
 * Ticket row in the chat look: no table rules, a rounded hover. Status dot,
 * key, title, current state (amber for Needs you), epic chip and agent. The
 * title is a stretched link; the checkbox appears on hover, focus or
 * selection; `focused` is the j/k cursor. Rows in the Needs you group get an
 * Open button that goes where the run waits.
 */
export function TicketRow({
  t,
  needs,
  selected,
  focused,
  density,
  showEpic,
  onSelect,
  onFocusRow,
  onStart,
}: {
  t: TicketSummary;
  needs?: NeedsYou;
  selected: boolean;
  focused: boolean;
  density: Density;
  showEpic: boolean;
  onSelect: (e: MouseEvent<HTMLInputElement>) => void;
  onFocusRow: () => void;
  onStart?: (t: TicketSummary) => void;
}) {
  const rowRef = useRef<HTMLDivElement>(null);
  const compact = density === "compact";
  const canStart = !compact && !needs && t.status === "todo" && t.unmet_dependencies === 0 && !!t.assignee && !!onStart;
  useTicketRowContextMenu(rowRef, t, needs, canStart ? () => onStart(t) : undefined);
  return (
    <div
      ref={rowRef}
      data-ticket-row={t.key}
      data-focused={focused || undefined}
      data-needs-you={needs ? true : undefined}
      onMouseDown={onFocusRow}
      className={cx(
        "group relative flex items-center gap-3 rounded-lg px-3 hover:bg-row-hover",
        compact ? "h-8" : "h-11",
        selected && "bg-accent/8 hover:bg-accent/10",
        focused && "outline outline-1 -outline-offset-1 outline-accent/45",
      )}
    >
      <input
        type="checkbox"
        checked={selected}
        onClick={onSelect}
        onChange={() => {}}
        aria-label={`Select ${t.key}`}
        className={cx(
          "relative z-10 size-3.5 flex-none accent-[var(--accent)]",
          selected || focused ? "opacity-100" : cx(hoverReveal(), "focus-visible:opacity-100"),
        )}
      />
      <StatusGlyph state={t.status} />
      <span className="w-[72px] flex-none truncate font-mono text-12 text-fg-tertiary">{t.key}</span>
      <span className="flex min-w-0 flex-1 items-center gap-2">
        {/* Stretched link: the whole row opens the ticket. */}
        <Link href={`/tickets/${t.key}`} className="truncate font-medium text-fg after:absolute after:inset-0 after:rounded-lg hover:text-fg">
          <ViewTransition name={`ticket-title-${t.key}`} share="auto" default="none"><span>{t.title}</span></ViewTransition>
        </Link>
        {t.priority !== "none" && <PriorityGlyph priority={t.priority} />}
      </span>
      {!compact && (
        <span className="hidden flex-none gap-1.5 2xl:flex">
          {t.labels.slice(0, 2).map((l) => (
            <LabelChip key={l.id} name={l.name} color={l.color} />
          ))}
        </span>
      )}
      <StateText t={t} needs={needs} className="w-[220px] flex-none max-lg:w-[150px]" />
      {!compact && (
        <span className="hidden w-[68px] flex-none lg:block">
          <CriteriaProgress done={t.criteria_done} total={t.criteria_total} compact />
        </span>
      )}
      <span className="w-8 flex-none text-center">
        {t.estimate_points != null ? (
          <span className="font-mono text-12 text-fg-secondary" title={`${t.estimate_points} points`}>
            {t.estimate_points}
          </span>
        ) : (
          <span className="font-mono text-12 text-fg-tertiary" title="Not estimated">–</span>
        )}
      </span>
      {showEpic && (
        <span className="hidden w-[150px] flex-none md:flex">
          <EpicChip epic={t.epic} />
        </span>
      )}
      <AssigneeAvatar assignee={t.assignee} />
      {needs ? (
        <Link
          href={needs.href}
          className="relative z-10 inline-flex h-[26px] flex-none items-center rounded-md border border-pill-human-bg px-2.5 text-13 font-medium text-pill-human-fg hover:bg-pill-human-bg"
          aria-label={`Open what ${t.key} needs`}
        >
          Open
        </Link>
      ) : canStart ? (
        <button
          type="button"
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            onStart(t);
          }}
          aria-label={`Start ${t.key}`}
          className="relative z-10 inline-flex h-[24px] flex-none items-center gap-1 rounded-md border border-border-strong bg-surface px-2 text-12 font-medium text-fg hover:border-accent hover:text-accent"
        >
          <Icon name="play" size={10} />
          Start
        </button>
      ) : (
        <span className="w-[44px] flex-none text-right text-12 text-fg-tertiary" title={new Date(t.updated_at).toLocaleString()}>
          {shortAgo(t.updated_at)}
        </span>
      )}
    </div>
  );
}

/**
 * Compact-screen ticket row (DESIGN.md §3 Responsive): 64px, the whole row opens the ticket.
 * Status, the title over key · state, and the agent on the right. Rows that need the person
 * get an Open button beside the link. Nothing in it waits for hover.
 */
export function CompactTicketRow({ t, needs }: { t: TicketSummary; needs?: NeedsYou }) {
  const rowRef = useRef<HTMLDivElement>(null);
  useTicketRowContextMenu(rowRef, t, needs);
  return (
    <div ref={rowRef} data-ticket-row={t.key} data-needs-you={needs ? true : undefined} className="relative flex h-[64px] items-center gap-3 px-4 active:bg-row-hover">
      <StatusGlyph state={t.status} />
      <span className="flex min-w-0 flex-1 flex-col gap-1">
        <Link href={`/tickets/${t.key}`} className="truncate text-15 font-medium text-fg after:absolute after:inset-0">
          <ViewTransition name={`ticket-title-${t.key}`} share="auto" default="none"><span>{t.title}</span></ViewTransition>
        </Link>
        <span className="flex min-w-0 items-center gap-2 text-12 text-fg-tertiary">
          <span className="flex-none font-mono">{t.key}</span>
          {t.priority !== "none" && <PriorityGlyph priority={t.priority} />}
          {t.estimate_points != null && <span className="flex-none font-mono" title={`${t.estimate_points} points`}>{t.estimate_points} pts</span>}
          <StateText t={t} needs={needs} className="min-w-0 text-12" />
        </span>
      </span>
      {needs ? (
        <Link href={needs.href} className="relative z-10 inline-flex h-[36px] flex-none items-center rounded-md border border-pill-human-bg px-3 text-13 font-medium text-pill-human-fg">
          Open
        </Link>
      ) : (
        <AssigneeAvatar assignee={t.assignee} size="md" />
      )}
    </div>
  );
}
