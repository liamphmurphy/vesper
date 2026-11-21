"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { usePage, useSavedQuery, type Page, type PageTable } from "@/lib/api/knowledge-hooks";
import { ago, pageHref, visibleProperties } from "@/lib/knowledge";
import {
  formatPropertyValue,
  KNOWLEDGE_PRINT_STYLES,
  knowledgePrintHref,
  parseKnowledgePrintStyle,
  prepareKnowledgePrint,
  type KnowledgePrintStyle,
  type PrintEmbedLike,
  type PrintSegment,
} from "@/lib/knowledge-print";
import { isNativeShell, post } from "@/lib/native-shell/bridge";
import { PALETTES } from "@/lib/palettes";
import { isPdfContentType } from "@/lib/pdf-viewer";
import { settled } from "@/lib/print-ready";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { Markdown } from "@/components/domain/markdown";
import { PrintMode } from "@/components/domain/print-mode";

const AUDIENCE_LABEL: Record<Page["audience"], string> = {
  private: "Private",
  shared: "Shared",
  agent: "Agent",
};

const PAPER_LIGHT_STYLE = Object.fromEntries(
  Object.entries(PALETTES[0].light).map(([k, v]) => [`--${k}`, v]),
) as CSSProperties;

export function PrintKnowledge({ id }: { id: string }) {
  const urlStyle = parseKnowledgePrintStyle(useSearchParams().get("style"));
  const [style, setStyle] = useState<KnowledgePrintStyle>(urlStyle);
  const [prevUrlStyle, setPrevUrlStyle] = useState(urlStyle);
  if (urlStyle !== prevUrlStyle) {
    setPrevUrlStyle(urlStyle);
    setStyle(urlStyle);
  }
  const [showMeta, setShowMeta] = useState(false);

  const pageQuery = usePage(id);
  const p = pageQuery.data;
  const hasQuery = !!p?.properties?.query;
  const savedQuery = useSavedQuery(id, hasQuery);
  const printable = !!p && p.kind !== "deck" && p.kind !== "design";

  const ref = useRef<HTMLElement>(null);
  const printed = useRef(false);

  const selectStyle = (next: KnowledgePrintStyle) => {
    setStyle(next);
    window.history.replaceState(null, "", knowledgePrintHref(id, next));
  };

  // Hide the native Mac sidebar while inspecting the print sheet.
  useEffect(() => {
    if (!isNativeShell()) return;
    post({ v: 1, type: "sidebarHidden", hidden: true });
    return () => post({ v: 1, type: "sidebarHidden", hidden: false });
  }, []);

  const styleInfo = KNOWLEDGE_PRINT_STYLES.find((s) => s.id === style) ?? KNOWLEDGE_PRINT_STYLES[0];

  // The PDF's default file name is the page title.
  useEffect(() => {
    if (!p) return;
    const docTitle = p.title || "Untitled";
    document.title = docTitle;
    if (isNativeShell()) {
      post({ v: 1, type: "title", title: docTitle, subtitle: `PDF · ${styleInfo.label}` });
    }
  }, [p, styleInfo.label]);

  const readyToPrint = !!p && printable && (!hasQuery || !savedQuery.isPending);

  // Open the print dialog once, when saved query, diagrams, and images have settled.
  useEffect(() => {
    if (!readyToPrint || printed.current || !ref.current) return;
    printed.current = true;
    let live = true;
    let done = false;
    settled(ref.current).then(() => {
      if (!live) return;
      done = true;
      window.print();
    });
    return () => {
      live = false;
      if (!done) printed.current = false;
    };
  }, [readyToPrint]);

  const crumbs = useMemo(() => (p ? (p.path ?? p.title).split("/").filter(Boolean) : []), [p]);
  const propRows = useMemo(() => (p ? visibleProperties(p.properties) : []), [p]);
  const hasMeta = crumbs.length > 1 || propRows.length > 0;
  const segments = useMemo(
    () => (p && printable ? prepareKnowledgePrint(p.body_md ?? "", p.title, p.embeds) : []),
    [p, printable],
  );

  if (pageQuery.error) {
    return (
      <div className="min-h-dvh bg-bg p-8 text-fg">
        <div className="mx-auto max-w-[720px]">
          <Banner tone="blocked" title="Couldn't load this page">{pageQuery.error.message}</Banner>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-dvh bg-bg text-fg print:bg-white">
      <div className="sticky top-0 z-10 flex flex-wrap items-center gap-3 border-b border-border-subtle bg-panel px-6 py-2.5 print:hidden">
        <Link href={p ? pageHref(p.id, p.title) : `/knowledge/${id}`} className="text-13 text-fg-secondary hover:text-fg">
          ← Back to page
        </Link>
        <div role="group" aria-label="PDF style" className="flex items-center gap-1 rounded-lg border border-border-subtle bg-surface p-0.5">
          {KNOWLEDGE_PRINT_STYLES.map((s) => (
            <button
              key={s.id}
              type="button"
              aria-pressed={style === s.id}
              title={s.description}
              onClick={() => selectStyle(s.id)}
              className={cx(
                "inline-flex h-7 items-center gap-1.5 rounded-md px-2.5 text-12 font-medium transition-colors",
                style === s.id ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              <Icon name={s.icon} size={12} />
              {s.label}
            </button>
          ))}
        </div>
        {hasMeta && (
          <label
            title="Show folder path, tags, dates, and page properties"
            className="inline-flex h-8 cursor-pointer select-none items-center gap-2 rounded-md border border-border-subtle bg-surface px-2.5 text-12 font-medium text-fg-secondary transition-colors hover:border-border-strong hover:text-fg"
          >
            <input
              type="checkbox"
              checked={showMeta}
              onChange={(e) => setShowMeta(e.target.checked)}
              className="size-3.5 accent-[var(--accent)]"
            />
            <span>Include metadata</span>
          </label>
        )}
        <span className="ml-auto text-12 text-fg-tertiary max-lg:hidden">Choose “Save as PDF” as the destination.</span>
        <Button variant="primary" icon="printer" disabled={!p || !printable} onClick={() => window.print()}>
          Print / Save as PDF
        </Button>
      </div>

      <article
        ref={ref}
        data-testid="print-knowledge"
        data-print-style={style}
        data-theme="light"
        style={PAPER_LIGHT_STYLE}
        className="print-doc print-knowledge mx-auto my-8 flex w-full max-w-[780px] flex-col rounded-sm border border-border-strong/60 bg-white px-12 py-12 shadow-[0_2px_8px_rgba(0,0,0,0.08),0_12px_32px_rgba(0,0,0,0.16)] print:my-0 print:max-w-none print:rounded-none print:border-0 print:bg-transparent print:p-0 print:shadow-none"
      >
        {!p ? (
          <div aria-busy="true" className="flex flex-col gap-4">
            <Skeleton className="h-8 w-2/3" />
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-3 w-5/6" />
            <Skeleton className="h-3 w-4/6" />
          </div>
        ) : !printable ? (
          <Banner tone="human" title="Decks and designs export from their own editor">
            <Link href={pageHref(p.id, p.title)} className="underline">
              Return to {p.title || "page"}
            </Link>{" "}
            to export slides or design frames.
          </Banner>
        ) : (
          <PrintMode.Provider value={true}>
            <header className="print-kn-header">
              {showMeta && crumbs.length > 1 && (
                <p className="print-kn-folder">{crumbs.slice(0, -1).join(" / ")}</p>
              )}
              <h1 className="print-kn-title">{p.title || "Untitled"}</h1>
              {showMeta && propRows.length > 0 && <PrintProperties rows={propRows} />}
            </header>

            {hasQuery && savedQuery.data && savedQuery.data.rows.length > 0 && (
              <PrintQueryTable table={savedQuery.data} />
            )}
            {hasQuery && savedQuery.error && (
              <p className="print-embed-missing">Couldn&apos;t load saved query results: {savedQuery.error.message}</p>
            )}

            <div className="print-kn-body">
              <PrintSegments segments={segments} />
            </div>
          </PrintMode.Provider>
        )}
      </article>
    </div>
  );
}

function PrintProperties({ rows }: { rows: [string, unknown][] }) {
  return (
    <dl className="print-kn-props">
      {rows.map(([k, v]) => (
        <div key={k} className="print-kn-prop-row">
          <dt className="print-kn-prop-key">{k}</dt>
          <dd className="print-kn-prop-val">
            {k === "tags" && Array.isArray(v) ? (
              <span className="print-kn-tags">
                {v.map((tag, i) => (
                  <span key={i} className="print-kn-tag">#{String(tag)}</span>
                ))}
              </span>
            ) : (
              formatPropertyValue(v) || "—"
            )}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function PrintQueryTable({ table }: { table: PageTable }) {
  const columns = useMemo(() => {
    const seen = new Map<string, number>();
    for (const r of table.rows) {
      for (const k of Object.keys(r.properties ?? {})) {
        if (!["tags", "aliases", "query", "zettel_id", "title"].includes(k)) {
          seen.set(k, (seen.get(k) ?? 0) + 1);
        }
      }
    }
    return [...seen.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 4)
      .map(([k]) => k);
  }, [table.rows]);

  return (
    <div className="print-kn-query-wrap">
      <table className="print-kn-query">
        <thead>
          <tr>
            <th>Name</th>
            {columns.map((c) => (
              <th key={c}>{c}</th>
            ))}
            <th>Tags</th>
            <th>Audience</th>
            <th>Updated</th>
          </tr>
        </thead>
        <tbody>
          {table.rows.map((r) => {
            const tags = Array.isArray(r.properties?.tags) ? (r.properties.tags as string[]) : [];
            return (
              <tr key={r.id}>
                <td className="print-kn-query-title">{r.title}</td>
                {columns.map((c) => (
                  <td key={c}>{formatPropertyValue(r.properties?.[c]) || "—"}</td>
                ))}
                <td>{tags.slice(0, 3).map((t) => `#${t}`).join(" ")}</td>
                <td>{AUDIENCE_LABEL[r.audience]}</td>
                <td>{ago(r.updated_at)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {table.has_more && (
        <p className="print-kn-query-more">Showing the first {table.rows.length} pages.</p>
      )}
    </div>
  );
}

function PrintSegments({ segments }: { segments: readonly PrintSegment[] }) {
  return (
    <>
      {segments.map((seg, i) => {
        if (seg.kind === "markdown") {
          return (
            <Markdown key={i} anchors visualBlocks className="print-kn-prose">
              {seg.content}
            </Markdown>
          );
        }
        if (seg.kind === "callout") {
          return (
            <aside key={i} className="print-callout" data-callout={seg.tone}>
              <p className="print-callout-title">{seg.title}</p>
              {seg.body && (
                <div className="print-callout-body">
                  <Markdown visualBlocks className="print-kn-prose">
                    {seg.body}
                  </Markdown>
                </div>
              )}
            </aside>
          );
        }
        return <PrintEmbed key={i} fallbackLabel={seg.fallbackLabel} embed={seg.embed} />;
      })}
    </>
  );
}

function embedKindLabel(e: PrintEmbedLike): string {
  if (isPdfContentType(e.content_type)) return "PDF";
  if (e.content_type?.startsWith("video/") || e.kind === "video") return "Video";
  if (e.content_type?.startsWith("audio/")) return "Audio";
  if (e.kind === "design") return "Design";
  return "Attachment";
}

function PrintEmbed({ fallbackLabel, embed: e }: { fallbackLabel: string; embed?: PrintEmbedLike }) {
  if (e?.available && e.url && (e.kind === "image" || e.content_type?.startsWith("image/"))) {
    return (
      <figure className="print-embed-image">
        <img src={e.url} alt={e.title ?? fallbackLabel} />
      </figure>
    );
  }
  if (e?.available && e.kind === "page" && e.markdown !== undefined) {
    const nested = prepareKnowledgePrint(e.markdown, e.title ?? "", [], { stripTitle: true });
    return (
      <figure className="print-embed-page">
        {e.title && <figcaption className="print-embed-caption">{e.title}</figcaption>}
        <div className="print-embed-body">
          {nested.length > 0 ? <PrintSegments segments={nested} /> : <p className="print-embed-missing">Empty page</p>}
        </div>
      </figure>
    );
  }
  if (e?.available) {
    return (
      <figure className="print-embed-ref">
        <span className="print-embed-kind">{embedKindLabel(e)}</span>
        <span className="print-embed-name">{e.title ?? fallbackLabel}</span>
      </figure>
    );
  }
  return <p className="print-embed-missing">Embedded reference unavailable: {fallbackLabel}</p>;
}
