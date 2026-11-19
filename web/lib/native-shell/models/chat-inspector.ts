import type { InspectorItem, InspectorSection, InspectorStep, NavItem, Tone } from "../protocol.ts";

export interface ChatTurnSummary {
  id: string;
  prompt: string;
  meta: string;
  tone: Tone;
}

export interface ChatActivityInspectorInput {
  modelLabel: string;
  harnessLabel: string;
  effort?: string;
  costLabel?: string;
  running: boolean;
  liveSummary?: string;
  turns: readonly ChatTurnSummary[];
}

export function buildChatActivitySections(input: ChatActivityInspectorInput): InspectorSection[] {
  const summaryItems: InspectorItem[] = [
    { id: "model", kind: "fact", label: "Model", value: input.modelLabel, mono: true },
    { id: "harness", kind: "fact", label: "Harness", value: input.harnessLabel, mono: true },
  ];
  if (input.effort) {
    summaryItems.push({ id: "effort", kind: "fact", label: "Effort", value: input.effort });
  }
  if (input.costLabel) {
    summaryItems.push({ id: "cost", kind: "fact", label: "Cost", value: input.costLabel, mono: true });
  }
  summaryItems.push({
    id: "state",
    kind: "fact",
    label: "Status",
    value: input.running ? "Running" : "Idle",
    tone: input.running ? "accent" : "neutral",
  });

  const sections: InspectorSection[] = [{ id: "summary", title: "Session", items: summaryItems }];

  if (input.running) {
    sections.push({
      id: "live",
      title: "Current turn",
      items: [
        {
          id: "live_note",
          kind: "note",
          detail: input.liveSummary || "Assistant is working on a reply…",
          tone: "accent",
        },
      ],
    });
  }

  sections.push({
    id: "turns",
    title: "Turns",
    ...(input.turns.length > 0 ? { aside: String(input.turns.length) } : {}),
    emptyText: "Tool calls, web searches and memory changes appear once the assistant replies.",
    items: input.turns.length
      ? [
          {
            id: "turn_rows",
            kind: "list",
            rows: input.turns.map(
              (t): NavItem => ({
                id: t.id,
                title: t.prompt || "Reply",
                subtitle: t.meta,
                status: t.tone,
              }),
            ),
          },
        ]
      : [],
  });

  return sections;
}

export type ChatItemInspectorInput =
  | {
      kind: "ticket";
      key: string;
      title: string;
      statusLabel: string;
      priorityLabel: string;
      assignee?: string;
      description?: string;
      criteria: readonly { id: string; text: string; done: boolean }[];
      href: string;
      loading?: boolean;
      error?: boolean;
    }
  | {
      kind: "run";
      id: string;
      title: string;
      agent?: string;
      ticketKey?: string;
      stateLabel?: string;
      outcome?: string;
      plan: readonly { position: number; text: string; state: "done" | "current" | "pending" | "failed" | "needs_human" }[];
      href: string;
      loading?: boolean;
      error?: boolean;
    }
  | {
      kind: "page";
      id: string;
      title: string;
      path?: string;
      excerpt?: string;
      href: string;
      loading?: boolean;
      error?: boolean;
    };

export function buildChatItemSections(input: ChatItemInspectorInput): InspectorSection[] {
  if (input.error) {
    return [
      {
        id: "item_error",
        title: "Linked item",
        items: [
          { id: "error", kind: "note", detail: `Couldn’t load the ${input.kind}.`, tone: "blocked" },
          {
            id: "item_actions",
            kind: "actions",
            actions: [{ id: "close_item", label: "Close panel", icon: "x" }],
          },
        ],
      },
    ];
  }

  if (input.loading) {
    return [
      {
        id: "item_loading",
        title: "Linked item",
        items: [{ id: "loading", kind: "note", detail: `Loading ${input.kind}…`, tone: "neutral" }],
      },
    ];
  }

  if (input.kind === "ticket") {
    const items: InspectorItem[] = [
      { id: "title", kind: "fact", label: input.key, value: input.title, href: input.href },
      { id: "status", kind: "fact", label: "Status", value: `${input.statusLabel} · ${input.priorityLabel}` },
    ];
    if (input.assignee) items.push({ id: "assignee", kind: "fact", label: "Assignee", value: input.assignee });
    items.push({
      id: "item_actions",
      kind: "actions",
      actions: [
        { id: "open_item", label: "Open ticket", icon: "expand", accent: true },
        { id: "close_item", label: "Close", icon: "x" },
      ],
    });
    const sections: InspectorSection[] = [{ id: "ticket", title: "Linked ticket", items }];
    if (input.criteria.length > 0) {
      const done = input.criteria.filter((c) => c.done).length;
      sections.push({
        id: "criteria",
        title: "Acceptance criteria",
        aside: `${done}/${input.criteria.length}`,
        items: [
          {
            id: "criteria_steps",
            kind: "checklist",
            steps: input.criteria.map(
              (c): InspectorStep => ({ id: c.id, text: c.text, state: c.done ? "done" : "pending" }),
            ),
          },
        ],
      });
    }
    if (input.description?.trim()) {
      sections.push({
        id: "description",
        title: "Description",
        items: [{ id: "desc_note", kind: "note", detail: input.description.trim().slice(0, 800), tone: "neutral" }],
      });
    }
    return sections;
  }

  if (input.kind === "run") {
    const items: InspectorItem[] = [
      { id: "title", kind: "fact", label: "Run", value: input.title, href: input.href },
      ...(input.agent ? [{ id: "agent", kind: "fact" as const, label: "Agent", value: input.agent }] : []),
      ...(input.ticketKey ? [{ id: "ticket", kind: "fact" as const, label: "Ticket", value: input.ticketKey }] : []),
      ...(input.stateLabel ? [{ id: "state", kind: "fact" as const, label: "State", value: input.stateLabel }] : []),
      {
        id: "item_actions",
        kind: "actions",
        actions: [
          { id: "open_item", label: "Open run", icon: "expand", accent: true },
          { id: "close_item", label: "Close", icon: "x" },
        ],
      },
    ];
    const sections: InspectorSection[] = [{ id: "run", title: "Linked run", items }];
    if (input.plan.length > 0) {
      const done = input.plan.filter((s) => s.state === "done").length;
      sections.push({
        id: "plan",
        title: "Plan",
        aside: `${done}/${input.plan.length}`,
        items: [
          {
            id: "plan_steps",
            kind: "checklist",
            steps: input.plan.map((s): InspectorStep => ({ id: `s:${s.position}`, text: s.text, state: s.state })),
          },
        ],
      });
    }
    if (input.outcome) {
      sections.push({
        id: "outcome",
        title: "Outcome",
        items: [{ id: "outcome_note", kind: "note", detail: input.outcome, tone: "neutral" }],
      });
    }
    return sections;
  }

  const sections: InspectorSection[] = [
    {
      id: "page",
      title: "Linked page",
      items: [
        { id: "title", kind: "fact", label: "Page", value: input.title, href: input.href },
        ...(input.path ? [{ id: "path", kind: "fact" as const, label: "Path", value: input.path, mono: true }] : []),
        {
          id: "item_actions",
          kind: "actions",
          actions: [
            { id: "open_item", label: "Open in Knowledge", icon: "expand", accent: true },
            { id: "close_item", label: "Close", icon: "x" },
          ],
        },
      ],
    },
  ];
  if (input.excerpt?.trim()) {
    sections.push({
      id: "body",
      title: "Preview",
      items: [{ id: "body_note", kind: "note", detail: input.excerpt.trim().slice(0, 800), tone: "neutral" }],
    });
  }
  return sections;
}
