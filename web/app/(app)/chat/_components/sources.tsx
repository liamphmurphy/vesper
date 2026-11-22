"use client";

import Link from "next/link";
import { useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useChatTurnEvents, useResolvedLinks } from "@/lib/api/hooks";
import { citationSources, type Source } from "@/lib/chat-context";
import { sourceSplit, usedWebSources, type ListedSource } from "@/lib/chat-sources";
import { webSearches, type WebSource } from "@/lib/web-search";
import { Icon } from "@/components/ui/icon";
import { Collapse } from "@/components/ui/motion";
import { cx } from "@/lib/cx";

const MAX_TILES = 4;

type Tile = { glyph: string; hue?: string };

function vesperTile(s: Source): Tile {
  if (s.target.kind === "ticket") return { glyph: "#", hue: "relay" };
  return s.wiki ? { glyph: "W", hue: "atlas" } : { glyph: s.target.kind === "epic" ? "E" : "A", hue: "nova" };
}
// A letter, not a favicon: fetching one would tell a third party what the reply cited.
const webTile = (s: WebSource): Tile => ({ glyph: s.host.slice(0, 1).toUpperCase() });

function SourceTile({ tile, size }: { tile: Tile; size: number }) {
  return (
    <span
      aria-hidden
      className={cx("grid flex-none place-items-center font-bold", !tile.hue && "bg-surface-sunken text-fg-secondary")}
      style={{
        width: size, height: size, borderRadius: size / 4, fontSize: size * 0.5,
        ...(tile.hue ? { color: `var(--agent-${tile.hue})`, background: `var(--agent-${tile.hue}-bg)` } : {}),
      }}
    >
      {tile.glyph}
    </span>
  );
}

/** An in-app link, an external one, or plain content when the source has nowhere to go. */
function SourceLink({ href, external, tip, className, children }: { href?: string; external?: boolean; tip?: string; className: string; children: ReactNode }) {
  if (!href) return <div title={tip} className={className}>{children}</div>;
  if (external) return <a href={href} title={tip} target="_blank" rel="noopener noreferrer" className={className}>{children}</a>;
  return <Link href={href} title={tip} className={className}>{children}</Link>;
}

type Card = { key: string; tile: Tile; title: string; meta: string; href?: string; external?: boolean; tip?: string; n?: number };

const vesperCard = (s: Source): Card => ({ key: s.key, tile: vesperTile(s), title: s.title, meta: s.meta, href: s.href, tip: s.label });
const webCard = (s: WebSource): Card => ({ key: s.url, tile: webTile(s), title: s.title, meta: s.host, href: s.url, external: true, tip: s.url });

