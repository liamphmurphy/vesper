// Pure builders and edit helpers for the Designs app native inspector tabs (Review + Design/Prototype/Inspect).
// Kept React- and DOM-free so `node --experimental-strip-types --test` covers it directly.

import { find, inAutoLayout, labelOf, mapNodes, resizeIn } from "../../designs/edit.ts";
import { inspect, INSPECT_TARGETS, type InspectTarget } from "../../designs/inspect.ts";
import type { Layout } from "../../designs/layout.ts";
import { linksFrom, screens, setLink, TRANSITIONS, TRIGGERS, type Transition, type Trigger } from "../../designs/prototype.ts";
import type { Change, Decisions } from "../../designs/review.ts";
import type { Design, DesignNode, Page, Paragraph } from "../../designs/schema.ts";
import { tokensChanged } from "../../designs/tokens.ts";
import type { InspectorAction, InspectorItem, InspectorSection, NavItem } from "../protocol.ts";

const TYPE_LABEL: Record<string, string> = {
  frame: "Frame",
  component: "Component",
  instance: "Instance",
  group: "Group",
  section: "Section",
  shape: "Shape",
  path: "Vector",
  text: "Text",
  image: "Image",
  sticky: "Sticky",
  connector: "Connector",
};

const VALID_COLOR_RE = /^(#[0-9A-F]{6}([0-9A-F]{2})?|\$[a-z0-9][a-z0-9-]{0,63})$/;
const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/;

function paragraphsToText(paragraphs: readonly Paragraph[]): string {
  return paragraphs.map((p) => p.runs.map((r) => r.text).join("")).join("\n");
}

function normalizeColorInput(raw: string): string | null | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  if (HEX_COLOR_RE.test(trimmed)) return trimmed.toUpperCase();
  if (VALID_COLOR_RE.test(trimmed)) return trimmed;
  return null;
}

export interface DesignReviewInspectorInput {
  persona: string;
  proposalCount: number;
  reviewing: boolean;
  changes?: readonly Change[];
  decisions?: Decisions;
  left?: number;
  busy: boolean;
  error?: string;
}

export function buildDesignReviewInspector({
  persona,
  proposalCount,
  reviewing,
  changes = [],
  decisions = {},
  left = 0,
  busy,
  error,
}: DesignReviewInspectorInput): { sections: InspectorSection[]; headerActions: InspectorAction[] } {
  if (!reviewing) {
    const suggestions = `${proposalCount} ${proposalCount === 1 ? "suggestion" : "suggestions"}`;
    return {
      headerActions: [{ id: "start_review", label: "Start review", icon: "check", accent: true }],
      sections: [
        {
          id: "pre-review",
          title: "Pending review",
          items: [
            {
              id: "pre-review-note",
              kind: "note",
              detail: `${persona} suggested ${suggestions}. Nothing changes until you accept.`,
            },
            {
              id: "pre-review-start",
              kind: "actions",
              actions: [{ id: "start_review", label: "Start review", accent: true }],
            },
          ],
        },
      ],
    };
  }

  const total = changes.length;
  const decidedCount = Math.max(0, total - left);
  const summaryItems: InspectorItem[] = [
    {
      id: "design-review-status",
      kind: "fact",
      label: `Suggestions from ${persona}`,
      value: left > 0 ? `${left} left` : "Ready to apply",
    },
    ...(total > 0
      ? [
          {
            id: "design-review-progress",
            kind: "progress" as const,
            label: "Decided",
            value: `${decidedCount} of ${total}`,
            fraction: decidedCount / total,
          },
        ]
      : []),
    ...(error
      ? [
          {
            id: "design-review-error",
            kind: "note" as const,
            detail: error,
            tone: "danger" as const,
          },
        ]
      : []),
    {
      id: "design-review-bulk",
      kind: "actions",
      actions:
        left > 0
          ? [
              { id: "reject_all", label: "Reject all", disabled: busy },
              { id: "accept_all", label: "Accept all", accent: true, disabled: busy },
            ]
          : [{ id: "done", label: busy ? "Applying…" : "Done", accent: true, disabled: busy }],
    },
  ];

  const changeSections: InspectorSection[] = changes.map((c) => {
    const d = decisions[c.i];
    const items: InspectorItem[] = [];
    if (c.why) {
      items.push({ id: `change-why-${c.i}`, kind: "note", detail: c.why });
    }
    if (c.needs.length > 0) {
      items.push({
        id: `change-deps-${c.i}`,
        kind: "fact",
        label: "Depends on",
        value: c.needs.map((n) => `Change ${n + 1}`).join(", "),
      });
    }
    items.push({
      id: `change-actions-${c.i}`,
      kind: "actions",
      actions: [
        { id: `focus:${c.i}`, label: "Show", icon: "search" },
        ...(d?.state === "rejected"
          ? [{ id: `accept:${c.i}`, label: "Accept instead", disabled: busy }]
          : d?.state === "accepted"
            ? [{ id: `reject:${c.i}`, label: "Reject instead", disabled: busy }]
            : [
                { id: `reject:${c.i}`, label: "Reject", disabled: busy },
                { id: `accept:${c.i}`, label: "Accept", accent: true, disabled: busy },
              ]),
      ],
    });
    return {
      id: `design-change-${c.i}`,
      title: `${c.i + 1}. ${c.title}`,
      ...(d
        ? {
            badge: {
              text: d.state === "accepted" ? "Accepted" : "Rejected",
              tone: d.state === "accepted" ? "done" : "danger",
            },
          }
        : {}),
      items,
    };
  });

  return {
    headerActions: [
      left > 0
        ? { id: "accept_all", label: "Accept all", icon: "check", accent: true, disabled: busy }
        : { id: "done", label: "Done", icon: "check", accent: true, disabled: busy },
    ],
    sections: [{ id: "review-summary", title: "Review", items: summaryItems }, ...changeSections],
  };
}

