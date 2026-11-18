"use client";

import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useLinkPreviews } from "@/lib/api/hooks";
import { useSaveLibraryLink, useSaveLibraryLinkSummary } from "@/lib/api/library-hooks";
import { parseRecommend, summarizePrompt, videoEmbedUrl } from "@/lib/chat-recommend";
import { hostOf } from "@/lib/web-search";
import { Icon } from "@/components/ui/icon";
import { CodeFence } from "./code-fence";
import { SvgFenceMessage } from "./svg-fence";

/**
 * What the chat lets a fence do: send a message to the persona that wrote this reply,
 * and see what the person said next (which answers a choices fence).
 */
export const RecommendActions = createContext<{
  ask: (messageId: string, body: string) => void;
  disabled: boolean;
  nextMessage: (messageId: string) => string | undefined;
  chatId?: string;
  project?: string;
  researchMore?: (artifactId: string, title: string) => void;
  /** Where this chat's canvas cards are, and whether they can be changed right now. */
  canvas?: { newest?: string; lastMessage: (canvasId: string) => string | undefined; live: boolean; readOnly: boolean; agent: string };
} | undefined>(undefined);

/** The chat's playing-capable videos by id, so a timestamp link can jump one to a moment. */
export const VideoPlayers = createContext<Map<string, (seconds: number) => void> | undefined>(undefined);

const FRAME = "overflow-hidden rounded-xl border border-border bg-surface";
const WIDTH = "w-[380px] max-w-full";
const ACTION = "inline-flex h-[30px] items-center gap-1.5 rounded-lg border border-border-strong px-2.5 text-13 font-medium text-fg transition-colors hover:bg-hover disabled:cursor-default disabled:opacity-50 disabled:hover:bg-transparent";

function Note({ note }: { note: string }) {
  return note ? <p className="mt-2 text-13 italic text-fg-secondary">“{note}”</p> : null;
}

function Badge({ children }: { children: string }) {
  return <span className="absolute left-2.5 top-2.5 rounded-full px-2.5 py-0.5 text-12 font-semibold" style={{ background: "rgb(0 0 0 / 0.55)", color: "#fff" }}>{children}</span>;
}

function OpenMark() {
  return <Icon name="link" size={13} className="flex-none text-fg-tertiary" />;
}

/** A video's thumbnail until it's played; the player, and any contact with YouTube, starts only on the click. */
export function VideoFrame({ embed, title, image, videoId }: { embed: string; title: string; image?: string; videoId?: string }) {
  const [playing, setPlaying] = useState(false);
  const [start, setStart] = useState<number>();
  const frame = useRef<HTMLDivElement>(null);
  const players = useContext(VideoPlayers);
  useEffect(() => {
    if (!players || !videoId) return;
    const seek = (s: number) => {
      setStart(s);
      setPlaying(true);
      frame.current?.scrollIntoView({ block: "center", behavior: "smooth" });
    };
    players.set(videoId, seek);
    return () => {
      if (players.get(videoId) === seek) players.delete(videoId);
    };
  }, [players, videoId]);
  return (
    <div ref={frame} className="relative aspect-video bg-surface-sunken">
      {playing ? (
        <iframe key={start ?? -1} src={start === undefined ? embed : `${embed}&start=${start}`} title={title} allow="autoplay; encrypted-media; picture-in-picture; fullscreen" referrerPolicy="strict-origin-when-cross-origin" className="absolute inset-0 size-full border-0" />
      ) : (
        <button type="button" aria-label={`Play ${title}`} onClick={() => setPlaying(true)} className="group absolute inset-0 grid place-items-center">
          {/* A same-origin, private URL: next/image would only add a proxy hop. */}
          {image && <img src={image} alt="" className="absolute inset-0 size-full object-cover" />}
          <Badge>Video</Badge>
          <span aria-hidden className="relative grid size-14 place-items-center rounded-full shadow-md transition-transform group-hover:scale-105" style={{ background: "rgb(255 255 255 / 0.95)", color: "#17171c" }}>
            <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M8 5.5v13l11-6.500z" /></svg>
          </span>
        </button>
      )}
    </div>
  );
}

/** Summarize and Save to Library, under a card in a stored reply. */
function CardActions({ url, preview, messageId }: { url: string; preview?: Schemas["LinkPreview"]; messageId?: string }) {
  const actions = useContext(RecommendActions);
  const save = useSaveLibraryLink();
  if (!messageId || !actions) return null;
  const video = preview?.kind === "video";
  const saved = !!preview?.saved || save.isSuccess;
  return (
    <div data-testid="recommend-actions" className="flex flex-wrap items-center gap-2 border-t border-border-subtle p-2.5">
      <button type="button" className={ACTION} disabled={actions.disabled} onClick={() => actions.ask(messageId, summarizePrompt(url, preview?.title, video))}>
        <Icon name="artifacts" size={13} className="text-fg-secondary" />
        {video ? "Summarize video" : "Summarize page"}
      </button>
      {saved ? (
        <span className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-accent-soft px-2.5 text-13 font-semibold text-accent">
          <Icon name="check" size={13} />
          Saved
        </span>
      ) : (
        <button type="button" className={ACTION} disabled={save.isPending} onClick={() => save.mutate({ message_id: messageId, url })}>
          <Icon name="bookmark" size={13} className="text-fg-secondary" />
          {save.isPending ? "Saving…" : "Save to Library"}
        </button>
      )}
      {save.isError && <span role="alert" className="text-12 text-pill-blocked-fg">{save.error.message || "Couldn’t save."}</span>}
    </div>
  );
}

