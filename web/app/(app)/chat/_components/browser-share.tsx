"use client";

import { Banner } from "@/components/ui/primitives";
import { Button } from "@/components/ui/button";
import { useStopBrowserShare } from "@/lib/api/browser-share-hooks";
import { shareDetail, shareLabel, type BrowserShare } from "@/lib/browser-share";

/**
 * The Safari tab shared with this chat, above the composer while sharing
 * lasts. The persona reads it with browser_snapshot; Stop here ends it the
 * same as Stop in Safari's popover.
 */
export function BrowserShareBanner({ chatId, share, disabled }: { chatId: string; share: BrowserShare; disabled?: boolean }) {
  const stop = useStopBrowserShare(chatId);
  return (
    <Banner
      tone="human"
      lead={<span aria-hidden className="size-2 shrink-0 rounded-full" style={{ background: "var(--state-human)" }} />}
      title={
        <>
          Sharing from Safari:{" "}
          <a href={share.url} target="_blank" rel="noreferrer noopener" className="hover:underline">
            {shareLabel(share)}
          </a>
        </>
      }
      actions={
        <Button variant="outline" icon="x" disabled={disabled || stop.isPending} onClick={() => stop.mutate()}>
          Stop sharing
        </Button>
      }
    >
      <span data-testid="browser-share-detail">{shareDetail(share)}</span>
      {stop.error ? <span role="alert" className="block text-pill-blocked-fg">Couldn’t stop sharing: {stop.error.message}</span> : null}
    </Banner>
  );
}
