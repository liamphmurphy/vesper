"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { createContext, useContext, type ReactNode } from "react";
import type { LinkTarget } from "@/lib/api/client";
import { useCreateWikiPage } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { parseWikiLinks, wikiHref } from "@/lib/wikilinks";
import { Icon } from "@/components/ui/icon";
import { usePrintMode } from "./print-mode";
import { agentHue } from "./avatars";
import { StatusGlyph, type GlyphState } from "./glyphs";

/** Resolved targets for the [[links]] in the markdown being rendered. */
export const LinkTargets = createContext<Map<string, LinkTarget> | undefined>(undefined);

const DOC_COLOR: Record<string, string> = {
  note: "text-doc-note",
  prd: "text-doc-prd",
  spec: "text-doc-spec",
  adr: "text-doc-adr",
  report: "text-doc-report",
  design: "text-doc-design",
};

/** Small leading mark that says what kind of thing a link points at. */
export function TargetMark({ t, size = 12 }: { t: LinkTarget; size?: number }) {
  switch (t.kind) {
    case "ticket":
      return <StatusGlyph state={(t.status ?? "todo") as GlyphState} size={size - 1} label={false} />;
    case "agent":
      return (
        <span
          aria-hidden
          className="grid flex-none place-items-center font-semibold"
          style={{
            width: size, height: size, borderRadius: 3, fontSize: size * 0.62,
            color: `var(--agent-${agentHue(t.color_index ?? 0)})`, background: `var(--agent-${agentHue(t.color_index ?? 0)}-bg)`,
          }}
        >
          {t.title.slice(0, 1).toUpperCase()}
        </span>
      );
    case "epic":
      return <Icon name="epics" size={size} className="text-fg-tertiary" />;
    case "comment":
      return <Icon name="msg" size={size} className="text-fg-tertiary" />;
    default:
      return <Icon name="artifacts" size={size} className={DOC_COLOR[t.artifact_type ?? "note"] ?? "text-fg-tertiary"} />;
  }
}

function kindLabel(t: LinkTarget) {
  if (t.kind === "artifact" || t.kind === "section") return t.artifact_type === "note" ? "Page" : (t.artifact_type ?? "").toUpperCase();
  return t.kind === "ticket" ? "Ticket" : t.kind === "agent" ? "Agent" : t.kind === "epic" ? "Epic" : "";
}

/** A ghost link: the page doesn't exist yet. Clicking creates it. */
function GhostLink({ target, children }: { target: string; children: ReactNode }) {
  const router = useRouter();
  const create = useCreateWikiPage();
  return (
    <button
      type="button"
      title={`“${target}” doesn't exist yet. Click to create it.`}
      disabled={create.isPending}
      onClick={() =>
        create.mutate(
          { path: target, body_md: "" },
          { onSuccess: (a) => router.push(`${wikiHref(a.path ?? target)}?edit=1`) },
        )
      }
      className="cursor-pointer rounded-xs text-fg-tertiary underline decoration-dashed decoration-1 underline-offset-[3px] hover:text-fg-secondary"
    >
      {children}
    </button>
  );
}

/** Renders one [[link]] with its type mark; unresolved links are ghosts. */
export function WikiLink({ refText, children }: { refText: string; children: ReactNode }) {
  const print = usePrintMode();
  const targets = useContext(LinkTargets);
  if (print) {
    return <span className="print-wikilink">{children}</span>;
  }
  const t = targets?.get(refText);
  if (!t) {
    // Still resolving (or rendered outside Markdown): plain text, no jump.
    return <span className="text-accent">{children}</span>;
  }
  if (t.kind === "unresolved" || !t.href) {
    const target = parseWikiLinks(`[[${refText}]]`)[0]?.target ?? refText;
    return <GhostLink target={target}>{children}</GhostLink>;
  }
  return (
    <Link
      href={t.href}
      title={[kindLabel(t), t.display_id, t.title].filter(Boolean).join(" · ")}
      className={cx("!no-underline hover:!underline", "text-accent")}
    >
      <span className="mr-1 inline-block align-[-1px] [&>*]:inline-grid">
        <TargetMark t={t} size={12} />
      </span>
      {children}
    </Link>
  );
}
