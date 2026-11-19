"use client";

import { useEffect, useRef } from "react";
import { useChatCanvases } from "@/lib/api/canvas-hooks";
import { useCanvasPanel } from "@/lib/use-canvas-panel";
import { DesignEditor } from "@/app/(app)/apps/designs/_components/design-editor";

/**
 * A design open beside the chat (docs/design/designs-from-chat.svg): the editor with a
 * cut-down toolbar and Pause, chosen through use-canvas-panel like a canvas card. A design
 * the persona starts while the chat is open (design_create) opens here by itself.
 */
/** Opens a design the persona starts while the chat is open (design_create). Key the caller by chat. */
export function useOpenNewDesigns(chatId: string, live: boolean) {
  const panel = useCanvasPanel();
  const list = useChatCanvases(chatId, live).data?.canvases;
  const ids = (list ?? []).filter((c) => c.kind === "design").map((c) => c.id);
  const key = ids.join(",");
  // The designs there were when the chat opened; one that appears after is new and opens.
  const seen = useRef<Set<string> | null>(null);
  const show = panel.show;
  useEffect(() => {
    if (!list) return;
    if (!seen.current) {
      seen.current = new Set(ids);
      return;
    }
    const fresh = ids.filter((id) => !seen.current!.has(id));
    for (const id of fresh) seen.current.add(id);
    if (fresh.length) show(fresh[fresh.length - 1]);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs when the set of designs changes
  }, [key, !!list]);
  return ids;
}

export type DesignPanelHost = {
  designId?: string;
  reviewing?: boolean;
  hideClose?: boolean;
  onClose?: () => void;
  onReview?: (on: boolean) => void;
};

/** The design open in the chat: it fills the desktop dock's Design tab or the compact panel sheet, and reviews its suggestions in place (review=1). */
export function DesignPanel({ chatId, live, host }: { chatId: string; live: boolean; host?: DesignPanelHost }) {
  const panel = useCanvasPanel();
  const list = useChatCanvases(chatId, live).data?.canvases;
  const ids = (list ?? []).filter((c) => c.kind === "design").map((c) => c.id);
  const focus = host ? (host.designId && ids.includes(host.designId) ? host.designId : ids[ids.length - 1]) : panel.focus;
  const open = focus && ids.includes(focus) && (host || !panel.fullscreen) ? focus : undefined;
  if (!open) return null;
  return (
    <aside aria-label="Design beside the chat" data-testid="design-panel" className="flex min-h-0 flex-1 flex-col bg-surface-sunken">
      <DesignEditor
        key={open}
        id={open}
        beside={{
          onClose: host?.onClose ?? panel.collapse,
          reviewing: host ? host.reviewing : panel.reviewing,
          hideClose: host?.hideClose,
          onReview: host?.onReview ?? ((on) => (on ? panel.review(open) : panel.show(open))),
        }}
      />
    </aside>
  );
}
