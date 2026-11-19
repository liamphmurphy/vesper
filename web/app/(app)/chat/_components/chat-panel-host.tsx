"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react";
import { useChatCanvases } from "@/lib/api/canvas-hooks";
import { useCanStartSavedPlayground, useChatPlayground, usePlaygroundAction } from "@/lib/api/playground-hooks";
import { useDesignProposals } from "@/lib/api/designs-hooks";
import { useChat, useChatMessages, useChatModels, useChatRunEvents, useCosts, useRunLog, useTicket } from "@/lib/api/hooks";
import { usePage } from "@/lib/api/knowledge-hooks";
import { closeItem, closeThread, itemOf, itemParam, dockOpen, dockTab, openPanels, setDock, threadOf, type ChatPanel, type DockTabId } from "@/lib/chat-panels";
import { toolCalls, turnWindows } from "@/lib/chat-ui";
import { spendLabel } from "@/lib/costs";
import { pageHref } from "@/lib/knowledge";
import { presenceOf } from "@/lib/designs/presence";
import { claimReadingFocus, dockReducer, dockShortcut, type DockAction, type DockState } from "@/lib/editor-layout";
import { CompanionPortal } from "@/components/shell/companion";
import { Dock, type DockTab, type NativeDockTab } from "@/components/shell/editor-layout";
import { ItemPanel } from "./item-panel";
import { useCanvasPanel } from "@/lib/use-canvas-panel";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { buildChatActivitySections, buildChatItemSections, type ChatTurnSummary } from "@/lib/native-shell/models/chat-inspector";
import { usePlaygroundPanel } from "@/lib/use-playground-panel";
import { toast } from "@/lib/toast";
import { type IconName } from "@/components/ui/icon";
import { CanvasDock, CanvasFullscreen } from "@/components/domain/canvas-view";
import { PlaygroundFullscreen, PlaygroundPanel } from "@/components/domain/playground";
import { STATUS_NAME, PRIORITY_NAME } from "@/components/domain/meta";
import { runTitle } from "@/lib/run-list";
import { useCodeReview } from "@/lib/api/code-review-hooks";
import { CodePanel } from "./code-panel";
import { DesignPanel, useOpenNewDesigns } from "./design-panel";
import { effortLabel, modelLabel } from "./model-picker";
import { ThreadPanel } from "./thread-panel";

const LABELS: Record<DockTabId, string> = { design: "Design", canvas: "Canvas", playground: "Playground", code: "Code", thread: "Thread", item: "Linked", activity: "Activity" };

/**
 * A chat's panels: the design, canvas and playground, in the shared dock
 * (components/shell/editor-layout) beside the conversation, one tab each, with Activity
 * always there too ("Chat: side panels in the shared dock"); the canvas and playground can still
 * go fullscreen from their tab. Key it by chat.
 */
export function ChatPanelHost({ chatId, live, readOnly, agent, activity }: { chatId: string; live: boolean; readOnly: boolean; agent: string; activity: ReactNode }) {
  useOpenNewDesigns(chatId, live);
  return <ChatDock chatId={chatId} live={live} readOnly={readOnly} agent={agent} activity={activity} />;
}

const ICONS: Record<DockTabId, IconName> = { design: "designs", canvas: "artifacts", playground: "playLeft", code: "code", thread: "branch", item: "link", activity: "history" };

/**
 * Which tabs changed since they last showed: a tab is unread once its `sig` moves on from what it
 * was the last time it was the visible tab (or when the chat opened).
 */
function useUnread(sigs: Partial<Record<DockTabId, string>>, visible: DockTabId | undefined): Set<DockTabId> {
  const [seen, setSeen] = useState<Partial<Record<DockTabId, string>>>(sigs);
  const unread = new Set<DockTabId>();
  for (const [t, sig] of Object.entries(sigs) as [DockTabId, string | undefined][]) {
    if (sig === undefined) continue;
    if (t === visible || seen[t] === undefined) {
      if (seen[t] !== sig) setSeen((s) => ({ ...s, [t]: sig }));
    } else if (seen[t] !== sig) unread.add(t);
  }
  return unread;
}

