// Pure builder for the Docs Review native inspector tab.
// Kept React- and DOM-free so `node --experimental-strip-types --test` covers it directly.

import type { Decision, Segment } from "../../doc-review.ts";
import type { InspectorAction, InspectorItem, InspectorSection } from "../protocol.ts";

type Change = Extract<Segment, { kind: "change" }>;

const plain = (md: string) =>
  md
    .replace(/^#{1,6}\s+|^\s*(?:[-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?|^>\s?|[*_`~]|\[([^\]]*)\]\([^)]*\)/gm, "$1")
    .replace(/\s+/g, " ")
    .trim();

const clip = (s: string, n = 60) => (s.length > n ? `${s.slice(0, n)}…` : s);

function sectionOf(segments: Segment[], at: number): string | undefined {
  const own = segments[at] as Change;
  const first = [...own.after, ...own.before].find((b) => /^#{1,6}\s/.test(b));
  if (first) return plain(first);
  for (let i = at - 1; i >= 0; i -= 1) {
    const s = segments[i];
    const blocks = s.kind === "same" ? s.blocks : s.after;
    const h = blocks.findLast((b) => /^#{1,6}\s/.test(b));
    if (h) return plain(h);
  }
  return undefined;
}

export interface DocReviewInspectorInput {
  persona: string;
  segments: Segment[];
  changes: Change[];
  decisions: Record<number, Decision>;
  left: number;
  busy: boolean;
  error?: string;
}

export function buildDocReviewInspector({
  persona,
  segments,
  changes,
  decisions,
  left,
  busy,
  error,
}: DocReviewInspectorInput): { sections: InspectorSection[]; headerActions: InspectorAction[] } {
  const total = changes.length;
  const summaryItems: InspectorItem[] = [
    {
      id: "review-status",
      kind: "fact",
      label: `${persona} suggested ${total === 1 ? "a change" : `${total} changes`}`,
      value: left === total ? "Decide each" : `${left} left`,
    },
    ...(total > 0
      ? [
          {
            id: "review-progress",
            kind: "progress" as const,
            label: "Decided",
            value: `${total - left} of ${total}`,
            fraction: (total - left) / total,
          },
        ]
      : []),
    ...(error
      ? [
          {
            id: "review-error",
            kind: "note" as const,
            detail: error,
            tone: "danger" as const,
          },
        ]
      : []),
    {
      id: "review-bulk",
      kind: "actions",
      actions: [
        { id: "reject_all", label: "Reject all", disabled: busy },
        { id: "accept_all", label: "Accept all", accent: true, disabled: busy },
      ],
    },
  ];

  const changeSections: InspectorSection[] = [];
  segments.forEach((s, i) => {
    if (s.kind !== "change") return;
    const sec = sectionOf(segments, i);
    const d = decisions[s.id];
    const snippet = s.after.length
      ? `“${clip(plain(s.after.join(" ")))}”`
      : `Removes “${clip(plain(s.before.join(" ")))}”`;

    const actions: InspectorAction[] = d
      ? [
          { id: `jump:${s.id}`, label: "Jump", icon: "link" },
          { id: `undo:${s.id}`, label: `${d === "accept" ? "Accepted" : "Rejected"} · Undo`, disabled: busy },
        ]
      : [
          { id: `jump:${s.id}`, label: "Jump", icon: "link" },
          { id: `reject:${s.id}`, label: "Reject", disabled: busy },
          { id: `accept:${s.id}`, label: "Accept", accent: true, disabled: busy },
        ];

    changeSections.push({
      id: `change-${s.id}`,
      title: `Change ${s.id + 1}${sec ? ` · ${sec}` : ""}`,
      ...(d
        ? {
            badge: {
              text: d === "accept" ? "Accepted" : "Rejected",
              tone: d === "accept" ? "done" : "danger",
            },
          }
        : {}),
      items: [
        {
          id: `change-body-${s.id}`,
          kind: "note",
          detail: snippet,
        },
        {
          id: `change-actions-${s.id}`,
          kind: "actions",
          actions,
        },
      ],
    });
  });

  return {
    sections: [{ id: "summary", title: "Review", items: summaryItems }, ...changeSections],
    headerActions: [
      { id: "accept_all", label: "Accept all", icon: "check", accent: true, disabled: busy },
    ],
  };
}
