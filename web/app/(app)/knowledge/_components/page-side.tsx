"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { cx } from "@/lib/cx";
import { ago, isoDay, monthGrid, pageHref } from "@/lib/knowledge";
import { useDaily, useFileCapture, usePages } from "@/lib/api/knowledge-hooks";
import { Button } from "@/components/ui/button";
import { Icon, type IconName } from "@/components/ui/icon";
import { SideHeading, useToday } from "./kit";

export type SideTab = "links" | "outline" | "calendar" | "history";

/** A page's side panels, Obsidian-style. They are tabs of the Knowledge dock, beside Chat, so a page has one right sidebar. */
export const SIDE_TABS: [SideTab, IconName, string][] = [
  ["links", "link", "Links"],
  ["outline", "epics", "Outline"],
  ["calendar", "clock", "Calendar and inbox"],
  ["history", "history", "History"],
];

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
    <div className="min-h-0 flex-1 overflow-y-auto p-3">
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