function CardGroup({ label, cards, focused }: { label: string; cards: Card[]; focused?: number }) {
  if (cards.length === 0) return null;
  return (
    <div className="flex flex-col gap-1.5">
      <h4 className="text-12 font-semibold uppercase tracking-wide text-fg-tertiary">{label}</h4>
      <ul className="grid grid-cols-[repeat(auto-fill,minmax(205px,1fr))] gap-2">
        {cards.map((c) => (
          <li key={c.key} data-testid="source" data-cite={c.n} className="min-w-0">
            <SourceLink href={c.href} external={c.external} tip={c.tip} className={cx("flex h-full items-center gap-2.5 rounded-[10px] border bg-surface px-2.5 py-2 transition-colors hover:border-border-strong", c.n !== undefined && c.n === focused ? "border-accent" : "border-border")}>
              <SourceTile tile={c.tile} size={30} />
              <span className="flex min-w-0 flex-col">
                <span className="truncate text-13 font-semibold text-fg">{c.title}</span>
                <span className="truncate text-12 text-fg-tertiary">{c.meta}</span>
              </span>
              {c.n !== undefined && <span aria-hidden className="ml-auto flex-none self-start rounded bg-accent-soft px-1 font-mono text-12 font-semibold text-accent">{c.n}</span>}
            </SourceLink>
          </li>
        ))}
      </ul>
    </div>
  );
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : (word.endsWith("h") ? "es" : "s")}`;

/**
 * What a reply drew on, Vesper documents and web pages alike: a one-line row that opens
 * into cards. Pages a search found but the reply didn't use stay behind "more".
 * Hidden when the turn read and searched nothing.
 */
export function Sources({ citations, body, listed, runId, since, until, webEvents, focus }: {
  citations?: Schemas["ChatCitation"][];
  body: string;
  listed: ListedSource[];
  runId?: string;
  since?: string;
  until?: string;
  /** The reply closes its turn, so the turn's web searches belong under it. */
  webEvents: boolean;
  /** The citation last clicked in the reply; tick repeats a click on the same one. */
  focus?: { n: number; tick: number };
}) {
  const refs = useMemo(() => listed.flatMap((l) => (l.ref ? [l.ref] : [])), [listed]);
  const resolved = useResolvedLinks(refs);
  // Pages the closing list names join what the turn read; a name that doesn't resolve still gets a card.
  const { vesper, byRef } = useMemo(() => {
    const read = citationSources(citations);
    const byRef = new Map<string, string>();
    for (const ref of refs) {
      const target = resolved.data?.find((l) => l.ref === ref)?.target ?? (resolved.data ? { kind: "unresolved" as const, title: ref } : undefined);
      if (!target) continue;
      const hit = read.find((s) => (target.id && s.target.id === target.id) || (!target.id && s.title === target.title));
      if (hit) byRef.set(ref, hit.key);
      else {
        const [added] = citationSources([{ target, title: target.title, path: target.path }]);
        read.push(added);
        byRef.set(ref, added.key);
      }
    }
    return { vesper: read, byRef };
  }, [citations, refs, resolved.data]);
  const q = useChatTurnEvents(webEvents ? runId : undefined, since, until, webEvents);
  const searches = useMemo(() => webSearches(webEvents ? q.data : undefined, since, until), [webEvents, q.data, since, until]);
  const { used, more } = useMemo(() => usedWebSources(body, listed, searches), [body, listed, searches]);
  const [open, setOpen] = useState(false);
  const [showQueries, setShowQueries] = useState(false);
  const [showMore, setShowMore] = useState(false);
  const panel = useId();
  const root = useRef<HTMLElement>(null);
  const [seenTick, setSeenTick] = useState<number>();
  if (focus && focus.tick !== seenTick) {
    setSeenTick(focus.tick);
    setOpen(true);
  }
  const [focused, setFocused] = useState<number>();
  useEffect(() => {
    if (!focus) return;
    root.current?.querySelector(`[data-cite="${focus.n}"]`)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    const on = setTimeout(() => setFocused(focus.n), 0);
    const off = setTimeout(() => setFocused(undefined), 1800);
    return () => {
      clearTimeout(on);
      clearTimeout(off);
    };
  }, [focus]);

  const total = vesper.length + used.length;
  const queries = searches.queries;
  if (total === 0 && queries.length === 0 && more.length === 0) return null;

  // A citation number belongs to the card its list line became.
  const numberOf = new Map<string, number>();
  for (const l of listed) {
    const key = l.ref ? byRef.get(l.ref) : l.url;
    if (key && l.n !== undefined) numberOf.set(key, l.n);
  }
  const numbered = (c: Card): Card => ({ ...c, n: numberOf.get(c.key) });
  const vesperCards = vesper.map(vesperCard).map(numbered);
  const webCards = used.map(webCard).map(numbered);
  const cards = [...vesperCards, ...webCards];
  const shell = "w-full max-w-[min(720px,100%)] text-13";
  const pill = "inline-flex max-w-full items-center gap-2 rounded-full border border-border bg-surface py-1 pl-1.5 pr-3 transition-colors hover:border-border-strong";

  // A lone source has nothing to open: the row is its link.
  if (total === 1 && more.length === 0) {
    const c = cards[0];
    return (
      <section ref={root} aria-label="Sources" data-testid="sources" className={shell}>
        <div data-testid="source" data-cite={c.n}>
          <SourceLink href={c.href} external={c.external} tip={c.tip} className={pill}>
            <SourceTile tile={c.tile} size={22} />
            <span className={cx("truncate text-13 font-semibold", c.href ? "text-accent" : "text-fg")}>{c.title}</span>
            <span className="flex-none text-12 text-fg-tertiary">· {c.meta.split(" · ")[0]}</span>
          </SourceLink>
        </div>
      </section>
    );
  }

  const heading = total > 0 ? plural(total, "source") : "Searched the web";
  const split = total > 0 ? sourceSplit(vesper.length, used.length) : "none used";
  const toggle = (
    <>
      <span className="text-13 font-semibold text-fg">{heading}</span>
      <span className="truncate text-12 text-fg-tertiary">{split}</span>
      <Icon name="chev" size={12} className={cx("flex-none text-fg-tertiary transition-transform", open && "rotate-180")} />
    </>
  );

  if (!open) {
    const tiles = cards.slice(0, MAX_TILES);
    return (
      <section ref={root} aria-label="Sources" data-testid="sources" className={shell}>
        <button type="button" aria-expanded={false} onClick={() => setOpen(true)} className={pill}>
          {tiles.length > 0 ? (
            <span aria-hidden className="flex flex-none -space-x-1.5">
              {tiles.map((c) => (
                <span key={c.key} className="rounded-[7px] bg-surface p-px"><SourceTile tile={c.tile} size={22} /></span>
              ))}
            </span>
          ) : (
            <span aria-hidden className="grid size-[22px] flex-none place-items-center rounded-md bg-surface-sunken text-fg-secondary"><Icon name="search" size={12} /></span>
          )}
          {cards.length > MAX_TILES && <span aria-hidden className="flex-none text-12 font-semibold text-fg-tertiary">+{cards.length - MAX_TILES}</span>}
          {toggle}
        </button>
      </section>
    );
  }

  return (
    <section ref={root} aria-label="Sources" data-testid="sources" className={cx(shell, "rounded-xl border border-border bg-surface")}>
      <div className="flex items-center justify-between gap-3 border-b border-border-subtle px-3 py-2">
        <button type="button" aria-expanded aria-controls={panel} onClick={() => setOpen(false)} className="flex min-w-0 items-center gap-2">{toggle}</button>
        {queries.length > 0 && (
          <button type="button" aria-expanded={showQueries} onClick={() => setShowQueries((v) => !v)} className="flex flex-none items-center gap-1.5 text-fg-secondary hover:text-fg">
            <Icon name="search" size={12} className="text-fg-tertiary" />
            {plural(queries.length, "search")}
            <Icon name="chev" size={12} className={cx("text-fg-tertiary transition-transform", showQueries && "rotate-180")} />
          </button>
        )}
      </div>
      <div id={panel} className="motion-rise flex flex-col gap-3 p-3">
        <Collapse open={showQueries}>
          <ul aria-label="Searches" className="flex flex-col gap-0.5">
            {queries.map((x) => (
              <li key={x} data-testid="source-query" className="flex items-center gap-2 text-fg">
                <Icon name="search" size={12} className="flex-none text-fg-tertiary" />
                <span className="min-w-0 truncate">{x}</span>
              </li>
            ))}
          </ul>
        </Collapse>
        <CardGroup label="In Vesper" cards={vesperCards} focused={focused} />
        <CardGroup label="From the web" cards={webCards} focused={focused} />
        {more.length > 0 && (
          <div className={cx(total > 0 && "border-t border-border-subtle pt-2.5")}>
            <button type="button" aria-expanded={showMore} onClick={() => setShowMore((v) => !v)} className="flex items-center gap-1.5 text-fg-secondary hover:text-fg">
              + {plural(more.length, "more search result")}{total > 0 ? ", not used in this reply" : ""}
              <Icon name="chev" size={12} className={cx("text-fg-tertiary transition-transform", showMore && "rotate-180")} />
            </button>
            <Collapse open={showMore}>
              <ul className="mt-1.5 flex flex-col gap-0.5">
                {more.map((s) => (
                  <li key={s.url} data-testid="source-more" className="flex items-baseline gap-3">
                    <a href={s.url} target="_blank" rel="noopener noreferrer" className="min-w-0 flex-1 truncate text-accent hover:underline">{s.title}</a>
                    <span className="flex-none text-12 text-fg-tertiary">{s.host}</span>
                  </li>
                ))}
              </ul>
            </Collapse>
          </div>
        )}
      </div>
    </section>
  );
}
