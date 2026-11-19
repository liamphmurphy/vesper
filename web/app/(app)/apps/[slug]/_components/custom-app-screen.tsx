"use client";

import { useQueryClient } from "@tanstack/react-query";
import { Dialog } from "radix-ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Conversation, type ConversationContext, type DockWelcome } from "@/app/(app)/chat/_components/conversation";
import { PersonaAvatar, personaLook, useDockPersona } from "@/app/(app)/chat/_components/persona";
import { DockChatSwitcher, type DockChatSection } from "@/components/domain/dock-chat-switcher";
import { DockContext, dockContextChip } from "@/components/domain/dock-context";
import { buildCustomAppActions, buildCustomAppNav, parseViewId } from "@/lib/native-shell/models/custom-app";
import { EditorLayout, type DockTab, type EditorHeader, type NativeEditorHeader } from "@/components/shell/editor-layout";
import { isTyping } from "@/components/shell/shortcuts";
import { Content, TopBar } from "@/components/shell/topbar";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Segmented } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Field, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { api, ApiError, unwrap, type Schemas } from "@/lib/api/client";
import { useConnectors } from "@/lib/api/connector-hooks";
import {
  customAppKeys,
  invokeCustomApp,
  useCustomApp,
  useUpdateCustomApp,
  type CustomAppCapabilityMode,
  type CustomAppDetail,
  type CustomAppInvokeRequest,
} from "@/lib/api/custom-app-hooks";
import { useAddDockChat, useDockChats, type DockScope } from "@/lib/api/dock-hooks";
import { chatKeys, useChat, useCreateChat } from "@/lib/api/hooks";
import { useSpaceChats } from "@/lib/api/space-hooks";
import {
  buildCustomAppSrcDoc,
  parseBridgeMessage,
  readThemeVarsFrom,
  resolveAppIcon,
  resolveVideoEmbed,
  withCustomAppContext,
  type CustomAppNavSpec,
  type VideoEmbed,
} from "@/lib/custom-app-bridge";
import { cx } from "@/lib/cx";
import type { DockState } from "@/lib/editor-layout";
import { shortAgo } from "@/lib/format";
import { toast } from "@/lib/toast";

const ALLOWED_FILE_EXTS = [".tsx", ".ts", ".jsx", ".js", ".css", ".sql", ".json"];

const MODE_OPTIONS: ReadonlyArray<{ value: CustomAppCapabilityMode; label: string }> = [
  { value: "allowed", label: "Allow" },
  { value: "requires_approval", label: "Ask" },
  { value: "denied", label: "Deny" },
];

const SCOPE_OPTIONS: ReadonlyArray<{ value: "chats" | "app_only"; label: string }> = [
  { value: "chats", label: "All chats" },
  { value: "app_only", label: "This app only" },
];

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace(/\.0$/, "")} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function readThemeVars(): Record<string, string> {
  if (typeof window === "undefined") return {};
  const styles = getComputedStyle(document.documentElement);
  return readThemeVarsFrom((name) => styles.getPropertyValue(name));
}

type PendingApproval = {
  seq: number;
  reload: number;
  reqId: string;
  body: CustomAppInvokeRequest;
  capability: string;
  summary: string;
};

export function CustomAppScreen({ slug }: { slug: string }) {
  const query = useCustomApp(slug);

  if (query.error instanceof ApiError && query.error.status === 404) {
    return (
      <>
        <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />
        <Content>
          <EmptyState
            icon="dashboard"
            title="Custom app not found"
            actions={
              <ButtonLink variant="primary" href="/apps">
                Back to Custom Apps
              </ButtonLink>
            }
          >
            No custom app exists at <span className="font-mono">/apps/{slug}</span>. Create it from Custom Apps or ask a persona to build it.
          </EmptyState>
        </Content>
      </>
    );
  }

  if (query.isError) {
    return (
      <>
        <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />
        <Content>
          <Banner tone="blocked" title="Couldn’t load custom app">
            {errorText(query.error)}
          </Banner>
        </Content>
      </>
    );
  }

  if (!query.data) {
    return (
      <>
        <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />
        <Content>
          <Skeleton className="h-[60vh] w-full rounded-xl" />
        </Content>
      </>
    );
  }

  return <CustomAppWorkbench key={query.data.id} app={query.data} />;
}

