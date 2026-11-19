import type { InspectorItem, InspectorOption, InspectorSection, NavItem } from "../protocol.ts";

export interface CustomAppCapabilityInput {
  key: string;
  label: string;
  hint: string;
  mode: "allowed" | "requires_approval" | "denied";
  requested?: "allowed" | "requires_approval" | "denied";
}

export interface CustomAppConnectorRow {
  slug: string;
  name: string;
  toolCount: number;
  status: string;
}

export interface CustomAppSecretRow {
  handle: string;
  name: string;
  allowedHosts: readonly string[];
}

export interface BuildCustomAppCapabilitiesInput {
  connectors: readonly CustomAppConnectorRow[];
  secrets: readonly CustomAppSecretRow[];
  requestedCapabilities?: Readonly<Record<string, CustomAppCapabilityInput["mode"]>>;
  grantedCapabilities?: Readonly<Record<string, CustomAppCapabilityInput["mode"]>>;
}

/** Collects built-in, connector, secret, and manifest-requested capabilities for the Custom App Permissions inspector. */
export function buildCustomAppCapabilities(input: BuildCustomAppCapabilitiesInput): CustomAppCapabilityInput[] {
  const connectorRows = input.connectors.map((c) => ({
    key: `mcp:${c.slug}:*`,
    label: `MCP · ${c.name}`,
    hint: `${c.toolCount} tool${c.toolCount === 1 ? "" : "s"} · ${c.status.replaceAll("_", " ")}`,
  }));

  const secretRows = input.secrets.map((s) => ({
    key: `secret:${s.handle}`,
    label: `Secret · ${s.name}`,
    hint:
      s.allowedHosts.length > 0
        ? `${s.handle} · ${s.allowedHosts.join(", ")}`
        : `${s.handle} · authenticated secretFetch calls`,
  }));

  const knownKeys = new Set<string>(["vesper.api:read", "vesper.api:write", "app.http:outbound"]);
  for (const c of connectorRows) knownKeys.add(c.key);
  for (const s of secretRows) knownKeys.add(s.key);
  for (const k of Object.keys(input.requestedCapabilities ?? {})) {
    if (!k.startsWith("app.sql:")) knownKeys.add(k);
  }
  for (const k of Object.keys(input.grantedCapabilities ?? {})) {
    if (!k.startsWith("app.sql:")) knownKeys.add(k);
  }

  const connectorMap = new Map(connectorRows.map((c) => [c.key, c]));
  const secretMap = new Map(secretRows.map((s) => [s.key, s]));

  return [...knownKeys].map((capKey) => {
    const cInfo = connectorMap.get(capKey);
    const sInfo = secretMap.get(capKey);
    const label =
      capKey === "vesper.api:read"
        ? "Vesper API · Read"
        : capKey === "vesper.api:write"
          ? "Vesper API · Write"
          : capKey === "app.http:outbound"
            ? "Outbound HTTPS"
            : sInfo?.label ??
              (capKey.startsWith("secret:")
                ? `Secret · ${capKey.slice("secret:".length)}`
                : cInfo?.label ?? capKey);
    const hint =
      capKey === "vesper.api:read"
        ? "GET requests to Vesper REST APIs"
        : capKey === "vesper.api:write"
          ? "POST, PATCH, PUT, DELETE requests to Vesper APIs"
          : capKey === "app.http:outbound"
            ? "Public HTTPS fetches from the app's MCP server and remote image proxy"
            : sInfo?.hint ??
              (capKey.startsWith("secret:")
                ? "Authenticated secretFetch calls using this Vesper secret"
                : cInfo?.hint ?? "Requested by app manifest");
    const mode: CustomAppCapabilityInput["mode"] = input.grantedCapabilities?.[capKey] ?? "denied";
    const requested = input.requestedCapabilities?.[capKey];
    return { key: capKey, label, hint, mode, requested };
  });
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
