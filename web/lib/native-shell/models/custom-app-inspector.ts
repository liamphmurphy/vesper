import type { InspectorItem, InspectorOption, InspectorSection, NavItem } from "../protocol.ts";

export interface CustomAppCapabilityInput {
  key: string;
  label: string;
  hint: string;
  mode: "allowed" | "requires_approval" | "denied";
  requested?: "allowed" | "requires_approval" | "denied";
}

export interface CustomAppVersionInput {
  seq: number;
  authorLabel: string;
  age: string;
  note?: string;
  current: boolean;
}

export interface CustomAppInspectorInput {
  hasMcpServer: boolean;
  mcpEntry: string;
  mcpToolCount: number;
  mcpTools: readonly { name: string; description: string }[];
  dbSizeLabel: string;
  schemaCount: number;
  schemaObjects: readonly { type: string; name: string }[];
  capabilities: readonly CustomAppCapabilityInput[];
  toolScope: "chats" | "app_only";
  versions: readonly CustomAppVersionInput[];
  updating?: boolean;
}

const MODE_OPTIONS: InspectorOption[] = [
  { value: "allowed", label: "Allow" },
  { value: "requires_approval", label: "Ask" },
  { value: "denied", label: "Deny" },
];

const SCOPE_OPTIONS: InspectorOption[] = [
  { value: "chats", label: "All chats" },
  { value: "app_only", label: "This app only" },
];

export function buildCustomAppInspectorSections(input: CustomAppInspectorInput): InspectorSection[] {
  const sections: InspectorSection[] = [];

  if (input.hasMcpServer) {
    const mcpItems: InspectorItem[] = [
      {
        id: "mcp_scope",
        kind: "fact",
        label: "Scope",
        value: input.toolScope === "app_only" ? "This app only" : "Chats & workflows",
        tone: "done",
      },
      { id: "mcp_entry", kind: "fact", label: "Entrypoint", value: input.mcpEntry || "server.ts", mono: true },
      {
        id: "mcp_count",
        kind: "fact",
        label: "Exposed tools",
        value: `${input.mcpToolCount} ${input.mcpToolCount === 1 ? "tool" : "tools"}`,
        mono: true,
      },
    ];
    if (input.mcpTools.length > 0) {
      mcpItems.push({
        id: "mcp_tool_list",
        kind: "list",
        rows: input.mcpTools.slice(0, 8).map(
          (t): NavItem => ({
            id: t.name,
            title: t.name,
            subtitle: t.description,
          }),
        ),
      });
    }
    sections.push({ id: "mcp", title: "MCP Server", items: mcpItems });
  }

  const sqliteItems: InspectorItem[] = [
    { id: "sqlite_status", kind: "fact", label: "Status", value: "Allowed", tone: "done" },
    { id: "sqlite_size", kind: "fact", label: "Size on disk", value: input.dbSizeLabel, mono: true },
    {
      id: "sqlite_objects",
      kind: "fact",
      label: "Schema",
      value: `${input.schemaCount} ${input.schemaCount === 1 ? "object" : "objects"}`,
      mono: true,
    },
  ];
  if (input.schemaObjects.length > 0) {
    sqliteItems.push({
      id: "sqlite_schema_list",
      kind: "list",
      rows: input.schemaObjects.slice(0, 8).map(
        (obj): NavItem => ({
          id: `${obj.type}:${obj.name}`,
          title: obj.name,
          trailing: obj.type,
        }),
      ),
    });
  }
  sections.push({ id: "sqlite", title: "Embedded SQLite", items: sqliteItems });

  sections.push({
    id: "capabilities",
    title: "Bridge capabilities",
    items: input.capabilities.map(
      (cap): InspectorItem => ({
        id: `cap:${cap.key}`,
        kind: "segmented",
        label: cap.label,
        value: cap.mode,
        detail:
          cap.requested && cap.requested !== cap.mode
            ? `${cap.hint} (manifest requests ${cap.requested === "requires_approval" ? "ask" : cap.requested})`
            : cap.hint,
        options: MODE_OPTIONS,
        ...(input.updating ? { disabled: true } : {}),
      }),
    ),
  });

  sections.push({
    id: "sql_scope",
    title: "Persona SQL tool scope",
    items: [
      {
        id: "tool_scope",
        kind: "segmented",
        label: "Database access",
        value: input.toolScope,
        detail: "Whether any chat can query this app’s SQLite DB or only chats opened in this app.",
        options: SCOPE_OPTIONS,
        ...(input.updating ? { disabled: true } : {}),
      },
    ],
  });

  sections.push({
    id: "versions",
    title: "Version history",
    aside: String(input.versions.length),
    items: input.versions.length
      ? [
          {
            id: "version_list",
            kind: "list",
            actionId: "restore_version",
            rows: input.versions.map(
              (v): NavItem => ({
                id: String(v.seq),
                title: `v${v.seq} · ${v.authorLabel}`,
                subtitle: v.note ? `${v.age} · ${v.note}` : v.age,
                trailing: v.current ? "Current" : "Restore",
                status: v.current ? "done" : "neutral",
                disabled: v.current || !!input.updating,
              }),
            ),
          },
        ]
      : [],
  });

  return sections;
}
