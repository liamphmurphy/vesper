"use client";

import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { useDesign, useDesignVersion } from "@/lib/api/designs-hooks";
import { designCounts } from "@/lib/designs/card";
import { DesignSvg, designAssetHref, useDesignFonts } from "@/lib/designs/render";
import { normalize } from "@/lib/designs/schema";
import { useCanvasPanel } from "@/lib/use-canvas-panel";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { LoadingText } from "@/components/ui/loading";

/**
 * A design in a chat's transcript (docs/design/designs-from-chat.svg): a live thumbnail
 * of its first page from the design renderer, what it holds, Present and Open (beside the
 * chat), and how many of the persona's suggestions wait for review, with Review opening them in the chat's dock.
 */
export function DesignCard({ id, title }: { id: string; title: string }) {
  const router = useRouter();
  const panel = useCanvasPanel();
  const ref = useDesign(id);
  const seq = ref.data?.seq;
  const version = useDesignVersion(id, seq);
  useDesignFonts();
  const body = useMemo(() => {
    try {
      return version.data ? normalize(version.data.body).design : undefined;
    } catch {
      return undefined;
    }
  }, [version.data]);
  // The renderer may be down (or not run here): the same display list drawn in the browser stands in.
  const [failed, setFailed] = useState<number>();
  const pending = ref.data?.pending_proposals ?? 0;
  const open = panel.focus === id && !panel.fullscreen;
  const name = ref.data?.title ?? title;
  return (
    <div data-testid="design-chat-card" data-design-card={id} className="flex w-[420px] max-w-full flex-col overflow-hidden rounded-xl border border-border bg-surface">
      <button
        type="button"
        aria-label={`Open ${name} beside the chat`}
        onClick={() => panel.show(id)}
        className="relative block h-[104px] overflow-hidden border-b border-border-subtle bg-surface-sunken p-2 [background-image:radial-gradient(var(--color-border-subtle)_1px,transparent_1px)] [background-size:16px_16px]"
      >
        {seq && failed !== seq ? (
          // eslint-disable-next-line @next/next/no-img-element -- a PNG from the design renderer, keyed by version
          <img data-testid="design-card-thumb" src={`/api/v1/designs/${id}/render?v=${seq}`} alt={`First page of ${name}`} className="mx-auto block h-full w-auto max-w-full object-contain" onError={() => setFailed(seq)} />
        ) : body ? (
          <DesignSvg design={body} assetUrl={(a) => designAssetHref(id, a)} className="block h-full w-full" title={`First page of ${name}`} pad={4} />
        ) : (
          <Skeleton className="h-full w-full opacity-40" />
        )}
        {pending > 0 && (
          <span data-testid="design-card-review" className="absolute right-2 top-2 rounded-full bg-pill-review-bg px-2 py-0.5 text-11 font-medium text-pill-review-fg">
            {pending} to review
          </span>
        )}
      </button>
      <div className="flex items-center gap-3 px-3.5 py-3">
        <span aria-hidden className="grid size-[22px] flex-none place-items-center rounded-md bg-accent/15 text-accent">
          <Icon name="designs" size={14} />
        </span>
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">Design</span>
          <span className="truncate text-13 font-semibold text-fg">{name}</span>
          <span data-testid="design-card-counts" className="truncate text-12 text-fg-tertiary">{body ? designCounts(body) : ref.isError ? "Couldn’t load this design" : <LoadingText />}</span>
        </span>
        <Button variant="secondary" disabled={!body} onClick={() => router.push(`/present/designs/${id}`)}>
          Present
        </Button>
        <Button variant="primary" aria-pressed={open} disabled={ref.isError} onClick={() => panel.show(id)}>
          Open
        </Button>
        {pending > 0 && (
          <Button variant="approve" disabled={ref.isError} onClick={() => panel.review(id)}>
            Review
          </Button>
        )}
      </div>
    </div>
  );
}
