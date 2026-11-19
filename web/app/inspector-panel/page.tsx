"use client";

import { DropdownMenu } from "radix-ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CodePanel } from "@/app/(app)/chat/_components/code-panel";
import { Conversation } from "@/app/(app)/chat/_components/conversation";
import { DesignPanel } from "@/app/(app)/chat/_components/design-panel";
import { ThreadPanel } from "@/app/(app)/chat/_components/thread-panel";
import { CustomAppChatPanel, CustomAppCodePanel } from "@/app/(app)/apps/[slug]/_components/custom-app-screen";
import { DeckReview } from "@/app/(app)/apps/slides/_components/deck-review";
import type { Attachment } from "@/app/(app)/knowledge/_components/chat-context";
import { KnowledgeChatPanel } from "@/app/(app)/knowledge/_components/knowledge-dock";
import { CalendarPanel } from "@/app/(app)/knowledge/_components/page-side";
import { CanvasDock } from "@/components/domain/canvas-view";
import { floatPanel } from "@/components/domain/pickers";
import { PlaygroundPanel } from "@/components/domain/playground";
import { LiveUpdates } from "@/components/shell/live-updates";
import { setSystemAccent } from "@/components/shell/theme";
import { Skeleton } from "@/components/ui/primitives";
import { useCanvasActions, useChatCanvas } from "@/lib/api/canvas-hooks";
import { useDesign, useDesignSettings } from "@/lib/api/designs-hooks";
import { useMarkDocReviewed } from "@/lib/api/docs-hooks";
import { provideChatRefs } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { onCommand, post } from "@/lib/native-shell/bridge";
import { encodeComposerDrop, parsePanelProps } from "@/lib/native-shell/panel-events";
import type { InspectorPanelContext, InspectorPanelSpec } from "@/lib/native-shell/protocol";
import { assetHref, useSlideFonts } from "@/lib/slides/render";
import { encodeDeck, parseDeck } from "@/lib/slides/schema";
import type { PlaygroundTab } from "@/lib/use-playground-panel";

const menuItem =
  "flex cursor-pointer select-none items-center rounded-md px-2.5 py-1.5 text-13 text-fg outline-none data-[highlighted]:bg-hover";
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function emitPanelEvent(tabId: string, event: string, payload?: unknown) {
  post({
    v: 1,
    type: "panel.event",
    tabId,
    event,
    ...(payload !== undefined ? { payloadJson: JSON.stringify(payload) } : {}),
  });
}

function applyPanelContext(
  prev: Map<string, InspectorPanelSpec>,
  ctx: InspectorPanelContext,
): Map<string, InspectorPanelSpec> {
  const allowed = new Set(ctx.keepKeys);
  if (ctx.active) allowed.add(ctx.active.key);
  const next = new Map<string, InspectorPanelSpec>();
  for (const [k, spec] of prev) {
    if (allowed.has(k)) next.set(k, spec);
  }
  if (ctx.active) next.set(ctx.active.key, ctx.active);
  return next;
}

type DesignChatProps = {
  tabId: string;
  chatId: string;
  designId: string;
  persona: string;
  pageId?: string;
  selected?: string[];
  viewport?: { x: number; y: number; w: number; h: number; zoom: number };
};

