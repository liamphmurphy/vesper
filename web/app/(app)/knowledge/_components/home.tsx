"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { HOME_TAB, KINDS, ago, kindHref, pageHref, pageIcon, type PageKind } from "@/lib/knowledge";
import { useAllPages, useCreatePage, usePages, type PageRow } from "@/lib/api/knowledge-hooks";
import { useCreateDesign } from "@/lib/api/designs-hooks";
import { useNewDeck } from "@/components/domain/use-new-deck";
import { toast } from "@/lib/toast";
import { cx } from "@/lib/cx";
import { useBootstrap } from "@/lib/api/hooks";
import { Icon } from "@/components/ui/icon";
import { Kbd, Skeleton } from "@/components/ui/primitives";
import { AUDIENCE, StatusBar, useToday } from "./kit";
import { useKnowledge, useKnowledgeTab } from "./shell";
import { useKnowledgeChat } from "./chat-context";

function greeting(d: Date | null) {
  if (!d) return "Welcome back";
  const h = d.getHours();
  return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
}

/** A new tab: what needs you, where you left off, and what you touched last. */
export function KnowledgeHome() {
  useKnowledgeTab(HOME_TAB);
  const k = useKnowledge();
  const chat = useKnowledgeChat();
  const today = useToday();
  const router = useRouter();
  const me = useBootstrap().data?.me;
  const agent = k.view === "agent";
  const recent = usePages({ limit: 8, include_agent: agent, audience: agent ? "agent" : undefined });
  // The explorer's own query, so this costs nothing extra: rows carry how many persona changes wait for review.
  const all = useAllPages(false);
  const inbox = usePages({ folder: "Inbox", limit: 50 });
  const proposals = usePages({ folder: "Patterns/Proposed", include_agent: true, audience: "agent", limit: 50 });
  const toReview = (all.data ?? []).filter((r) => r.pending > 0);
  const name = me?.name?.split(/\s+/)[0];
  const [latest, ...rest] = recent.data?.rows ?? [];

  const needs: { key: string; count: number; more?: boolean; label: string; action: string; go: () => void; hot?: boolean }[] = [
    { key: "review", count: toReview.length, label: toReview.length === 1 ? "page with suggestions to review" : "pages with suggestions to review", action: "Review", hot: true,
      go: () => router.push(pageHref(toReview[0].id, toReview[0].title)) },
    { key: "inbox", count: inbox.data?.rows.length ?? 0, more: inbox.data?.has_more, label: "inbox captures to file", action: "File with a persona",
      go: () => chat.askFolder({ path: "Inbox", pages: (inbox.data?.rows ?? []).map((r) => r.path), count: inbox.data?.rows.length ?? 0 }) },
    { key: "proposals", count: proposals.data?.rows.length ?? 0, more: proposals.data?.has_more, label: "agent pattern proposals", action: "Review",
      go: () => { const first = proposals.data!.rows[0]; k.setView("agent"); router.push(pageHref(first.id, first.title)); } },
  ];
  const waiting = needs.filter((n) => n.count > 0);
  const loaded = all.data && inbox.data && proposals.data;

  return (
    <>
      {/* relative: the rows' sr-only labels are absolutely placed, and would otherwise escape this scroller and stretch the page. */}
      <div className="relative min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto w-full max-w-[760px] px-6 pb-12 pt-14">
          <h1 className="text-28 font-bold tracking-[-0.02em] text-fg">
            {greeting(today)}
            {/* Only once on the client: the name comes from data the server render doesn't have. */}
            {today && name ? `, ${name}` : ""}
          </h1>
          <p className="mt-1 text-14 text-fg-tertiary">{today?.toLocaleDateString("en", { weekday: "long", day: "numeric", month: "long" })}</p>

          {!agent && <StartRow pages={all.data} />}

          {!agent && (
            <section aria-label="Needs you" className="mt-8">
              <h2 className="text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Needs you</h2>
              {!loaded ? (
                <Skeleton className="mt-2 h-[84px] w-full" />
              ) : waiting.length === 0 ? (
                <p className="mt-2 text-13 text-fg-tertiary">Nothing to review or file.</p>
              ) : (
                <div className="mt-2 grid gap-2.5 sm:grid-cols-3">
                  {waiting.map((n) => (
                    <button key={n.key} onClick={n.go} className={cx("flex flex-col items-start rounded-xl border bg-surface p-3.5 text-left hover:bg-hover", n.hot ? "border-accent/40" : "border-border")}>
                      <span className={cx("text-22 font-bold leading-none", n.hot ? "text-accent" : "text-fg")}>{n.count}{n.more ? "+" : ""}</span>
                      <span className="mt-1.5 text-13 text-fg">{n.label}</span>
                      <span className="mt-1 text-12 font-medium text-accent">{n.action} →</span>
                    </button>
                  ))}
                </div>
              )}
            </section>
          )}

          {latest && (
            <section aria-label="Pick up where you left off" className="mt-8">
              <h2 className="text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Pick up where you left off</h2>
              <Link href={pageHref(latest.id, latest.title)} className="mt-2 flex items-center gap-3 rounded-xl border border-border bg-surface p-4 hover:bg-hover">
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-14 font-semibold text-fg">{displayTitle(latest)}</span>
                  <span className="mt-0.5 block truncate text-12 text-fg-secondary">{latest.summary || "Empty page"}</span>
                  <span className="mt-0.5 block text-11 text-fg-tertiary">{folderOf(latest.path)} · edited {ago(latest.updated_at)}</span>
                </span>
                <Icon name="chevr" size={14} className="flex-none text-accent" />
              </Link>
            </section>
          )}

          <div className="mt-8 flex items-baseline justify-between">
            <h2 className="text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Recent</h2>
            <button onClick={k.openSwitcher} className="text-12 font-medium text-accent hover:underline">
              Find a page
            </button>
          </div>
          <ul className="mt-2">
            {recent.isPending &&
              Array.from({ length: 5 }, (_, i) => (
                <li key={i} className="py-3">
                  <Skeleton className="h-4 w-2/3" />
                </li>
              ))}
            {rest.map((r) => (
              <li key={r.id} className="border-b border-border-row">
                <Link href={pageHref(r.id, r.title)} className="grid grid-cols-[20px_1fr_auto] items-center gap-3 rounded-md px-2 py-2 hover:bg-hover">
                  <Icon name={pageIcon(r)} size={14} className="text-fg-tertiary" />
                  <span className="min-w-0">
                    <span className={cx("block truncate text-14 font-medium", isUntitled(r) ? "italic text-fg-secondary" : "text-fg")}>{displayTitle(r)}</span>
                    <span className="block truncate text-12 text-fg-tertiary">
                      {folderOf(r.path)}
                      {r.summary && !isUntitled(r) ? ` · ${r.summary}` : !r.summary ? " · empty" : ""}
                    </span>
                  </span>
                  <span className="flex items-center gap-1.5 text-12 text-fg-tertiary" title={AUDIENCE[r.audience].label}>
                    <Icon name={AUDIENCE[r.audience].icon} size={12} />
                    <span className="sr-only">{AUDIENCE[r.audience].label} · </span>
                    {ago(r.updated_at)}
                  </span>
                </Link>
              </li>
            ))}
            {recent.data && recent.data.rows.length === 0 && <li className="py-6 text-center text-13 text-fg-tertiary">No pages yet. Capture a thought with ⌥⌘N or import your Obsidian vault from the explorer.</li>}
          </ul>

          <p className="mt-8 text-center text-12 text-fg-tertiary">
            <Kbd>⌘D</Kbd> today · <Kbd>⌘O</Kbd> go to page · <Kbd>⌥⌘N</Kbd> capture · <Kbd>⌥W</Kbd> close tab · <Kbd>⌘J</Kbd> ask a persona
          </p>
        </div>
      </div>
      <StatusBar left={agent ? "Agent knowledge · written by runs" : "Your knowledge · private by default"} right="Online over Tailscale" />
    </>
  );
}

