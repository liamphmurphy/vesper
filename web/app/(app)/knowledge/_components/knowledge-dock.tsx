"use client";

import { usePathname } from "next/navigation";
import { useCallback, useEffect, useId, useRef, useState } from "react";
import { Conversation, type ConversationContext, type DockStarter, type DockWelcome } from "@/app/(app)/chat/_components/conversation";
import { PersonaAvatar, personaLook, useDockPersona } from "@/app/(app)/chat/_components/persona";
import { Dock, type DockTab, type NativeDockTab } from "@/components/shell/editor-layout";
import { CompanionPortal } from "@/components/shell/companion";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { isTyping } from "@/components/shell/shortcuts";
import { DockChatSwitcher, type DockChatSection } from "@/components/domain/dock-chat-switcher";
import { DockContext, dockContextChip } from "@/components/domain/dock-context";
import { useAddDockChat, useDockChats, type DockScope } from "@/lib/api/dock-hooks";
import { provideChatRefs, useBacklinks, useChat, useCreateChat, useLinkMention } from "@/lib/api/hooks";
import { fetchPage, useAttachChat, usePage, usePageControls, useRestore, type Page } from "@/lib/api/knowledge-hooks";
import { ApiError, type Schemas } from "@/lib/api/client";
import { useQueryClient } from "@tanstack/react-query";
import { ago, outline } from "@/lib/knowledge";
import { buildKnowledgeHistorySections, buildKnowledgeLinksSections, buildKnowledgeOutlineSections } from "@/lib/native-shell/models/knowledge-inspector";
import { KNOWLEDGE_CONTEXT_MARKER, refKey } from "@/lib/chat-context";
import { actOnDock, dockShortcut, loadDock, saveDock, type DockAction, type DockState } from "@/lib/editor-layout";
import { isFolder, useKnowledgeChat, type Attachment, type FolderAttachment, type PageAttachment } from "./chat-context";
import { SIDE_TABS, SidePanel } from "./page-side";

const APP = "knowledge";
// Chat everywhere; a page adds its side panels (Links, Outline, Calendar, History).
const TABS = ["chat", ...SIDE_TABS.map(([t]) => t)];
/** The chat for screens that aren't a page (Home, Graph, Connect). A page's own chat is the one it's attached to. */
const GENERAL_CHAT_KEY = "vesper.knowledge.chat";
/** Where the dock keeps the chats for screens that aren't a page. */
const APP_SCOPE: DockScope = "app:knowledge";

/** The screen a Knowledge address shows when it isn't a page, as the persona is told it. */
function screenOf(pathname: string): string {
  if (pathname.startsWith("/knowledge/graph")) return "Graph";
  if (pathname.startsWith("/knowledge/connect")) return "Connect";
  return "Home";
}

/**
 * The persona chat on the right of every Knowledge screen, on the shared dock: it folds to a rail and starts
 * folded in each new browser tab. On a page it is that page's chat; elsewhere one general Knowledge chat.
 */