function DesignsChatPanel({ p }: { p: DesignChatProps }) {
  const ref = useDesign(p.designId);
  const settings = useDesignSettings(p.designId);
  const direct = !!ref.data?.settings?.direct_edit;
  const ctx = useRef({
    page: p.pageId ?? "",
    selected: p.selected ?? [],
    viewport: p.viewport ?? { x: 0, y: 0, w: 1200, h: 800, zoom: 1 },
  });
  useEffect(() => {
    ctx.current = {
      page: p.pageId ?? "",
      selected: p.selected ?? [],
      viewport: p.viewport ?? { x: 0, y: 0, w: 1200, h: 800, zoom: 1 },
    };
  }, [p.pageId, p.selected, p.viewport]);
  useEffect(() => {
    if (!p.chatId) return;
    return provideChatRefs(p.chatId, () => {
      const c = ctx.current;
      if (!c.page) return undefined;
      return [{ kind: "canvas", id: p.designId, selection: { page: c.page, nodes: c.selected.slice(0, 100), viewport: c.viewport } }];
    });
  }, [p.chatId, p.designId]);

  const editMode = (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          data-testid="direct-edit"
          disabled={!ref.data || settings.isPending}
          title={`Suggests: ${p.persona}’s edits wait as suggestions you review. Edits directly: they apply at once, and Undo reverts them.`}
          aria-label={`${p.persona} ${direct ? "edits directly" : "suggests changes"}`}
          className="flex h-[26px] flex-none items-center gap-1 rounded-full border border-border bg-surface-raised px-2.5 text-12 text-fg hover:bg-hover disabled:opacity-50"
        >
          {direct ? "Direct" : "Suggests"} <span aria-hidden className="text-fg-tertiary">▾</span>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "z-50 w-64")}>
          <DropdownMenu.RadioGroup
            value={direct ? "direct" : "suggest"}
            onValueChange={(v) => settings.mutate({ direct_edit: v === "direct" })}
          >
            <DropdownMenu.RadioItem value="suggest" className={cx(menuItem, "flex-col items-start")}>
              <span>{direct ? "" : "✓ "}Suggests changes</span>
              <span className="text-11 text-fg-tertiary">Edits wait as suggestions you review.</span>
            </DropdownMenu.RadioItem>
            <DropdownMenu.RadioItem value="direct" className={cx(menuItem, "flex-col items-start")}>
              <span>{direct ? "✓ " : ""}Edits directly</span>
              <span className="text-11 text-fg-tertiary">Edits apply at once; Undo reverts them.</span>
            </DropdownMenu.RadioItem>
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );

  return (
    <div data-design-chat className="flex min-h-0 flex-1 flex-col">
      <Conversation
        key={p.chatId}
        id={p.chatId}
        docked
        actions={editMode}
        onNew={() => post({ v: 1, type: "openInMain", path: "/knowledge" })}
      />
    </div>
  );
}

type SlidesReviewProps = {
  tabId: string;
  chatId: string;
  docId: string;
  baseSeq: number;
  headSeq: number;
  persona: string;
  archived: boolean;
};

function SlidesReviewPanel({ p }: { p: SlidesReviewProps }) {
  const c = useChatCanvas(p.chatId, p.docId).data;
  const before = useChatCanvas(p.chatId, p.docId, p.baseSeq).data;
  const actions = useCanvasActions(p.chatId, p.docId);
  const reviewed = useMarkDocReviewed(p.docId);
  const fonts = useSlideFonts();
  const assetUrl = useCallback((a: string) => assetHref(p.docId, a), [p.docId]);
  const baseDeck = useMemo(
    () => (before && before.viewing_seq === p.baseSeq ? parseDeck(before.body) : undefined),
    [before, p.baseSeq],
  );
  const headDeck = useMemo(() => (c ? parseDeck(c.body) : undefined), [c]);
  if (!c || !baseDeck || !headDeck) {
    return <div aria-busy="true" className="p-3"><Skeleton className="h-[320px]" /></div>;
  }
  return (
    <DeckReview
      key={`${p.baseSeq}-${c.seq}`}
      base={baseDeck}
      head={headDeck}
      persona={p.persona}
      assetUrl={assetUrl}
      fontsReady={fonts}
      busy={p.archived || reviewed.isPending || actions.save.isPending}
      error={reviewed.error || actions.save.error ? errorText(reviewed.error ?? actions.save.error) : undefined}
      onAcceptAll={() => reviewed.mutate(c.seq)}
      onResolve={(d, note) =>
        actions.save.mutate(
          { base_seq: c.seq, body: encodeDeck(d), note },
          { onSuccess: (v) => reviewed.mutate(v.seq) },
        )
      }
    />
  );
}

type DesignPanelProps = {
  tabId: string;
  chatId: string;
  live: boolean;
  designId?: string;
  reviewing?: boolean;
};

function HostedDesignPanel({ p }: { p: DesignPanelProps }) {
  const [optimisticReview, setOptimisticReview] = useState(p.reviewing);
  const [prevProp, setPrevProp] = useState(p.reviewing);
  if (p.reviewing !== prevProp) {
    setPrevProp(p.reviewing);
    setOptimisticReview(p.reviewing);
  }
  return (
    <DesignPanel
      chatId={p.chatId}
      live={p.live}
      host={{
        designId: p.designId,
        reviewing: optimisticReview,
        hideClose: true,
        onClose: () => emitPanelEvent(p.tabId, "close"),
        onReview: (on) => {
          setOptimisticReview(on);
          emitPanelEvent(p.tabId, "review", { on, designId: p.designId });
        },
      }}
    />
  );
}