/** Under a reply that summarizes a link: keeps the summary with the link in the Library. */
export function SaveSummary({ messageId, url }: { messageId: string; url: string }) {
  const save = useSaveLibraryLinkSummary();
  return (
    <div className="flex flex-wrap items-center gap-2">
      {save.isSuccess ? (
        <span className="inline-flex h-[30px] items-center gap-1.5 rounded-lg bg-accent-soft px-2.5 text-13 font-semibold text-accent">
          <Icon name="check" size={13} />
          Summary saved
        </span>
      ) : (
        <button type="button" className={ACTION} disabled={save.isPending} onClick={() => save.mutate({ message_id: messageId, url })}>
          <Icon name="bookmark" size={13} className="text-fg-secondary" />
          {save.isPending ? "Saving…" : "Save summary to Library"}
        </button>
      )}
      {save.isError && <span role="alert" className="text-12 text-pill-blocked-fg">{save.error.message || "Couldn’t save."}</span>}
    </div>
  );
}

function Shell({ kind, children }: { kind: string; children: ReactNode }) {
  return <div data-testid="recommend-card" data-kind={kind} className={`${WIDTH} ${FRAME}`}>{children}</div>;
}

/** No title or image to show: a compact link, with the persona's reason. */
function CompactCard({ url, title, note, actions }: { url: string; title?: string; note: string; actions: ReactNode }) {
  const host = hostOf(url);
  return (
    <Shell kind="link">
      <a href={url} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2.5 p-2.5 transition-colors hover:bg-hover">
        <span aria-hidden className="grid size-8 flex-none place-items-center rounded-lg bg-surface-sunken text-14 font-bold text-fg-secondary">{host.slice(0, 1).toUpperCase()}</span>
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-13 font-semibold text-fg">{title || `${host}${new URL(url).pathname.replace(/\/$/, "")}`}</span>
          {note ? <span className="truncate text-12 italic text-fg-secondary">“{note}”</span> : title && <span className="truncate text-12 text-fg-tertiary">{host}</span>}
        </span>
        <OpenMark />
      </a>
      {actions}
    </Shell>
  );
}

function VideoCard({ url, preview, embed, note, actions }: { url: string; preview: Schemas["LinkPreview"]; embed: string; note: string; actions: ReactNode }) {
  return (
    <Shell kind="video">
      <VideoFrame embed={embed} title={preview.title} image={preview.image_url} videoId={preview.video_id} />
      <div className="p-3">
        <a href={url} target="_blank" rel="noopener noreferrer" className="flex items-start gap-2 hover:underline">
          <span className="min-w-0 flex-1 text-14 font-semibold text-fg">{preview.title}</span>
          <OpenMark />
        </a>
        <p className="mt-0.5 truncate text-12 text-fg-tertiary">{[preview.site, hostOf(url)].filter(Boolean).join(" · ")}</p>
        <Note note={note} />
      </div>
      {actions}
    </Shell>
  );
}

function SiteCard({ url, preview, note, actions }: { url: string; preview: Schemas["LinkPreview"]; note: string; actions: ReactNode }) {
  const [broken, setBroken] = useState(false);
  if (!preview.image_url || broken) return <CompactCard url={url} title={preview.title} note={note} actions={actions} />;
  return (
    <Shell kind="site">
      <a href={url} target="_blank" rel="noopener noreferrer" className="block">
        <span className="relative block aspect-video bg-surface-sunken">
          <img src={preview.image_url} alt="" onError={() => setBroken(true)} className="absolute inset-0 size-full object-cover" />
          <Badge>Website</Badge>
        </span>
        <span className="block p-3">
          <span className="flex items-start gap-2">
            <span className="min-w-0 flex-1 text-14 font-semibold text-fg">{preview.title}</span>
            <OpenMark />
          </span>
          <span className="mt-0.5 block truncate text-12 text-fg-tertiary">{preview.site || hostOf(url)}</span>
          {note ? <Note note={note} /> : preview.description && <span className="mt-2 line-clamp-2 block text-13 text-fg-secondary">{preview.description}</span>}
        </span>
      </a>
      {actions}
    </Shell>
  );
}

/** A ```recommend fence: a card for the page or video a persona says to go look at. */
export function RecommendFence({ code, info }: { code: string; info?: string }) {
  const parsed = parseRecommend(code);
  const messageId = useContext(SvgFenceMessage);
  const q = useLinkPreviews(parsed ? messageId : undefined);
  if (!parsed) return <CodeFence code={code} info={info} />;
  const { url, note } = parsed;
  // Sized like the card it usually becomes, so the reply doesn't jump when it arrives.
  if (messageId && q.isPending) return <div data-testid="recommend-loading" aria-label="Loading preview" className={`${WIDTH} ${FRAME} h-[372px] animate-pulse`} />;
  const preview = q.data?.previews.find((p) => p.url === url);
  const actions = <CardActions url={url} preview={preview} messageId={messageId} />;
  if (!preview?.title) return <CompactCard url={url} note={note} actions={actions} />;
  const embed = preview.kind === "video" ? videoEmbedUrl(preview.video_id) : null;
  return embed ? <VideoCard url={url} preview={preview} embed={embed} note={note} actions={actions} /> : <SiteCard url={url} preview={preview} note={note} actions={actions} />;
}
