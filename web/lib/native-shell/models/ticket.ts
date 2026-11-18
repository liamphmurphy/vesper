// The ticket page's left column: the Work header and the sibling tickets (tickets/[key]/ticket-screen.tsx).
import type { NavModel, Tone } from "../protocol.ts";
import { workModel } from "./work.ts";

const STATUS_TONE: Record<string, Tone> = { todo: "neutral", in_progress: "accent", in_review: "warning", done: "done" };

export function buildTicketNavModel(input: {
  project?: string;
  siblings: readonly { key: string; title: string; status: string }[];
  statusNames: Record<string, string>;
  ticketKey: string;
}): NavModel {
  return workModel(
    "ticket",
    { active: "tickets", project: input.project, agent: "", noFilters: true },
    [
      {
        id: "tickets",
        items: input.siblings.map((s) => ({
          id: s.key,
          title: s.title,
          subtitle: `${s.key} · ${input.statusNames[s.status] ?? s.status}`,
          href: `/tickets/${encodeURIComponent(s.key)}`,
          ...(STATUS_TONE[s.status] ? { status: STATUS_TONE[s.status] } : {}),
        })),
      },
    ],
    input.ticketKey,
  );
}