/** The desktop dock: its tab and open/collapsed state live in the URL (lib/chat-panels), ⌘. only for the visit. */
function ChatDock({ chatId, live, readOnly, agent, activity }: { chatId: string; live: boolean; readOnly: boolean; agent: string; activity: ReactNode }) {
  const uid = useId();
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const canvasPanel = useCanvasPanel();
  const canvases = useChatCanvases(chatId, live).data?.canvases;
  const pg = useChatPlayground(chatId).data;
  const chat = useChat(chatId).data;
  const code = useCodeReview(chatId).data?.repositories;
  const hasCodeTab = !!chat?.repo_url || (code?.length ?? 0) > 0;
  const designIds = (canvases ?? []).filter((c) => c.kind === "design").map((c) => c.id);
  const open = openPanels(search, designIds);
  const [hidden, setHidden] = useState(false);
  const state: DockState = { open: dockOpen(search, open, { hasCode: hasCodeTab }), tab: dockTab(search, open, { hasCode: hasCodeTab }), hidden };
  const go = (q: URLSearchParams) => router.replace(`${pathname}?${q.toString()}`, { scroll: false });

  // ⌘. hides the Vesper sidebar along with the dock, without writing its preference.
  useEffect(() => (hidden ? claimReadingFocus() : undefined), [hidden]);

  const latest = useRef({ state, search });
  useEffect(() => {
    latest.current = { state, search };
  });
  const dispatch = useCallback(
    (a: DockAction) => {
      const { state: s, search: q } = latest.current;
      const next = dockReducer(s, a);
      // A second key before the URL update renders works from this state, not the old one.
      latest.current = { ...latest.current, state: next };
      if (next.hidden !== s.hidden) setHidden(next.hidden);
      if (next.open !== s.open || next.tab !== s.tab) go(setDock(new URLSearchParams(q.toString()), { tab: next.tab as DockTabId, open: next.open }));
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reads the latest state through the ref
    [pathname],
  );

  // A panel opening (a card's Open, a design the persona starts, a new playground) opens the dock on it.
  // Not before the chat's canvases load: a design in the URL only counts as open then, and a
  // reload must keep the dock as the URL left it.
  const key = open.join(",");
  const ready = !!canvases;
  const seen = useRef<ChatPanel[] | null>(null);
  useEffect(() => {
    if (!ready) return;
    const before = seen.current;
    seen.current = open;
    const opened = before ? open.filter((p) => !before.includes(p)) : [];
    if (!opened.length) return;
    setHidden(false);
    go(setDock(new URLSearchParams(search.toString()), { tab: opened.at(-1)!, open: true }));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs when the set of open panels changes
  }, [key, ready]);

  // ⌘\ collapses or reopens the dock and ⌘. hides or restores it with the sidebar. The composer
  // usually has focus in a chat, so they apply while typing too. ⌘J doesn't: the composer is always there.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const action = dockShortcut(e, false);
      if (action !== "toggle" && action !== "hideAll") return;
      e.preventDefault();
      dispatch({ type: action === "toggle" ? "toggle" : "toggleHidden" });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dispatch]);

  // Busy: the persona editing the open design, the playground starting or restarting, a turn running.
  const designId = open.includes("design") ? canvasPanel.focus : undefined;
  const events = useChatRunEvents(chat?.current_run_id, live && !!designId).data;
  const designBusy = useMemo(() => !!designId && live && !!presenceOf(toolCalls(events), designId, true)?.busy, [designId, live, events]);
  const pgBusy = !!pg && (pg.state === "starting" || !!pg.action);
  // The open design's suggestions waiting for review, as a count on its tab (its header's Review opens them).
  const pending = useDesignProposals(designId ?? "", !!designId).data?.length ?? 0;

  const sigOf = (id?: string) => {
    const c = id ? canvases?.find((x) => x.id === id) : undefined;
    return c && `${c.seq}:${c.updated_at}`;
  };
  const canvasId = canvasPanel.focus ?? canvases?.at(-1)?.id;
  const unread = useUnread(
    {
      design: open.includes("design") ? sigOf(designId) : undefined,
      canvas: open.includes("canvas") ? sigOf(canvasId) : undefined,
      playground: pg && open.includes("playground") ? `${pg.state}:${pg.action ?? ""}:${pg.data_reset_at ?? ""}` : undefined,
      code: code && hasCodeTab ? code.map((r) => `${r.head_sha}:${r.updated_at}`).join(",") : undefined,
      activity: chat ? `${chat.state}:${chat.current_run_id ?? ""}` : undefined,
    },
    state.open && !hidden ? (state.tab as DockTabId) : undefined,
  );

  const isNative = useIsNativeShell();
  const thread = threadOf(search);
  const item = itemOf(search);
  const messagesQuery = useChatMessages(isNative ? chatId : undefined, 200);
  const modelsQuery = useChatModels();
  const chatCosts = useCosts({ chat: chatId }, isNative);
  const itemTicket = useTicket(isNative && item?.kind === "ticket" ? item.key : "");
  const itemRun = useRunLog(isNative && item?.kind === "run" ? item.id : "");
  const itemPage = usePage(isNative && item?.kind === "page" ? item.id : undefined);

  const activityNative = useMemo<NativeDockTab | undefined>(() => {
    if (!isNative || !chat) return undefined;
    const msgList = messagesQuery.data?.messages;
    const groups = modelsQuery.data;
    const current = { harness: chat.harness, model: chat.model, auto: !!chat.auto_model };
    const ml = modelLabel(groups, current);
    const turnsMap = turnWindows(msgList);
    const turnSummaries: ChatTurnSummary[] = [];
    let lastUserPrompt = "";
    for (const m of msgList ?? []) {
      if (m.role === "user") {
        lastUserPrompt = m.body_md;
      } else if (turnsMap.has(m.id)) {
        const promptText = turnsMap.get(m.id)?.followup
          ? "Follow-up: reacting to generated images"
          : lastUserPrompt;
        const trimmed = promptText.length > 90 ? `${promptText.slice(0, 90).trimEnd()}…` : promptText;
        const mLabel = m.harness && m.model ? modelLabel(groups, { harness: m.harness, model: m.model }) : ml;
        turnSummaries.push({
          id: m.id,
          prompt: trimmed || "Reply",
          meta: `${mLabel.harness} · ${mLabel.model}`,
          tone: "done",
        });
      }
    }
    const total = chatCosts.data?.total;
    const costLabel =
      total && total.runs > 0
        ? spendLabel(total.cost_micros, chatCosts.data?.unpriced_runs ?? 0)
        : undefined;
    return {
      kind: "native",
      sections: buildChatActivitySections({
        modelLabel: `${ml.model}${current.auto ? " (auto)" : ""}`,
        harnessLabel: ml.harness,
        effort: chat.effort ? effortLabel(chat.effort) : undefined,
        costLabel,
        running: chat.state === "running",
        turns: turnSummaries.reverse(),
      }),
    };
  }, [isNative, chat, messagesQuery.data?.messages, modelsQuery.data, chatCosts.data]);

  const itemHref = !item
    ? ""
    : item.kind === "ticket"
      ? `/tickets/${encodeURIComponent(item.key)}`
      : item.kind === "run"
        ? `/runs/${encodeURIComponent(item.id)}`
        : pageHref(item.id, itemPage.data?.title);

  const itemNative: NativeDockTab | undefined = !isNative || !item
    ? undefined
    : {
        kind: "native",
        sections: buildChatItemSections(
          item.kind === "ticket"
            ? {
                kind: "ticket",
                key: item.key,
                title: itemTicket.data?.title ?? item.key,
                statusLabel: itemTicket.data ? (STATUS_NAME[itemTicket.data.status] ?? itemTicket.data.status) : "Ticket",
                priorityLabel: itemTicket.data ? (PRIORITY_NAME[itemTicket.data.priority] ?? itemTicket.data.priority) : "",
                assignee: itemTicket.data?.assignee?.name,
                description: itemTicket.data?.description_md,
                criteria: (itemTicket.data?.criteria ?? []).map((c) => ({ id: c.id, text: c.text, done: c.done })),
                href: itemHref,
                loading: itemTicket.isPending,
                error: itemTicket.isError,
              }
            : item.kind === "run"
              ? {
                  kind: "run",
                  id: item.id,
                  title: itemRun.data?.run ? runTitle(itemRun.data.run) : "Run",
                  agent: itemRun.data?.run.agent.name,
                  ticketKey: itemRun.data?.run.ticket_key ?? undefined,
                  stateLabel: itemRun.data?.run.state.replace("_", " "),
                  outcome: itemRun.data?.run.outcome ?? undefined,
                  plan: (itemRun.data?.run.plan ?? []).map((s) => ({ position: s.position, text: s.text, state: s.state })),
                  href: itemHref,
                  loading: itemRun.isPending,
                  error: itemRun.isError,
                }
              : {
                  kind: "page",
                  id: item.id,
                  title: itemPage.data?.title ?? "Page",
                  path: itemPage.data?.path ?? undefined,
                  excerpt: itemPage.data?.body_md ?? undefined,
                  href: itemHref,
                  loading: itemPage.isPending,
                  error: itemPage.isError,
                },
        ),
        onAction: (actionId) => {
          if (actionId === "open_item" && itemHref) router.push(itemHref);
          else if (actionId === "close_item") go(closeItem(new URLSearchParams(search.toString())));
        },
      };

  const content: Record<DockTabId, ReactNode> = {
    item: item && <ItemPanel key={itemParam(item)} item={item} onClose={() => go(closeItem(new URLSearchParams(search.toString())))} />,
    thread: thread && <ThreadPanel key={thread} chatId={chatId} messageId={thread} onClose={() => go(closeThread(new URLSearchParams(search.toString())))} />,
    design: <DesignPanel chatId={chatId} live={live} />,
    canvas: <CanvasDock chatId={chatId} live={live} readOnly={readOnly} agent={agent} />,
    playground: <PlaygroundPanel chatId={chatId} />,
    code: <CodePanel chatId={chatId} />,
    activity,
  };
  const busy: Partial<Record<DockTabId, boolean>> = { design: designBusy, playground: pgBusy, code: !!code?.some((r) => r.live), activity: live };
  // The playground and Code sit together, the playground just above.
  const ids: DockTabId[] = [
    ...open.filter((p) => p !== "playground" && p !== "code"),
    ...(open.includes("playground") ? ["playground" as const] : []),
    ...(hasCodeTab || open.includes("code") ? ["code" as const] : []),
    ...(thread ? ["thread" as const] : []),
    ...(item ? ["item" as const] : []),
    "activity" as const,
  ];
  const tabs: DockTab[] = ids.map((id) => ({
    id,
    label: LABELS[id],
    icon: ICONS[id],
    busy: busy[id],
    unread: unread.has(id),
    badge: id === "design" && pending > 0 ? <span data-testid="design-tab-pending" title={`${pending} to review`} className="rounded-full bg-pill-review-bg px-1.5 text-11 text-pill-review-fg">{pending}</span> : undefined,
    // A design under review needs its canvas and the list of changes side by side.
    wide: id === "design" && canvasPanel.reviewing ? "max" : id !== "activity" && id !== "thread" && id !== "item",
    native: id === "activity" ? activityNative : id === "item" ? itemNative : undefined,
    content: content[id],
  }));
  const start = usePlaygroundStart(chatId);
  if (start) tabs.splice(tabs.findIndex((t) => t.id === "code" || t.id === "thread" || t.id === "item" || t.id === "activity"), 0, start);

  return (
    <>
      <CompanionPortal>
        <Dock uid={uid} tabs={tabs} state={state} dispatch={dispatch} overlay="lg" />
      </CompanionPortal>
      <PlaygroundFullscreen chatId={chatId} />
      {canvasPanel.maximized && open.includes("canvas") ? <CanvasFullscreen chatId={chatId} live={live} readOnly={readOnly} agent={agent} /> : null}
    </>
  );
}

