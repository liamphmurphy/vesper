"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState, type FormEvent, type ReactNode } from "react";
import { KINDS, ago, kindHref, pageHref, pageIcon, startTab, type PageKind } from "@/lib/knowledge";
import { useCreatePage, usePages, useTemplates, type PageRow } from "@/lib/api/knowledge-hooks";
import { useCreateDeck, useDecks, useSlideStarters, type DeckSummary, type SlideStarter, type StarterKey } from "@/lib/api/slides-hooks";
import { useCreateDesign, useDesigns, useDesignVersion, type DesignStarter, type DesignSummary } from "@/lib/api/designs-hooks";
import { designBriefTitle, isDeckBrief, isDesignBrief, MAX_OUTLINE, splitOutline } from "@/lib/start";
import { assetHref, SlideSvg, useSlideFonts } from "@/lib/slides/render";
import { H, THEMES, W, parseDeck, placeholders, type Deck, type ThemeKey } from "@/lib/slides/schema";
import { DesignSvg, designAssetHref, useDesignFonts } from "@/lib/designs/render";
import { normalize, type Design } from "@/lib/designs/schema";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { useKnowledge, useKnowledgeTab } from "./shell";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
const sectionLabel = "text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary";
const startBox = "flex flex-wrap items-center gap-2 rounded-xl border border-border-strong bg-surface p-1 pl-3 focus-within:border-accent";
const startInput = "min-w-[200px] flex-1 bg-transparent text-14 text-fg outline-none placeholder:text-fg-tertiary";
const tile = "flex flex-col rounded-xl border bg-surface p-2 text-left outline-none transition-colors focus-visible:ring-2 focus-visible:ring-accent/35 disabled:opacity-60";

const DESCRIPTION: Record<PageKind, string> = {
  document: "Notes, specs and writing. Each is a page, filed in whatever folder you put it in.",
  deck: "Slides you build and present with a persona. Each deck is a page, so it lives in whatever folder you put it in.",
  design: "App flows, diagrams and wireframes you build with your personas. Each design is a page in Knowledge.",
};

/**
 * A kind's start page in Knowledge (/knowledge?kind=…): what Docs, Slides and Designs each had as
 * their own home before they became pages: a way to start one, and every one you have, wherever
 * it's filed. The three share one tab and switch between themselves from their header.
 */
export function KindStart({ kind }: { kind: PageKind }) {
  useKnowledgeTab(startTab(kind));
  const label = KINDS.find((k) => k.kind === kind)!;
  return (
    <div className="relative min-h-0 flex-1 overflow-y-auto">
      <div className="mx-auto flex w-full max-w-[1000px] flex-col gap-6 px-6 pb-12 pt-10 max-sm:px-4">
        <header className="flex flex-col gap-1.5">
          <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
            <h1 className="text-28 font-bold tracking-[-0.02em] text-fg">{label.plural}</h1>
            <nav aria-label="Kinds" className="flex rounded-md border border-border-subtle bg-surface-sunken p-0.5">
              {KINDS.map((k) => (
                <Link
                  key={k.kind}
                  href={kindHref(k.kind)}
                  aria-current={k.kind === kind ? "page" : undefined}
                  className={cx("flex h-6 items-center gap-1.5 rounded px-2.5 text-12 font-medium", k.kind === kind ? "bg-selected text-fg" : "text-fg-tertiary hover:text-fg-secondary")}
                >
                  <Icon name={pageIcon({ kind: k.kind })} size={12} />
                  {k.plural}
                </Link>
              ))}
            </nav>
          </div>
          <p className="text-13 text-fg-secondary">{DESCRIPTION[kind]}</p>
        </header>
        {kind === "document" ? <DocumentStart /> : kind === "deck" ? <DeckStart /> : <DesignStart />}
        <Gallery kind={kind} />
      </div>
    </div>
  );
}

// ---- Starting one

