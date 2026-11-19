import type { InspectorChip, InspectorItem, InspectorOption, InspectorSection, MenuItem, NavItem, Tone } from "../protocol.ts";

export interface TicketDependencyInput {
  key: string;
  title: string;
  statusLabel: string;
  statusTone: Tone;
}

export interface TicketRunInput {
  id: string;
  handle: string;
  stateLabel: string;
  stateTone: Tone;
  subtitle: string;
  cost: string;
}

export interface TicketBacklinkMention {
  id: string;
  sourceKind: string;
  sourceId: string;
  title: string;
  subtitle?: string;
  href?: string;
}

export interface TicketInspectorInput {
  status: string;
  statusOptions: readonly InspectorOption[];
  priority: string;
  priorityOptions: readonly InspectorOption[];
  assignee: string;
  assigneeOptions: readonly InspectorOption[];
  assigneeBadge?: { text: string; tone: Tone };
  reviewer: string;
  reviewerOptions: readonly InspectorOption[];
  epic: string;
  epicOptions: readonly InspectorOption[];
  spaceName: string;
  mockupFromEpic?: string;
  requiresMockup: boolean;
  estimate: string;
  estimateOptions: readonly InspectorOption[];
  estimateDisabled: boolean;
  estimateNote?: string;
  dueDate: string;
  selectedLabels: readonly { id: string; name: string; color?: string }[];
  allLabels: readonly { id: string; name: string }[];
  blockedBy: readonly TicketDependencyInput[];
  blocks: readonly TicketDependencyInput[];
  canEditBlockedBy: boolean;
  runs: readonly TicketRunInput[];
  runsSummary?: string;
  code?: {
    branch?: string;
    prNumber?: number;
    prState?: string;
    prUrl?: string;
    diff?: string;
    closedUnmerged?: boolean;
    synced?: string;
  };
  linkedMentions?: readonly TicketBacklinkMention[];
  unlinkedMentions?: readonly TicketBacklinkMention[];
  error?: string | null;
}