function PanelEntry({ spec }: { spec: InspectorPanelSpec }) {
  const props = useMemo(() => parsePanelProps<Record<string, unknown>>(spec.propsJson), [spec.propsJson]);
  if (!props || typeof props.tabId !== "string") return null;
  const tabId = props.tabId;

  switch (spec.kind) {
    case "chat.playground": {
      if (typeof props.chatId !== "string") return null;
      const chatId = props.chatId;
      const initialTab = props.initialTab as PlaygroundTab | undefined;
      return (
        <PlaygroundPanel
          chatId={chatId}
          host={{
            hideTitle: true,
            initialTab,
            onOpenFull: () => emitPanelEvent(tabId, "openFull"),
            onClose: () => emitPanelEvent(tabId, "close"),
            onSendToComposer: async (drop) => {
              const payloadJson = await encodeComposerDrop(chatId, drop);
              post({ v: 1, type: "panel.event", tabId, event: "composerDrop", payloadJson });
              return true;
            },
          }}
        />
      );
    }
    case "chat.code": {
      if (typeof props.chatId !== "string") return null;
      return (
        <CodePanel
          chatId={props.chatId}
          host={{
            hideFullscreenButton: true,
            onOpenFull: () => emitPanelEvent(tabId, "openFull"),
          }}
        />
      );
    }
    case "chat.design": {
      if (typeof props.chatId !== "string") return null;
      return (
        <HostedDesignPanel
          p={{
            tabId,
            chatId: props.chatId,
            live: Boolean(props.live),
            designId: typeof props.designId === "string" ? props.designId : undefined,
            reviewing: typeof props.reviewing === "boolean" ? props.reviewing : undefined,
          }}
        />
      );
    }
    case "chat.canvas": {
      if (typeof props.chatId !== "string") return null;
      return (
        <CanvasDock
          chatId={props.chatId}
          live={Boolean(props.live)}
          readOnly={Boolean(props.readOnly)}
          agent={typeof props.agent === "string" ? props.agent : "Assistant"}
          host={{
            canvasId: typeof props.canvasId === "string" ? props.canvasId : undefined,
            hideWindowActions: true,
            onFullscreen: (canvasId) => emitPanelEvent(tabId, "openFull", { canvasId }),
            onClose: () => emitPanelEvent(tabId, "close"),
          }}
        />
      );
    }
    case "chat.thread": {
      if (typeof props.chatId !== "string" || typeof props.messageId !== "string") return null;
      return (
        <ThreadPanel
          chatId={props.chatId}
          messageId={props.messageId}
          hideHeader
          onClose={() => emitPanelEvent(tabId, "close")}
        />
      );
    }
    case "knowledge.calendar":
      return (
        <div className="min-h-0 flex-1 overflow-y-auto p-3">
          <CalendarPanel onNavigate={(path) => post({ v: 1, type: "openInMain", path })} />
        </div>
      );
    case "knowledge.chat":
      return (
        <KnowledgeChatPanel
          pageId={typeof props.pageId === "string" ? props.pageId : undefined}
          screen={typeof props.screen === "string" ? props.screen : undefined}
          chatId={typeof props.chatId === "string" ? props.chatId : undefined}
          host={{
            attachments: Array.isArray(props.attachments) ? (props.attachments as Attachment[]) : [],
            request: typeof props.request === "number" ? props.request : 0,
            draftText: typeof props.draftText === "string" ? props.draftText : undefined,
            onRemove: (keys) => emitPanelEvent(tabId, "removeAttachments", { keys }),
            onGeneral: (chatId) => emitPanelEvent(tabId, "generalChat", { chatId }),
          }}
        />
      );
    case "customApp.chat": {
      if (typeof props.slug !== "string") return null;
      return (
        <CustomAppChatPanel
          slug={props.slug}
          activeNav={typeof props.activeNav === "string" ? props.activeNav : undefined}
          runtimeError={typeof props.runtimeError === "string" ? props.runtimeError : null}
          chatId={typeof props.chatId === "string" ? props.chatId : undefined}
          onSelectChat={(chatId) => emitPanelEvent(tabId, "selectChat", { chatId })}
        />
      );
    }
    case "customApp.code": {
      if (typeof props.slug !== "string") return null;
      return <CustomAppCodePanel slug={props.slug} />;
    }
    case "editor.chat": {
      if (typeof props.chatId !== "string") return null;
      return (
        <div className="flex min-h-0 flex-1 flex-col">
          <Conversation
            key={props.chatId}
            id={props.chatId}
            docked
            onNew={() => post({ v: 1, type: "openInMain", path: "/knowledge" })}
          />
        </div>
      );
    }
    case "designs.chat": {
      if (typeof props.chatId !== "string" || typeof props.designId !== "string") return null;
      return (
        <DesignsChatPanel
          p={{
            tabId,
            chatId: props.chatId,
            designId: props.designId,
            persona: typeof props.persona === "string" ? props.persona : "Assistant",
            pageId: typeof props.pageId === "string" ? props.pageId : undefined,
            selected: Array.isArray(props.selected) ? (props.selected as string[]) : undefined,
            viewport:
              props.viewport && typeof props.viewport === "object"
                ? (props.viewport as DesignChatProps["viewport"])
                : undefined,
          }}
        />
      );
    }
    case "slides.review": {
      if (
        typeof props.chatId !== "string" ||
        typeof props.docId !== "string" ||
        typeof props.baseSeq !== "number" ||
        typeof props.headSeq !== "number"
      ) {
        return null;
      }
      return (
        <SlidesReviewPanel
          p={{
            tabId,
            chatId: props.chatId,
            docId: props.docId,
            baseSeq: props.baseSeq,
            headSeq: props.headSeq,
            persona: typeof props.persona === "string" ? props.persona : "Assistant",
            archived: Boolean(props.archived),
          }}
        />
      );
    }
    default:
      return null;
  }
}

