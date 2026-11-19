import type { InspectorSection, NavItem } from "../protocol.ts";

export interface KnowledgeOutlineHeading {
  level: number;
  text: string;
}

export function buildKnowledgeOutlineSections(headings: readonly KnowledgeOutlineHeading[]): InspectorSection[] {
  if (!headings.length) {
    return [
      {
        id: "outline",
        title: "Outline",
        emptyText: "No headings yet. Start a line with # to add one.",
        items: [],
      },
    ];
  }
  const top = Math.min(...headings.map((h) => h.level));
  return [
    {
      id: "outline",
      title: "Outline",
      aside: String(headings.length),
      items: [
        {
          id: "headings",
          kind: "list",
          actionId: "jump_heading",
          rows: headings.map((h, i): NavItem => {
            const indent = h.level > top ? `${"  ".repeat(h.level - top)}↳ ` : "";
            return {
              id: `${i}:${h.text}`,
              title: `${indent}${h.text}`,
              trailing: `H${h.level}`,
            };
          }),
        },
      ],
    },
  ];
}

export interface KnowledgeMentionInput {
  id: string;
  sourceKind: string;
  sourceId: string;
  title: string;
  subtitle?: string;
  href?: string;
}

export function buildKnowledgeLinksSections(input: {
  linked: readonly KnowledgeMentionInput[];
  unlinked: readonly KnowledgeMentionInput[];
  linking?: boolean;
}): InspectorSection[] {
  const sections: InspectorSection[] = [
    {
      id: "linked",
      title: "Linked mentions",
      ...(input.linked.length > 0 ? { aside: String(input.linked.length) } : {}),
      emptyText: "Nothing links here yet. Link it from any page, ticket or comment with [[…]].",
      items: input.linked.length
        ? [
            {
              id: "linked_rows",
              kind: "list",
              rows: input.linked.map(
                (m): NavItem => ({
                  id: m.id,
                  title: m.title,
                  ...(m.subtitle ? { subtitle: m.subtitle } : {}),
                  ...(m.href ? { href: m.href } : {}),
                }),
              ),
            },
          ]
        : [],
    },
  ];

  if (input.unlinked.length > 0) {
    sections.push({
      id: "unlinked",
      title: "Unlinked mentions",
      aside: String(input.unlinked.length),
      items: [
        {
          id: "unlinked_rows",
          kind: "list",
          actionId: "link_mention",
          rows: input.unlinked.map(
            (m): NavItem => ({
              id: `${m.sourceKind}:${m.sourceId}`,
              title: m.title,
              subtitle: m.subtitle ? `${m.subtitle} · Click to link` : "Click to link",
              trailing: "Link",
              disabled: !!input.linking,
            }),
          ),
        },
      ],
    });
  }

  return sections;
}

export interface KnowledgeVersionInput {
  id: string;
  label: string;
  who: string;
  age: string;
  current: boolean;
}

export function buildKnowledgeHistorySections(input: {
  mode: "direct" | "suggest" | "paused";
  versions: readonly KnowledgeVersionInput[];
  busy?: boolean;
}): InspectorSection[] {
  const modeDetail =
    input.mode === "direct"
      ? "Changes apply at once; you review them afterwards."
      : input.mode === "suggest"
        ? "Nothing changes until you accept it."
        : "Persona writes are refused.";

  return [
    {
      id: "controls",
      title: "Persona edits on this page",
      items: [
        {
          id: "edit_mode",
          kind: "segmented",
          value: input.mode,
          detail: modeDetail,
          options: [
            { value: "direct", label: "Direct" },
            { value: "suggest", label: "Suggest" },
            { value: "paused", label: "Paused" },
          ],
          disabled: !!input.busy,
        },
      ],
    },
    {
      id: "versions",
      title: "History",
      aside: String(input.versions.length),
      emptyText: "No versions yet.",
      items: input.versions.length
        ? [
            {
              id: "version_rows",
              kind: "list",
              actionId: "restore_version",
              rows: input.versions.map(
                (v): NavItem => ({
                  id: v.id,
                  title: v.label,
                  subtitle: `${v.who} · ${v.age}`,
                  trailing: v.current ? "Current" : "Restore",
                  status: v.current ? "done" : "neutral",
                  disabled: v.current || !!input.busy,
                }),
              ),
            },
          ]
        : [],
    },
  ];
}
