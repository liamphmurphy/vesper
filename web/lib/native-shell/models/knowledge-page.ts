// A Knowledge page's header row (knowledge/_components/page-screen.tsx) as native toolbar items:
// who can see it, how its persona edits, Copy link and the More menu. Pure; the handlers ride along
// as `run`. The folder path stays in the page, above the title.
import type { NativeAction } from "../actions.ts";
import type { Avatar } from "../protocol.ts";

export type PageAudience = "private" | "shared" | "agent";

/** The web's AUDIENCE labels and icons (knowledge/_components/kit.tsx), as the toolbar shows them. */
const AUDIENCE: Record<PageAudience, { label: string; icon: string }> = {
  private: { label: "Private", icon: "lock" },
  shared: { label: "Shared", icon: "users" },
  agent: { label: "Agent", icon: "agents" },
};

export const KP = {
  audience: "kn.audience",
  audienceOption: (a: PageAudience) => `audience:${a}`,
  mode: "kn.mode",
  copyLink: "kn.copy-link",
  more: "kn.more",
  exportMarkdown: "export-md",
  print: "print",
  history: "history",
} as const;

export interface KnowledgePageInput {
  audience: PageAudience;
  /** Only the person moves a page between Private and Shared; Agent pages are the agents'. */
  setAudience: (a: "private" | "shared") => void;
  /** "Ada suggests changes" and the persona's face; opens the page's history. */
  mode: { label: string; avatar?: Avatar; open: () => void };
  copyLink: () => void;
  exportMarkdown: () => void;
  print: () => void;
  history: () => void;
}

export function knowledgePageActions(i: KnowledgePageInput): NativeAction[] {
  const current = AUDIENCE[i.audience];
  return [
    {
      id: KP.audience,
      label: current.label,
      icon: current.icon,
      kind: "menu",
      showsLabel: true,
      menu: (Object.keys(AUDIENCE) as PageAudience[]).map((a) => ({
        id: KP.audienceOption(a),
        label: AUDIENCE[a].label,
        icon: AUDIENCE[a].icon,
        checked: a === i.audience,
        disabled: a === "agent",
        run: a === "agent" || a === i.audience ? undefined : () => i.setAudience(a),
      })),
    },
    { id: KP.mode, label: i.mode.label, kind: "button", showsLabel: true, run: i.mode.open, ...(i.mode.avatar ? { avatar: i.mode.avatar } : { icon: "agents" }) },
    { id: KP.copyLink, label: "Copy [[link]]", icon: "link", kind: "button", run: i.copyLink },
    {
      id: KP.more,
      label: "More",
      icon: "dots",
      kind: "menu",
      menu: [
        { id: KP.exportMarkdown, label: "Export Markdown", icon: "download", run: i.exportMarkdown },
        { id: KP.print, label: "Print or save as PDF", icon: "printer", run: i.print },
        { id: KP.history, label: "Version history", icon: "history", run: i.history },
      ],
    },
  ];
}
