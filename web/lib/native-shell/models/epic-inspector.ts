import type { InspectorBarPoint, InspectorItem, InspectorSection, InspectorStep, NavItem, Tone } from "../protocol.ts";

export interface EpicDetailInspectorInput {
  status: "open" | "done";
  pointsDone: number;
  pointsTotal: number;
  criteriaDone: number;
  criteriaTotal: number;
  criteria: readonly { id: string; text: string; done: boolean }[];
  canMarkDone: boolean;
  canToggleStatus: boolean;
  blockerNote?: string;
  ownerName: string;
  schedule: string;
  source?: { title: string; href: string };
  requiresMockup: boolean;
  agentHours: string;
  burnUpPoints: readonly InspectorBarPoint[];
  burnUpSummary?: string;
}

export function buildEpicInspectorSections(input: EpicDetailInspectorInput): InspectorSection[] {
  const closed = input.status === "done";
  const pointsFrac = input.pointsTotal > 0 ? input.pointsDone / input.pointsTotal : 0;
  const criteriaFrac = input.criteriaTotal > 0 ? input.criteriaDone / input.criteriaTotal : 0;

  const completionItems: InspectorItem[] = [
    {
      id: "epic_status",
      kind: "fact",
      label: "Status",
      value: closed ? "Done" : "Open",
      tone: closed ? "done" : "neutral",
    },
    {
      id: "points_progress",
      kind: "progress",
      label: "Points",
      detail: `${input.pointsDone} / ${input.pointsTotal} pts`,
      fraction: pointsFrac,
      tone: "done",
    },
    {
      id: "criteria_progress",
      kind: "progress",
      label: "Criteria",
      detail: `${input.criteriaDone} / ${input.criteriaTotal} met`,
      fraction: criteriaFrac,
      tone: "accent",
    },
  ];

  if (input.criteria.length > 0) {
    completionItems.push({
      id: "criteria_list",
      kind: "checklist",
      steps: input.criteria.map(
        (c): InspectorStep => ({
          id: `criterion:${c.id}`,
          text: c.text,
          state: c.done ? "done" : "pending",
          interactive: !closed,
        }),
      ),
    });
  }

  if (input.blockerNote) {
    completionItems.push({
      id: "blocker_note",
      kind: "note",
      label: "Done blockers",
      detail: input.blockerNote,
      tone: "blocked",
    });
  }

  if (input.canToggleStatus) {
    completionItems.push({
      id: "status_actions",
      kind: "actions",
      actions: [
        closed
          ? { id: "reopen_epic", label: "Reopen epic", icon: "refresh" }
          : { id: "mark_epic_done", label: "Mark epic done", icon: "check", accent: true, disabled: !input.canMarkDone },
      ],
    });
  }

  const detailItems: InspectorItem[] = [
    { id: "owner", kind: "fact", label: "Owner", value: input.ownerName },
    { id: "schedule", kind: "fact", label: "Schedule", value: input.schedule },
    input.source
      ? { id: "source", kind: "fact", label: "Source", value: input.source.title, href: input.source.href }
      : { id: "source", kind: "fact", label: "Source", value: "No linked PRD" },
    {
      id: "requires_mockup",
      kind: "toggle",
      label: "Requires mockup",
      checked: input.requiresMockup,
      detail: "Tickets need an approved UI mockup before finishing.",
    },
    { id: "agent_hours", kind: "fact", label: "Agent hours", value: input.agentHours, mono: true },
  ];

  const burnupItems: InspectorItem[] =
    input.burnUpPoints.length >= 2
      ? [
          {
            id: "burnup_chart",
            kind: "chart",
            label: input.burnUpSummary ?? "Points completed",
            points: [...input.burnUpPoints],
          },
        ]
      : [
          {
            id: "burnup_empty",
            kind: "note",
            detail: input.burnUpSummary ?? "No estimates yet. Estimate the epic’s tickets to see a burn-up.",
            tone: "neutral",
          },
        ];

  return [
    {
      id: "completion",
      title: "Acceptance criteria",
      aside: `${input.criteriaDone}/${input.criteriaTotal}`,
      items: completionItems,
    },
    { id: "details", title: "Specs and details", items: detailItems },
    { id: "burnup", title: "Points burn-up", items: burnupItems },
  ];
}

export interface EpicsOverviewInspectorInput {
  epicId: string;
  name: string;
  projectName: string;
  healthLabel: string;
  healthTone: Tone;
  status: "open" | "done";
  doneCount: number;
  totalCount: number;
  pointsDone: number;
  pointsTotal: number;
  ownerName: string;
  targetDate: string;
  objective?: string;
  tickets: readonly { key: string; title: string; statusLabel: string; statusTone: Tone }[];
}

export function buildEpicsOverviewInspectorSections(input: EpicsOverviewInspectorInput): InspectorSection[] {
  const pct = input.totalCount > 0 ? input.doneCount / input.totalCount : 0;
  const ptsPct = input.pointsTotal > 0 ? input.pointsDone / input.pointsTotal : 0;

  const summaryItems: InspectorItem[] = [
    { id: "health", kind: "fact", label: "Health", value: input.healthLabel, tone: input.healthTone },
    { id: "status", kind: "fact", label: "Status", value: input.status === "done" ? "Done" : "Open" },
    { id: "owner", kind: "fact", label: "Owner", value: input.ownerName },
    { id: "target", kind: "fact", label: "Target", value: input.targetDate },
    {
      id: "ticket_progress",
      kind: "progress",
      label: "Tickets",
      detail: `${input.doneCount}/${input.totalCount} done`,
      fraction: pct,
      tone: "done",
    },
  ];
  if (input.pointsTotal > 0) {
    summaryItems.push({
      id: "points_progress",
      kind: "progress",
      label: "Points",
      detail: `${input.pointsDone}/${input.pointsTotal} pts`,
      fraction: ptsPct,
      tone: "accent",
    });
  }
  if (input.objective) {
    summaryItems.push({ id: "objective", kind: "note", label: "Objective", detail: input.objective, tone: "neutral" });
  }
  summaryItems.push({
    id: "open_actions",
    kind: "actions",
    actions: [{ id: "open_epic", label: "Open epic page", icon: "epics", accent: true }],
  });

  return [
    { id: "overview", title: input.name, aside: input.projectName, items: summaryItems },
    {
      id: "tickets",
      title: "Tickets",
      aside: String(input.tickets.length),
      emptyText: "No tickets in this epic.",
      items: input.tickets.length
        ? [
            {
              id: "epic_tickets",
              kind: "list",
              rows: input.tickets.map(
                (t): NavItem => ({
                  id: t.key,
                  title: `${t.key} · ${t.title}`,
                  trailing: t.statusLabel,
                  status: t.statusTone,
                  href: `/tickets/${encodeURIComponent(t.key)}`,
                }),
              ),
            },
          ]
        : [],
    },
  ];
}