function DocumentStart() {
  const k = useKnowledge();
  const router = useRouter();
  const create = useCreatePage();
  const templates = useTemplates();
  const [title, setTitle] = useState("");
  const make = (template?: string, name = title.trim()) =>
    create.mutate({ title: name || "Untitled", body_md: "", template }, { onSuccess: (p) => router.push(pageHref(p.id, p.title)) });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!create.isPending) make();
  };
  // Today has its own starter (it finds today's note rather than making another), so Daily isn't offered again.
  const named = Object.keys(templates.data ?? {}).filter((t) => t !== "Daily").sort();
  return (
    <>
      <form onSubmit={submit} className={startBox}>
        <input aria-label="New document title" className={startInput} placeholder="Give it a title…" maxLength={200} value={title} onChange={(e) => setTitle(e.target.value)} />
        <Button type="submit" variant="primary" icon="plus" disabled={create.isPending}>
          {create.isPending ? "Creating…" : "New document"}
        </Button>
      </form>
      {create.isError && <p role="alert" className="-mt-4 text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
      <StartFrom>
        <StartTile label="Blank" detail="An empty page" disabled={create.isPending} onClick={() => make()}>
          <span className="text-22 font-light text-fg-tertiary">+</span>
        </StartTile>
        <StartTile label="Today" detail="Your daily note" onClick={k.openToday}>
          <Icon name="clock" size={22} className="text-fg-tertiary" />
        </StartTile>
        {named.map((t) => (
          <StartTile key={t} label={t} detail="Template" disabled={create.isPending} onClick={() => make(t, title.trim() || t)}>
            <TemplateArt />
          </StartTile>
        ))}
      </StartFrom>
    </>
  );
}

/** What a new deck starts from: one blank title slide, a starter deck, or an outline its persona drafts. */
type DeckFrom = "blank" | "outline" | StarterKey;
const BLANK_COVER: Deck = { schema: 1, size: { w: W, h: H }, theme: THEMES.light, assets: {}, slides: [{ id: "s_blank", layout: "title", elements: placeholders("title") }] };

function DeckStart() {
  const router = useRouter();
  const create = useCreateDeck();
  const fonts = useSlideFonts();
  const [title, setTitle] = useState("");
  const [theme, setTheme] = useState<ThemeKey>("light");
  const [from, setFrom] = useState<DeckFrom>("blank");
  const [outline, setOutline] = useState("");
  const [outlineError, setOutlineError] = useState("");
  const brief = from === "blank" && isDeckBrief(title);
  const open = (id: string, ask?: string) => router.push(`/apps/slides/${id}${ask ?? ""}`);

  const start = (e?: FormEvent) => {
    e?.preventDefault();
    if (create.isPending) return;
    const themeKey = theme as "light";
    if (from === "outline") {
      const o = splitOutline(outline, title);
      if (!o.slides) return setOutlineError("Add at least one line for a slide after the title.");
      setOutlineError("");
      create.mutate({ title: o.title, theme: themeKey }, { onSuccess: (d) => open(d.id, `?outline=${encodeURIComponent(o.slides)}`) });
    } else if (from !== "blank") {
      create.mutate({ title, theme: themeKey, starter: from }, { onSuccess: (d) => open(d.id) });
    } else {
      // A description makes an untitled deck whose chat drafts it; the persona names it.
      create.mutate({ title: brief ? "" : title, theme: themeKey }, { onSuccess: (d) => open(d.id, brief ? `?brief=${encodeURIComponent(title.trim())}` : undefined) });
    }
  };

  return (
    <>
      <form onSubmit={start} className={startBox}>
        <input aria-label="New deck title or brief" className={startInput} placeholder="Give it a title, or describe it and its persona drafts the slides…" maxLength={2000} value={title} onChange={(e) => setTitle(e.target.value)} />
        <label className="flex items-center gap-2 rounded-md border border-border-strong bg-surface-sunken px-2 text-12 text-fg-2">
          <span aria-hidden className="h-3.5 w-5 rounded-[3px] border border-border-strong" style={{ background: THEMES[theme].colors.background }} />
          <select aria-label="Theme" className="h-[26px] bg-transparent outline-none" value={theme} onChange={(e) => setTheme(e.target.value as ThemeKey)}>
            {Object.entries(THEMES).map(([key, t]) => (
              <option key={key} value={key}>
                Theme: {t.name}
              </option>
            ))}
          </select>
        </label>
        <Button type="submit" variant="primary" icon={brief ? undefined : "plus"} disabled={create.isPending}>
          {create.isPending ? "Creating…" : brief ? "✦ Draft it" : "New deck"}
        </Button>
      </form>
      {create.isError && <p role="alert" className="-mt-4 text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
      <DeckChooser value={from} onChange={setFrom} theme={theme} fonts={fonts} />
      {from === "outline" && (
        <form onSubmit={start} className="flex flex-col gap-2 rounded-xl border border-accent bg-surface p-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <label htmlFor="deck-outline" className="text-12 font-medium text-fg-2">Outline</label>
            <span className="text-12 text-fg-tertiary">One slide per top-level line · indented lines become its points</span>
          </div>
          <textarea
            id="deck-outline"
            autoFocus
            rows={6}
            maxLength={MAX_OUTLINE}
            placeholder={"Q3 roadmap\nWhy now\n  - churn up 4% in EU\nPlan: three bets"}
            className="resize-y rounded-md border border-border bg-surface-sunken px-3 py-2 font-mono text-13 text-fg outline-none placeholder:text-fg-tertiary focus:border-accent"
            value={outline}
            onChange={(e) => setOutline(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) start();
            }}
          />
          {outlineError && <p role="alert" className="text-12 text-pill-blocked-fg">{outlineError}</p>}
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-12 text-fg-secondary">The deck opens with its title slide; its persona drafts the rest as suggestions. Nothing is added until you accept.</p>
            <Button type="submit" variant="primary" disabled={create.isPending || !outline.trim()}>
              {create.isPending ? "Creating…" : "✦ Create & draft"}
            </Button>
          </div>
        </form>
      )}
    </>
  );
}

