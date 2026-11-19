"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { cx } from "@/lib/cx";
import { ago, isoDay, monthGrid, outline, pageHref } from "@/lib/knowledge";
import { useDaily, useFileCapture, usePageControls, usePages, useRestore, type Page } from "@/lib/api/knowledge-hooks";
import { Button } from "@/components/ui/button";
import { Icon, type IconName } from "@/components/ui/icon";
import { BacklinksPanel } from "@/components/domain/backlinks";
import { LocalGraph } from "@/components/domain/local-graph";
import { SideHeading, useToday } from "./kit";

export type SideTab = "links" | "outline" | "calendar" | "history";

/** A page's side panels, Obsidian-style. They are tabs of the Knowledge dock, beside Chat, so a page has one right sidebar. */
export const SIDE_TABS: [SideTab, IconName, string][] = [
  ["links", "link", "Links"],
  ["outline", "epics", "Outline"],
  ["calendar", "clock", "Calendar and inbox"],
  ["history", "history", "History"],
];

export function SidePanel({ page, tab, persona }: { page: Page; tab: SideTab; persona: string }) {
  return (
    <div className="min-h-0 flex-1 overflow-y-auto p-3">
      {tab === "links" && <LinksPanel page={page} />}
      {tab === "outline" && <OutlinePanel body={page.body_md ?? ""} />}
      {tab === "calendar" && <CalendarPanel />}
      {tab === "history" && <HistoryPanel page={page} persona={persona} />}
    </div>
  );
}

function LinksPanel({ page }: { page: Page }) {
  return (
    <div className="space-y-5">
      <BacklinksPanel kind="artifact" id={page.id} compact />
      <div>
        <SideHeading>Local graph</SideHeading>
        <div className="h-[240px] overflow-hidden rounded-lg border border-border-subtle bg-surface-sunken">
          <LocalGraph kind="artifact" id={page.id} />
        </div>
      </div>
    </div>
  );
}

function OutlinePanel({ body }: { body: string }) {
  const heads = useMemo(() => outline(body), [body]);
  if (!heads.length) return <p className="px-1 text-12 text-fg-tertiary">No headings yet. Start a line with # to add one.</p>;
  const jump = (text: string) => {
    const el = [...document.querySelectorAll<HTMLElement>(".ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror h4, .ProseMirror h5, .ProseMirror h6")].find((h) => h.textContent?.trim() === text);
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  const top = Math.min(...heads.map((h) => h.level));
  return (
    <>
      <SideHeading>Outline</SideHeading>
      <ul className="space-y-0.5">
        {heads.map((h, i) => (
          <li key={i}>
            <button onClick={() => jump(h.text)} style={{ paddingLeft: 8 + (h.level - top) * 14 }} className="w-full truncate rounded-md py-1 pr-2 text-left text-13 text-fg-secondary hover:bg-hover hover:text-fg">
              {h.text}
            </button>
          </li>
        ))}
      </ul>
    </>
  );
}

const DAY_NAMES = ["M", "T", "W", "T", "F", "S", "S"];

/** A month of daily notes, and the inbox to file from: the Calendar plugin and the capture inbox in one. */
export function CalendarPanel({ onNavigate }: { onNavigate?: (path: string) => void } = {}) {
  const router = useRouter();
  const today = useToday() ?? new Date(0);
  const [picked, setMonth] = useState<{ y: number; m: number }>();
  const month = picked ?? { y: today.getFullYear(), m: today.getMonth() };
  const daily = useDaily();
  const notes = usePages({ folder: "Daily", limit: 200 });
  const have = useMemo(() => new Set((notes.data?.rows ?? []).map((r) => r.title)), [notes.data]);
  const weeks = monthGrid(month.y, month.m);
  const dayKey = (d: number) => isoDay(new Date(month.y, month.m, d));
  const shift = (n: number) => setMonth({ y: month.m + n < 0 ? month.y - 1 : month.m + n > 11 ? month.y + 1 : month.y, m: (month.m + n + 12) % 12 });
  return (
    <div>
      <div className="flex items-center px-1 pb-2">
        <span className="flex-1 text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">
          {new Date(month.y, month.m).toLocaleDateString("en", { month: "long", year: "numeric" })}
        </span>
        <button aria-label="Previous month" onClick={() => shift(-1)} className="grid size-6 place-items-center rounded text-fg-tertiary hover:bg-hover">
          <Icon name="chevr" size={12} className="rotate-180" />
        </button>
        <button aria-label="Next month" onClick={() => shift(1)} className="grid size-6 place-items-center rounded text-fg-tertiary hover:bg-hover">
          <Icon name="chevr" size={12} />
        </button>
      </div>
      <div role="grid" aria-label="Daily notes" className="grid grid-cols-7 gap-y-1 text-center">
        {DAY_NAMES.map((d, i) => (
          <span key={i} className="pb-1 text-11 font-semibold text-fg-tertiary">
            {d}
          </span>
        ))}
        {weeks.flat().map((d, i) => {
          if (!d) return <span key={i} />;
          const key = dayKey(d);
          const isToday = key === isoDay(today);
          return (
            <button
              key={i}
              aria-label={key}
              onClick={() =>
                daily.mutate(
                  { date: key },
                  {
                    onSuccess: (p) => {
                      const href = pageHref(p.id, p.title);
                      if (onNavigate) onNavigate(href);
                      else router.push(href);
                    },
                  },
                )
              }
              className={cx("relative mx-auto grid h-8 w-9 place-items-center rounded-lg text-13", isToday ? "bg-accent font-semibold text-on-accent" : "text-fg-2 hover:bg-hover")}
            >
              {d}
              {have.has(key) && !isToday && <span className="absolute bottom-1 size-1 rounded-full bg-accent" />}
            </button>
          );
        })}
      </div>
      <div className="my-4 h-px bg-border-subtle" />
      <InboxPanel />
    </div>
  );
}

function InboxPanel() {
  const inbox = usePages({ folder: "Inbox", limit: 20 });
  const rows = inbox.data?.rows ?? [];
  return (
    <>
      <SideHeading count={rows.length}>Inbox</SideHeading>
      {!rows.length && <p className="px-1 text-12 text-fg-tertiary">Nothing to file. Capture with ⌥⌘N.</p>}
      <ul className="space-y-2">
        {rows.map((r) => (
          <InboxItem key={r.id} id={r.id} title={r.title} when={r.updated_at} />
        ))}
      </ul>
    </>
  );
}

function InboxItem({ id, title, when }: { id: string; title: string; when: string }) {
  const file = useFileCapture(id);
  const [mode, setMode] = useState<"file" | "merge">();
  const [value, setValue] = useState("");
  const matches = usePages({ text: value || undefined, limit: 5 }, mode === "merge" && value.length > 1);
  return (
    <li className="rounded-xl border border-border-subtle bg-surface p-3">
      <Link href={pageHref(id, title)} className="block text-13 font-medium text-fg hover:underline">
        {title}
      </Link>
      <p className="mt-0.5 text-11 text-fg-tertiary">{ago(when)}</p>
      {!mode ? (
        <div className="mt-2 flex gap-1.5">
          <Button className="h-[26px] text-12" onClick={() => setMode("file")}>
            File into…
          </Button>
          <Button className="h-[26px] text-12" onClick={() => setMode("merge")}>
            Merge into…
          </Button>
        </div>
      ) : (
        <div className="mt-2">
          <input
            autoFocus
            value={value}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") setMode(undefined);
              if (e.key === "Enter" && mode === "file" && value.trim()) file.mutate({ folder: value.trim().replace(/^\/+|\/+$/g, "") });
            }}
            placeholder={mode === "file" ? "Folder, e.g. Campaign/NPCs" : "Page to add it to"}
            aria-label={mode === "file" ? "Folder" : "Page"}
            className="h-7 w-full rounded-md border border-border-strong bg-surface-sunken px-2 text-12 text-fg outline-none focus:border-accent"
          />
          {mode === "merge" &&
            matches.data?.rows
              .filter((r) => r.id !== id)
              .map((r) => (
                <button key={r.id} onClick={() => file.mutate({ merge: r.id })} className="mt-1 block w-full truncate rounded px-2 py-1 text-left text-12 text-fg-2 hover:bg-hover">
                  {r.title} <span className="text-fg-tertiary">{r.path.split("/").slice(0, -1).join("/")}</span>
                </button>
              ))}
          {file.error && <p className="mt-1 text-11 text-state-blocked">{file.error.message}</p>}
        </div>
      )}
    </li>
  );
}

