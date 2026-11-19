import type { InspectorItem, InspectorSection, InspectorStep, NavItem, Tone } from "../protocol.ts";

export interface RunInspectorPlanStep {
  position: number;
  text: string;
  state: "done" | "current" | "pending" | "failed" | "needs_human";
}

export interface RunInspectorInput {
  plan: readonly RunInspectorPlanStep[];
  ticket?: {
    key: string;
    title: string;
    statusLabel: string;
    priorityLabel: string;
    epic?: { id: string; name: string; done?: number; total?: number };
    criteria: readonly { id: string; position: number; text: string; done: boolean }[];
  };
  code?: {
    branch?: string;
    additions?: number;
    deletions?: number;
    prNumber?: number;
    prState?: string;
    prUrl?: string;
  };
  subAgents?: readonly {
    id: string;
    agent: string;
    subtitle: string;
    stateTone: Tone;
  }[];
  run: {
    id: string;
    purpose: string;
    model: string;
    harness: string;
    mode: string;
    started: string;
    elapsed: string;
    cost: string;
    tokens: string;
    subRuns: number;
    slot: string;
    dispatchedBy?: string;
    workspacePath?: string;
  };
  usage: {
    tokensSummary?: string;
    costSummary?: string;
    cacheSharePct?: number | null;
    turns: readonly { seq: number; summary: string }[];
    models: readonly { model: string; summary: string }[];
  };
  viewMode: "simple" | "details" | "graph" | "files";
  environmentHref: string;
  rawLogUrl?: string;
}

