"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { DesignPanel } from "@/app/(app)/chat/_components/design-panel";
import { CustomAppCodePanel } from "@/app/(app)/apps/[slug]/_components/custom-app-screen";
import { DeckReview } from "@/app/(app)/apps/slides/_components/deck-review";
import { CanvasDock } from "@/components/domain/canvas-view";
import { PlaygroundPanel } from "@/components/domain/playground";
import { LiveUpdates } from "@/components/shell/live-updates";
import { applyNativeAppearance } from "@/components/shell/theme";
import { Skeleton } from "@/components/ui/primitives";
import { useCanvasActions, useChatCanvas } from "@/lib/api/canvas-hooks";
import { useMarkDocReviewed } from "@/lib/api/docs-hooks";
import { onCommand, post } from "@/lib/native-shell/bridge";
import { encodeComposerDrop, parsePanelProps } from "@/lib/native-shell/panel-events";
import type { InspectorPanelContext, InspectorPanelSpec } from "@/lib/native-shell/protocol";
import { assetHref, useSlideFonts } from "@/lib/slides/render";
import { encodeDeck, parseDeck } from "@/lib/slides/schema";
import type { PlaygroundTab } from "@/lib/use-playground-panel";

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

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

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
    case "customApp.code": {
      if (typeof props.slug !== "string") return null;
      return <CustomAppCodePanel slug={props.slug} />;
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

export default function NativeInspectorPanelPage() {
  const [activeKey, setActiveKey] = useState<string | null>(null);
  const [mounted, setMounted] = useState<Map<string, InspectorPanelSpec>>(() => new Map());

  useEffect(() => {
    post({ v: 1, type: "ready", path: "/inspector-panel" });
    const offCommand = onCommand((cmd) => {
      if (cmd.type === "appearance") {
        applyNativeAppearance(cmd);
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