function HistoryPanel({ page, persona }: { page: Page; persona: string }) {
  const controls = usePageControls(page.id);
  const restore = useRestore(page.id);
  const mode = page.paused ? "paused" : page.direct ? "direct" : "suggest";
  const set = (m: "direct" | "suggest" | "paused") => controls.mutate({ direct: m === "direct" || (m === "paused" && page.direct), paused: m === "paused" });
  const versions = [...page.versions].sort((a, b) => b.seq - a.seq);
  return (
    <>
      <SideHeading>History</SideHeading>
      <div className="mb-4 rounded-xl border border-border-subtle bg-surface p-3">
        <p className="text-12 font-semibold text-fg">Persona edits on this page</p>
        <div role="radiogroup" aria-label="Persona edits" className="mt-2 flex h-7 rounded-md border border-border-subtle bg-surface-sunken p-0.5">
          {(
            [
              ["direct", "Direct"],
              ["suggest", "Suggest"],
              ["paused", "Paused"],
            ] as const
          ).map(([m, label]) => (
            <button key={m} role="radio" aria-checked={mode === m} disabled={controls.isPending} onClick={() => set(m)} className={cx("flex-1 rounded text-12 font-medium", mode === m ? "bg-selected text-fg" : "text-fg-tertiary hover:text-fg-secondary")}>
              {label}
            </button>
          ))}
        </div>
        <p className="mt-2 text-11 leading-relaxed text-fg-tertiary">
          {mode === "direct" ? "Changes apply at once; you review them afterwards." : mode === "suggest" ? "Nothing changes until you accept it." : "Persona writes are refused."}
        </p>
      </div>
      <ul>
        {versions.map((v) => {
          const current = v.id === page.version_id;
          const who = v.author_type === "user" ? "You" : persona;
          return (
            <li key={v.id} className="flex items-start gap-3 border-b border-border-row py-2.5">
              <span className={cx("mt-0.5 grid size-6 flex-none place-items-center rounded-full text-11 font-bold", v.author_type === "user" ? "bg-[#3B3260] text-fg" : "bg-[#3FC1B033] text-[#3FC1B0]")}>{who[0]}</span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-13 font-medium text-fg">{v.note || v.label}</span>
                <span className="block text-11 text-fg-tertiary">
                  {who} · {ago(v.created_at)}
                </span>
              </span>
              {current ? (
                <span className="rounded-full bg-[#4CB7821F] px-2 py-0.5 text-10 font-semibold text-state-done">Current</span>
              ) : (
                <button onClick={() => restore.mutate(v.id)} disabled={restore.isPending} className="text-12 font-medium text-accent hover:underline">
                  Restore
                </button>
              )}
            </li>
          );
        })}
      </ul>
      {(restore.error || controls.error) && <p className="mt-2 text-12 text-state-blocked">{(restore.error ?? controls.error)?.message}</p>}
    </>
  );
}