function CustomAppWorkbench({ app }: { app: CustomAppDetail }) {
  const qc = useQueryClient();
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [initialThemeVars] = useState<Record<string, string>>(() => readThemeVars());

  const [reloadKey, setReloadKey] = useState(0);
  const [runtimeErrorState, setRuntimeErrorState] = useState<{ seq: number; reload: number; message: string } | null>(null);
  const [dynamicNavState, setDynamicNavState] = useState<{ seq: number; items: CustomAppNavSpec[] } | null>(null);
  const [activeNav, setActiveNav] = useState<string>();
  const [pendingApprovals, setPendingApprovals] = useState<PendingApproval[]>([]);
  const [decidingApproval, setDecidingApproval] = useState(false);
  const [activeVideo, setActiveVideo] = useState<(VideoEmbed & { title: string }) | null>(null);

  const [show, setShow] = useState({ tab: "chat", n: 0 });
  const openDockTab = useCallback((tab: string) => {
    setShow((s) => ({ tab, n: s.n + 1 }));
  }, []);
  const [dock, setDock] = useState<DockState>();

  const postToFrame = useCallback((msg: unknown) => {
    frameRef.current?.contentWindow?.postMessage(msg, "*");
  }, []);

  // Theme sync whenever root attributes change (dark/light/palette switch).
  useEffect(() => {
    const observer = new MutationObserver(() => {
      postToFrame({ type: "vesper:theme", vars: readThemeVars() });
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    });
    return () => observer.disconnect();
  }, [postToFrame]);

  // Forward shell SSE events to the sandboxed app.
  useEffect(() => {
    const onSSE = (e: Event) => {
      postToFrame({ type: "vesper:sse", event: (e as CustomEvent).detail });
    };
    window.addEventListener("vesper:sse", onSSE);
    return () => window.removeEventListener("vesper:sse", onSSE);
  }, [postToFrame]);

  const runtimeError =
    runtimeErrorState?.seq === app.current_seq && runtimeErrorState?.reload === reloadKey
      ? runtimeErrorState.message
      : null;

  const dynamicNav = dynamicNavState?.seq === app.current_seq ? dynamicNavState.items : null;
  const navItems = dynamicNav ?? app.manifest.nav ?? [];
  const currentNav = navItems.some((n) => n.id === activeNav) ? activeNav : navItems[0]?.id;

  const visibleApprovals = pendingApprovals.filter(
    (a) => a.seq === app.current_seq && a.reload === reloadKey,
  );
  const headApproval = visibleApprovals[0];

  // ---- Dock chat wiring (`app:custom:<slug>` + app's space)
  const dockScope: DockScope = `app:custom:${app.slug}`;
  const dockChats = useDockChats(dockScope);
  const spaceChats = useSpaceChats(app.space_id ?? undefined);
  const createChat = useCreateChat();
  const addDockChat = useAddDockChat();
  const startingPersona = useDockPersona(dockScope);

  const knownChats = useMemo(() => {
    const byId = new Map<string, Schemas["ChatSession"]>();
    for (const c of dockChats.data?.chats ?? []) byId.set(c.id, c);
    for (const c of spaceChats.data?.chats ?? []) byId.set(c.id, c);
    return [...byId.values()].sort((a, b) =>
      (b.last_message_at ?? b.created_at).localeCompare(a.last_message_at ?? a.created_at),
    );
  }, [dockChats.data?.chats, spaceChats.data?.chats]);

  const [selectedChatId, setSelectedChatId] = useState<string>();
  const candidateChatId = selectedChatId ?? knownChats[0]?.id;
  const chatQuery = useChat(candidateChatId);
  const gone = chatQuery.error instanceof ApiError && chatQuery.error.status === 404;
  const chatId = gone ? undefined : candidateChatId;
  const chat = gone ? undefined : chatQuery.data;
  const running = chat?.state === "running";

  const rememberPersona = startingPersona.remember;
  const openPersonaId = chat?.persona?.id;
  useEffect(() => {
    rememberPersona(openPersonaId);
  }, [rememberPersona, openPersonaId]);

  // Refresh app code, bundle, and SQLite schema when a persona turn completes.
  const wasRunning = useRef(false);
  useEffect(() => {
    if (wasRunning.current && !running) {
      void qc.invalidateQueries({ queryKey: customAppKeys.all });
    }
    wasRunning.current = running;
  }, [running, qc]);

  const chatShowing = !dock || (dock.open && !dock.hidden && dock.tab === "chat");
  const lastReply = chat?.last_message_at;
  const [seenReply, setSeenReply] = useState<{ chat?: string; at?: string }>({});
  if (lastReply && (seenReply.chat !== chatId || ((chatShowing || seenReply.at === undefined) && seenReply.at !== lastReply))) {
    setSeenReply({ chat: chatId, at: lastReply });
  }
  const unread = !chatShowing && !!lastReply && seenReply.chat === chatId && !!seenReply.at && seenReply.at !== lastReply && !running;

  const selectChat = useCallback(
    (nextId: string) => {
      setSelectedChatId(nextId);
      addDockChat.mutate({ scope: dockScope, chatId: nextId });
    },
    [addDockChat, dockScope],
  );

  const startChat = useCallback(() => {
    if (createChat.isPending) return;
    createChat.mutate(
      {
        title: app.name,
        hidden: true,
        ...(app.space_id ? { space_id: app.space_id } : {}),
        ...(startingPersona.id ? { persona_id: startingPersona.id } : {}),
      },
      {
        onSuccess: (created) => selectChat(created.id),
      },
    );
  }, [app.name, app.space_id, createChat, selectChat, startingPersona.id]);

  const handleAskDock = useCallback(
    async (prompt: string) => {
      openDockTab("chat");
      const formatted = withCustomAppContext(prompt, {
        slug: app.slug,
        name: app.name,
        seq: app.current_seq,
        activeNav: currentNav,
        error: runtimeError ?? undefined,
      });
      try {
        if (chatId) {
          if (running) {
            await unwrap(api.POST("/chats/{id}/followups", { params: { path: { id: chatId } }, body: { body: formatted } }));
          } else {
            await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id: chatId } }, body: { body: formatted } }));
          }
          await qc.invalidateQueries({ queryKey: chatKeys.all });
          return;
        }
        const created = await createChat.mutateAsync({
          title: app.name,
          hidden: true,
          ...(app.space_id ? { space_id: app.space_id } : {}),
          ...(startingPersona.id ? { persona_id: startingPersona.id } : {}),
          message: { body: formatted },
        });
        selectChat(created.id);
        await qc.invalidateQueries({ queryKey: chatKeys.all });
      } catch (err) {
        toast({ id: `ask-${app.slug}`, tone: "error", title: "Couldn’t send to chat", description: errorText(err) });
      }
    },
    [app.slug, app.name, app.current_seq, app.space_id, currentNav, runtimeError, chatId, running, qc, createChat, startingPersona.id, selectChat, openDockTab],
  );

  const askDockRef = useRef(handleAskDock);
  useEffect(() => {
    askDockRef.current = handleAskDock;
  }, [handleAskDock]);

  // Listen to bridge postMessages from the sandboxed iframe.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (!frameRef.current || e.source !== frameRef.current.contentWindow) return;
      const msg = parseBridgeMessage(e.data);
      if (!msg) return;

      if (msg.type === "set-nav") {
        setDynamicNavState({ seq: app.current_seq, items: msg.payload.items });
        if (msg.payload.activeId !== undefined) setActiveNav(msg.payload.activeId);
        return;
      }
      if (msg.type === "ask-dock") {
        void askDockRef.current(msg.payload.prompt);
        return;
      }
      if (msg.type === "open-url") {
        window.open(msg.payload.url, "_blank", "noopener,noreferrer");
        return;
      }
      if (msg.type === "play-video") {
        const embed = resolveVideoEmbed(msg.payload.url, typeof window !== "undefined" ? window.location.hostname : undefined);
        if (embed) {
          setActiveVideo({ ...embed, title: msg.payload.title || embed.titleFallback });
        } else {
          window.open(msg.payload.url, "_blank", "noopener,noreferrer");
        }
        return;
      }
      if (msg.type === "app-error") {
        setRuntimeErrorState({ seq: app.current_seq, reload: reloadKey, message: msg.payload.message });
        return;
      }

      const reqBody: CustomAppInvokeRequest =
        msg.type === "sql"
          ? { kind: "sql", query: msg.payload.query, params: msg.payload.params }
          : msg.type === "api"
            ? { kind: "api", method: msg.payload.method, path: msg.payload.path, body: msg.payload.body }
            : { kind: "mcp", connector: msg.payload.connector, tool: msg.payload.tool, arguments: msg.payload.arguments };

      void invokeCustomApp(app.slug, reqBody)
        .then((res) => {
          if (res.status === "approval_required") {
            setPendingApprovals((prev) => [
              ...prev,
              {
                seq: app.current_seq,
                reload: reloadKey,
                reqId: msg.id,
                body: reqBody,
                capability: res.capability,
                summary: res.summary ?? `Allow ${res.capability}`,
              },
            ]);
            return;
          }
          if (msg.type === "sql" && /\b(create|alter|drop)\b/i.test(msg.payload.query)) {
            void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
          }
          postToFrame({ type: "vesper:response", id: msg.id, ok: true, data: res.result });
        })
        .catch((err) => {
          postToFrame({ type: "vesper:response", id: msg.id, ok: false, error: errorText(err) });
        });
    };

    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [app.slug, app.current_seq, reloadKey, postToFrame, qc]);

  const decideApproval = useCallback(
    async (decision: "once" | "always" | "decline") => {
      if (!headApproval || decidingApproval) return;
      if (decision === "decline") {
        setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: "Capability request declined" });
        return;
      }
      setDecidingApproval(true);
      try {
        const res = await invokeCustomApp(app.slug, {
          ...headApproval.body,
          approved: true,
          ...(decision === "always" ? { always_allow: true } : {}),
        });
        if (decision === "always") {
          void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
          void qc.invalidateQueries({ queryKey: customAppKeys.list });
        }
        if (headApproval.body.kind === "sql" && typeof headApproval.body.query === "string" && /\b(create|alter|drop)\b/i.test(headApproval.body.query)) {
          void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
        }
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: true, data: res.result });
      } catch (err) {
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: errorText(err) });
      } finally {
        setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
        setDecidingApproval(false);
      }
    },
    [headApproval, decidingApproval, app.slug, postToFrame, qc],
  );

  const decideRef = useRef(decideApproval);
  useEffect(() => {
    decideRef.current = decideApproval;
  }, [decideApproval]);

  // ⌥A approves once, ⌥D declines when a capability prompt is active.
  useEffect(() => {
    if (!headApproval) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (!e.altKey || e.metaKey || e.ctrlKey || isTyping(e.target) || document.querySelector('[role="dialog"]')) return;
      const key = e.key.toLowerCase();
      if (e.code === "KeyA" || key === "a") {
        e.preventDefault();
        void decideRef.current("once");
      } else if (e.code === "KeyD" || key === "d") {
        e.preventDefault();
        void decideRef.current("decline");
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [headApproval]);

  const { slug: appSlug, current } = app;
  const { seq: currentSeq, bundle_js: bundleJs, bundle_css: bundleCss } = current;
  const srcDoc = useMemo(
    () =>
      buildCustomAppSrcDoc({
        slug: appSlug,
        seq: currentSeq,
        bundleJs,
        bundleCss,
        themeVars: initialThemeVars,
      }),
    [appSlug, currentSeq, bundleJs, bundleCss, initialThemeVars],
  );

  const personaName = chat ? personaLook(chat.speaker ?? chat.persona).name : startingPersona.look.name;
  const sections: DockChatSection[] = [{ label: app.name, chats: knownChats }];

  const switcher = (
    <DockChatSwitcher
      current={knownChats.find((c) => c.id === chatId)}
      sections={sections}
      newLabel="New chat for this app"
      onSelect={(next) => {
        if (next !== chatId) selectChat(next);
      }}
      onNew={startChat}
      creating={createChat.isPending}
      inline={!!chatId}
    />
  );

  const appWelcome: DockWelcome = {
    where: `in ${app.name}`,
    intro: "Ask me to build new views, evolve the SQLite tables, or wire in Vesper APIs and MCP connectors.",
    label: "App ideas",
    starters: [
      { icon: "dashboard", title: "Add a view or chart", prompt: `Add a summary view and interactive filters to "${app.name}".` },
      { icon: "server", title: "Inspect & evolve SQLite schema", prompt: `Inspect the SQLite schema in "${app.name}" and suggest useful columns or views.` },
      { icon: "bolt", title: "Connect Vesper API data", prompt: `Show how to connect "${app.name}" to Vesper tickets, runs, or Knowledge via bridge.api.` },
    ],
  };

  const renderContext = (className?: string) => (
    <DockContext persona={personaName} label="Custom app context" className={className}>
      <span className={dockContextChip} title={`/apps/${app.slug}`}>
        <Icon name={resolveAppIcon(app.icon)} size={12} className="flex-none text-fg-tertiary" />
        <span className="min-w-0 truncate">Viewing: {app.name} · v{app.current_seq}</span>
      </span>
    </DockContext>
  );

  const conversationContext: ConversationContext = {
    hidden: true,
    composer: renderContext(),
    prepare: async (input) => ({
      ...input,
      body: withCustomAppContext(input.body, {
        slug: app.slug,
        name: app.name,
        seq: app.current_seq,
        activeNav: currentNav,
        error: runtimeError ?? undefined,
      }),
    }),
    prepareText: async (body) =>
      withCustomAppContext(body, {
        slug: app.slug,
        name: app.name,
        seq: app.current_seq,
        activeNav: currentNav,
        error: runtimeError ?? undefined,
      }),
    onSent: () => {},
    welcome: appWelcome,
  };

  const reload = () => {
    setRuntimeErrorState(null);
    setPendingApprovals([]);
    setReloadKey((k) => k + 1);
  };
  const header: EditorHeader = {
    back: { href: "/apps", label: "Custom Apps" },
    name: app.name,
    title: (
      <span className="inline-flex items-center gap-2">
        <Icon name={resolveAppIcon(app.icon)} size={15} className="flex-none text-fg-secondary" />
        <span className="truncate">{app.name}</span>
        <span className="rounded bg-selected px-1.5 py-0.5 font-mono text-11 font-normal text-fg-tertiary">
          v{app.current_seq}
        </span>
      </span>
    ),
    actions: [
      <IconButton
        key="reload"
        icon="refresh"
        label="Reload app"
        onClick={reload}
      />,
      <Button key="perms" variant="outline" icon="shield" onClick={() => openDockTab("permissions")}>
        Permissions
      </Button>,
    ],
  };

  const nativeHeader: NativeEditorHeader = {
    title: app.name,
    subtitle: `v${app.current_seq}`,
    actions: buildCustomAppActions({ reload, permissions: () => openDockTab("permissions") }),
  };
  const nativeLeft =
    navItems.length > 0
      ? {
          model: buildCustomAppNav({ title: app.name, items: navItems.map((n) => ({ id: n.id, label: n.label, icon: n.icon ? resolveAppIcon(n.icon) : undefined })), currentId: currentNav }),
          onCommand: (cmd: { type: string; itemId?: string }) => {
            const id = cmd.type === "nav.activate" && cmd.itemId ? parseViewId(cmd.itemId) : null;
            if (!id) return;
            setActiveNav(id);
            postToFrame({ type: "vesper:nav-select", id });
          },
        }
      : undefined;

  const left =
    navItems.length > 0 ? (
      <nav aria-label="App views" className="flex flex-col gap-0.5 p-2">
        {navItems.map((item) => {
          const selected = item.id === currentNav;
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => {
                setActiveNav(item.id);
                postToFrame({ type: "vesper:nav-select", id: item.id });
              }}
              aria-current={selected ? "page" : undefined}
              className={cx(
                "flex h-8 w-full items-center gap-2 rounded-md px-2.5 text-left text-13 transition-colors",
                selected ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              {item.icon && <Icon name={resolveAppIcon(item.icon)} size={14} className="flex-none" />}
              <span className="truncate">{item.label}</span>
            </button>
          );
        })}
      </nav>
    ) : undefined;

  const main = (
    <div className="flex min-h-0 flex-1 flex-col">
      {(headApproval || runtimeError) && (
        <div className="flex flex-col gap-2 border-b border-border-subtle bg-surface p-3">
          {headApproval && (
            <Banner
              tone="human"
              title={`Permission needed · ${headApproval.capability}`}
              actions={
                <>
                  <Button
                    variant="approve"
                    hint="⌥A"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("once")}
                  >
                    Approve once
                  </Button>
                  <Button
                    variant="approve-outline"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("always")}
                  >
                    Always allow
                  </Button>
                  <Button
                    variant="outline"
                    hint="⌥D"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("decline")}
                  >
                    Decline
                  </Button>
                </>
              }
            >
              {headApproval.summary}
            </Banner>
          )}
          {runtimeError && (
            <Banner
              tone="blocked"
              title="Runtime error in sandbox"
              actions={
                <>
                  <Button
                    variant="secondary"
                    icon="msg"
                    onClick={() =>
                      void handleAskDock(
                        `Please fix this runtime error in custom app "${app.name}" (/apps/${app.slug}):\n\n${runtimeError}`,
                      )
                    }
                  >
                    Ask persona to fix
                  </Button>
                  <Button variant="ghost" onClick={() => setRuntimeErrorState(null)}>
                    Dismiss
                  </Button>
                </>
              }
            >
              {runtimeError}
            </Banner>
          )}
        </div>
      )}
      <iframe
        ref={frameRef}
        key={`${app.current.seq}:${reloadKey}`}
        sandbox="allow-scripts"
        referrerPolicy="no-referrer"
        srcDoc={srcDoc}
        title={app.name}
        data-testid="custom-app-frame"
        onLoad={() => postToFrame({ type: "vesper:theme", vars: readThemeVars() })}
        className="h-full min-h-[420px] w-full flex-1 border-0 bg-bg"
      />
      <Dialog.Root open={activeVideo !== null} onOpenChange={(open) => { if (!open) setActiveVideo(null); }}>
        <Dialog.Portal>
          <Dialog.Overlay className="motion-scrim fixed inset-0 z-50 bg-scrim" />
          <Dialog.Content
            aria-describedby={undefined}
            className="motion-dialog fixed left-1/2 top-1/2 z-50 flex w-[min(960px,calc(100%-32px))] -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
          >
            {activeVideo && (
              <>
                <div className="flex items-center gap-2 border-b border-border-subtle px-4 py-2.5">
                  <Dialog.Title className="min-w-0 flex-1 truncate text-14 font-semibold text-fg">
                    {activeVideo.title}
                  </Dialog.Title>
                  <a
                    href={activeVideo.externalUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex h-7 flex-none items-center gap-1.5 rounded-md border border-border-strong px-2.5 text-12 font-medium text-fg-secondary transition-colors hover:bg-hover hover:text-fg"
                  >
                    <Icon name="link" size={13} />
                    {activeVideo.provider === "youtube" ? "Open on YouTube" : "Open on Twitch"}
                  </a>
                  <Dialog.Close asChild>
                    <IconButton icon="x" label="Close video player" />
                  </Dialog.Close>
                </div>
                <div className="relative aspect-video w-full bg-black">
                  <iframe
                    key={activeVideo.embedUrl}
                    src={activeVideo.embedUrl}
                    title={activeVideo.title}
                    allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                    allowFullScreen
                    referrerPolicy="strict-origin-when-cross-origin"
                    className="absolute inset-0 size-full border-0"
                  />
                </div>
              </>
            )}
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </div>
  );

  const personaLookForTab = chat ? personaLook(chat.speaker ?? chat.persona) : startingPersona.look;
  const dockTabs: DockTab[] = [
    {
      id: "chat",
      label: "Chat",
      icon: "msg",
      avatar: <PersonaAvatar persona={personaLookForTab} size={16} />,
      busy: running,
      unread,
      content: chatId ? (
        <Conversation
          key={chatId}
          id={chatId}
          docked
          hideTitle
          onNew={startChat}
          onReplace={selectChat}
          context={conversationContext}
          actions={switcher}
        />
      ) : (
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          {knownChats.length > 0 && switcher}
          <div className="flex min-w-0 flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
            <Icon name="msg" size={22} className="text-fg-tertiary" />
            {renderContext("justify-center")}
            <p className="max-w-[260px] text-13 text-fg-secondary">
              Talk to a persona about <span className="font-medium text-fg">{app.name}</span>. It can read its files, run SQLite queries, and ship new versions with you.
            </p>
            <Button variant="primary" disabled={createChat.isPending} onClick={startChat}>
              {createChat.isPending ? "Starting…" : "Start a chat"}
            </Button>
            {createChat.error && <p className="text-12 text-pill-blocked-fg">{errorText(createChat.error)}</p>}
          </div>
        </div>
      ),
    },
    {
      id: "code",
      label: "Code",
      icon: "code",
      wide: true,
      content: <CodeInspectorTab key={app.current.seq} app={app} />,
    },
    {
      id: "permissions",
      label: "Permissions",
      icon: "shield",
      content: dock?.open && dock.tab === "permissions" ? <PermissionsTab app={app} /> : <Skeleton className="m-3 h-40" />,
    },
  ];

  return (
    <EditorLayout
      app={`custom-app:${app.slug}`}
      header={header}
      nativeHeader={nativeHeader}
      nativeLeft={nativeLeft}
      left={left}
      main={main}
      dock={dockTabs}
      show={show}
      onDockChange={setDock}
    />
  );
}

