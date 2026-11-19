import type { InspectorItem, InspectorOption, InspectorSection, NavItem } from "../protocol.ts";

export interface SpaceInspectorInput {
  id: string;
  instructions: string;
  sourceCount: number;
  sources: readonly { id: string; name: string; kindLabel: string }[];
  inlineUsed: number;
  inlineBudget: number;
  inlineLabel: string;
  spaceMemory: boolean;
  spaceName: string;
  memoryCount: number;
  personaId: string;
  personaOptions: readonly InspectorOption[];
  projectName?: string;
  connectorsSummary: string;
  work?: {
    key: string;
    archived: boolean;
    repoName?: string;
    branch: string;
  };
  filesUnder?: string;
}

export function buildSpaceInspectorSections(input: SpaceInspectorInput): InspectorSection[] {
  const instructionsText = input.instructions.trim();
  const inlineFraction = input.inlineBudget > 0 ? Math.min(1, input.inlineUsed / input.inlineBudget) : 0;

  const sourceItems: InspectorItem[] = [];
  if (input.sources.length > 0) {
    sourceItems.push({
      id: "source_list",
      kind: "list",
      rows: input.sources.slice(0, 5).map(
        (s): NavItem => ({
          id: s.id,
          title: s.name,
          trailing: s.kindLabel,
        }),
      ),
    });
  }
  sourceItems.push({
    id: "inline_budget",
    kind: "progress",
    label: "Inline context",
    detail: input.inlineLabel,
    fraction: inlineFraction,
    tone: "accent",
  });
  sourceItems.push({
    id: "source_actions",
    kind: "actions",
    actions: [{ id: "manage_sources", label: input.sources.length > 5 ? `Manage all ${input.sources.length}` : "Manage sources", icon: "artifacts" }],
  });

  const memoryItems: InspectorItem[] = [
    {
      id: "space_memory",
      kind: "toggle",
      label: "Space memory",
      checked: input.spaceMemory,
      detail: input.spaceMemory
        ? `Isolated in ${input.spaceName}; general memory still read.`
        : "Chats read and update general memory.",
    },
  ];
  if (input.memoryCount > 0) {
    memoryItems.push({
      id: "memories_link",
      kind: "fact",
      label: "Saved",
      value: `${input.memoryCount} ${input.memoryCount === 1 ? "memory" : "memories"}`,
      href: `/settings?section=spaces&space=${encodeURIComponent(input.id)}`,
    });
  }

  const defaultItems: InspectorItem[] = [
    {
      id: "persona_id",
      kind: "picker",
      label: "Persona",
      value: input.personaId,
      options: [...input.personaOptions],
    },
  ];
  if (!input.work) {
    defaultItems.push({
      id: "project",
      kind: "fact",
      label: "New tickets",
      value: input.projectName ?? "None",
    });
  }
  defaultItems.push({
    id: "connectors",
    kind: "fact",
    label: "Connectors",
    value: input.connectorsSummary,
  });

  const workItems: InspectorItem[] = input.work
    ? [
        {
          id: "work_status",
          kind: "fact",
          label: "Status",
          value: input.work.archived ? "Archived" : "Tracked",
          tone: input.work.archived ? "neutral" : "accent",
        },
        { id: "work_key", kind: "fact", label: "Key", value: input.work.key, mono: true },
        { id: "work_repo", kind: "fact", label: "Repository", value: input.work.repoName ?? "None" },
        { id: "work_branch", kind: "fact", label: "Branch", value: input.work.branch, mono: true },
      ]
    : [
        {
          id: "work_note",
          kind: "note",
          detail: `Track work to give ${input.spaceName} tickets, epics, runs and a repository.${input.filesUnder ? ` Until then, new tickets go to ${input.filesUnder}.` : ""}`,
          tone: "neutral",
        },
      ];

  return [
    {
      id: "instructions",
      title: "Instructions",
      items: [
        {
          id: "instructions_text",
          kind: "note",
          detail: instructionsText || "No instructions yet. Say how chats here should help.",
          tone: "neutral",
        },
        {
          id: "space_actions",
          kind: "actions",
          actions: [{ id: "edit_space", label: "Space settings", icon: "gear" }],
        },
      ],
    },
    {
      id: "sources",
      title: "Sources",
      aside: String(input.sourceCount),
      emptyText: "No sources yet.",
      items: sourceItems,
    },
    { id: "memory", title: "Memory", items: memoryItems },
    { id: "defaults", title: "Defaults", items: defaultItems },
    { id: "work", title: "Work", items: workItems },
  ];
}
