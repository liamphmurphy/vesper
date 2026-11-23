"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { isTyping } from "@/components/shell/shortcuts";
import { IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { cx } from "@/lib/cx";
import type { VideoEmbed } from "@/lib/custom-app-bridge";

export type StageVideo = VideoEmbed & { title: string };

type WebKitVideoElement = HTMLVideoElement & {
  webkitShowPlaybackTargetPicker?: () => void;
  webkitCurrentPlaybackTargetIsWireless?: boolean;
};

type WebKitPlaybackTargetAvailabilityEvent = Event & {
  availability?: "available" | "not-available";
};

function externalLinkLabel(video: StageVideo): string {
  if (video.provider === "youtube") return "Open on YouTube";
  if (video.provider === "twitch") return "Open on Twitch";
  try {
    const host = new URL(video.externalUrl).hostname.toLowerCase();
    if (host === "twitch.tv" || host.endsWith(".twitch.tv")) return "Open on Twitch";
    if (host === "youtube.com" || host.endsWith(".youtube.com") || host === "youtu.be") return "Open on YouTube";
  } catch {
    // fall through
  }
  return "Open link";
}

function HlsNativeVideo({
  video,
  onAirPlayState,
  onRegisterPicker,
}: {
  video: StageVideo;
  onAirPlayState: (state: { available: boolean; wireless: boolean }) => void;
  onRegisterPicker: (picker: (() => void) | null) => void;
}) {
  const videoRef = useRef<WebKitVideoElement>(null);
  const [needsClick, setNeedsClick] = useState<"" | "sound" | "play">("");
  const [errorText, setErrorText] = useState("");
  const [unsupported, setUnsupported] = useState(false);

  useEffect(() => {
    const el = videoRef.current;
    if (!el) return;
    setNeedsClick("");
    setErrorText("");

    el.setAttribute("x-webkit-airplay", "allow");
    el.disableRemotePlayback = false;

    const canNative = Boolean(
      el.canPlayType("application/vnd.apple.mpegurl") || el.canPlayType("application/x-mpegURL"),
    );
    if (!canNative) {
      setUnsupported(true);
      onAirPlayState({ available: false, wireless: false });
      onRegisterPicker(null);
      return;
    }
    setUnsupported(false);

    let available = false;
    let wireless = Boolean(el.webkitCurrentPlaybackTargetIsWireless);
    const emit = () => onAirPlayState({ available, wireless });
    emit();
    onRegisterPicker(() => {
      videoRef.current?.webkitShowPlaybackTargetPicker?.();
    });

    const onAvailability = (e: Event) => {
      const ev = e as WebKitPlaybackTargetAvailabilityEvent;
      available = ev.availability === "available";
      emit();
    };
    const onWireless = () => {
      wireless = Boolean(el.webkitCurrentPlaybackTargetIsWireless);
      emit();
    };
    const onError = () => {
      setErrorText("Stream playback stopped. Close and reopen it, or switch to the standard player.");
    };
    const onPlaying = () => {
      setErrorText("");
    };

    el.addEventListener("webkitplaybacktargetavailabilitychanged", onAvailability);
    el.addEventListener("webkitcurrentplaybacktargetiswirelesschanged", onWireless);
    el.addEventListener("error", onError);
    el.addEventListener("playing", onPlaying);

    el.src = video.embedUrl;
    el.load();

    let cancelled = false;
    (async () => {
      try {
        el.muted = false;
        await el.play();
        if (!cancelled) setNeedsClick("");
        return;
      } catch {
        // Sound wasn't allowed without a direct gesture: start muted, which browsers allow.
      }
      el.muted = true;
      try {
        await el.play();
        if (!cancelled) setNeedsClick("sound");
      } catch {
        if (!cancelled) setNeedsClick("play");
      }
    })();

    return () => {
      cancelled = true;
      el.removeEventListener("webkitplaybacktargetavailabilitychanged", onAvailability);
      el.removeEventListener("webkitcurrentplaybacktargetiswirelesschanged", onWireless);
      el.removeEventListener("error", onError);
      el.removeEventListener("playing", onPlaying);
      el.pause();
      el.removeAttribute("src");
      el.load();
      onAirPlayState({ available: false, wireless: false });
      onRegisterPicker(null);
    };
  }, [video.embedUrl, onAirPlayState, onRegisterPicker]);

  const playWithSound = () => {
    const el = videoRef.current;
    if (!el) return;
    el.muted = false;
    void el.play().then(
      () => setNeedsClick(""),
      () => setNeedsClick("play"),
    );
  };

  return (
    <>
      <video
        ref={videoRef}
        title={video.title}
        controls
        playsInline
        data-testid="custom-app-hls-video"
        className="absolute inset-0 size-full"
      />
      {unsupported && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-black/80 px-6 text-center text-13 text-white">
          Native HLS / AirPlay playback requires Safari or the Vesper Mac app.
        </div>
      )}
      {!unsupported && errorText && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-black/75 px-6 text-center text-13 text-white">
          {errorText}
        </div>
      )}
      {!unsupported && needsClick === "sound" && (
        <button
          type="button"
          onClick={playWithSound}
          className="absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-lg bg-black/80 px-3 py-1.5 text-13 font-semibold text-white hover:bg-black"
        >
          Unmute
        </button>
      )}
      {!unsupported && needsClick === "play" && (
        <button
          type="button"
          onClick={playWithSound}
          className="absolute left-3 top-3 inline-flex items-center gap-1.5 rounded-lg bg-black/80 px-3 py-1.5 text-13 font-semibold text-white hover:bg-black"
        >
          Play
        </button>
      )}
    </>
  );
}

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
  sidePanelAvailable = false,
  sidePanelLayout = false,
  sidePanelOpen = true,
  onSidePanelChange,
  onTheaterChange,
  onClose,
}: {
  video: StageVideo;
  theater: boolean;
  sidePanelAvailable?: boolean;
  sidePanelLayout?: boolean;
  sidePanelOpen?: boolean;
  onSidePanelChange?: (open: boolean) => void;
  onTheaterChange: (theater: boolean) => void;
  onClose: () => void;
}) {
  const [airPlay, setAirPlay] = useState({ available: false, wireless: false });
  const pickerRef = useRef<(() => void) | null>(null);
  const registerPicker = useCallback((picker: (() => void) | null) => {
    pickerRef.current = picker;
  }, []);

  // Esc leaves theater first, then closes; T toggles theater. Keys pressed inside the app's frame or
  // the player's own iframe never reach this window, so they can't trigger it by accident. While the
  // video is fullscreen the keys belong to it.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target) || document.fullscreenElement || document.querySelector('[role="dialog"]')) return;
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
  // half of it otherwise, so the app's list stays in view below. Its box doesn't clip (no
  // overflow-hidden or rounded corners): WebKit can draw a fullscreen iframe or video inside a
  // clipping ancestor as a black screen.
  const maxHeight = theater ? "calc(100dvh - 9rem)" : "56dvh";

  return (
    <section
      ref={stageRef}
      aria-label="Video player"
      data-testid="custom-app-player"
      data-theater={theater ? "true" : "false"}
      className={cx(
        sidePanelLayout ? "flex min-w-0 flex-1 flex-col bg-black" : "flex-none border-b border-border-subtle",
        !sidePanelLayout && (theater ? "bg-black" : "bg-bg px-4 pt-3"),
      )}
    >
      <div className={cx("mx-auto flex w-full flex-col", sidePanelLayout && "min-h-0 flex-1", !theater && "max-w-[1280px]")}>
        <div className={cx("flex items-center justify-center bg-black", sidePanelLayout && "min-h-0 flex-1")}>
          <div
            className="relative aspect-video w-full bg-black"
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
            ) : video.provider === "hls" ? (
              <HlsNativeVideo
                key={video.embedUrl}
                video={video}
                onAirPlayState={setAirPlay}
                onRegisterPicker={registerPicker}
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
          {video.provider === "hls" && airPlay.available && (
            <button
              type="button"
              aria-pressed={airPlay.wireless}
              title={airPlay.wireless ? "AirPlay active — click to switch output" : "Stream to an AirPlay device"}
              onClick={() => pickerRef.current?.()}
              data-testid="custom-app-airplay-button"
              className={cx(
                "inline-flex h-7 flex-none items-center gap-1.5 rounded-full border px-3 text-12 font-medium transition-colors",
                airPlay.wireless ? "border-accent bg-accent-soft text-fg" : "border-border-strong text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              <Icon name="airplay" size={13} />
              {airPlay.wireless ? "AirPlaying" : "AirPlay"}
            </button>
          )}
          {video.externalUrl && (
            <a
              href={video.externalUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex h-7 flex-none items-center gap-1.5 rounded-md border border-border-strong px-2.5 text-12 font-medium text-fg-secondary transition-colors hover:bg-hover hover:text-fg"
            >
              <Icon name="link" size={13} />
              {externalLinkLabel(video)}
            </a>
          )}
          {theater && sidePanelAvailable && onSidePanelChange && (
            <button
              type="button"
              aria-pressed={sidePanelOpen}
              title={sidePanelOpen ? "Hide chat panel" : "Show chat panel"}
              onClick={() => onSidePanelChange(!sidePanelOpen)}
              className={cx(
                "inline-flex h-7 flex-none items-center gap-1.5 rounded-full border px-3 text-12 font-medium transition-colors",
                sidePanelOpen ? "border-accent bg-accent-soft text-fg" : "border-border-strong text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              {sidePanelOpen ? "Hide chat" : "Show chat"}
            </button>
          )}
          <button
            type="button"
            aria-pressed={theater}
            title={theater ? "Leave theater mode (T)" : "Theater mode: wide player, sidebar hidden (T)"}
            onClick={() => onTheaterChange(!theater)}
            className={cx(
              "inline-flex h-7 flex-none items-center gap-1.5 rounded-full border px-3 text-12 font-medium transition-colors",
              theater ? "border-accent bg-accent-soft text-fg" : "border-border-strong text-fg-secondary hover:bg-hover hover:text-fg",
            )}
          >
            <Icon name="play" size={13} />
            Theater
          </button>
          <IconButton icon="x" label="Close video player (Esc)" onClick={onClose} />
        </div>
      </div>
    </section>
  );
}
