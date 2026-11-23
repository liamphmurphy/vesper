// Which of a chat's side panels are open, in the URL (components: app/(app)/chat/_components/chat-panel-host).
// The params are the ones use-canvas-panel and use-playground-panel already read and write, so
// links and reloads behave as before; `panel` only picks which open panel a sheet shows.
// Kept free of React so `npm run test:unit` covers it.

export type ChatPanel = "design" | "canvas" | "playground" | "code";

/** How the host lays its panels out: beside the chat (desktop) or as one full-height sheet with a switch (compact). */
export type PanelLayout = "side" | "sheet";

export const PANELS: ChatPanel[] = ["design", "canvas", "playground", "code"];

/** A tab in the desktop dock: the open panels, a thread or linked item while one is open, Outline, and Activity. */
export type DockTabId = ChatPanel | "thread" | "item" | "outline" | "activity";

type Query = Pick<URLSearchParams, "get">;

/** The panels open now, in switch order. `designIds` are the chat's designs: a canvas focus on one of them opens the design panel. */
export function openPanels(q: Query, designIds: readonly string[]): ChatPanel[] {
  const focus = q.get("canvas");
  // "full" shows the canvas as a panel (the dock, or the compact sheet); "max" takes it over the window.
  const full = q.get("canvas_view") === "full" || q.get("canvas_view") === "max";
  const pg = q.get("playground");
  const code = q.get("code");
  const open: ChatPanel[] = [];
  if (!full && focus && focus !== "none" && designIds.includes(focus)) open.push("design");
  if (full) open.push("canvas");
  if (pg === "open" || pg === "full") open.push("playground");
  if (code === "open" || code === "full") open.push("code");
  return open;
}

/** Whether the Code panel is expanded to fullscreen (`code=full`). */
export function codeFullscreen(q: Query): boolean {
  return q.get("code") === "full";
}

/** Query with Code open in fullscreen. */
export function openCodeFullscreen(q: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("code", "full");
  next.set("panel", "code");
  next.delete("sheet");
  return next;
}

/** Query exiting Code fullscreen back to the docked/sheet panel. */
export function exitCodeFullscreen(q: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("code", "open");
  return next;
}

/** The one panel a sheet shows: the one switched to, if it's still open, else the frontmost (a fullscreen canvas, then the playground, then the code, then a design). */
export function activePanel(q: Query, open: readonly ChatPanel[]): ChatPanel | undefined {
  const picked = q.get("panel") as ChatPanel | null;
  if (picked && open.includes(picked)) return picked;
  return (["canvas", "playground", "code", "design"] as const).find((p) => open.includes(p));
}

/** The query that shows `panel`, opening it if it's closed. A design needs the id to open; without one the query is unchanged. */
export function switchPanel(q: URLSearchParams, panel: ChatPanel, opts: { designId?: string } = {}): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  if (panel === "design") {
    if (!opts.designId) return next;
    next.set("canvas", opts.designId);
    next.delete("canvas_view");
  } else if (panel === "canvas") {
    next.set("canvas_view", "full");
  } else if (panel === "code") {
    next.set("code", next.get("code") === "full" ? "full" : "open");
  } else if (next.get("playground") !== "open" && next.get("playground") !== "full") {
    next.set("playground", "open");
  }
  next.set("panel", panel);
  next.delete("sheet");
  return next;
}

/** Whether the compact sheet is dismissed: back to the chat with its panels still open, until a switch shows it again. */
export function sheetHidden(q: Query): boolean {
  return q.get("sheet") === "hidden";
}

/** The query with the compact sheet dismissed; switchPanel shows it again. */
export function hideSheet(q: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("sheet", "hidden");
  return next;
}

/** The query with `panel` closed; the others stay as they were. */
export function closePanel(q: URLSearchParams, panel: ChatPanel): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  if (panel === "design") next.set("canvas", "none");
  else if (panel === "canvas") next.delete("canvas_view");
  else if (panel === "code") next.delete("code");
  else {
    next.delete("playground");
    next.delete("playground_tab");
  }
  if (next.get("panel") === panel) next.delete("panel");
  return next;
}

/** The tab the desktop dock shows: the one picked (Activity, persistent Code, or a panel still open), else the frontmost open panel, else Activity. */
export function dockTab(q: Query, open: readonly ChatPanel[], opts: { hasCode?: boolean } = {}): DockTabId {
  if (q.get("panel") === "activity") return "activity";
  if (q.get("panel") === "code" && (opts.hasCode || open.includes("code"))) return "code";
  if (q.get("panel") === "thread" && q.get("thread")) return "thread";
  if (q.get("panel") === "item" && itemOf(q)) return "item";
  return activePanel(q, open) ?? "activity";
}