/** Blank, the starter decks and Draft from outline; previews draw in the chosen theme. */
function DeckChooser({ value, onChange, theme, fonts }: { value: DeckFrom; onChange: (s: DeckFrom) => void; theme: ThemeKey; fonts: boolean }) {
  const starters = useSlideStarters();
  const covers = useMemo(
    () =>
      (starters.data ?? []).flatMap((s: SlideStarter) => {
        try {
          return [{ s, deck: parseDeck(s.cover) }];
        } catch {
          return [];
        }
      }),
    [starters.data],
  );
  const options: { key: DeckFrom; label: string; detail: string; deck?: Deck }[] = [
    { key: "blank", label: "Blank", detail: "1 slide", deck: BLANK_COVER },
    ...covers.map(({ s, deck }) => ({ key: s.key as DeckFrom, label: s.name, detail: `${s.slide_count} slides`, deck })),
    { key: "outline", label: "Draft from outline", detail: "Persona suggests slides" },
  ];
  return (
    <StartFrom radio>
      {options.map((o) => {
        const on = o.key === value;
        return (
          <button
            key={o.key}
            type="button"
            role="radio"
            aria-checked={on}
            onClick={() => onChange(o.key)}
            className={cx(tile, on ? "border-accent ring-1 ring-accent" : "border-border hover:border-border-hover", o.key === "outline" && !on && "border-dashed")}
          >
            <span className="block overflow-hidden rounded-[4px] border border-border">
              {o.deck ? (
                <SlideSvg deck={{ ...o.deck, theme: THEMES[theme] }} slide={o.deck.slides[0]} assetUrl={() => ""} fontsReady={fonts} className="block aspect-video w-full" label={`${o.label} preview`} />
              ) : (
                <span aria-hidden className="block aspect-video w-full bg-surface-sunken px-2 py-1.5 font-mono text-10 leading-[1.45] text-fg-secondary">
                  • Intro
                  <br />
                  &nbsp;&nbsp;– why now
                  <br />• Plan
                </span>
              )}
            </span>
            <span className="mt-2 block truncate text-13 font-medium text-fg">{o.label}</span>
            <span className="block text-11 text-fg-tertiary">{o.detail}</span>
          </button>
        );
      })}
      {starters.isError && <p className="col-span-full text-12 text-fg-tertiary">Starter decks couldn’t load; you can still start blank or from an outline.</p>}
    </StartFrom>
  );
}