export interface DesignInspectorInput {
  design: Design;
  page?: Page;
  selected: readonly string[];
  lay: Layout;
  tab: "Design" | "Prototype" | "Inspect";
  inspectTarget: InspectTarget;
  readOnly: boolean;
}

export function buildDesignInspector({
  design,
  page,
  selected,
  lay,
  tab,
  inspectTarget,
  readOnly,
}: DesignInspectorInput): { sections: InspectorSection[]; headerActions: InspectorAction[] } {
  const modeSection: InspectorSection = {
    id: "mode",
    items: [
      {
        id: "mode",
        kind: "segmented",
        value: tab,
        options: [
          { value: "Design", label: "Design" },
          { value: "Prototype", label: "Prototype" },
          { value: "Inspect", label: "Inspect" },
        ],
      },
    ],
  };

  const found = selected.map((id) => find(design, id)).filter((f): f is NonNullable<typeof f> => !!f);
  const allScreens = screens(design);

  if (tab === "Prototype") {
    const screenOptions = allScreens.map((s) => ({ value: s.id, label: `${s.name} · ${s.pageName}` }));
    const overviewSection: InspectorSection = {
      id: "proto-overview",
      title: "Prototype",
      items: [
        { id: "proto-screens", kind: "fact", label: "Screens", value: String(allScreens.length) },
        { id: "proto-links", kind: "fact", label: "Links", value: String(design.links.length) },
        {
          id: "proto-actions",
          kind: "actions",
          actions: [
            { id: "present", label: "Present", icon: "play", accent: true },
            ...(found.length === 1 && !readOnly && allScreens.length > 0
              ? [{ id: "proto:add_link", label: "Add interaction", icon: "plus" }]
              : []),
          ],
        },
      ],
    };

    if (found.length === 1) {
      const targetNode = found[0].node;
      const nodeLinks = linksFrom(design, targetNode.id);
      if (nodeLinks.length === 0) {
        return {
          headerActions: [{ id: "present", label: "Present", icon: "play" }],
          sections: [
            modeSection,
            overviewSection,
            {
              id: "proto-node-empty",
              title: labelOf(targetNode),
              emptyText: "No interactions on this layer yet.",
              items: [],
            },
          ],
        };
      }
      const linkSections: InspectorSection[] = nodeLinks.map((lnk, idx) => ({
        id: `proto-link-${lnk.id}`,
        title: `Interaction ${idx + 1}`,
        items: [
          ...(screenOptions.length > 0
            ? [
                {
                  id: `proto:to:${lnk.id}`,
                  kind: "picker" as const,
                  label: "Destination",
                  value: lnk.to,
                  options: screenOptions,
                  disabled: readOnly,
                },
              ]
            : []),
          {
            id: `proto:trigger:${lnk.id}`,
            kind: "picker",
            label: "Trigger",
            value: lnk.trigger,
            options: TRIGGERS.map((t) => ({ value: t.id, label: t.label })),
            disabled: readOnly,
          },
          {
            id: `proto:transition:${lnk.id}`,
            kind: "picker",
            label: "Transition",
            value: lnk.transition,
            options: TRANSITIONS.map((t) => ({ value: t.id, label: t.label })),
            disabled: readOnly,
          },
          {
            id: `proto:remove-wrap:${lnk.id}`,
            kind: "actions",
            actions: [{ id: `proto:remove:${lnk.id}`, label: "Remove link", destructive: true, disabled: readOnly }],
          },
        ],
      }));
      return {
        headerActions: [{ id: "present", label: "Present", icon: "play" }],
        sections: [modeSection, overviewSection, ...linkSections],
      };
    }

    const screenMap = new Map(allScreens.map((s) => [s.id, s.name]));
    const rows: NavItem[] = design.links.map((lnk) => {
      const src = find(design, lnk.from)?.node;
      return {
        id: lnk.from,
        title: `${src ? labelOf(src) : lnk.from} → ${screenMap.get(lnk.to) ?? lnk.to}`,
        subtitle: `${lnk.trigger} · ${lnk.transition}`,
      };
    });
    return {
      headerActions: [{ id: "present", label: "Present", icon: "play" }],
      sections: [
        modeSection,
        overviewSection,
        {
          id: "proto-all-links",
          title: "All links",
          emptyText: "Select a layer to wire a Prototype interaction.",
          items: rows.length ? [{ id: "proto-link-list", kind: "list", actionId: "select_node", rows }] : [],
        },
      ],
    };
  }

  if (tab === "Inspect") {
    const langSection: InspectorSection = {
      id: "inspect-lang",
      items: [
        {
          id: "inspect:target",
          kind: "segmented",
          value: inspectTarget,
          options: INSPECT_TARGETS.map((t) => ({
            value: t,
            label: t === "css" ? "CSS" : t === "tailwind" ? "Tailwind" : "React",
          })),
        },
      ],
    };

    if (found.length !== 1) {
      return {
        headerActions: [{ id: "present", label: "Present", icon: "play" }],
        sections: [
          modeSection,
          langSection,
          {
            id: "inspect-empty",
            title: "Code",
            emptyText: "Select a single layer to inspect its layout and code.",
            items: [],
          },
        ],
      };
    }

    try {
      const res = inspect(design, found[0].node.id, inspectTarget);
      const specItems: InspectorItem[] = [
        {
          id: "inspect-box",
          kind: "fact",
          label: "Box",
          value: `${Math.round(res.box.w)} × ${Math.round(res.box.h)} at (${Math.round(res.box.x)}, ${Math.round(res.box.y)})`,
          mono: true,
        },
      ];
      if (res.spacing) {
        specItems.push({
          id: "inspect-spacing",
          kind: "fact",
          label: "Auto layout",
          value: `${res.spacing.direction} · gap ${res.spacing.gap}px`,
          mono: true,
        });
      }
      const sections: InspectorSection[] = [
        modeSection,
        langSection,
        { id: "inspect-layout", title: res.node.name, items: specItems },
      ];
      if (res.tokens.length > 0) {
        sections.push({
          id: "inspect-tokens",
          title: "Tokens",
          items: [
            {
              id: "inspect-token-chips",
              kind: "chips",
              chips: res.tokens.map((t) => ({
                id: t.name,
                text: t.value ? `$${t.name} (${t.value})` : `$${t.name}`,
              })),
            },
          ],
        });
      }
      sections.push({
        id: "inspect-code",
        title: "Snippet",
        items: [{ id: "inspect-snippet", kind: "note", detail: res.code, mono: true }],
      });
      return {
        headerActions: [{ id: "present", label: "Present", icon: "play" }],
        sections,
      };
    } catch (err) {
      return {
        headerActions: [{ id: "present", label: "Present", icon: "play" }],
        sections: [
          modeSection,
          langSection,
          {
            id: "inspect-error",
            title: "Inspect",
            items: [
              {
                id: "inspect-err-note",
                kind: "note",
                detail: err instanceof Error ? err.message : "Couldn’t inspect this layer.",
                tone: "warning",
              },
            ],
          },
        ],
      };
    }
  }

  // Default: "Design" mode
  if (found.length === 0) {
    return {
      headerActions: [{ id: "present", label: "Present", icon: "play" }],
      sections: [
        modeSection,
        {
          id: "canvas-summary",
          title: page?.name ?? "Canvas",
          items: [
            { id: "page-layers", kind: "fact", label: "Top-level layers", value: String(page?.children.length ?? 0) },
            { id: "design-mode", kind: "fact", label: "Mode", value: design.mode === "light" ? "Light" : "Dark" },
            {
              id: "design-tokens",
              kind: "fact",
              label: "Tokens",
              value: tokensChanged(design) ? "Out of sync" : "In sync",
            },
            {
              id: "design-hint",
              kind: "note",
              detail: "Select a layer to edit its dimensions, style, or text.",
            },
            {
              id: "canvas-actions",
              kind: "actions",
              actions: [{ id: "present", label: "Present", icon: "play", accent: true }],
            },
          ],
        },
      ],
    };
  }

  if (found.length > 1) {
    return {
      headerActions: [{ id: "present", label: "Present", icon: "play" }],
      sections: [
        modeSection,
        {
          id: "multi-selection",
          title: "Selection",
          items: [
            { id: "multi-count", kind: "fact", label: "Selected layers", value: String(found.length) },
            {
              id: "multi-actions",
              kind: "actions",
              actions: [
                { id: "group", label: "Group", disabled: readOnly },
                { id: "delete", label: "Delete", icon: "trash", destructive: true, disabled: readOnly },
              ],
            },
          ],
        },
      ],
    };
  }

  const { node: n, parent } = found[0];
  if (n.type === "connector") {
    return {
      headerActions: [{ id: "present", label: "Present", icon: "play" }],
      sections: [
        modeSection,
        {
          id: "connector-info",
          title: TYPE_LABEL[n.type],
          items: [
            {
              id: "node:name",
              kind: "text",
              label: "Name",
              value: n.name ?? "",
              placeholder: labelOf(n),
              disabled: readOnly,
            },
            {
              id: "connector-note",
              kind: "note",
              detail: "Connectors are edited directly with diagram tools on the canvas.",
            },
            {
              id: "connector-actions",
              kind: "actions",
              actions: [{ id: "delete", label: "Delete", icon: "trash", destructive: true, disabled: readOnly }],
            },
          ],
        },
      ],
    };
  }

  const boxW = lay.widthOf(n);
  const boxH = lay.heightOf(n, boxW);
  const autoLaid = inAutoLayout(parent);
  const sizingW = n.sizing?.w ?? "fixed";
  const sizingH = n.sizing?.h ?? "fixed";

  const identitySection: InspectorSection = {
    id: "node-identity",
    title: TYPE_LABEL[n.type] ?? n.type,
    items: [
      {
        id: "node:name",
        kind: "text",
        label: "Name",
        value: n.name ?? "",
        placeholder: labelOf(n),
        disabled: readOnly,
      },
    ],
  };

  const geometrySection: InspectorSection = {
    id: "node-geometry",
    title: "Position & Size",
    items: [
      { id: "node:x", kind: "text", label: "X", value: String(Math.round(n.x * 100) / 100), inputType: "number", mono: true, disabled: readOnly || autoLaid },
      { id: "node:y", kind: "text", label: "Y", value: String(Math.round(n.y * 100) / 100), inputType: "number", mono: true, disabled: readOnly || autoLaid },
      { id: "node:w", kind: "text", label: "Width", value: String(Math.round(boxW * 100) / 100), inputType: "number", mono: true, disabled: readOnly || sizingW !== "fixed" },
      { id: "node:h", kind: "text", label: "Height", value: String(Math.round(boxH * 100) / 100), inputType: "number", mono: true, disabled: readOnly || sizingH !== "fixed" },
      { id: "node:rotation", kind: "text", label: "Rotation (°)", value: String(n.rotation ?? 0), inputType: "number", mono: true, disabled: readOnly },
      { id: "node:opacity", kind: "text", label: "Opacity (%)", value: String(Math.round((n.opacity ?? 1) * 100)), inputType: "number", mono: true, disabled: readOnly },
    ],
  };

  const appearanceItems: InspectorItem[] = [];
  if ("fill" in n) {
    if (typeof n.fill === "object") {
      appearanceItems.push({ id: "node-fill-gradient", kind: "fact", label: "Fill", value: "Gradient" });
    } else {
      appearanceItems.push({
        id: "node:fill",
        kind: "text",
        label: "Fill",
        value: n.fill ?? "",
        placeholder: "#HEX or $token",
        mono: true,
        disabled: readOnly,
      });
    }
  }
  if ("stroke" in n) {
    appearanceItems.push({
      id: "node:stroke",
      kind: "text",
      label: "Stroke",
      value: n.stroke ?? "",
      placeholder: "#HEX or $token",
      mono: true,
      disabled: readOnly,
    });
    appearanceItems.push({
      id: "node:stroke_width",
      kind: "text",
      label: "Stroke width",
      value: String(n.stroke_width ?? (n.stroke ? 1 : 0)),
      inputType: "number",
      mono: true,
      disabled: readOnly || !n.stroke,
    });
  }
  if (
    n.type === "frame" ||
    n.type === "component" ||
    n.type === "image" ||
    (n.type === "shape" && n.shape !== "ellipse")
  ) {
    const rVal = n.radius ?? (n.type === "shape" && n.shape === "roundRect" ? 8 : 0);
    appearanceItems.push({
      id: "node:radius",
      kind: "text",
      label: "Corner radius",
      value: String(rVal),
      inputType: "number",
      mono: true,
      disabled: readOnly,
    });
  }
  if (n.type === "text" || n.type === "sticky") {
    appearanceItems.push({
      id: "node:text",
      kind: "text",
      label: "Text",
      value: n.type === "sticky" ? n.text : paragraphsToText(n.paragraphs),
      multiline: true,
      disabled: readOnly,
    });
  }

  const sections: InspectorSection[] = [modeSection, identitySection, geometrySection];
  if (appearanceItems.length > 0) {
    sections.push({ id: "node-appearance", title: "Appearance", items: appearanceItems });
  }
  sections.push({
    id: "node-actions",
    title: "Actions",
    items: [
      {
        id: "node-action-buttons",
        kind: "actions",
        actions: [
          ...(n.type === "group" ? [{ id: "ungroup", label: "Ungroup", disabled: readOnly }] : []),
          { id: "delete", label: "Delete", icon: "trash", destructive: true, disabled: readOnly },
        ],
      },
    ],
  });

  return {
    headerActions: [{ id: "present", label: "Present", icon: "play" }],
    sections,
  };
}

