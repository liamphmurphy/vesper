"use client";

import { useContext, useEffect, useState } from "react";
import { Dialog } from "radix-ui";
import type { Schemas } from "@/lib/api/client";
import { useLinkPreviews } from "@/lib/api/hooks";
import { useSaveLibraryLink } from "@/lib/api/library-hooks";
import { mediaHost, parseGallery, parseProduct, type GalleryItem, type ProductItem } from "@/lib/chat-media";
import { Icon } from "@/components/ui/icon";
import { CodeFence } from "./code-fence";
import { SvgFenceMessage } from "./svg-fence";

function resolveProxy(
  previews: Schemas["LinkPreview"][] | undefined,
  image?: string,
  url?: string,
): { imgSrc?: string; preview?: Schemas["LinkPreview"] } {
  if (!previews?.length) return {};
  const byImg = image ? previews.find((p) => p.url === image) : undefined;
  const byUrl = url ? previews.find((p) => p.url === url) : undefined;
  const imgSrc = byImg?.image_url ?? byUrl?.image_url;
  return { imgSrc, preview: byUrl ?? byImg };
}

function SaveLinkChip({ messageId, url, saved }: { messageId?: string; url?: string; saved?: boolean }) {
  const save = useSaveLibraryLink();
  if (!messageId || !url) return null;
  if (saved || save.isSuccess) {
    return (
      <span className="inline-flex h-6 items-center gap-1 rounded-md bg-accent-soft px-2 text-11 font-semibold text-accent">
        <Icon name="check" size={11} />
        Saved
      </span>
    );
  }
  return (
    <button
      type="button"
      disabled={save.isPending}
      onClick={(e) => {
        e.stopPropagation();
        save.mutate({ message_id: messageId, url });
      }}
      className="inline-flex h-6 items-center gap-1 rounded-md border border-border-strong px-2 text-11 font-medium text-fg-secondary transition-colors hover:bg-hover hover:text-fg disabled:opacity-50"
    >
      <Icon name="bookmark" size={11} />
      {save.isPending ? "Saving…" : "Save"}
    </button>
  );
}

