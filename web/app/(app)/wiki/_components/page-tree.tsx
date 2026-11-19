"use client";

import { useCallback, useMemo, useSyncExternalStore } from "react";
import type { WikiPageSummary } from "@/lib/api/client";
import { useArtifacts } from "@/lib/api/hooks";
import { ancestors, buildTree } from "@/lib/wiki";
import { findNavItem } from "@/lib/native-shell/nav-model";
import { buildWikiNavModel } from "@/lib/native-shell/models/wiki";
import type { NativeCommand } from "@/lib/native-shell/protocol";

/** Which wiki index is showing, for highlighting its tree row. */
export type WikiIndex = "patterns" | "adrs";

// ------------------------------------------------------------ open state

const OPEN_KEY = "lazyagents.wiki.open";
const OPEN_CHANGED = "lazyagents:wiki-open";
// Fallback when storage is unavailable (private mode), so toggles still apply until reload.
let openFallback = "[]";

function subscribeOpen(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(OPEN_CHANGED, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(OPEN_CHANGED, onChange);
  };
}

function readOpen(): string {
  try {
    return window.localStorage.getItem(OPEN_KEY) ?? openFallback;
  } catch {
    return openFallback;
  }
}

/** Open folders, saved per device. Keys are lowercased folder paths (or a namespace id). */
function useOpenFolders() {
  const raw = useSyncExternalStore(subscribeOpen, readOpen, () => "[]");
  const open = useMemo(() => {
    try {
      const v: unknown = JSON.parse(raw);
      return new Set(Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
    } catch {
      return new Set<string>();
    }
  }, [raw]);
  const toggle = useCallback(
    (key: string, next: boolean) => {
      const s = new Set(open);
      if (next) s.add(key);
      else s.delete(key);
      openFallback = JSON.stringify([...s]);
      try {
        window.localStorage.setItem(OPEN_KEY, openFallback);
      } catch {
        // Storage unavailable: openFallback keeps it for this page.
      }
      window.dispatchEvent(new Event(OPEN_CHANGED));
    },
    [open],
  );
  return { open, toggle };
}

function splitPages(pages: WikiPageSummary[] | undefined) {
  const published = (pages ?? []).filter((p) => p.published);
  const isMemory = (p: WikiPageSummary) => p.path.toLowerCase().startsWith("agents/");
  return { team: buildTree(published.filter((p) => !isMemory(p))), memory: buildTree(published.filter(isMemory), "agents/") };
}

function forcedFolders(current: string, index?: WikiIndex) {
  const s = new Set(current ? ancestors(current) : []);
  if (index === "patterns") s.add("patterns");
  if (index === "adrs") s.add("architecture");
  return s;
}

/** The wiki tree for the native sidebar: the same folders, open state and Reports as <PageTree>, and the commands the shell sends. */
export function useWikiNative(pages: WikiPageSummary[] | undefined, current: string, index?: WikiIndex) {
  const { open, toggle } = useOpenFolders();
  const { team, memory } = useMemo(() => splitPages(pages), [pages]);
  const forced = useMemo(() => forcedFolders(current, index), [current, index]);
  const reports = useArtifacts({ type: "report" });
  const list = reports.data?.artifacts ?? [];
  const other = { ...team, folders: new Map([...team.folders].filter(([k]) => k !== "architecture" && k !== "patterns")) };
  const model = buildWikiNavModel({
    loaded: !!pages,
    current,
    index,
    architecture: team.folders.get("architecture"),
    patterns: team.folders.get("patterns"),
    memory,
    other,
    reports: { state: reports.isError ? "error" : !reports.data ? "loading" : "ready", list, total: reports.data?.counts.report ?? list.length },
    open,
    forced,
  });
  const onCommand = (cmd: NativeCommand) => {
    if (cmd.type !== "nav.toggle" && cmd.type !== "nav.activate") return;
    if (!cmd.itemId.startsWith("f:")) return;
    const key = cmd.itemId.slice(2);
    if (forced.has(key)) return;
    // A folder row without a page toggles on click, as in the page.
    if (cmd.type === "nav.toggle") toggle(key, cmd.expanded);
    else if (!findNavItem(model, cmd.itemId)?.href) toggle(key, !open.has(key));
  };
  return { model, onCommand };
}