/**
 * Window-level persistent host for web-rendered inspector panels mounted inside macOS's
 * native inspector WKWebView with Liquid Glass transparency. Panels in `keepKeys` stay
 * mounted (hidden with CSS) across tab switches so state and previews survive intact.
 */
export default function NativeInspectorPanelPage() {
  const [activeKey, setActiveKey] = useState<string | null>(null);
  const [mounted, setMounted] = useState<Map<string, InspectorPanelSpec>>(() => new Map());

  useEffect(() => {
    post({ v: 1, type: "ready", path: "/inspector-panel" });
    const offCommand = onCommand((cmd) => {
      if (cmd.type === "appearance") {
        setSystemAccent(cmd.accent);
      } else if (cmd.type === "panel.context") {
        setActiveKey(cmd.context.active?.key ?? null);
        setMounted((prev) => applyPanelContext(prev, cmd.context));
      }
    });

    function onDocumentClick(e: MouseEvent) {
      if (e.defaultPrevented || !(e.target instanceof Element)) return;
      const anchor = e.target.closest<HTMLAnchorElement>("a[href]");
      if (!anchor || anchor.hasAttribute("download")) return;
      const rawHref = anchor.getAttribute("href");
      if (!rawHref || rawHref.startsWith("#")) return;
      let url: URL;
      try {
        url = new URL(anchor.href, window.location.origin);
      } catch {
        return;
      }
      if (url.origin !== window.location.origin) return;
      if (!url.pathname.startsWith("/") || url.pathname === "/inspector-panel") return;
      e.preventDefault();
      e.stopPropagation();
      post({
        v: 1,
        type: "openInMain",
        path: `${url.pathname}${url.search}${url.hash}`,
        newTab: e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1,
      });
    }

    document.addEventListener("click", onDocumentClick, true);
    return () => {
      offCommand();
      document.removeEventListener("click", onDocumentClick, true);
    };
  }, []);

  return (
    <div className="flex h-dvh min-h-0 flex-col bg-transparent text-fg">
      <LiveUpdates />
      {[...mounted.entries()].map(([key, spec]) => {
        const isActive = key === activeKey;
        return (
          <div key={key} className={isActive ? "flex min-h-0 flex-1 flex-col" : "hidden"}>
            <PanelEntry spec={spec} />
          </div>
        );
      })}
    </div>
  );
}