/** A ```gallery fence: server-proxied web/article photos with click-to-zoom lightbox. */
export function GalleryFence({ code, info }: { code: string; info?: string }) {
  const spec = parseGallery(code);
  const messageId = useContext(SvgFenceMessage);
  const q = useLinkPreviews(spec ? messageId : undefined);
  const [lightbox, setLightbox] = useState<number | null>(null);
  const [broken, setBroken] = useState<Record<number, boolean>>({});

  useEffect(() => {
    if (lightbox === null || !spec) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") setLightbox((i) => (i === null ? null : (i + 1) % spec.items.length));
      if (e.key === "ArrowLeft") setLightbox((i) => (i === null ? null : (i - 1 + spec.items.length) % spec.items.length));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [lightbox, spec]);

  if (!spec) return <CodeFence code={code} info={info} />;
  const previews = q.data?.previews;
  const active: GalleryItem | undefined = lightbox !== null ? spec.items[lightbox] : undefined;
  const activeProxy = active ? resolveProxy(previews, active.image, active.url) : undefined;

  return (
    <div data-testid="gallery-card" className="w-full overflow-hidden rounded-xl border border-border bg-surface">
      {spec.title && (
        <div className="flex items-center justify-between border-b border-border-subtle px-3 py-2">
          <span className="text-13 font-semibold text-fg">{spec.title}</span>
          <span className="text-11 text-fg-tertiary">{spec.items.length} {spec.items.length === 1 ? "image" : "images"}</span>
        </div>
      )}
      <div className="grid grid-cols-[repeat(auto-fill,minmax(190px,1fr))] gap-2.5 p-3">
        {spec.items.map((item, idx) => {
          const { imgSrc, preview } = resolveProxy(previews, item.image, item.url);
          const host = item.source || preview?.site || mediaHost(item.url ?? item.image);
          const saveUrl = item.url ?? item.image;
          const showImg = !!imgSrc && !broken[idx];
          return (
            <div key={idx} className="group flex flex-col overflow-hidden rounded-lg border border-border bg-surface-sunken">
              <button
                type="button"
                aria-label={item.caption ? `Zoom ${item.caption}` : `Zoom image ${idx + 1}`}
                onClick={() => setLightbox(idx)}
                className="relative aspect-[4/3] w-full overflow-hidden bg-surface-sunken text-left"
              >
                {showImg ? (
                  <img
                    src={imgSrc}
                    alt={item.caption ?? ""}
                    onError={() => setBroken((b) => ({ ...b, [idx]: true }))}
                    className="size-full object-cover transition-transform duration-(--motion-fast) group-hover:scale-[1.03]"
                  />
                ) : messageId && q.isPending ? (
                  <div className="size-full animate-pulse bg-hover" />
                ) : (
                  <div className="grid size-full place-items-center text-fg-tertiary">
                    <Icon name="library" size={22} />
                  </div>
                )}
                {host && (
                  <span className="absolute bottom-1.5 left-1.5 max-w-[calc(100%-12px)] truncate rounded-full px-2 py-0.5 text-11 font-medium text-white" style={{ background: "rgb(0 0 0 / 0.6)" }}>
                    {host}
                  </span>
                )}
              </button>
              <div className="flex flex-1 flex-col gap-1.5 bg-surface p-2">
                {item.caption && <p className="line-clamp-2 text-12 text-fg">{item.caption}</p>}
                <div className="mt-auto flex items-center justify-between gap-1.5 pt-0.5">
                  {item.url ? (
                    <a href={item.url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-11 font-medium text-accent hover:underline">
                      Source
                      <Icon name="link" size={11} />
                    </a>
                  ) : <span />}
                  <SaveLinkChip messageId={messageId} url={saveUrl} saved={preview?.saved} />
                </div>
              </div>
            </div>
          );
        })}
      </div>

      <Dialog.Root open={lightbox !== null} onOpenChange={(o) => !o && setLightbox(null)}>
        <Dialog.Portal>
          <Dialog.Overlay className="fixed inset-0 z-50 bg-black/75 backdrop-blur-xs" />
          <Dialog.Content
            aria-describedby={undefined}
            className="fixed left-1/2 top-1/2 z-50 flex max-h-[90vh] w-[min(920px,calc(100vw-32px))] -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-2xl outline-none"
          >
            <div className="flex items-center justify-between gap-3 border-b border-border-subtle px-4 py-2.5">
              <Dialog.Title className="truncate text-14 font-semibold text-fg">
                {active?.caption || spec.title || "Image preview"}
              </Dialog.Title>
              <div className="flex items-center gap-2">
                {spec.items.length > 1 && lightbox !== null && (
                  <span className="font-mono text-12 text-fg-tertiary">{lightbox + 1} / {spec.items.length}</span>
                )}
                <Dialog.Close asChild>
                  <button type="button" aria-label="Close preview" className="grid size-7 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg">
                    <Icon name="x" size={14} />
                  </button>
                </Dialog.Close>
              </div>
            </div>
            <div className="relative flex min-h-[280px] flex-1 items-center justify-center bg-surface-sunken p-4">
              {activeProxy?.imgSrc ? (
                <img src={activeProxy.imgSrc} alt={active?.caption ?? ""} className="max-h-[68vh] max-w-full rounded-lg object-contain" />
              ) : (
                <p className="text-13 text-fg-tertiary">Image preview unavailable.</p>
              )}
            </div>
            {active && (
              <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border-subtle px-4 py-2.5">
                <div className="flex items-center gap-2">
                  {spec.items.length > 1 && (
                    <>
                      <button
                        type="button"
                        onClick={() => setLightbox((i) => (i === null ? null : (i - 1 + spec.items.length) % spec.items.length))}
                        className="rounded-md border border-border px-2.5 py-1 text-12 text-fg hover:bg-hover"
                      >
                        Prev
                      </button>
                      <button
                        type="button"
                        onClick={() => setLightbox((i) => (i === null ? null : (i + 1) % spec.items.length))}
                        className="rounded-md border border-border px-2.5 py-1 text-12 text-fg hover:bg-hover"
                      >
                        Next
                      </button>
                    </>
                  )}
                  <span className="text-12 text-fg-tertiary">{active.source || mediaHost(active.url ?? active.image)}</span>
                </div>
                <div className="flex items-center gap-2">
                  <SaveLinkChip messageId={messageId} url={active.url ?? active.image} saved={activeProxy?.preview?.saved} />
                  {active.url && (
                    <a href={active.url} target="_blank" rel="noopener noreferrer" className="inline-flex h-6 items-center gap-1 rounded-md bg-accent px-2.5 text-11 font-medium text-on-accent hover:brightness-110">
                      Open source
                      <Icon name="link" size={11} />
                    </a>
                  )}
                </div>
              </div>
            )}
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </div>
  );
}

function ProductCard({
  item,
  imgSrc,
  preview,
  loading,
  messageId,
}: {
  item: ProductItem;
  imgSrc?: string;
  preview?: Schemas["LinkPreview"];
  loading: boolean;
  messageId?: string;
}) {
  const [broken, setBroken] = useState(false);
  const host = preview?.site || mediaHost(item.url ?? item.image);
  const saveUrl = item.url ?? item.image;

  return (
    <div className="flex flex-col overflow-hidden rounded-xl border border-border bg-surface">
      <div className="relative aspect-[16/10] w-full bg-surface-sunken">
        {imgSrc && !broken ? (
          <img src={imgSrc} alt={item.name} onError={() => setBroken(true)} className="size-full object-cover" />
        ) : loading ? (
          <div className="size-full animate-pulse bg-hover" />
        ) : (
          <div className="grid size-full place-items-center text-fg-tertiary">
            <Icon name="library" size={24} />
          </div>
        )}
        {item.badge && (
          <span className="absolute left-2 top-2 rounded-full bg-accent px-2 py-0.5 text-11 font-semibold text-on-accent shadow-xs">
            {item.badge}
          </span>
        )}
        {item.price && (
          <span className="absolute bottom-2 right-2 rounded-md px-2 py-0.5 font-mono text-12 font-semibold text-white" style={{ background: "rgb(0 0 0 / 0.72)" }}>
            {item.price}
          </span>
        )}
      </div>
      <div className="flex flex-1 flex-col gap-2 p-3">
        <div className="flex items-start justify-between gap-2">
          {item.url ? (
            <a href={item.url} target="_blank" rel="noopener noreferrer" className="text-14 font-semibold text-fg hover:text-accent hover:underline">
              {item.name}
            </a>
          ) : (
            <span className="text-14 font-semibold text-fg">{item.name}</span>
          )}
          {item.rating && (
            <span className="flex-none rounded bg-accent-soft px-1.5 py-0.5 font-mono text-11 font-semibold text-accent">
              ★ {item.rating}
            </span>
          )}
        </div>
        {host && <span className="text-11 text-fg-tertiary">{host}</span>}
        {(item.description || preview?.description) && (
          <p className="line-clamp-2 text-12 text-fg-secondary">{item.description || preview?.description}</p>
        )}
        {item.specs.length > 0 && (
          <ul className="flex flex-wrap gap-1">
            {item.specs.map((s, i) => (
              <li key={i} className="rounded-md border border-border-subtle bg-surface-sunken px-1.5 py-0.5 text-11 text-fg-secondary">
                {s}
              </li>
            ))}
          </ul>
        )}
        <div className="mt-auto flex items-center justify-between gap-2 border-t border-border-subtle pt-2">
          {item.url ? (
            <a href={item.url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-12 font-medium text-accent hover:underline">
              View product
              <Icon name="link" size={12} />
            </a>
          ) : <span />}
          <SaveLinkChip messageId={messageId} url={saveUrl} saved={preview?.saved} />
        </div>
      </div>
    </div>
  );
}

/** A ```product fence: side-by-side product cards with server-proxied images, price/rating and specs. */
export function ProductFence({ code, info }: { code: string; info?: string }) {
  const spec = parseProduct(code);
  const messageId = useContext(SvgFenceMessage);
  const q = useLinkPreviews(spec ? messageId : undefined);
  if (!spec) return <CodeFence code={code} info={info} />;
  const previews = q.data?.previews;

  return (
    <div data-testid="product-cards" className="flex w-full flex-col gap-2">
      {spec.title && <h4 className="text-13 font-semibold text-fg">{spec.title}</h4>}
      <div className="grid grid-cols-[repeat(auto-fill,minmax(230px,1fr))] gap-3">
        {spec.items.map((item, idx) => {
          const { imgSrc, preview } = resolveProxy(previews, item.image, item.url);
          return (
            <ProductCard
              key={idx}
              item={item}
              imgSrc={imgSrc}
              preview={preview}
              loading={!!messageId && q.isPending}
              messageId={messageId}
            />
          );
        })}
      </div>
    </div>
  );
}