function DesignStart() {
  const router = useRouter();
  const create = useCreateDesign();
  const [prompt, setPrompt] = useState("");
  const brief = isDesignBrief(prompt);
  const startWith = (starter: DesignStarter, title = "", ask?: string) =>
    create.mutate({ starter, title }, { onSuccess: (d) => router.push(`/apps/designs/${d.id}${ask ? `?brief=${encodeURIComponent(ask)}` : ""}`) });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (create.isPending) return;
    const text = prompt.trim();
    // A request or a ticket key starts a blank design whose chat drafts it; anything else is a title.
    if (text && brief) startWith("blank", designBriefTitle(text), text);
    else startWith("blank", text);
  };
  return (
    <>
      <form onSubmit={submit} className={startBox}>
        <input aria-label="Describe a design, or paste a ticket key" className={startInput} placeholder="Describe a flow or diagram, or paste a ticket key…" maxLength={2000} value={prompt} onChange={(e) => setPrompt(e.target.value)} />
        <Button type="submit" variant="primary" icon={brief ? undefined : "plus"} disabled={create.isPending}>
          {create.isPending ? "Creating…" : brief ? "✦ Draft it" : "New design"}
        </Button>
      </form>
      {create.isError && <p role="alert" className="-mt-4 text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
      <StartFrom>
        {DESIGN_STARTERS.map((s) => (
          <StartTile key={s.key} label={s.label} disabled={create.isPending} onClick={() => startWith(s.key)}>
            {s.art}
          </StartTile>
        ))}
      </StartFrom>
    </>
  );
}

function StartFrom({ radio, children }: { radio?: boolean; children: ReactNode }) {
  return (
    <section aria-labelledby="start-from" className="flex flex-col gap-2">
      <h2 id="start-from" className={sectionLabel}>Start from</h2>
      <div role={radio ? "radiogroup" : undefined} aria-labelledby={radio ? "start-from" : undefined} className="grid grid-cols-[repeat(auto-fill,minmax(140px,1fr))] gap-2.5">
        {children}
      </div>
    </section>
  );
}

function StartTile({ label, detail, disabled, onClick, children }: { label: string; detail?: string; disabled?: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" disabled={disabled} onClick={onClick} className={cx(tile, "border-border hover:border-border-hover")}>
      <span aria-hidden className="flex aspect-video w-full items-center justify-center overflow-hidden rounded-[4px] bg-surface-sunken">
        {children}
      </span>
      <span className="mt-2 block truncate text-13 font-medium text-fg">{label}</span>
      {detail && <span className="block text-11 text-fg-tertiary">{detail}</span>}
    </button>
  );
}

function TemplateArt() {
  return (
    <svg width="64" height="44" viewBox="0 0 64 44" fill="none" stroke="currentColor" strokeWidth="1.2" className="text-fg-tertiary">
      <path d="M8 6h30M8 16h18M8 24h40M8 30h36M8 38h22" />
    </svg>
  );
}

/** Starter cards with the old Designs home's little pictures, in the theme's colors. */
const DESIGN_STARTERS: { key: DesignStarter; label: string; art: ReactNode }[] = [
  { key: "blank", label: "Blank", art: <span className="text-22 font-light text-fg-tertiary">+</span> },
  {
    key: "mobile-flow",
    label: "Mobile flow",
    art: (
      <svg width="104" height="64" viewBox="0 0 104 64" fill="none" className="text-fg-tertiary">
        <rect x="10" y="2" width="30" height="60" rx="4" stroke="currentColor" />
        <rect x="70" y="2" width="30" height="60" rx="4" stroke="currentColor" />
        <path d="M40 52c14 0 14-26 28-26" stroke="var(--color-accent)" strokeWidth="1.5" />
      </svg>
    ),
  },
  {
    key: "web-flow",
    label: "Web flow",
    art: (
      <svg width="120" height="56" viewBox="0 0 140 56" fill="none" stroke="currentColor" className="text-fg-tertiary">
        <rect x="2" y="4" width="62" height="44" rx="3" /><path d="M2 11h62" />
        <rect x="86" y="18" width="52" height="36" rx="3" /><path d="M86 25h52" />
        <path d="M64 30c10 0 10 6 20 6" stroke="var(--color-accent)" strokeWidth="1.5" />
      </svg>
    ),
  },
  {
    key: "diagram",
    label: "Diagram",
    art: (
      <svg width="120" height="64" viewBox="0 0 148 64" fill="none" stroke="currentColor" strokeWidth="1.2" className="text-fg-tertiary">
        <rect x="4" y="4" width="40" height="20" rx="4" /><rect x="74" y="4" width="40" height="20" rx="4" /><rect x="74" y="42" width="40" height="20" rx="4" />
        <path d="M44 14h30M94 24v18" /><path d="m132 4 10 10-10 10-10-10z" stroke="var(--color-accent)" />
      </svg>
    ),
  },
  {
    key: "wireframe",
    label: "Wireframe",
    art: (
      <svg width="120" height="56" viewBox="0 0 140 60" fill="none" stroke="currentColor" strokeWidth="1.2" strokeDasharray="3 2" className="text-fg-tertiary">
        <rect x="2" y="2" width="136" height="56" rx="3" /><path d="M2 16h136M38 16v42" /><path d="M50 28h60M50 36h40" strokeDasharray="none" />
      </svg>
    ),
  },
];

