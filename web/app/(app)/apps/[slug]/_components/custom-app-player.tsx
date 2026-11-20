"use client";

import { useEffect, useRef } from "react";
import { isTyping } from "@/components/shell/shortcuts";
import { IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { cx } from "@/lib/cx";
import type { VideoEmbed } from "@/lib/custom-app-bridge";

export type StageVideo = VideoEmbed & { title: string };

/**
 * The player a custom app opens with playVideo, docked above the app like a watch page rather than
 * in a popup. The host renders it, not the app's sandboxed frame: embeds inside that frame would
 * inherit its sandbox (no storage, an opaque parent Twitch refuses) and a downloaded video there
 * wouldn't carry the session cookie. Theater widens it to the whole width and, through the caller,
 * folds the window's sidebar.
 */
export function CustomAppPlayerStage({
  video,
  theater,
  onTheaterChange,
  onClose,
}: {
  video: StageVideo;
  theater: boolean;
  onTheaterChange: (theater: boolean) => void;
  onClose: () => void;
}) {
  // Esc leaves theater first, then closes; T toggles theater. Keys pressed inside the app's frame or
  // the player's own iframe never reach this window, so they can't trigger it by accident.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target) || document.querySelector('[role="dialog"]')) return;
      if (e.key === "Escape") {
        e.preventDefault();
        if (theater) onTheaterChange(false);
        else onClose();
      } else if (e.key === "t" || e.key === "T") {
        e.preventDefault();
        onTheaterChange(!theater);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [theater, onTheaterChange, onClose]);

  // A new video brings the player into view if the app was scrolled past it.
  const stageRef = useRef<HTMLElement>(null);
  useEffect(() => {
    stageRef.current?.scrollIntoView({ block: "nearest" });
  }, [video.embedUrl]);

  // The player keeps 16:9 and fits the height left for it: most of the window in theater, about
  // half of it otherwise, so the app's list stays in view below.
  const maxHeight = theater ? "calc(100dvh - 9rem)" : "56dvh";

  return (
    <section
      ref={stageRef}
      aria-label="Video player"
      data-testid="custom-app-player"
      data-theater={theater ? "true" : "false"}
      className={cx("flex-none border-b border-border-subtle", theater ? "bg-black" : "bg-bg px-4 pt-3")}
    >
      <div className={cx("mx-auto flex w-full flex-col", !theater && "max-w-[1280px]")}>
        <div className="flex justify-center bg-black">
          <div
            className={cx("relative aspect-video w-full overflow-hidden bg-black", !theater && "rounded-lg")}
            style={{ maxWidth: `calc(${maxHeight} * 16 / 9)` }}
          >
            {video.provider === "local" ? (
              <video
                key={video.embedUrl}
                src={video.embedUrl}
                title={video.title}
                controls
                autoPlay
                playsInline
                data-testid="custom-app-local-video"
                className="absolute inset-0 size-full"
              />
            ) : (
              <iframe
                key={video.embedUrl}
                src={video.embedUrl}
                title={video.title}
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowFullScreen
                referrerPolicy="strict-origin-when-cross-origin"
                className="absolute inset-0 size-full border-0"
              />
            )}
          </div>
        </div>
        <div className={cx("flex items-center gap-2 py-2", theater ? "bg-bg px-4" : "")}>
          <h2 className="min-w-0 flex-1 truncate text-14 font-semibold text-fg">{video.title}</h2>
          {video.provider !== "local" && (
            <a
              href={video.externalUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex h-7 flex-none items-center gap-1.5 rounded-md border border-border-strong px-2.5 text-12 font-medium text-fg-secondary transition-colors hover:bg-hover hover:text-fg"
            >
              <Icon name="link" size={13} />
              {video.provider === "youtube" ? "Open on YouTube" : "Open on Twitch"}
            </a>
          )}
          <IconButton
            icon={theater ? "shrink" : "expand"}
            label={theater ? "Exit theater mode (T)" : "Theater mode (T)"}
            aria-pressed={theater}
            onClick={() => onTheaterChange(!theater)}
          />
          <IconButton icon="x" label="Close video player (Esc)" onClick={onClose} />
        </div>
      </div>
    </section>
  );
}
