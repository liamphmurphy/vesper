"use client";

import { useState } from "react";
import { libraryItemUrl } from "@/lib/api/client";
import { useDeleteLibraryItem, useLibrary, useSetLibraryLinkStatus, type LibraryItem } from "@/lib/api/library-hooks";
import { videoEmbedUrl } from "@/lib/chat-recommend";
import { cx } from "@/lib/cx";
import { timelineTime } from "@/lib/format";
import { summaryText } from "@/lib/chat-sources";
import { hostOf } from "@/lib/web-search";
import { Markdown } from "@/components/domain/markdown";
import { VideoFrame } from "@/components/domain/recommend-fence";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { undoable } from "@/components/ui/toast";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { Spinner } from "@/components/ui/loading";

const FILTERS = [{ key: "all", label: "All" }, { key: "video", label: "Videos" }, { key: "page", label: "Pages" }] as const;
type Filter = (typeof FILTERS)[number]["key"];

const done = (i: LibraryItem) => i.link_status === "done";

function LinkCard({ item }: { item: LibraryItem }) {
  const del = useDeleteLibraryItem();
  const status = useSetLibraryLinkStatus();
  const url = item.url ?? "";
  const embed = videoEmbedUrl(item.video_id);
  const image = item.size_bytes > 0 ? libraryItemUrl(item.id) : undefined;
  const site = item.site || hostOf(url);
  // Removed but still undoable: hidden here until the toast goes and the delete runs.
  const [hidden, setHidden] = useState(false);
  if (hidden) return null;
  return (
    <li data-testid="library-link" data-kind={embed ? "video" : "page"} className="flex min-w-0 flex-col overflow-hidden rounded-xl border border-border bg-surface">
      {embed ? (
        <VideoFrame embed={embed} title={item.title} image={image} videoId={item.video_id} />
      ) : (
        image && (
          <a href={url} target="_blank" rel="noopener noreferrer" className="relative block aspect-video bg-surface-sunken">
            {/* A same-origin, private URL: next/image would only add a proxy hop. */}
            <img src={image} alt="" loading="lazy" className="absolute inset-0 size-full object-cover" />
          </a>
        )
      )}
      <div className="flex flex-1 flex-col gap-1 p-3">
        <a href={url} target="_blank" rel="noopener noreferrer" className="flex items-start gap-2 hover:underline">
          <span className="min-w-0 flex-1 text-14 font-semibold text-fg">{item.title}</span>
          <Icon name="link" size={13} className="mt-0.5 flex-none text-fg-tertiary" />
        </a>
        <span className="truncate text-12 text-fg-tertiary">{site}</span>
        {item.note && <p className="mt-1 text-13 italic text-fg-secondary">“{item.note}”</p>}
        {item.summary && (
          <details data-testid="link-summary" className="mt-1 text-13">
            <summary className="cursor-pointer font-medium text-fg-secondary">Summary</summary>
            <Markdown className="mt-1.5 text-fg-2">{summaryText(item.summary)}</Markdown>
          </details>
        )}
        <div className="mt-auto flex items-center justify-between gap-2 pt-2 text-12 text-fg-tertiary">
          <span className="min-w-0 truncate">From {item.persona_name ?? "Assistant"} · {timelineTime(item.created_at)}</span>
          <button type="button" disabled={status.isPending} className="ml-auto flex-none text-accent hover:underline" onClick={() => status.mutate({ itemId: item.id, status: done(item) ? "to_read" : "done" })}>
            {done(item) ? "Move to To read" : "Mark done"}
          </button>
          <button
            type="button"
            aria-label={`Remove ${item.title}`}
            disabled={del.isPending}
            className="flex-none hover:text-fg"
            onClick={() => undoable({
              title: `Removed ${item.title}`,
              failed: `Couldn't remove ${item.title}`,
              hide: () => setHidden(true),
              restore: () => setHidden(false),
              commit: () => del.mutateAsync(item.id),
            })}
          >
            <Icon name="trash" size={14} />
          </button>
        </div>
      </div>
    </li>
  );
}

/** The Library's Links: pages and videos saved from a persona's recommendation. */
export function Links() {
  const lib = useLibrary("link");
  const [filter, setFilter] = useState<Filter>("all");
  const items = lib.data?.pages.flatMap((p) => p.items) ?? [];
  const [queue, setQueue] = useState<"to_read" | "done">("to_read");
  const shown = items.filter((i) => (queue === "done") === done(i) && (filter === "all" || (filter === "video") === !!i.video_id));
  const grid = "grid grid-cols-[repeat(auto-fill,minmax(250px,1fr))] items-start gap-4";
  if (lib.isError) {
    return (
      <Banner tone="blocked" title="Couldn't load your links" actions={<Button onClick={() => lib.refetch()}>Retry</Button>}>
        {lib.error.message}
      </Banner>
    );
  }
  if (lib.isPending) {
    return (
      <ul aria-busy="true" aria-label="Loading your links" className={grid}>
        {[0, 1, 2].map((i) => <li key={i}><Skeleton className="aspect-video w-full rounded-xl" /></li>)}
      </ul>
    );
  }
  if (items.length === 0) {
    return (
      <EmptyState icon="library" title="No saved links yet">
        When a persona recommends a page or video in a chat, choose Save to Library on its card to keep it here.
      </EmptyState>
    );
  }
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between gap-3">
      <div role="group" aria-label="Reading queue" className="flex gap-1 text-12">
        {(["to_read", "done"] as const).map((q) => (
          <button key={q} type="button" aria-pressed={queue === q} onClick={() => setQueue(q)} className={cx("rounded-full px-3 py-1", queue === q ? "bg-accent-soft font-semibold text-accent" : "text-fg-secondary hover:text-fg")}>
            {q === "done" ? "Done" : "To read"} ({items.filter((i) => (q === "done") === done(i)).length})
          </button>
        ))}
      </div>
      <div role="group" aria-label="Filter links" className="flex justify-end gap-1 text-12">
        {FILTERS.map((f) => (
          <button key={f.key} type="button" aria-pressed={filter === f.key} onClick={() => setFilter(f.key)} className={cx("rounded-full px-3 py-1", filter === f.key ? "bg-accent-soft font-semibold text-accent" : "text-fg-secondary hover:text-fg")}>
            {f.label}
          </button>
        ))}
      </div>
      </div>
      <ul className={grid}>
        {shown.map((it) => <LinkCard key={it.id} item={it} />)}
      </ul>
      {lib.hasNextPage && (
        <div className="flex justify-center">
          <Button onClick={() => lib.fetchNextPage()} disabled={lib.isFetchingNextPage}>
            {lib.isFetchingNextPage && <Spinner />}Show more
          </Button>
        </div>
      )}
    </div>
  );
}