// ---- Every one you have

function Gallery({ kind }: { kind: PageKind }) {
  const k = useKnowledge();
  const [query, setQuery] = useState("");
  const label = KINDS.find((x) => x.kind === kind)!;
  const agent = k.view === "agent";
  const pages = usePages({ kind, text: query.trim() || undefined, limit: 120, include_agent: agent, audience: agent ? "agent" : undefined });
  const rows = pages.data?.rows ?? [];
  return (
    <section aria-labelledby="kind-gallery" className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 id="kind-gallery" className={sectionLabel}>
          Your {label.plural.toLowerCase()}
          {pages.data && !query.trim() ? ` · ${rows.length}${pages.data.has_more ? "+" : ""}` : ""}
        </h2>
        <label className="flex h-7 w-[220px] items-center gap-2 rounded-md border border-border bg-surface px-2 text-12 focus-within:border-accent max-sm:w-full">
          <Icon name="search" size={12} className="text-fg-tertiary" />
          <input aria-label={`Search ${label.plural.toLowerCase()}`} placeholder={`Search ${label.plural.toLowerCase()}`} className="min-w-0 flex-1 bg-transparent text-fg outline-none placeholder:text-fg-tertiary" value={query} onChange={(e) => setQuery(e.target.value)} />
        </label>
      </div>
      {pages.isError ? (
        <Banner tone="blocked" title={`Couldn’t load your ${label.plural.toLowerCase()}`} actions={<Button onClick={() => void pages.refetch()}>Retry</Button>}>
          {errorText(pages.error)}
        </Banner>
      ) : !pages.data ? (
        <div aria-busy="true" className="grid grid-cols-[repeat(auto-fill,minmax(220px,1fr))] gap-4">
          {[0, 1, 2].map((i) => (
            <Skeleton key={i} className="h-[180px] rounded-xl" />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <EmptyState icon={pageIcon({ kind })} title={query.trim() ? `No ${label.plural.toLowerCase()} match “${query.trim()}”` : `No ${label.plural.toLowerCase()} yet`}>
          {query.trim() ? "Try another word, or search everything with ⌘⇧K." : "Start one above: every one you make shows up here, whatever folder it's in."}
        </EmptyState>
      ) : kind === "document" ? (
        <DocumentList rows={rows} />
      ) : kind === "deck" ? (
        <DeckGrid rows={rows} />
      ) : (
        <DesignGrid rows={rows} />
      )}
    </section>
  );
}

const folderOf = (path: string) => path.split("/").slice(0, -1).join(" / ") || "Top level";

/** Documents are mostly words, so their summary line says more than a thumbnail would. */
function DocumentList({ rows }: { rows: PageRow[] }) {
  return (
    <ul aria-label="Documents">
      {rows.map((r) => (
        <li key={r.id} className="border-b border-border-row">
          <Link href={pageHref(r.id, r.title)} className="grid grid-cols-[20px_1fr_auto] items-center gap-3 rounded-md px-2 py-2 hover:bg-hover">
            <Icon name={pageIcon(r)} size={14} className="text-fg-tertiary" />
            <span className="min-w-0">
              <span className="block truncate text-14 font-medium text-fg">{r.title}</span>
              <span className="block truncate text-12 text-fg-tertiary">
                {folderOf(r.path)}
                {r.summary ? ` · ${r.summary}` : ""}
              </span>
            </span>
            <span className="flex items-center gap-2 text-12 text-fg-tertiary">
              {r.pending > 0 && <ReviewPill n={r.pending} />}
              {ago(r.updated_at)}
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}

function ReviewPill({ n }: { n: number }) {
  return <span className="rounded-full bg-pill-review-bg px-2 py-0.5 text-11 text-pill-review-fg">{n} to review</span>;
}

/** A deck or design card: its picture, title, folder and when it changed. */
function Card({ row, picture, detail, badge }: { row: PageRow; picture: ReactNode; detail: string; badge?: ReactNode }) {
  return (
    <li>
      <Link
        href={pageHref(row.id, row.title)}
        className={cx(
          "flex h-full flex-col rounded-xl border bg-surface p-2.5 outline-none transition-colors hover:border-border-hover focus-visible:border-accent focus-visible:ring-2 focus-visible:ring-accent/35",
          row.pending > 0 ? "border-accent/50" : "border-border",
        )}
      >
        <span className="block overflow-hidden rounded-md border border-border-subtle">{picture}</span>
        <span className="mt-2.5 flex items-start gap-2 px-0.5">
          <span className="min-w-0 flex-1">
            <span className="block truncate text-14 font-semibold text-fg">{row.title}</span>
            <span className="block truncate text-12 text-fg-tertiary">
              {folderOf(row.path)} · {detail} · {ago(row.updated_at)}
            </span>
          </span>
          {badge}
        </span>
        {row.pending > 0 && (
          <span className="mt-1.5 px-0.5">
            <ReviewPill n={row.pending} />
          </span>
        )}
      </Link>
    </li>
  );
}

const grid = "grid grid-cols-[repeat(auto-fill,minmax(220px,1fr))] gap-4";

function DeckGrid({ rows }: { rows: PageRow[] }) {
  const decks = useDecks();
  const fonts = useSlideFonts();
  const byCanvas = useMemo(() => new Map((decks.data ?? []).map((d) => [d.id, d])), [decks.data]);
  return (
    <ul aria-label="Decks" className={grid}>
      {rows.map((r) => {
        const d = r.canvas_id ? byCanvas.get(r.canvas_id) : undefined;
        return <Card key={r.id} row={r} picture={<DeckCover d={d} fonts={fonts} />} detail={d ? `${d.slide_count} ${d.slide_count === 1 ? "slide" : "slides"}` : "deck"} />;
      })}
    </ul>
  );
}

function DeckCover({ d, fonts }: { d?: DeckSummary; fonts: boolean }) {
  const raw = d?.cover;
  const cover = useMemo<Deck | null>(() => {
    try {
      return raw ? parseDeck(raw) : null;
    } catch {
      return null;
    }
  }, [raw]);
  if (!d || !cover) return <span className="block aspect-video w-full bg-surface-sunken" />;
  return <SlideSvg deck={cover} slide={cover.slides[0]} assetUrl={(a) => assetHref(d.id, a)} fontsReady={fonts} className="block aspect-video w-full" label={`First slide of ${d.title}`} />;
}

function DesignGrid({ rows }: { rows: PageRow[] }) {
  const designs = useDesigns();
  useDesignFonts();
  const byCanvas = useMemo(() => new Map((designs.data ?? []).map((d) => [d.id, d])), [designs.data]);
  return (
    <ul aria-label="Designs" className={grid}>
      {rows.map((r) => {
        const d = r.canvas_id ? byCanvas.get(r.canvas_id) : undefined;
        const badge = d?.persona_edited ? (
          <span aria-label="A persona worked on this" title="A persona worked on this" className="mt-0.5 grid size-[20px] flex-none place-items-center rounded-full border border-accent text-10 font-bold text-accent">
            ✦
          </span>
        ) : undefined;
        return <Card key={r.id} row={r} picture={<DesignPicture d={d} />} detail={d ? `${d.frames} ${d.frames === 1 ? "frame" : "frames"}` : "design"} badge={badge} />;
      })}
    </ul>
  );
}

function DesignPicture({ d }: { d?: DesignSummary }) {
  const version = useDesignVersion(d?.id, d?.seq);
  const body = useMemo<Design | undefined>(() => {
    try {
      return version.data ? normalize(version.data.body).design : undefined;
    } catch {
      return undefined;
    }
  }, [version.data]);
  return (
    <span className="block aspect-video w-full bg-surface-sunken p-2 [background-image:radial-gradient(var(--color-border-subtle)_1px,transparent_1px)] [background-size:12px_12px]">
      {d && body ? <DesignSvg design={body} assetUrl={(a) => designAssetHref(d.id, a)} className="block h-full w-full" title={`First page of ${d.title}`} pad={6} /> : d && <Skeleton className="h-full w-full opacity-40" />}
    </span>
  );
}