export function buildTicketInspectorSections(input: TicketInspectorInput): InspectorSection[] {
  const sections: InspectorSection[] = [];

  const propItems: InspectorItem[] = [];
  if (input.error) {
    propItems.push({ id: "save_error", kind: "note", label: "Save failed", detail: input.error, tone: "blocked" });
  }
  propItems.push(
    {
      id: "status",
      kind: "picker",
      label: "Status",
      value: input.status,
      options: [...input.statusOptions],
    },
    {
      id: "priority",
      kind: "picker",
      label: "Priority",
      value: input.priority,
      options: [...input.priorityOptions],
    },
    {
      id: "assignee_agent_id",
      kind: "picker",
      label: "Persona",
      value: input.assignee,
      options: [...input.assigneeOptions],
      ...(input.assigneeBadge ? { badge: input.assigneeBadge } : {}),
    },
    {
      id: "reviewer_user_id",
      kind: "picker",
      label: "Reviewer",
      value: input.reviewer,
      options: [...input.reviewerOptions],
    },
    {
      id: "epic_id",
      kind: "picker",
      label: "Epic",
      value: input.epic,
      options: [...input.epicOptions],
    },
    {
      id: "space",
      kind: "fact",
      label: "Space",
      value: input.spaceName,
    },
  );

  if (input.mockupFromEpic) {
    propItems.push({
      id: "requires_mockup_note",
      kind: "fact",
      label: "Mockup",
      value: `Required by epic ${input.mockupFromEpic}`,
    });
  } else {
    propItems.push({
      id: "requires_mockup",
      kind: "toggle",
      label: "Mockup",
      checked: input.requiresMockup,
      value: input.requiresMockup ? "Required" : "Not required",
      detail: input.requiresMockup ? "Required" : "Not required",
    });
  }

  propItems.push({
    id: "estimate_points",
    kind: "picker",
    label: "Estimate",
    value: input.estimate,
    options: [...input.estimateOptions],
    disabled: input.estimateDisabled,
  });

  if (input.estimateNote) {
    propItems.push({ id: "estimate_note", kind: "note", detail: input.estimateNote, tone: "neutral" });
  }

  propItems.push({
    id: "due_date",
    kind: "text",
    label: "Due",
    value: input.dueDate,
    placeholder: "YYYY-MM-DD",
  });

  const selectedIds = new Set(input.selectedLabels.map((l) => l.id));
  const labelMenu: MenuItem[] = input.allLabels.map((l) => ({
    id: l.id,
    label: l.name,
    checked: selectedIds.has(l.id),
  }));
  propItems.push({
    id: "labels",
    kind: "chips",
    label: "Labels",
    placeholder: "Toggle label",
    actionId: "labels",
    chips: input.selectedLabels.map(
      (l): InspectorChip => ({
        id: l.id,
        text: l.name,
        ...(l.color ? { color: l.color } : {}),
        removable: true,
      }),
    ),
    ...(labelMenu.length > 0 ? { menu: labelMenu } : {}),
  });

  sections.push({
    id: "properties",
    title: "Properties",
    items: propItems,
  });

  sections.push({
    id: "blocked_by",
    title: "Blocked by",
    ...(input.blockedBy.length > 0 ? { aside: String(input.blockedBy.length) } : {}),
    emptyText: "No blockers.",
    items: input.blockedBy.length
      ? [
          {
            id: "blocked_by_list",
            kind: "list",
            actionId: "remove_blocked_by",
            rows: input.blockedBy.map(
              (d): NavItem => ({
                id: d.key,
                title: `${d.key} · ${d.title}`,
                trailing: d.statusLabel,
                status: d.statusTone,
                href: `/tickets/${encodeURIComponent(d.key)}`,
                ...(input.canEditBlockedBy
                  ? {
                      contextMenu: [{ id: "remove", label: "Remove blocker", icon: "x", destructive: true }],
                    }
                  : {}),
              }),
            ),
          },
        ]
      : [],
  });

  sections.push({
    id: "blocks",
    title: "Blocks",
    ...(input.blocks.length > 0 ? { aside: String(input.blocks.length) } : {}),
    emptyText: "Doesn’t block other tickets.",
    items: input.blocks.length
      ? [
          {
            id: "blocks_list",
            kind: "list",
            actionId: "remove_blocks",
            rows: input.blocks.map(
              (d): NavItem => ({
                id: d.key,
                title: `${d.key} · ${d.title}`,
                trailing: d.statusLabel,
                status: d.statusTone,
                href: `/tickets/${encodeURIComponent(d.key)}`,
                contextMenu: [{ id: "remove", label: "Remove blocking link", icon: "x", destructive: true }],
              }),
            ),
          },
        ]
      : [],
  });

  sections.push({
    id: "runs",
    title: "Runs",
    ...(input.runsSummary ? { aside: input.runsSummary } : input.runs.length > 0 ? { aside: String(input.runs.length) } : {}),
    emptyText: "No runs yet. Dispatch the ticket to start one.",
    items: input.runs.length
      ? [
          {
            id: "runs_list",
            kind: "list",
            rows: input.runs.map(
              (r): NavItem => ({
                id: r.id,
                title: `@${r.handle} · ${r.stateLabel}`,
                subtitle: r.subtitle,
                trailing: r.cost,
                status: r.stateTone,
                href: `/runs/${encodeURIComponent(r.id)}`,
              }),
            ),
          },
        ]
      : [],
  });

  if (input.code && (input.code.branch || input.code.prNumber)) {
    const codeItems: InspectorItem[] = [];
    if (input.code.branch) {
      codeItems.push({ id: "branch", kind: "fact", label: "Branch", value: input.code.branch, mono: true });
    }
    if (input.code.prNumber) {
      codeItems.push({
        id: "pr",
        kind: "fact",
        label: "Pull request",
        value: `#${input.code.prNumber}${input.code.prState ? ` · ${input.code.prState}` : ""}${input.code.diff ? ` (${input.code.diff})` : ""}`,
        ...(input.code.prUrl ? { url: input.code.prUrl } : {}),
      });
    }
    if (input.code.closedUnmerged) {
      codeItems.push({ id: "pr_closed", kind: "note", detail: "PR closed without merging", tone: "blocked" });
    }
    if (input.code.synced) {
      codeItems.push({ id: "pr_synced", kind: "fact", label: "Synced", value: input.code.synced });
    }
    sections.push({ id: "code", title: "Code", items: codeItems });
  }

  if (input.linkedMentions || input.unlinkedMentions) {
    const linked = input.linkedMentions ?? [];
    const unlinked = input.unlinkedMentions ?? [];
    const items: InspectorItem[] = [];
    if (linked.length > 0) {
      items.push({
        id: "linked_mentions",
        kind: "list",
        label: "Linked mentions",
        rows: linked.map(
          (m): NavItem => ({
            id: m.id,
            title: m.title,
            ...(m.subtitle ? { subtitle: m.subtitle } : {}),
            ...(m.href ? { href: m.href } : {}),
          }),
        ),
      });
    }
    if (unlinked.length > 0) {
      items.push({
        id: "unlinked_mentions",
        kind: "list",
        label: "Unlinked mentions",
        actionId: "link_mention",
        rows: unlinked.map(
          (m): NavItem => ({
            id: `${m.sourceKind}:${m.sourceId}`,
            title: m.title,
            subtitle: m.subtitle ? `${m.subtitle} · Click to link` : "Click to link",
            trailing: "Link",
          }),
        ),
      });
    }
    sections.push({
      id: "backlinks",
      title: "Backlinks",
      ...(linked.length + unlinked.length > 0 ? { aside: String(linked.length + unlinked.length) } : {}),
      emptyText: "Nothing links here yet.",
      items,
    });
  }

  return sections;
}