/**
 * The Mac app's playground button on the rail, where the window toolbar had it (the browser keeps
 * the chat header's PlaygroundButton): Start playground while the chat has none but can start the
 * repository's saved one, else Playground to open its closed panel. Null once the panel is open (it is
 * a tab then) or when there is nothing to start.
 */
function usePlaygroundStart(chatId: string): DockTab | null {
  const native = useIsNativeShell();
  const pg = useChatPlayground(chatId).data;
  const canStart = useCanStartSavedPlayground(chatId);
  const act = usePlaygroundAction(chatId);
  const panel = usePlaygroundPanel();
  if (!native || panel.open) return null;
  if (!pg && canStart) {
    return {
      id: "playground",
      label: act.isPending ? "Starting playground…" : "Start playground",
      icon: "playLeft",
      busy: act.isPending,
      content: null,
      run: () => {
        if (act.isPending) return;
        act.mutate("start", { onSuccess: panel.show, onError: (e) => toast({ title: e instanceof Error ? e.message : "Couldn’t start the playground.", tone: "error" }) });
      },
    };
  }
  if (!pg) return null;
  const state = pg.state === "running" ? "" : pg.state === "starting" ? " (starting)" : pg.state === "failed" ? " (failed)" : " (stopped)";
  return { id: "playground", label: `Playground${state}`, icon: "playLeft", busy: pg.state === "starting", content: null, run: panel.show };
}