export function KnowledgeDock({ pageId }: { pageId?: string }) {
  const { request, panel } = useKnowledgeChat();
  const screen = screenOf(usePathname());
  const uid = useId();
  const page = usePage(pageId).data;
  const [general, setGeneral] = useState<string | null>(null);
  const [state, setState] = useState<DockState>({ open: false, tab: "chat", hidden: false });
  const dispatch = useCallback((a: DockAction) => setState((s) => actOnDock(s, a)), []);
  const [loaded, setLoaded] = useState(false);
  const [focusChat, setFocusChat] = useState(0);

  // Read after mount so the server render matches the first client render.
  const restored = useRef(false);
  useEffect(() => {
    if (restored.current) return;
    restored.current = true;
    // Per tab (sessionStorage), so a new visit starts folded but a reload keeps it as it was. Knowledge
    // doesn't open with the companion's shared state: a new tab of notes starts as a reading space.
    setState(loadDock(window.sessionStorage, APP, TABS, false, null));
    setGeneral(window.localStorage.getItem(GENERAL_CHAT_KEY));
    setLoaded(true);
  }, []);
  useEffect(() => {
    if (loaded) saveDock(window.sessionStorage, APP, state);
  }, [state, loaded]);
  const [seenRequest, setSeenRequest] = useState(request);
  if (request !== seenRequest) {
    setSeenRequest(request);
    dispatch({ type: "open", tab: "chat" });
  }
  const [seenPanel, setSeenPanel] = useState(panel.n);
  if (panel.n !== seenPanel) {
    setSeenPanel(panel.n);
    dispatch({ type: "open", tab: panel.tab });
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const action = dockShortcut(e, isTyping(e.target));
      if (action !== "toggle" && action !== "chat") return;
      e.preventDefault();
      if (action === "toggle") dispatch({ type: "toggle" });
      else {
        dispatch({ type: "open", tab: "chat" });
        setFocusChat((n) => n + 1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dispatch]);

  // ⌘J: once the panel has rendered, focus its composer.
  useEffect(() => {
    if (!focusChat) return;
    const frame = requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-dock-panel="${CSS.escape(`${uid}:chat`)}"] textarea, [data-dock-panel="${CSS.escape(`${uid}:chat`)}"] [contenteditable='true']`)?.focus());
    return () => cancelAnimationFrame(frame);
  }, [focusChat, uid]);

  // The linked chat can be gone (deleted, or an id remembered from another instance): treat it as no chat.
  const linked = pageId ? (page?.chat_id ?? undefined) : (general ?? undefined);
  const linkedChat = useChat(linked);
  const gone = linkedChat.error instanceof ApiError && linkedChat.error.status === 404;
  const chatId = gone ? undefined : linked;
  useEffect(() => {
    if (gone && !pageId && window.localStorage.getItem(GENERAL_CHAT_KEY) === linked) window.localStorage.removeItem(GENERAL_CHAT_KEY);
  }, [gone, pageId, linked]);
  useEffect(() => {
    if (chatId && pageId) return provideChatRefs(chatId, () => [{ kind: "page", id: pageId }]);
  }, [chatId, pageId]);
  const chat = gone ? undefined : linkedChat.data;
  const running = chat?.state === "running";
  const backlinks = useBacklinks("artifact", page?.id);
  const linkMention = useLinkMention();
  const pageControls = usePageControls(page?.id ?? "");
  const restoreVersion = useRestore(page?.id ?? "");

  // A persona can create, move and edit pages during a turn: refresh the explorer and lists when it ends.
  // The open page's own query is left alone so a refetch can't disturb the editor.
  const qc = useQueryClient();
  const wasRunning = useRef(running);
  useEffect(() => {
    if (wasRunning.current && !running) void qc.invalidateQueries({ queryKey: ["knowledge"], predicate: (q) => q.queryKey[1] !== "page" });
    wasRunning.current = running;
  }, [running, qc]);
  const shown = state.open && !state.hidden;

  // A reply that arrived while the chat was out of sight is unread; one there on load, or that arrives while it shows, is read.
  const lastReply = chat?.last_message_at;
  const [seen, setSeen] = useState<{ chat?: string; at?: string }>({});
  if (lastReply && (seen.chat !== chatId || (shown && seen.at !== lastReply))) setSeen({ chat: chatId, at: lastReply });
  const unread = !shown && !!lastReply && seen.chat === chatId && seen.at !== lastReply && !running;

  const personaName = (chat?.speaker ?? chat?.persona)?.name ?? "Persona";
  const nativeSideTab = (p: Page, tab: (typeof SIDE_TABS)[number][0]): NativeDockTab | undefined => {
    if (tab === "outline") {
      return {
        kind: "native",
        sections: buildKnowledgeOutlineSections(outline(p.body_md ?? "")),
        onAction: (actionId, itemId) => {
          if (actionId !== "jump_heading" || !itemId) return;
          const sep = itemId.indexOf(":");
          const text = sep >= 0 ? itemId.slice(sep + 1) : itemId;
          const el = [...document.querySelectorAll<HTMLElement>(".ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror h4, .ProseMirror h5, .ProseMirror h6")].find((h) => h.textContent?.trim() === text);
          el?.scrollIntoView({ behavior: "smooth", block: "start" });
        },
      };
    }
    if (tab === "links") {
      const mapMention = (m: Schemas["Mention"]) => {
        const s = m.source;
        const raw = s.kind === "artifact" && s.artifact_type === "note" ? (s.path ?? s.title) : s.title;
        return {
          id: `${m.source_kind}:${m.source_id}`,
          sourceKind: m.source_kind,
          sourceId: m.source_id,
          title: s.display_id && s.kind !== "agent" ? `${s.display_id} · ${s.kind === "comment" ? "Comment" : raw}` : s.kind === "comment" ? "Comment" : raw,
          href: s.href ?? undefined,
        };
      };
      return {
        kind: "native",
        sections: buildKnowledgeLinksSections({
          linked: (backlinks.data?.linked ?? []).map(mapMention),
          unlinked: (backlinks.data?.unlinked ?? [])
            .filter((m) => m.source_kind === "artifact" || m.source_kind === "ticket")
            .map(mapMention),
          linking: linkMention.isPending,
        }),
        onAction: (actionId, itemId) => {
          if (actionId !== "link_mention" || !itemId) return;
          const sep = itemId.indexOf(":");
          if (sep <= 0) return;
          const sourceKind = itemId.slice(0, sep);
          const sourceId = itemId.slice(sep + 1);
          if (sourceKind === "artifact" || sourceKind === "ticket") {
            linkMention.mutate({ target_kind: "artifact", target_id: p.id, source_kind: sourceKind, source_id: sourceId });
          }
        },
      };
    }
    if (tab === "history") {
      const mode: "direct" | "suggest" | "paused" = p.paused ? "paused" : p.direct ? "direct" : "suggest";
      const versions = [...p.versions].sort((a, b) => b.seq - a.seq);
      return {
        kind: "native",
        sections: buildKnowledgeHistorySections({
          mode,
          versions: versions.map((v) => ({
            id: v.id,
            label: v.note || v.label,
            who: v.author_type === "user" ? "You" : personaName,
            age: ago(v.created_at),
            current: v.id === p.version_id,
          })),
          busy: pageControls.isPending || restoreVersion.isPending,
        }),
        onChange: (fieldId, value) => {
          if (fieldId === "edit_mode" && (value === "direct" || value === "suggest" || value === "paused")) {
            pageControls.mutate({ direct: value === "direct" || (value === "paused" && p.direct), paused: value === "paused" });
          }
        },
        onAction: (actionId, itemId) => {
          if (actionId === "restore_version" && itemId && itemId !== p.version_id) {
            restoreVersion.mutate(itemId);
          }
        },
      };
    }
    return undefined;
  };

  const tabs: DockTab[] = [
    {
      id: "chat",
      label: "Chat",
      icon: "msg",
      avatar: <PersonaAvatar persona={personaLook(chat?.speaker ?? chat?.persona)} size={16} />,
      busy: running,
      unread,
      content: (
        <ChatBody
          key={pageId ?? "general"}
          chatId={chatId}
          page={pageId ? page : undefined}
          screen={pageId ? undefined : screen}
          loadingPage={!!pageId && !page}
          onGeneral={(id) => {
            window.localStorage.setItem(GENERAL_CHAT_KEY, id);
            setGeneral(id);
          }}
        />
      ),
    },
    ...(pageId && page
      ? SIDE_TABS.map(([t, icon, label]): DockTab => ({
          id: t,
          label,
          icon,
          native: nativeSideTab(page, t),
          content: <SidePanel page={page} tab={t} persona={personaName} />,
        }))
      : []),
  ];
  // Hidden below md: the page sidebar and explorer already fill a phone.
  return (
    <div className="hidden md:contents">
      <CompanionPortal>
        <Dock uid={uid} tabs={tabs} state={state} dispatch={dispatch} unmountWhenClosed />
      </CompanionPortal>
    </div>
  );
}

export type KnowledgeChatHost = {
  attachments: Attachment[];
  request: number;
  draftText?: string;
  readDraft?: (id: string) => string | undefined;
  onRemove: (keys: string[]) => void;
  onClaimRequest?: (n: number) => boolean;
  onGeneral: (id: string) => void;
};

export function KnowledgeChatPanel({
  pageId,
  screen,
  chatId,
  loadingPage,
  host,
}: {
  pageId?: string;
  screen?: string;
  chatId?: string;
  loadingPage?: boolean;
  host: KnowledgeChatHost;
}) {
  const pageQuery = usePage(pageId);
  const page = pageId ? pageQuery.data : undefined;
  const loading = loadingPage ?? (!!pageId && !page);
  const create = useCreateChat();
  const attach = useAttachChat(page?.id ?? "");
  const addDockChat = useAddDockChat();
  const { attachments, request, onRemove: remove, readDraft: hostReadDraft, draftText, onClaimRequest, onGeneral } = host;
  const handledRequest = useRef(0);
  const claimRequest = useCallback(
    (n: number) => {
      if (onClaimRequest) return onClaimRequest(n);
      if (n <= handledRequest.current) return false;
      handledRequest.current = n;
      return true;
    },
    [onClaimRequest],
  );
  const readDraft = useCallback(
    (id: string) => (hostReadDraft ? hostReadDraft(id) : page?.id === id ? draftText : undefined),
    [hostReadDraft, page?.id, draftText],
  );
  const [created, setCreated] = useState<string>();
  const id = created ?? chatId;
  const open = useChat(id).data;
  // A new chat starts with the persona last used here; the empty dock names it rather than "your persona".
  const starting = useDockPersona(APP_SCOPE);
  // The chat's own persona, not a guest who spoke last in a group chat.
  const openPersonaId = open?.persona?.id;
  const rememberPersona = starting.remember;
  useEffect(() => rememberPersona(openPersonaId), [rememberPersona, openPersonaId]);
  const persona = open ? personaLook(open.speaker ?? open.persona).name : starting.look.name;
  const hostRef = useRef<HTMLDivElement>(null);
  const pageScope: DockScope | undefined = page ? `page:${page.id}` : undefined;
  const pageChats = useDockChats(pageScope);
  const appChats = useDockChats(APP_SCOPE);
  // A general chat picked before the dock kept a list joins it the first time it shows.
  const appList = appChats.data?.chats;
  useEffect(() => {
    if (!page && id && appList && !appList.some((c) => c.id === id) && !addDockChat.isPending) addDockChat.mutate({ scope: APP_SCOPE, chatId: id });
  }, [page, id, appList, addDockChat]);
  const selectChat = async (next: string) => {
    setCreated(next);
    // A page records the chat in its dock list as it attaches it (SetPageChat).
    if (page) await attach.mutateAsync(next);
    else {
      onGeneral(next);
      await addDockChat.mutateAsync({ scope: APP_SCOPE, chatId: next });
    }
  };
  const start = () => {
    create.mutate(
      { title: page?.title ?? "Knowledge", hidden: true, ...(starting.id ? { persona_id: starting.id } : {}) },
      { onSuccess: (c) => { void selectChat(c.id).catch(() => { /* attach.error keeps the chat available with Retry. */ }); } },
    );
  };
  const sections: DockChatSection[] = page
    ? [{ label: "This page", chats: pageChats.data?.chats ?? [] }, { label: "Elsewhere in Knowledge", chats: (appList ?? []).filter((c) => !pageChats.data?.chats.some((p) => p.id === c.id)) }]
    : [{ label: "Knowledge", chats: appList ?? [] }];
  const known = sections.flatMap((s) => s.chats);
  const switcher = (
    <DockChatSwitcher
      current={known.find((c) => c.id === id)}
      sections={sections}
      newLabel={page ? "New chat about this page" : "New chat"}
      onSelect={(next) => { if (next !== id) void selectChat(next).catch(() => { /* attach.error offers Retry. */ }); }}
      onNew={() => start()}
      creating={create.isPending}
      inline={!!id}
    />
  );

  // Only an explicit Ask action creates an empty conversation; opening the rail does not.
  useEffect(() => {
    if (!request || loading || !claimRequest(request)) return;
    if (!id && !create.isPending) start();
  });
  useEffect(() => {
    if (!request || !id) return;
    const frame = requestAnimationFrame(() => hostRef.current?.querySelector<HTMLElement>("textarea")?.focus());
    return () => cancelAnimationFrame(frame);
  }, [request, id]);

  const pages = attachments.filter((a): a is PageAttachment => !isFolder(a));
  const folders = attachments.filter(isFolder);
  const refs: Schemas["ChatContextRef"][] = [];
  for (const p of [...(page ? [page] : []), ...pages]) {
    if (!refs.some((r) => r.id === p.id)) refs.push({ kind: "page", id: p.id });
  }
  const quote = (text: string) => text.split("\n").map((line) => `> ${line}`).join("\n");
  const label = (p: { path: string | null; title: string }) => `[[${p.path ?? p.title}]]`;
  const passages = pages.filter((a) => a.quote !== undefined).map((a) => `Selected passage from ${label(a)}:\n${quote(a.quote!)}`);
  const folderBlocks = folders.map(folderBlock);
  const contextBody = (body: string, snapshots: string[] = []) => {
    const viewing = page ? [`Currently viewing Knowledge page ${label(page)}.`] : screen ? [`On the Knowledge ${screen} screen, not viewing a page.`] : [];
    const blocks = [...viewing, ...passages, ...folderBlocks, ...snapshots];
    // The server excludes this source material when interpreting persona mentions and hand-off limits.
    const suffix = `${KNOWLEDGE_CONTEXT_MARKER}${blocks.join("\n\n")}`;
    return blocks.length && !body.endsWith(suffix) ? `${body}${suffix}` : body;
  };
  const renderContext = (className?: string) => (
    <DockContext persona={persona} label="Knowledge context" className={className}>
      {page && <span className={dockContextChip} title={page.path ?? page.title}><Icon name="wiki" size={12} className="flex-none text-fg-tertiary" /><span className="min-w-0 truncate">Viewing: {page.title}</span></span>}
      {!page && screen && <span className={dockContextChip}>On: {screen}</span>}
      {folders.map((f) => (
        <span key={f.key} className={dockContextChip} title={f.path}>
          <Icon name="folder" size={12} className="flex-none" />
          <span className="min-w-0 truncate">{f.path}/</span>
          <button aria-label={`Remove folder ${f.path}`} onClick={() => remove([f.key])} className="grid size-4 flex-none place-items-center rounded hover:bg-hover"><Icon name="x" size={11} /></button>
        </span>
      ))}
      {pages.map((a) => (
        <span key={a.key} className={dockContextChip} title={a.quote ?? a.path ?? a.title}>
          <Icon name={a.quote === undefined ? "wiki" : "msg"} size={12} className="flex-none" />
          <span className="min-w-0 truncate">{a.title}{a.quote === undefined ? "" : " · selection"}</span>
          <button aria-label={`Remove ${a.quote === undefined ? a.title : `selection from ${a.title}`}`} onClick={() => remove([a.key])} className="grid size-4 flex-none place-items-center rounded hover:bg-hover"><Icon name="x" size={11} /></button>
        </span>
      ))}
    </DockContext>
  );
  const context: ConversationContext = {
    hidden: true,
    composer: renderContext(),
    prepare: async (input) => {
      const draft = page && readDraft(page.id);
      const unsaved = page && draft !== undefined && draft.trim() !== (page.body_md ?? "").trim()
        ? [`Current editor text of ${label(page)} (includes unsaved edits; use this over the saved page):\n${quote(draft)}`] : [];
      const all = [...(input.context_refs ?? [])];
      for (const ref of refs) if (!all.some((r) => refKey(r) === refKey(ref))) all.push(ref);
      return { ...input, body: contextBody(input.body, unsaved), ...(all.length ? { context_refs: all } : {}) };
    },
    prepareText: async (body) => {
      // These endpoints accept text only. Freeze their page context when queued, before navigation or edits.
      const snapshots = await Promise.all(refs.map(async (r) => {
        const draft = readDraft(r.id!);
        const p = await fetchPage(r.id!);
        const text = draft ?? p.body_md ?? "";
        return `Page snapshot of ${label(p)}:\n${quote(text)}`;
      }));
      return contextBody(body, snapshots);
    },
    onSent: () => remove(attachments.map((a) => a.key)),
    welcome: welcomeFor({ page, screen, selection: pages.some((a) => a.quote !== undefined), folders: folders.map((f) => f.path) }),
  };

  if (loading) return <div className="p-4"><Skeleton className="h-4 w-2/3" /></div>;
  if (id) return (
    <div ref={hostRef} className="flex min-h-0 min-w-0 flex-1 flex-col">
      {attach.error && <p role="alert" className="p-2 text-12 text-state-blocked">Couldn’t link this chat to the page. <button className="underline" onClick={() => attach.mutate(id)}>Retry</button></p>}
      <Conversation key={id} id={id} docked hideTitle onNew={start} onReplace={selectChat} context={context} actions={switcher} />
    </div>
  );
  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      {known.length > 0 && switcher}
      <div className="flex min-w-0 flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
        <Icon name="msg" size={22} className="text-fg-tertiary" />
        {renderContext("justify-center")}
        <p className="text-13 text-fg-secondary">
          {page ? "Talk to a persona about this page. It can read it, link it and edit it with you." : "Talk to a persona about your notes. It can search, link and write pages with you."}
        </p>
        <Button variant="primary" disabled={create.isPending} onClick={start}>
          {page ? "Start a chat about this page" : "Start a chat"}
        </Button>
        {create.error && <p className="text-12 text-state-blocked">{create.error.message}</p>}
      </div>
    </div>
  );
}

function ChatBody({ chatId, page, screen, loadingPage, onGeneral }: { chatId?: string; page?: Page; screen?: string; loadingPage: boolean; onGeneral: (id: string) => void }) {
  const { attachments, request, remove, readDraft, claimRequest } = useKnowledgeChat();
  return (
    <KnowledgeChatPanel
      pageId={page?.id}
      screen={screen}
      chatId={chatId}
      loadingPage={loadingPage}
      host={{
        attachments,
        request,
        readDraft,
        onRemove: remove,
        onClaimRequest: claimRequest,
        onGeneral,
      }}
    />
  );
}

/**
 * What an empty Knowledge chat offers to start with: about the selection, the folders or the page
 * attached, else the screen. Templates rather than the person's general suggestions, which come
 * from their other chats and have nothing to do with their notes.
 */
export function welcomeFor({ page, screen, selection, folders }: { page?: Pick<Page, "title">; screen?: string; selection: boolean; folders: string[] }): DockWelcome {
  if (selection)
    return {
      where: page ? `on “${page.title}”` : "in Knowledge",
      intro: "I can read the passage you selected and suggest edits you accept or reject.",
      label: "For the selection",
      starters: [
        { icon: "edit", title: "Rewrite the selection", prompt: "Rewrite the selected passage to read more clearly, as a suggestion I can accept or reject." },
        { icon: "bulb", title: "Explain the selection", prompt: "Explain the selected passage, and link any pages it relates to." },
      ],
    };
  if (folders.length) {
    const named = folders.length === 1 ? `${folders[0]}/` : "these folders";
    return {
      where: "in Knowledge",
      intro: `I can read every page in ${named}, link them and tidy them with you.`,
      label: "For the folder",
      starters: [
        { icon: "wiki", title: `Summarise ${named}`, prompt: `Summarise what's in ${named}: the main topics and the pages that matter most.` },
        { icon: "search", title: "Find gaps and duplicates", prompt: `Look through ${named} for pages that overlap or say the same thing, and for topics that are missing.` },
        { icon: "graph", title: "Link the pages together", prompt: `Find unlinked mentions between the pages in ${named} and propose links.` },
      ],
    };
  }
  if (page)
    return {
      where: `on “${page.title}”`,
      intro: "I can read this page, link it and suggest edits you accept or reject.",
      label: "For this page",
      starters: [
        { icon: "wiki", title: "Summarise this page", prompt: "Summarise this page in three lines, and suggest adding it as a TL;DR at the top." },
        { icon: "graph", title: "Suggest links", prompt: "Find mentions of other pages in this one that aren't linked yet, and propose links." },
        { icon: "search", title: "Find related pages", prompt: "Which of my pages are related to this one? Group them by how they relate." },
        { icon: "edit", title: "Tidy tags and properties", prompt: "Suggest tags and properties for this page that match the pages beside it." },
      ],
    };
  return {
    where: screen && screen !== "Home" ? `in Knowledge · ${screen}` : "in Knowledge",
    intro: "Ask about your notes. I can search, link, tag and write pages with you.",
    label: "For your notes",
    starters: [
      { icon: "inbox", title: "File my inbox", prompt: "Look at the captures in my Inbox and suggest a folder or page for each. Don't move anything until I say." },
      { icon: "graph", title: "Connect orphan pages", prompt: "Find pages nothing links to and propose links to them from related pages." },
      { icon: "history", title: "What did I write this week?", prompt: "Summarise the pages I created or edited this week." },
      { icon: "edit", title: "Start today's note", prompt: "Start today's daily note, carrying over anything still open from my last one." },
    ] satisfies DockStarter[],
  };
}

/** A folder as message context: its path and the pages under it, with how to find any left out. */
function folderBlock(f: FolderAttachment): string {
  const lines = [`Attached folder ${f.path}/ (${f.count} ${f.count === 1 ? "page" : "pages"}):`, ...f.pages.map((p) => `- [[${p}]]`)];
  if (f.count > f.pages.length) lines.push(`- and ${f.count - f.pages.length} more: list_pages with folder "${f.path}" lists them all.`);
  return lines.join("\n");
}