export function buildRunInspectorSections(input: RunInspectorInput): InspectorSection[] {
  const sections: InspectorSection[] = [];

  if (input.plan.length > 0) {
    const doneCount = input.plan.filter((s) => s.state === "done").length;
    sections.push({
      id: "plan",
      title: "Plan",
      aside: `${doneCount}/${input.plan.length}`,
      items: [
        {
          id: "plan_steps",
          kind: "checklist",
          steps: input.plan.map(
            (s): InspectorStep => ({
              id: `step:${s.position}`,
              text: s.text,
              state: s.state,
            }),
          ),
        },
      ],
    });
  }

  if (input.ticket) {
    const t = input.ticket;
    const ticketItems: InspectorItem[] = [
      {
        id: "ticket_link",
        kind: "fact",
        label: "Ticket",
        value: `${t.key} · ${t.title}`,
        href: `/tickets/${encodeURIComponent(t.key)}`,
      },
      {
        id: "ticket_state",
        kind: "fact",
        label: "State",
        value: `${t.statusLabel} · ${t.priorityLabel}`,
      },
    ];
    if (t.epic) {
      ticketItems.push({
        id: "epic_link",
        kind: "fact",
        label: "Epic",
        value: t.epic.name,
        href: `/epics/${encodeURIComponent(t.epic.id)}`,
      });
      if (t.epic.total && t.epic.total > 0 && t.epic.done !== undefined) {
        ticketItems.push({
          id: "epic_progress",
          kind: "progress",
          label: "Epic progress",
          detail: `${t.epic.done}/${t.epic.total} done`,
          fraction: t.epic.done / t.epic.total,
          tone: "done",
        });
      }
    }
    sections.push({
      id: "ticket",
      title: "Ticket",
      items: ticketItems,
    });

    if (t.criteria.length > 0) {
      const sorted = [...t.criteria].sort((a, b) => a.position - b.position);
      const met = sorted.filter((c) => c.done).length;
      sections.push({
        id: "criteria",
        title: "Acceptance criteria",
        aside: `${met}/${sorted.length}`,
        items: [
          {
            id: "ticket_criteria",
            kind: "checklist",
            steps: sorted.map((c) => ({
              id: c.id,
              text: c.text,
              state: c.done ? "done" : "pending",
            })),
          },
        ],
      });
    }
  }

  if (input.code && (input.code.branch || input.code.prNumber)) {
    const codeItems: InspectorItem[] = [];
    if (input.code.branch) {
      codeItems.push({ id: "branch", kind: "fact", label: "Branch", value: input.code.branch, mono: true });
    }
    if (input.code.additions !== undefined || input.code.deletions !== undefined) {
      codeItems.push({
        id: "diff",
        kind: "fact",
        label: "Diff",
        value: `+${input.code.additions ?? 0} −${input.code.deletions ?? 0}`,
        mono: true,
      });
    }
    if (input.code.prNumber) {
      const label = `#${input.code.prNumber}${input.code.prState ? ` · ${input.code.prState}` : ""}`;
      codeItems.push({
        id: "pr",
        kind: "fact",
        label: "Pull request",
        value: label,
        ...(input.code.prUrl ? { url: input.code.prUrl } : {}),
      });
    }
    sections.push({ id: "code", title: "Code", items: codeItems });
  }

  if (input.subAgents && input.subAgents.length > 0) {
    sections.push({
      id: "sub_agents",
      title: "Sub-agents",
      aside: String(input.subAgents.length),
      items: [
        {
          id: "sub_agent_rows",
          kind: "list",
          rows: input.subAgents.map(
            (s): NavItem => ({
              id: s.id,
              title: s.agent,
              subtitle: s.subtitle,
              status: s.stateTone,
              href: `/runs/${encodeURIComponent(s.id)}`,
            }),
          ),
        },
      ],
    });
  }

  const r = input.run;
  const runItems: InspectorItem[] = [
    { id: "purpose", kind: "fact", label: "Purpose", value: r.purpose },
    { id: "model", kind: "fact", label: "Model", value: r.model, mono: true },
    { id: "harness", kind: "fact", label: "Harness", value: `${r.harness} · ${r.mode}`, mono: true },
    { id: "started", kind: "fact", label: "Started", value: r.started },
    { id: "elapsed", kind: "fact", label: "Elapsed", value: r.elapsed, mono: true },
    { id: "cost", kind: "fact", label: "Cost", value: r.cost, mono: true },
    { id: "tokens", kind: "fact", label: "Tokens", value: r.tokens, mono: true },
    { id: "sub_runs", kind: "fact", label: "Sub runs", value: String(r.subRuns), mono: true },
    { id: "slot", kind: "fact", label: "Runner slot", value: r.slot, mono: true },
  ];
  if (r.dispatchedBy) {
    runItems.push({ id: "dispatched_by", kind: "fact", label: "Dispatched by", value: r.dispatchedBy });
  }
  if (r.workspacePath) {
    runItems.push({ id: "workspace", kind: "fact", label: "Workspace", value: r.workspacePath, mono: true });
  }
  sections.push({ id: "run", title: "Run", items: runItems });

  const usageItems: InspectorItem[] = [];
  if (input.usage.tokensSummary) {
    usageItems.push({ id: "usage_tokens", kind: "fact", label: "Total tokens", value: input.usage.tokensSummary, mono: true });
  }
  if (input.usage.costSummary) {
    usageItems.push({ id: "usage_cost", kind: "fact", label: "Estimated cost", value: input.usage.costSummary, mono: true });
  }
  if (input.usage.cacheSharePct !== null && input.usage.cacheSharePct !== undefined) {
    const pct = Math.max(0, Math.min(100, Math.round(input.usage.cacheSharePct)));
    usageItems.push({
      id: "cache_share",
      kind: "progress",
      label: "Cache share",
      detail: `${pct}%`,
      fraction: pct / 100,
      tone: "accent",
    });
  }
  for (const t of input.usage.turns) {
    usageItems.push({ id: `turn:${t.seq}`, kind: "fact", label: `Turn ${t.seq}`, value: t.summary, mono: true });
  }
  if (input.usage.models.length > 1) {
    for (const m of input.usage.models) {
      usageItems.push({ id: `model:${m.model}`, kind: "fact", label: m.model, value: m.summary, mono: true });
    }
  }
  if (usageItems.length > 0) {
    sections.push({ id: "usage", title: "Usage", items: usageItems });
  }

  const openItems: InspectorItem[] = [
    {
      id: "views",
      kind: "actions",
      actions: [
        { id: "view:details", label: "Raw log", icon: "terminal", active: input.viewMode === "details" },
        { id: "view:graph", label: "Graph", icon: "graph", active: input.viewMode === "graph" },
        { id: "view:files", label: "Files", icon: "folder", active: input.viewMode === "files" },
      ],
    },
    { id: "environment", kind: "fact", label: "Environment", value: "Open settings", href: input.environmentHref },
  ];
  if (input.rawLogUrl) {
    openItems.push({ id: "raw_log", kind: "fact", label: "Raw log", value: "Download JSONL", url: input.rawLogUrl });
  }
  sections.push({ id: "open", title: "Open", items: openItems });

  return sections;
}