const KIND_DETAIL: Record<PageKind, string> = { document: "Notes, specs, writing", deck: "Slides you present", design: "Flows and diagrams" };

/** One tile per kind: make one now, or open its start page with every one you have. */
function StartRow({ pages }: { pages?: PageRow[] }) {
  const router = useRouter();
  const doc = useCreatePage();
  const deck = useNewDeck();
  const design = useCreateDesign();
  const failed = (what: string) => (e: Error) => toast({ id: `new-${what}`, tone: "error", title: `Couldn’t make the ${what}`, description: e.message });
  const make: Record<PageKind, () => void> = {
    document: () => doc.mutate({ title: "Untitled", body_md: "" }, { onSuccess: (p) => router.push(pageHref(p.id, p.title)), onError: failed("document") }),
    deck: () => deck.start(),
    design: () => design.mutate({ starter: "blank", title: "" }, { onSuccess: (d) => router.push(`/apps/designs/${d.id}`), onError: failed("design") }),
  };
  const busy = doc.isPending || deck.pending || design.isPending;
  return (
    <section aria-label="Start" className="mt-8">
      <h2 className="text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Start</h2>
      <div className="mt-2 grid gap-2.5 sm:grid-cols-3">
        {KINDS.map(({ kind, label, plural }) => {
          const count = pages?.filter((p) => (p.kind ?? "document") === kind).length;
          return (
            <div key={kind} className="flex flex-col rounded-xl border border-border bg-surface p-3.5">
              <Link href={kindHref(kind)} className="flex items-start gap-2.5 rounded-md hover:opacity-90">
                <Icon name={pageIcon({ kind })} size={18} className="mt-0.5 text-fg-secondary" />
                <span className="min-w-0">
                  <span className="block text-14 font-semibold text-fg">{label}</span>
                  <span className="block truncate text-12 text-fg-secondary">{KIND_DETAIL[kind]}</span>
                </span>
              </Link>
              <span className="mt-3 flex items-center gap-3 text-12">
                <button type="button" disabled={busy} onClick={make[kind]} className="font-medium text-accent hover:underline disabled:opacity-50">
                  + New
                </button>
                <Link href={kindHref(kind)} className="text-fg-tertiary hover:text-fg-secondary">
                  All {plural.toLowerCase()}
                  {count !== undefined ? ` · ${count}` : ""} →
                </Link>
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}

const UNTITLED = /^untitled( document)?( [0-9a-z]+)?$/i;
const isUntitled = (r: PageRow) => UNTITLED.test(r.title.trim());
/** An untitled page goes by its first line, so two of them can be told apart. */
const displayTitle = (r: PageRow) => (isUntitled(r) && r.summary ? `Untitled · “${r.summary}”` : r.title);
const folderOf = (path: string) => path.split("/").slice(0, -1).join(" / ") || "Top level";