function patchNodeField(node: DesignNode, fields: Record<string, unknown>): DesignNode {
  const out: Record<string, unknown> = { ...node };
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined) delete out[k];
    else out[k] = v;
  }
  return out as DesignNode;
}

/** Pure state update for any `onChange` coming from the Designs native inspector. */
export function applyDesignInspectorChange(
  design: Design,
  selected: readonly string[],
  fieldId: string,
  value: string,
): Design {
  if (fieldId.startsWith("proto:to:")) {
    const linkId = fieldId.slice("proto:to:".length);
    return setLink(design, linkId, { to: value });
  }
  if (fieldId.startsWith("proto:trigger:")) {
    const linkId = fieldId.slice("proto:trigger:".length);
    if (TRIGGERS.some((t) => t.id === value)) {
      return setLink(design, linkId, { trigger: value as Trigger });
    }
    return design;
  }
  if (fieldId.startsWith("proto:transition:")) {
    const linkId = fieldId.slice("proto:transition:".length);
    if (TRANSITIONS.some((t) => t.id === value)) {
      return setLink(design, linkId, { transition: value as Transition });
    }
    return design;
  }

  if (selected.length !== 1) return design;
  const id = selected[0];
  const found = find(design, id);
  if (!found) return design;

  if (fieldId === "node:name") {
    const nextName = value.trim().slice(0, 200) || undefined;
    return mapNodes(design, new Set([id]), (n) => patchNodeField(n, { name: nextName }));
  }

  if (found.node.type === "connector") return design;
  const autoLaid = inAutoLayout(found.parent);

  switch (fieldId) {
    case "node:x":
    case "node:y": {
      if (autoLaid) return design;
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      return mapNodes(design, new Set([id]), (n) =>
        fieldId === "node:x" ? patchNodeField(n, { x: v }) : patchNodeField(n, { y: v }),
      );
    }
    case "node:w":
    case "node:h": {
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      const clamped = Math.max(1, v);
      return resizeIn(design, id, (x) =>
        x.type === "connector"
          ? { x: 0, y: 0, w: 0, h: 0 }
          : fieldId === "node:w"
            ? { x: x.x, y: x.y, w: clamped, h: x.h }
            : { x: x.x, y: x.y, w: x.w, h: clamped },
      );
    }
    case "node:rotation": {
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      const clamped = Math.max(-360, Math.min(360, v));
      return mapNodes(design, new Set([id]), (n) => patchNodeField(n, { rotation: clamped || undefined }));
    }
    case "node:opacity": {
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      const clamped = Math.max(0, Math.min(100, v));
      return mapNodes(design, new Set([id]), (n) =>
        patchNodeField(n, { opacity: clamped >= 100 ? undefined : Math.round(clamped) / 100 }),
      );
    }
    case "node:fill": {
      if (!("fill" in found.node)) return design;
      const color = normalizeColorInput(value);
      if (color === null) return design;
      return mapNodes(design, new Set([id]), (n) => patchNodeField(n, { fill: color }));
    }
    case "node:stroke": {
      if (!("stroke" in found.node)) return design;
      const color = normalizeColorInput(value);
      if (color === null) return design;
      return mapNodes(design, new Set([id]), (n) =>
        patchNodeField(n, {
          stroke: color,
          stroke_width: color ? (("stroke_width" in n && n.stroke_width) || 1) : undefined,
        }),
      );
    }
    case "node:stroke_width": {
      if (!("stroke" in found.node) || !found.node.stroke) return design;
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      const clamped = Math.max(0, Math.min(1000, v));
      return mapNodes(design, new Set([id]), (n) => patchNodeField(n, { stroke_width: clamped }));
    }
    case "node:radius": {
      if (
        found.node.type !== "frame" &&
        found.node.type !== "component" &&
        found.node.type !== "image" &&
        !(found.node.type === "shape" && found.node.shape !== "ellipse")
      ) {
        return design;
      }
      const v = Number(value);
      if (!value.trim() || !Number.isFinite(v)) return design;
      const clamped = Math.max(0, v);
      return mapNodes(design, new Set([id]), (n) => patchNodeField(n, { radius: clamped || undefined }));
    }
    case "node:text": {
      return mapNodes(design, new Set([id]), (n) => {
        if (n.type === "sticky") return { ...n, text: value };
        if (n.type === "text") {
          const basePara = n.paragraphs[0];
          const baseRun = basePara?.runs[0];
          const lines = value.split("\n");
          const paragraphs: Paragraph[] = lines.map((line) => ({
            ...(basePara ?? {}),
            runs: [{ ...(baseRun ?? {}), text: line }],
          }));
          return { ...n, paragraphs };
        }
        return n;
      });
    }
    default:
      return design;
  }
}