function CodeInspectorTab({ app }: { app: CustomAppDetail }) {
  const update = useUpdateCustomApp(app.slug);
  const [draftFiles, setDraftFiles] = useState<Record<string, string>>(() => ({ ...app.current.files }));
  const fileNames = useMemo(() => Object.keys(draftFiles).sort(), [draftFiles]);
  const [selectedFile, setSelectedFile] = useState<string>(() =>
    app.current.files[app.manifest.entry] !== undefined ? app.manifest.entry : Object.keys(app.current.files).sort()[0] ?? app.manifest.entry,
  );
  const [note, setNote] = useState("");
  const [addingFile, setAddingFile] = useState(false);
  const [newPath, setNewPath] = useState("");
  const [newPathError, setNewPathError] = useState<string | null>(null);

  const baseFiles = app.current.files;
  const dirty = useMemo(() => {
    const dk = Object.keys(draftFiles);
    const bk = Object.keys(baseFiles);
    if (dk.length !== bk.length) return true;
    return dk.some((k) => draftFiles[k] !== baseFiles[k]);
  }, [draftFiles, baseFiles]);

  const handleAddFile = () => {
    const cleaned = newPath.trim().replace(/^\/+/, "");
    if (!cleaned || cleaned.includes("..")) {
      setNewPathError("Enter a relative file path (for example components/Table.tsx).");
      return;
    }
    if (!ALLOWED_FILE_EXTS.some((ext) => cleaned.toLowerCase().endsWith(ext))) {
      setNewPathError(`Allowed extensions: ${ALLOWED_FILE_EXTS.join(", ")}`);
      return;
    }
    if (draftFiles[cleaned] !== undefined) {
      setNewPathError("File already exists.");
      return;
    }
    setDraftFiles((prev) => ({ ...prev, [cleaned]: "" }));
    setSelectedFile(cleaned);
    setNewPath("");
    setNewPathError(null);
    setAddingFile(false);
  };

  const handleDeleteFile = (path: string) => {
    if (path === app.manifest.entry) return;
    setDraftFiles((prev) => {
      const next = { ...prev };
      delete next[path];
      return next;
    });
    if (selectedFile === path) {
      setSelectedFile(app.manifest.entry);
    }
  };

  const handleSave = () => {
    update.mutate(
      {
        files: draftFiles,
        replace_files: true,
        note: note.trim() || "Edited in Code inspector",
      },
      {
        onSuccess: (updated) => {
          toast({ id: `save-${app.slug}`, tone: "success", title: `Saved ${app.name} v${updated.current_seq}` });
        },
      },
    );
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex flex-wrap items-center gap-1 border-b border-border-subtle px-2.5 py-2">
        {fileNames.map((name) => {
          const active = name === selectedFile;
          return (
            <button
              key={name}
              type="button"
              onClick={() => setSelectedFile(name)}
              className={cx(
                "inline-flex h-6 items-center gap-1 rounded px-2 font-mono text-11 transition-colors",
                active ? "bg-selected font-semibold text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              {name}
            </button>
          );
        })}
        <button
          type="button"
          onClick={() => {
            setAddingFile((v) => !v);
            setNewPathError(null);
          }}
          className="inline-flex h-6 items-center gap-1 rounded border border-dashed border-border-strong px-2 text-11 text-fg-secondary hover:bg-hover hover:text-fg"
        >
          <Icon name="plus" size={11} />
          File
        </button>
        {selectedFile !== app.manifest.entry && fileNames.includes(selectedFile) && (
          <IconButton
            icon="trash"
            size={24}
            label={`Delete ${selectedFile}`}
            onClick={() => handleDeleteFile(selectedFile)}
            className="ml-auto text-fg-tertiary hover:text-pill-blocked-fg"
          />
        )}
      </div>

      {addingFile && (
        <div className="flex flex-col gap-1.5 border-b border-border-subtle bg-surface-sunken px-3 py-2">
          <div className="flex items-center gap-2">
            <TextInput
              mono
              value={newPath}
              placeholder="components/Summary.tsx"
              onChange={(e) => {
                setNewPath(e.target.value);
                setNewPathError(null);
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  handleAddFile();
                }
              }}
              className="flex-1"
            />
            <Button variant="secondary" onClick={handleAddFile}>
              Add
            </Button>
          </div>
          {newPathError && <p className="text-11 text-pill-blocked-fg">{newPathError}</p>}
        </div>
      )}

      {update.isError && (
        <div className="border-b border-border-subtle p-2.5">
          <Banner tone="blocked" title="Compile error">
            {errorText(update.error)}
          </Banner>
        </div>
      )}

      <div className="flex min-h-0 flex-1 flex-col p-2.5">
        <TextArea
          mono
          aria-label={`Source code for ${selectedFile}`}
          value={draftFiles[selectedFile] ?? ""}
          onChange={(e) => setDraftFiles((prev) => ({ ...prev, [selectedFile]: e.target.value }))}
          spellCheck={false}
          className="min-h-[320px] flex-1 resize-none text-12"
        />
      </div>

      <div className="flex items-center gap-2 border-t border-border-subtle px-3 py-2.5">
        <TextInput
          value={note}
          placeholder="Version note (optional)"
          onChange={(e) => setNote(e.target.value)}
          className="flex-1"
        />
        <Button variant="primary" disabled={!dirty || update.isPending} onClick={handleSave}>
          {update.isPending ? "Compiling…" : "Save & compile"}
        </Button>
      </div>
    </div>
  );
}

function PermissionsTab({ app }: { app: CustomAppDetail }) {
  const update = useUpdateCustomApp(app.slug);
  const connectors = useConnectors();
  const [schemaOpen, setSchemaOpen] = useState(false);
  const [toolsOpen, setToolsOpen] = useState(false);

  const connectorRows = useMemo(() => {
    const rows = connectors.data?.connectors ?? [];
    return rows.map((c) => ({
      key: `mcp:${c.slug}:*`,
      label: `MCP · ${c.name}`,
      hint: `${c.tools.length} tool${c.tools.length === 1 ? "" : "s"} · ${c.status.replaceAll("_", " ")}`,
    }));
  }, [connectors.data?.connectors]);

  const knownKeys = useMemo(() => {
    const keys = new Set<string>(["vesper.api:read", "vesper.api:write"]);
    if (app.has_mcp_server) keys.add("app.http:outbound");
    for (const c of connectorRows) keys.add(c.key);
    for (const k of Object.keys(app.manifest.requested_capabilities ?? {})) {
      if (!k.startsWith("app.sql:")) keys.add(k);
    }
    for (const k of Object.keys(app.capabilities ?? {})) {
      if (!k.startsWith("app.sql:")) keys.add(k);
    }
    return [...keys];
  }, [app.has_mcp_server, connectorRows, app.manifest.requested_capabilities, app.capabilities]);

  const connectorMap = useMemo(() => new Map(connectorRows.map((c) => [c.key, c])), [connectorRows]);

  const setCapabilityMode = (capKey: string, mode: CustomAppCapabilityMode) => {
    update.mutate(
      {
        capabilities: { ...app.capabilities, [capKey]: mode },
      },
      {
        onError: (e) => toast({ id: `cap-${app.slug}`, tone: "error", title: "Couldn’t update capability", description: errorText(e) }),
      },
    );
  };

  const versions = useMemo(() => [...app.versions].sort((a, b) => b.seq - a.seq), [app.versions]);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto p-3.5">
      {app.has_mcp_server && (
        <section className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-2">
            <h3 className="text-12 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">MCP Server</h3>
            <span className="rounded-sm bg-pill-done-bg px-1.5 py-0.5 text-11 font-medium text-pill-done-fg">
              {app.manifest.tool_scope === "app_only" ? "This app only" : "Chats & workflows"}
            </span>
          </div>
          <div className="rounded-lg border border-border bg-surface-sunken p-2.5 text-12">
            <div className="flex items-center justify-between text-fg-2">
              <span>Entrypoint</span>
              <span className="font-mono text-11">{app.manifest.mcp_entry || "server.ts"}</span>
            </div>
            <div className="mt-1.5 flex items-center justify-between text-fg-2">
              <span>Exposed tools</span>
              <button
                type="button"
                onClick={() => setToolsOpen((v) => !v)}
                className="font-mono text-11 text-accent hover:underline"
              >
                {(app.mcp_tools ?? []).length} {(app.mcp_tools ?? []).length === 1 ? "tool" : "tools"}{" "}
                {(app.mcp_tools ?? []).length > 0 ? (toolsOpen ? "▾" : "▸") : ""}
              </button>
            </div>
            {toolsOpen && (app.mcp_tools ?? []).length > 0 && (
              <ul className="mt-2 flex flex-col gap-1.5 border-t border-border-subtle pt-2">
                {(app.mcp_tools ?? []).map((t) => (
                  <li key={t.name} className="flex flex-col gap-0.5">
                    <span className="font-mono text-11 font-medium text-fg">{t.name}</span>
                    <span className="text-11 text-fg-secondary">{t.description}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>
      )}

      <section className="flex flex-col gap-2">
        <div className="flex items-center justify-between gap-2">
          <h3 className="text-12 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">Embedded SQLite</h3>
          <span className="rounded-sm bg-pill-done-bg px-1.5 py-0.5 text-11 font-medium text-pill-done-fg">Allowed</span>
        </div>
        <div className="rounded-lg border border-border bg-surface-sunken p-2.5 text-12">
          <div className="flex items-center justify-between text-fg-2">
            <span>Size on disk</span>
            <span className="font-mono text-11">{formatBytes(app.db_size_bytes)}</span>
          </div>
          <div className="mt-1.5 flex items-center justify-between text-fg-2">
            <span>Schema objects</span>
            <button
              type="button"
              onClick={() => setSchemaOpen((v) => !v)}
              className="font-mono text-11 text-accent hover:underline"
            >
              {app.schema.length} {app.schema.length === 1 ? "object" : "objects"} {app.schema.length > 0 ? (schemaOpen ? "▾" : "▸") : ""}
            </button>
          </div>
          {schemaOpen && app.schema.length > 0 && (
            <ul className="mt-2 flex flex-col gap-1.5 border-t border-border-subtle pt-2">
              {app.schema.map((obj) => (
                <li key={`${obj.type}:${obj.name}`} className="flex flex-col gap-0.5">
                  <span className="font-mono text-11 font-medium text-fg">
                    {obj.type} · {obj.name}
                  </span>
                  <pre className="overflow-x-auto whitespace-pre-wrap rounded bg-bg px-2 py-1 font-mono text-11 text-fg-secondary">
                    {obj.sql}
                  </pre>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      <section className="flex flex-col gap-2.5">
        <h3 className="text-12 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">Bridge capabilities</h3>
        <div className="flex flex-col gap-2">
          {knownKeys.map((capKey) => {
            const cInfo = connectorMap.get(capKey);
            const label =
              capKey === "vesper.api:read"
                ? "Vesper API · Read"
                : capKey === "vesper.api:write"
                  ? "Vesper API · Write"
                  : capKey === "app.http:outbound"
                    ? "Outbound HTTPS (MCP server)"
                    : capKey.startsWith("secret:")
                      ? `Secret · ${capKey.slice("secret:".length)}`
                      : cInfo?.label ?? capKey;
            const hint =
              capKey === "vesper.api:read"
                ? "GET requests to Vesper REST APIs"
                : capKey === "vesper.api:write"
                  ? "POST, PATCH, PUT, DELETE requests to Vesper APIs"
                  : capKey === "app.http:outbound"
                    ? "Public HTTPS fetch calls from the app's MCP server"
                    : capKey.startsWith("secret:")
                      ? "Authenticated secretFetch calls using this Vesper secret"
                      : cInfo?.hint ?? "Requested by app manifest";
            const mode: CustomAppCapabilityMode = app.capabilities[capKey] ?? "denied";
            const requested = app.manifest.requested_capabilities?.[capKey];
            return (
              <div key={capKey} className="flex flex-col gap-1.5 rounded-lg border border-border bg-surface-sunken p-2.5">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="truncate text-13 font-medium text-fg">{label}</div>
                    <div className="truncate text-11 text-fg-tertiary">{hint}</div>
                  </div>
                  {requested && requested !== mode && (
                    <span className="flex-none rounded bg-pill-human-bg px-1.5 py-0.5 text-10 font-medium text-pill-human-fg">
                      wants {requested === "requires_approval" ? "ask" : requested}
                    </span>
                  )}
                </div>
                <Segmented
                  small
                  label={`${label} permission`}
                  layout="fill"
                  value={mode}
                  onChange={(next) => setCapabilityMode(capKey, next)}
                  options={MODE_OPTIONS}
                />
              </div>
            );
          })}
        </div>
      </section>

      <section className="flex flex-col gap-2">
        <Field label="Persona SQL tool scope" hint="Whether any chat can query this app’s SQLite DB or only chats opened in this app.">
          <Segmented
            small
            label="Persona SQL tool scope"
            layout="fill"
            value={app.manifest.tool_scope === "app_only" ? "app_only" : "chats"}
            onChange={(nextScope) =>
              update.mutate({
                manifest: { ...app.manifest, tool_scope: nextScope },
                note: `Set SQL tool scope to ${nextScope}`,
              })
            }
            options={SCOPE_OPTIONS}
          />
        </Field>
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="text-12 font-semibold uppercase tracking-[0.04em] text-fg-tertiary">Version history</h3>
        <ul className="flex flex-col divide-y divide-border-subtle rounded-lg border border-border bg-surface-sunken">
          {versions.map((v) => {
            const current = v.seq === app.current_seq;
            return (
              <li key={v.seq} className="flex items-center justify-between gap-2 px-2.5 py-2">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5 text-12 font-medium text-fg">
                    <span className="font-mono">v{v.seq}</span>
                    <span className="text-fg-tertiary">·</span>
                    <span>{v.author_type === "persona" ? "Persona" : "You"}</span>
                    <span className="text-fg-tertiary">· {shortAgo(v.created_at)}</span>
                  </div>
                  {v.note && <div className="truncate text-11 text-fg-secondary">{v.note}</div>}
                </div>
                {current ? (
                  <span className="flex-none rounded bg-selected px-1.5 py-0.5 text-11 font-medium text-fg">Current</span>
                ) : (
                  <Button
                    variant="outline"
                    disabled={update.isPending}
                    onClick={() =>
                      update.mutate({
                        restore_seq: v.seq,
                        note: `Restored v${v.seq}`,
                      })
                    }
                    className="h-6 px-2 text-11"
                  >
                    Restore
                  </Button>
                )}
              </li>
            );
          })}
        </ul>
      </section>
    </div>
  );
}