/**
 * Whether the desktop dock is open or collapsed to its rail: `dock=1` / `dock=0` once the person
 * chose, else open while a panel (or Activity / persistent Code) is picked or open, so a chat with nothing open starts on the rail.
 */
export function dockOpen(q: Query, open: readonly ChatPanel[], opts: { hasCode?: boolean } = {}): boolean {
  const d = q.get("dock");
  if (d === "0") return false;
  if (d === "1") return true;
  return (
    open.length > 0 ||
    q.get("panel") === "activity" ||
    (q.get("panel") === "code" && !!opts.hasCode) ||
    (q.get("panel") === "thread" && !!q.get("thread")) ||
    (q.get("panel") === "item" && !!itemOf(q))
  );
}

/** The message whose thread the dock shows, if one is open. */
export function threadOf(q: Query): string | undefined {
  return q.get("thread") || undefined;
}

/** The query showing the thread about `messageId` in the dock, open. */
export function openThread(q: URLSearchParams, messageId: string): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("thread", messageId);
  next.set("panel", "thread");
  next.set("dock", "1");
  return next;
}

/** The query with the thread closed; the dock falls back to the other tabs. */
export function closeThread(q: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.delete("thread");
  if (next.get("panel") === "thread") next.delete("panel");
  return next;
}

/** The query showing the dock on `tab` (which must already be open), open or collapsed. */
export function setDock(q: URLSearchParams, s: { tab: DockTabId; open: boolean }): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("panel", s.tab);
  next.set("dock", s.open ? "1" : "0");
  return next;
}

/**
 * Whether a drag down on the sheet's grabber, released `dy` px below where it started after `ms`,
 * closes the sheet: past a quarter of its height (at least 120px), or a quick flick of 40px or more.
 */
export function dragCloses(dy: number, ms: number, height: number): boolean {
  if (dy >= Math.max(120, height / 4)) return true;
  return dy >= 40 && dy / Math.max(ms, 1) > 0.5;
}

/** The threads a Comments button counts: top-level comments that aren't resolved (replies don't count). */
export function openThreads(comments: readonly { status: string; parent_id?: string | null }[] | undefined): number {
  return (comments ?? []).filter((c) => !c.parent_id && c.status !== "resolved").length;
}

/** Something a chat links to that opens beside it in the dock: a ticket, a run or a Knowledge page. */
export type LinkedItem = { kind: "ticket"; key: string } | { kind: "run"; id: string } | { kind: "page"; id: string };

/** The item as the `item` param: "ticket:WEB-42", "run:<id>", "page:<id>". */
export function itemParam(i: LinkedItem): string {
  return i.kind === "ticket" ? `ticket:${i.key}` : `${i.kind}:${i.id}`;
}

/** The linked item the dock shows, if the URL names a valid one. */
export function itemOf(q: Query): LinkedItem | undefined {
  const m = /^(ticket|run|page):(.+)$/.exec(q.get("item") ?? "");
  if (!m) return undefined;
  const [, kind, ref] = m;
  if (kind === "ticket") return /^[A-Z][A-Z0-9]*-\d+$/.test(ref) ? { kind, key: ref } : undefined;
  return /^[0-9a-f-]{36}$/i.test(ref) ? { kind: kind as "run" | "page", id: ref } : undefined;
}

/** The query showing `item` beside the chat, in an open dock. */
export function openItem(q: URLSearchParams, item: LinkedItem): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.set("item", itemParam(item));
  next.set("panel", "item");
  next.set("dock", "1");
  return next;
}

/** The query with the linked item closed; the dock falls back to the other tabs. */
export function closeItem(q: URLSearchParams): URLSearchParams {
  const next = new URLSearchParams(q.toString());
  next.delete("item");
  if (next.get("panel") === "item") next.delete("panel");
  return next;
}

/**
 * What a chat links to, for the row under its header: the tickets and pages its messages carried
 * as context, then its ticket runs, each once, newest message's first.
 */
export function linkedItems(refs: readonly { kind: string; id?: string; key?: string }[], runs: readonly { run_id: string }[]): LinkedItem[] {
  const out: LinkedItem[] = [];
  const add = (i: LinkedItem) => {
    if (!out.some((o) => itemParam(o) === itemParam(i))) out.push(i);
  };
  for (const r of [...refs].reverse()) {
    if (r.kind === "ticket" && r.key) add({ kind: "ticket", key: r.key });
    else if (r.kind === "page" && r.id) add({ kind: "page", id: r.id });
  }
  for (const r of runs) add({ kind: "run", id: r.run_id });
  return out;
}
