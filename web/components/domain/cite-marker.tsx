"use client";

import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import { HoverCard } from "radix-ui";
import { Icon } from "@/components/ui/icon";
import { VideoPlayers } from "./recommend-fence";
import { youtubeMoment } from "@/lib/chat-recommend";

export type CiteMeta = {
  title: string;
  url?: string;
  ref?: string;
  host?: string;
  kind?: "web" | "wiki" | "ticket" | "epic" | "artifact";
  description?: string;
  imageUrl?: string;
};

/** The reply's citations: what each number is, rich hover metadata, and how to bring its source into view. */
export const CiteContext = createContext<{
  titles: Map<number, string>;
  items?: Map<number, CiteMeta>;
  focus: (n: number) => void;
} | undefined>(undefined);

const KIND_LABEL: Record<NonNullable<CiteMeta["kind"]>, string> = {
  web: "Web",
  wiki: "Knowledge",
  ticket: "Ticket",
  epic: "Epic",
  artifact: "Artifact",
};

export function CiteMarker({ n }: { n: number }) {
  const cites = useContext(CiteContext);
  const meta = cites?.items?.get(n);
  const title = meta?.title ?? cites?.titles.get(n);
  const [imgBroken, setImgBroken] = useState(false);

  const button = (
    <button
      type="button"
      data-testid="cite"
      aria-label={`Source ${n}${title ? `: ${title}` : ""}`}
      title={meta ? undefined : title}
      onClick={() => cites?.focus(n)}
      className="mx-px inline-grid h-4 min-w-4 -translate-y-0.5 place-items-center rounded bg-accent-soft px-1 align-baseline font-mono text-11 font-semibold text-accent hover:underline"
    >
      {n}
    </button>
  );

  if (!meta) return button;

  return (
    <HoverCard.Root openDelay={180} closeDelay={120}>
      <HoverCard.Trigger asChild>{button}</HoverCard.Trigger>
      <HoverCard.Portal>
        <HoverCard.Content
          side="top"
          align="center"
          sideOffset={6}
          data-testid="cite-hover-card"
          className="motion-float z-50 w-72 overflow-hidden rounded-xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          {meta.imageUrl && !imgBroken && (
            <div className="aspect-[16/9] w-full overflow-hidden bg-surface-sunken">
              <img
                src={meta.imageUrl}
                alt=""
                onError={() => setImgBroken(true)}
                className="size-full object-cover"
              />
            </div>
          )}
          <div className="flex flex-col gap-1.5 p-3">
            <div className="flex items-center gap-1.5 text-11 text-fg-tertiary">
              <span className="rounded bg-accent-soft px-1 font-mono font-semibold text-accent">{n}</span>
              {meta.kind && <span className="font-medium uppercase tracking-wide">{KIND_LABEL[meta.kind]}</span>}
              {meta.host && (
                <>
                  <span aria-hidden>·</span>
                  <span className="truncate">{meta.host}</span>
                </>
              )}
            </div>
            <p className="line-clamp-2 text-13 font-semibold leading-snug text-fg">{meta.title}</p>
            {meta.description && (
              <p className="line-clamp-3 text-12 leading-relaxed text-fg-secondary">{meta.description}</p>
            )}
            <div className="mt-1 flex items-center justify-between gap-2 border-t border-border-subtle pt-2">
              <button
                type="button"
                onClick={() => cites?.focus(n)}
                className="text-11 font-medium text-fg-secondary hover:text-fg"
              >
                Jump to Sources
              </button>
              {meta.url && (
                <a
                  href={meta.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-11 font-medium text-accent hover:underline"
                >
                  Open
                  <Icon name="link" size={11} />
                </a>
              )}
            </div>
          </div>
        </HoverCard.Content>
      </HoverCard.Portal>
    </HoverCard.Root>
  );
}

/** A link to a moment in a video: jumps the chat's player there, or opens YouTube when there is none. */
export function MomentLink({ href, children }: { href: string; children: ReactNode }) {
  const players = useContext(VideoPlayers);
  const moment = useMemo(() => youtubeMoment(href), [href]);
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer noopener"
      data-testid="moment"
      onClick={(e) => {
        const seek = moment && players?.get(moment.id);
        if (seek) {
          e.preventDefault();
          seek(moment.seconds);
        }
      }}
    >
      {children}
    </a>
  );
}
