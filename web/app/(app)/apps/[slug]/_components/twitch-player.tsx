"use client";

import Hls from "hls.js";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Icon } from "@/components/ui/icon";
import type { TwitchTarget } from "@/lib/custom-app-bridge";
import { appendChatMessage, parseIrcLine, type TwitchChatMessage } from "@/lib/twitch-irc";
import {
  DEFAULT_BACKUP_PLAYER_TYPES,
  formatTwitchLatency,
  formatTwitchTime,
  isSameOriginTwitchPlaylistUrl,
  parseBackupTypesInput,
  shouldHideAdOverlay,
  type TwitchAdStatus,
} from "@/lib/twitch-player";

interface TwitchVariant {
  index: number;
  name: string;
  group_id: string;
  resolution?: string;
  bandwidth: number;
  frame_rate?: number;
  codecs?: string;
  audio_only: boolean;
}

interface TwitchSessionInfo {
  id: string;
  kind: "live" | "vod";
  channel?: string;
  vod_id?: string;
  player_type: string;
  active_type: string;
  backup_types: string[];
  ad_swap_enabled: boolean;
  ad_active: boolean;
  using_backup: boolean;
  ad_status: TwitchAdStatus;
  ad_duration_sec?: number;
  ad_swaps_count: number;
  ad_breaks_hidden: number;
  master_url: string;
  variants: TwitchVariant[];
}

interface WebKitHTMLVideoElement extends HTMLVideoElement {
  webkitPresentationMode?: "inline" | "picture-in-picture" | "fullscreen";
  webkitSetPresentationMode?: (mode: "inline" | "picture-in-picture" | "fullscreen") => void;
  webkitSupportsPresentationMode?: (mode: "inline" | "picture-in-picture" | "fullscreen") => boolean;
  webkitShowPlaybackTargetPicker?: () => void;
}

const LS_AD_SWAP = "vesper:twitch:adSwap";
const LS_BACKUP_TYPES = "vesper:twitch:backupTypes";
const LS_VOLUME = "vesper:twitch:volume";
const LS_MUTED = "vesper:twitch:muted";

function readPref<T>(key: string, fallback: T, parse: (raw: string) => T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = window.localStorage.getItem(key);
    return raw !== null ? parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function writePref(key: string, val: string) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(key, val);
  } catch {
    // Ignore storage quota / privacy errors.
  }
}

function readResponseHeader(networkDetails: unknown, name: string): string | null {
  if (!networkDetails || typeof networkDetails !== "object") return null;
  const xhrLike = networkDetails as { getResponseHeader?: (k: string) => string | null; headers?: Headers };
  if (typeof xhrLike.getResponseHeader === "function") {
    return xhrLike.getResponseHeader(name);
  }
  if (xhrLike.headers && typeof xhrLike.headers.get === "function") {
    return xhrLike.headers.get(name);
  }
  return null;
}

export interface TwitchPlayerProps {
  target: TwitchTarget;
  title: string;
  embedUrl: string;
  chatOpen: boolean;
  onToggleChat?: () => void;
}

export function TwitchPlayer({ target, title, embedUrl, chatOpen, onToggleChat }: TwitchPlayerProps) {
  const [useOfficialEmbed, setUseOfficialEmbed] = useState(false);
  const [retrySeq, setRetrySeq] = useState(0);
  const [adSwapEnabled, setAdSwapEnabled] = useState<boolean>(() =>
    readPref(LS_AD_SWAP, true, (s) => s !== "false"),
  );
  const [backupTypes, setBackupTypes] = useState<string[]>(() =>
    readPref(LS_BACKUP_TYPES, [...DEFAULT_BACKUP_PLAYER_TYPES], (s) => {
      const parsed = parseBackupTypesInput(s);
      return parsed.length > 0 ? parsed : [...DEFAULT_BACKUP_PLAYER_TYPES];
    }),
  );
  const [userVolume, setUserVolume] = useState<number>(() =>
    readPref(LS_VOLUME, 1, (s) => {
      const v = Number(s);
      return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 1;
    }),
  );
  const [userMuted, setUserMuted] = useState<boolean>(() => readPref(LS_MUTED, false, (s) => s === "true"));

  const targetKey =
    target.kind === "live" ? `live:${target.channel}` : `vod:${target.vodId}:${target.startSec ?? 0}`;

  const toggleMute = useCallback(() => {
    setUserMuted((m) => {
      const next = !m;
      writePref(LS_MUTED, String(next));
      return next;
    });
  }, []);

  const changeVolume = useCallback((val: number) => {
    const clamped = Math.min(1, Math.max(0, val));
    setUserVolume(clamped);
    writePref(LS_VOLUME, String(clamped));
    if (clamped > 0) {
      setUserMuted(false);
      writePref(LS_MUTED, "false");
    }
  }, []);

  const changeAdSwapEnabled = useCallback((next: boolean) => {
    setAdSwapEnabled(next);
    writePref(LS_AD_SWAP, String(next));
  }, []);

  const changeBackupTypes = useCallback((next: string[]) => {
    setBackupTypes(next);
    writePref(LS_BACKUP_TYPES, next.join(", "));
  }, []);

  return (
    <div className="flex w-full flex-col bg-black lg:flex-row">
      {useOfficialEmbed ? (
        <div className="relative aspect-video flex-1 bg-black">
          <iframe
            key={embedUrl}
            src={embedUrl}
            title={title}
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowFullScreen
            referrerPolicy="strict-origin-when-cross-origin"
            className="absolute inset-0 size-full border-0"
          />
          <button
            type="button"
            onClick={() => setUseOfficialEmbed(false)}
            className="absolute left-3 top-3 z-20 rounded-md bg-black/75 px-2.5 py-1 text-11 font-medium text-white/90 backdrop-blur transition-colors hover:bg-black"
          >
            Switch to Alternate Player
          </button>
        </div>
      ) : (
        <TwitchHlsPane
          key={`${targetKey}:${retrySeq}`}
          target={target}
          adSwapEnabled={adSwapEnabled}
          backupTypes={backupTypes}
          userVolume={userVolume}
          userMuted={userMuted}
          onToggleMute={toggleMute}
          onChangeVolume={changeVolume}
          onChangeAdSwapEnabled={changeAdSwapEnabled}
          onChangeBackupTypes={changeBackupTypes}
          onRetry={() => setRetrySeq((s) => s + 1)}
          onSwitchOfficialEmbed={() => setUseOfficialEmbed(true)}
          onToggleChat={onToggleChat}
        />
      )}

      {chatOpen && target.kind === "live" && <TwitchChatPane key={target.channel} channel={target.channel} />}
    </div>
  );
}

interface TwitchHlsPaneProps {
  target: TwitchTarget;
  adSwapEnabled: boolean;
  backupTypes: string[];
  userVolume: number;
  userMuted: boolean;
  onToggleMute: () => void;
  onChangeVolume: (val: number) => void;
  onChangeAdSwapEnabled: (next: boolean) => void;
  onChangeBackupTypes: (next: string[]) => void;
  onRetry: () => void;
  onSwitchOfficialEmbed: () => void;
  onToggleChat?: () => void;
}

function TwitchHlsPane({
  target,
  adSwapEnabled,
  backupTypes,
  userVolume,
  userMuted,
  onToggleMute,
  onChangeVolume,
  onChangeAdSwapEnabled,
  onChangeBackupTypes,
  onRetry,
  onSwitchOfficialEmbed,
  onToggleChat,
}: TwitchHlsPaneProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const freezeCanvasRef = useRef<HTMLCanvasElement>(null);
  const hlsRef = useRef<Hls | null>(null);
  const sessionIdRef = useRef<string | null>(null);
  const initialVariantsRef = useRef<TwitchVariant[]>([]);
  const manualSeekAppliedRef = useRef(false);
  const initialPrefsRef = useRef({ adSwapEnabled, backupTypes });

  const targetKind = target.kind;
  const targetChannel = target.kind === "live" ? target.channel : "";
  const targetVodId = target.kind === "vod" ? target.vodId : "";
  const targetStartSec = target.kind === "vod" ? target.startSec : undefined;

  const [backupTypesDraft, setBackupTypesDraft] = useState(() => backupTypes.join(", "));
  const [sessionHandle, setSessionHandle] = useState<{ id: string; masterUrl: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [latencySec, setLatencySec] = useState<number | null>(null);
  const [levels, setLevels] = useState<Array<{ index: number; label: string }>>([]);
  const [selectedLevel, setSelectedLevel] = useState(-1);

  const [adActive, setAdActive] = useState(false);
  const [usingBackup, setUsingBackup] = useState(false);
  const [activeType, setActiveType] = useState("site");
  const [adExpectedSec, setAdExpectedSec] = useState<number | null>(null);
  const [adStartedAtMs, setAdStartedAtMs] = useState<number | null>(null);
  const [nowTickMs, setNowTickMs] = useState(() => Date.now());
  const [manualReveal, setManualReveal] = useState(false);
  const [freezeFrameReady, setFreezeFrameReady] = useState(false);
  const [adSwapsCount, setAdSwapsCount] = useState(0);
  const [adBreaksHidden, setAdBreaksHidden] = useState(0);

  const [settingsOpen, setSettingsOpen] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [pipSupported, setPipSupported] = useState(false);
  const [airPlaySupported, setAirPlaySupported] = useState(false);

  const adHide = shouldHideAdOverlay(adActive, manualReveal);
  const adElapsedSec =
    adActive && adStartedAtMs !== null ? Math.max(0, Math.floor((nowTickMs - adStartedAtMs) / 1000)) : 0;

  const applySessionState = useCallback((info: TwitchSessionInfo) => {
    setActiveType(info.active_type);
    setUsingBackup(info.using_backup);
    setAdActive(info.ad_active);
    setAdExpectedSec(info.ad_duration_sec && info.ad_duration_sec > 0 ? Math.round(info.ad_duration_sec) : null);
    setAdSwapsCount(info.ad_swaps_count);
    setAdBreaksHidden(info.ad_breaks_hidden);
    if (info.ad_active) {
      setAdStartedAtMs((prev) => prev ?? Date.now());
    } else {
      setAdStartedAtMs(null);
      setManualReveal(false);
    }
  }, []);

  const refreshSessionStats = useCallback(
    async (sid: string) => {
      try {
        const res = await fetch(`/api/v1/twitch/sessions/${encodeURIComponent(sid)}`, {
          credentials: "same-origin",
        });
        if (!res.ok) return;
        const info = (await res.json()) as TwitchSessionInfo;
        applySessionState(info);
      } catch {
        // Ignore transient status refresh failures.
      }
    },
    [applySessionState],
  );

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    v.volume = userVolume;
    v.muted = userMuted || adHide;
  }, [userVolume, userMuted, adHide]);

  useEffect(() => {
    if (!adActive) return;
    const id = setInterval(() => setNowTickMs(Date.now()), 1000);
    return () => clearInterval(id);
  }, [adActive]);

  // Periodically snapshot clean video frames so ad breaks freeze on the last stream frame.
  useEffect(() => {
    if (adActive) return;
    const captureFrame = () => {
      const video = videoRef.current;
      const canvas = freezeCanvasRef.current;
      if (!video || !canvas || video.readyState < 2 || video.videoWidth <= 0 || video.videoHeight <= 0) return;
      try {
        if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
        }
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        setFreezeFrameReady(true);
      } catch {
        setFreezeFrameReady(false);
      }
    };
    const id = setInterval(captureFrame, 1000);
    return () => clearInterval(id);
  }, [adActive]);

  // Create and tear down the server-side Usher/HLS session for this mount.
  useEffect(() => {
    let cancelled = false;
    const ctrl = new AbortController();

    const run = async () => {
      const prefs = initialPrefsRef.current;
      const bodyPayload =
        targetKind === "live"
          ? {
              kind: "live",
              channel: targetChannel,
              backup_types: prefs.backupTypes,
              ad_swap_enabled: prefs.adSwapEnabled,
            }
          : {
              kind: "vod",
              vod_id: targetVodId,
              backup_types: prefs.backupTypes,
              ad_swap_enabled: prefs.adSwapEnabled,
            };

      try {
        const res = await fetch("/api/v1/twitch/sessions", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(bodyPayload),
          signal: ctrl.signal,
        });
        if (!res.ok) {
          const errJson = (await res.json().catch(() => ({}))) as { message?: string };
          const msg =
            res.status === 404
              ? targetKind === "live"
                ? `${targetChannel} is currently offline.`
                : "Twitch VOD is unavailable."
              : errJson.message || `Stream resolver returned HTTP ${res.status}`;
          if (!cancelled) {
            setErrorMsg(msg);
            setLoading(false);
          }
          return;
        }
        const info = (await res.json()) as TwitchSessionInfo;
        if (cancelled) {
          void fetch(`/api/v1/twitch/sessions/${encodeURIComponent(info.id)}`, {
            method: "DELETE",
            keepalive: true,
            credentials: "same-origin",
          });
          return;
        }
        sessionIdRef.current = info.id;
        initialVariantsRef.current = info.variants;
        applySessionState(info);
        setSessionHandle({ id: info.id, masterUrl: info.master_url });
        setLoading(false);
      } catch (err) {
        if (cancelled || ctrl.signal.aborted) return;
        setErrorMsg(err instanceof Error ? err.message : "Failed to initialize Twitch stream.");
        setLoading(false);
      }
    };

    void run();

    return () => {
      cancelled = true;
      ctrl.abort();
      const sid = sessionIdRef.current;
      sessionIdRef.current = null;
      if (sid) {
        void fetch(`/api/v1/twitch/sessions/${encodeURIComponent(sid)}`, {
          method: "DELETE",
          keepalive: true,
          credentials: "same-origin",
        });
      }
    };
  }, [targetKind, targetChannel, targetVodId, applySessionState]);

  // Attach hls.js or native WebKit HLS once session master URL is ready.
  useEffect(() => {
    const video = videoRef.current;
    if (!sessionHandle || !video) return;

    const seekVodIfNeeded = () => {
      if (targetKind === "vod" && targetStartSec && targetStartSec > 0 && !manualSeekAppliedRef.current) {
        manualSeekAppliedRef.current = true;
        video.currentTime = targetStartSec;
      }
    };

    const probePlatformCapabilities = () => {
      const wk = video as WebKitHTMLVideoElement;
      const canStdPip =
        typeof document !== "undefined" &&
        "pictureInPictureEnabled" in document &&
        Boolean(document.pictureInPictureEnabled) &&
        typeof video.requestPictureInPicture === "function";
      const canWkPip =
        typeof wk.webkitSupportsPresentationMode === "function" &&
        wk.webkitSupportsPresentationMode("picture-in-picture");
      setPipSupported(canStdPip || canWkPip);
      setAirPlaySupported(typeof wk.webkitShowPlaybackTargetPicker === "function");
    };

    let pollTimer: ReturnType<typeof setInterval> | null = null;
    let lastObservedAdState = "";

    if (Hls.isSupported()) {
      const hls = new Hls({
        enableWorker: true,
        lowLatencyMode: targetKind === "live",
        backBufferLength: 30,
        xhrSetup: (xhr, url) => {
          xhr.withCredentials = isSameOriginTwitchPlaylistUrl(url, window.location.origin);
        },
      });
      hlsRef.current = hls;

      hls.on(Hls.Events.MANIFEST_PARSED, (_ev, data) => {
        const mapped = data.levels.map((lvl, idx) => ({
          index: idx,
          label: lvl.name || (lvl.height ? `${lvl.height}p` : `${Math.round(lvl.bitrate / 1000)}k`),
        }));
        setLevels(
          mapped.length > 0
            ? mapped
            : initialVariantsRef.current.map((v) => ({ index: v.index, label: v.name })),
        );
        seekVodIfNeeded();
        probePlatformCapabilities();
        void video.play().catch(() => {});
      });

      hls.on(Hls.Events.LEVEL_LOADED, (_ev, data) => {
        const net = (data as { networkDetails?: unknown }).networkDetails;
        const adHeader = readResponseHeader(net, "X-Vesper-Twitch-Ad");
        const playerTypeHdr = readResponseHeader(net, "X-Vesper-Twitch-Player-Type");
        const usingBackupHdr = readResponseHeader(net, "X-Vesper-Twitch-Using-Backup");
        const adDurHdr = readResponseHeader(net, "X-Vesper-Twitch-Ad-Duration");

        if (adHeader) {
          const nextAdActive = adHeader === "active";
          setAdActive(nextAdActive);
          setUsingBackup(usingBackupHdr === "true" || adHeader === "swapped");
          if (playerTypeHdr) setActiveType(playerTypeHdr);
          setAdExpectedSec(adDurHdr ? Math.round(Number(adDurHdr)) || null : null);
          if (nextAdActive) {
            setNowTickMs(Date.now());
            setAdStartedAtMs((prev) => prev ?? Date.now());
          } else {
            setAdStartedAtMs(null);
            setManualReveal(false);
          }

          if (adHeader !== lastObservedAdState) {
            lastObservedAdState = adHeader;
            void refreshSessionStats(sessionHandle.id);
          }
        }
        if (targetKind === "live" && Number.isFinite(hls.latency)) {
          setLatencySec(hls.latency);
        }
      });

      hls.on(Hls.Events.LEVEL_UPDATED, () => {
        if (targetKind === "live" && Number.isFinite(hls.latency)) {
          setLatencySec(hls.latency);
        }
      });

      hls.on(Hls.Events.ERROR, (_ev, data) => {
        if (!data.fatal) return;
        if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
          hls.recoverMediaError();
          return;
        }
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR && data.response?.code === 404) {
          setErrorMsg(targetKind === "live" ? "Stream went offline." : "VOD playlist expired.");
          return;
        }
        setErrorMsg(`Playback error (${data.details || "network"}). Try Retry or Switch to Official Twitch Embed.`);
      });

      hls.loadSource(sessionHandle.masterUrl);
      hls.attachMedia(video);

      return () => {
        if (pollTimer) clearInterval(pollTimer);
        hls.destroy();
        hlsRef.current = null;
      };
    }

    // Native HLS fallback (Safari / WKWebView): browser handles ABR natively.
    video.src = sessionHandle.masterUrl;
    const onLoadedMeta = () => {
      seekVodIfNeeded();
      probePlatformCapabilities();
      void video.play().catch(() => {});
    };
    video.addEventListener("loadedmetadata", onLoadedMeta);
    pollTimer = setInterval(() => {
      void refreshSessionStats(sessionHandle.id);
    }, 2500);

    return () => {
      if (pollTimer) clearInterval(pollTimer);
      video.removeEventListener("loadedmetadata", onLoadedMeta);
      video.removeAttribute("src");
      video.load();
    };
  }, [sessionHandle, targetKind, targetStartSec, refreshSessionStats]);

  // Track <video> time/play state and fullscreen changes.
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    const onPlay = () => setPlaying(true);
    const onPause = () => setPlaying(false);
    const onTime = () => {
      setCurrentTime(v.currentTime || 0);
      setDuration(Number.isFinite(v.duration) ? v.duration : 0);
    };
    v.addEventListener("play", onPlay);
    v.addEventListener("pause", onPause);
    v.addEventListener("timeupdate", onTime);
    v.addEventListener("durationchange", onTime);
    return () => {
      v.removeEventListener("play", onPlay);
      v.removeEventListener("pause", onPause);
      v.removeEventListener("timeupdate", onTime);
      v.removeEventListener("durationchange", onTime);
    };
  }, []);

  useEffect(() => {
    const onFsChange = () => {
      setIsFullscreen(Boolean(document.fullscreenElement));
    };
    document.addEventListener("fullscreenchange", onFsChange);
    return () => document.removeEventListener("fullscreenchange", onFsChange);
  }, []);

  const togglePlay = useCallback(() => {
    const v = videoRef.current;
    if (!v) return;
    if (v.paused) void v.play().catch(() => {});
    else v.pause();
  }, []);

  const toggleFullscreen = useCallback(() => {
    const el = containerRef.current;
    if (!el) return;
    if (document.fullscreenElement) {
      void document.exitFullscreen().catch(() => {});
    } else {
      void el.requestFullscreen().catch(() => {});
    }
  }, []);

  const togglePiP = useCallback(() => {
    const v = videoRef.current as WebKitHTMLVideoElement | null;
    if (!v) return;
    if (typeof v.webkitSetPresentationMode === "function") {
      const next = v.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture";
      v.webkitSetPresentationMode(next);
      return;
    }
    if (document.pictureInPictureElement) {
      void document.exitPictureInPicture().catch(() => {});
    } else if (typeof v.requestPictureInPicture === "function") {
      void v.requestPictureInPicture().catch(() => {});
    }
  }, []);

  const openAirPlay = useCallback(() => {
    const v = videoRef.current as WebKitHTMLVideoElement | null;
    v?.webkitShowPlaybackTargetPicker?.();
  }, []);

  const jumpToLive = useCallback(() => {
    const v = videoRef.current;
    const hls = hlsRef.current;
    if (!v) return;
    if (hls && Number.isFinite(hls.liveSyncPosition ?? NaN) && (hls.liveSyncPosition ?? 0) > 0) {
      v.currentTime = hls.liveSyncPosition!;
    } else if (v.seekable.length > 0) {
      v.currentTime = Math.max(0, v.seekable.end(v.seekable.length - 1) - 1.5);
    }
    void v.play().catch(() => {});
  }, []);

  const patchSession = useCallback(
    async (patch: { ad_swap_enabled?: boolean; backup_types?: string[] }) => {
      if (!sessionHandle) return;
      try {
        const res = await fetch(`/api/v1/twitch/sessions/${encodeURIComponent(sessionHandle.id)}`, {
          method: "PATCH",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(patch),
        });
        if (!res.ok) return;
        const info = (await res.json()) as TwitchSessionInfo;
        applySessionState(info);
      } catch {
        // Ignore network glitch updating session config.
      }
    },
    [sessionHandle, applySessionState],
  );

  // Player keyboard shortcuts when focus isn't inside form inputs.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName || "";
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === " " || e.key.toLowerCase() === "k") {
        e.preventDefault();
        togglePlay();
      } else if (e.key.toLowerCase() === "m") {
        e.preventDefault();
        onToggleMute();
      } else if (e.key.toLowerCase() === "f") {
        e.preventDefault();
        toggleFullscreen();
      } else if (e.key.toLowerCase() === "p") {
        e.preventDefault();
        togglePiP();
      } else if (e.key.toLowerCase() === "c" && target.kind === "live" && onToggleChat) {
        e.preventDefault();
        onToggleChat();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [togglePlay, onToggleMute, toggleFullscreen, togglePiP, target.kind, onToggleChat]);

  const formattedLatency = useMemo(() => formatTwitchLatency(latencySec), [latencySec]);

  return (
    <div ref={containerRef} className="relative aspect-video flex-1 bg-black">
      <video
        ref={videoRef}
        playsInline
        onClick={togglePlay}
        className={`size-full bg-black object-contain ${adHide ? "opacity-0" : "opacity-100"}`}
      />

      <canvas
        ref={freezeCanvasRef}
        aria-hidden="true"
        className={`pointer-events-none absolute inset-0 size-full object-contain ${
          adHide && freezeFrameReady ? "block" : "hidden"
        }`}
      />

      {adHide && (
        <div className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2.5 bg-black/70 px-6 text-center text-white backdrop-blur-sm">
          <span className="rounded-full border border-white/20 bg-white/10 px-3 py-1 text-11 font-semibold uppercase tracking-wide">
            Ad break hidden · audio muted
          </span>
          <p className="text-13 text-white/85">
            {target.kind === "live"
              ? "Waiting for stitched ad segments to finish. Video resumes automatically."
              : "Stitched ad segment hidden & muted."}
          </p>
          <div className="font-mono text-12 text-white/70">
            {formatTwitchTime(adElapsedSec)}
            {adExpectedSec ? ` / ~${formatTwitchTime(adExpectedSec)}` : ""}
          </div>
          <button
            type="button"
            onClick={() => setManualReveal(true)}
            className="mt-1 rounded-md border border-white/25 bg-white/10 px-2.5 py-1 text-11 font-medium text-white transition-colors hover:bg-white/20"
          >
            Show anyway
          </button>
        </div>
      )}

      {adActive && manualReveal && (
        <div className="absolute right-3 top-3 z-20 flex items-center gap-2 rounded-md bg-black/80 px-2.5 py-1 text-11 text-white">
          <span>Ad break active</span>
          <button type="button" onClick={() => setManualReveal(false)} className="underline hover:text-white/80">
            Hide &amp; mute
          </button>
        </div>
      )}

      {/* Top-left telemetry badges */}
      <div className="pointer-events-none absolute left-3 top-3 z-20 flex flex-wrap items-center gap-1.5">
        {target.kind === "live" && (
          <button
            type="button"
            onClick={jumpToLive}
            title="Jump to live edge"
            className="pointer-events-auto inline-flex items-center gap-1.5 rounded-md bg-black/75 px-2 py-0.5 text-11 font-semibold text-white backdrop-blur hover:bg-black"
          >
            <span className="size-2 rounded-full bg-red-500" />
            LIVE{formattedLatency ? ` · ${formattedLatency}` : ""}
          </button>
        )}
        {usingBackup && (
          <span className="rounded-md bg-purple-600/90 px-2 py-0.5 text-11 font-medium text-white backdrop-blur">
            Backup ({activeType})
          </span>
        )}
        {adSwapsCount > 0 && !usingBackup && (
          <span className="rounded-md bg-black/70 px-2 py-0.5 text-11 text-white/80 backdrop-blur">
            {adSwapsCount} ad {adSwapsCount === 1 ? "swap" : "swaps"}
          </span>
        )}
      </div>

      {loading && (
        <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/75 text-13 text-white/85">
          Loading Twitch HLS stream…
        </div>
      )}

      {errorMsg && (
        <div className="absolute inset-0 z-30 flex flex-col items-center justify-center gap-3 bg-black/85 px-6 text-center text-white">
          <Icon name="alert" size={22} className="text-amber-400" />
          <p className="max-w-md text-13 text-white/90">{errorMsg}</p>
          <div className="flex flex-wrap justify-center gap-2">
            <button
              type="button"
              onClick={onRetry}
              className="inline-flex h-8 items-center gap-1.5 rounded-md bg-white/15 px-3 text-12 font-medium text-white hover:bg-white/25"
            >
              <Icon name="refresh" size={13} />
              Retry HLS
            </button>
            <button
              type="button"
              onClick={onSwitchOfficialEmbed}
              className="inline-flex h-8 items-center gap-1.5 rounded-md border border-white/25 px-3 text-12 font-medium text-white/90 hover:bg-white/10"
            >
              Official Twitch Embed
            </button>
          </div>
        </div>
      )}

      {/* Settings Popover */}
      {settingsOpen && (
        <div
          onClick={(e) => e.stopPropagation()}
          className="absolute bottom-14 right-3 z-30 w-72 rounded-xl border border-white/15 bg-zinc-950/95 p-3 text-12 text-white shadow-xl backdrop-blur"
        >
          <div className="mb-2 flex items-center justify-between border-b border-white/10 pb-1.5">
            <span className="font-semibold">Alternate Player Settings</span>
            <button
              type="button"
              onClick={() => setSettingsOpen(false)}
              aria-label="Close settings"
              className="text-white/60 hover:text-white"
            >
              <Icon name="x" size={13} />
            </button>
          </div>

          <label className="mb-2.5 flex cursor-pointer items-center justify-between gap-2">
            <span>Auto backup stream swap</span>
            <input
              type="checkbox"
              checked={adSwapEnabled}
              onChange={(e) => {
                const next = e.target.checked;
                onChangeAdSwapEnabled(next);
                void patchSession({ ad_swap_enabled: next });
              }}
            />
          </label>

          <div className="mb-2.5 flex flex-col gap-1">
            <span className="text-11 text-white/60">Backup player_type rotation</span>
            <div className="flex gap-1.5">
              <input
                value={backupTypesDraft}
                onChange={(e) => setBackupTypesDraft(e.target.value)}
                placeholder="embed, popout, autoplay"
                className="h-7 min-w-0 flex-1 rounded border border-white/15 bg-black/50 px-2 font-mono text-11 text-white outline-none focus:border-purple-400"
              />
              <button
                type="button"
                onClick={() => {
                  const next = parseBackupTypesInput(backupTypesDraft);
                  if (next.length === 0) return;
                  onChangeBackupTypes(next);
                  setBackupTypesDraft(next.join(", "));
                  void patchSession({ backup_types: next });
                }}
                className="h-7 rounded bg-white/15 px-2 text-11 font-medium hover:bg-white/25"
              >
                Save
              </button>
            </div>
          </div>

          <div className="mb-2.5 space-y-0.5 rounded bg-white/5 px-2 py-1.5 font-mono text-11 text-white/75">
            <div>player_type: {activeType}</div>
            <div>
              swaps: {adSwapsCount} · ads hidden: {adBreaksHidden}
            </div>
          </div>

          <button
            type="button"
            onClick={() => {
              setSettingsOpen(false);
              onSwitchOfficialEmbed();
            }}
            className="w-full rounded-md border border-white/20 px-2.5 py-1.5 text-center text-11 font-medium text-white/90 hover:bg-white/10"
          >
            Switch to Official Twitch Embed
          </button>
        </div>
      )}

      {/* Bottom player control bar */}
      <div className="absolute inset-x-0 bottom-0 z-20 flex flex-col gap-1.5 bg-gradient-to-t from-black/90 via-black/55 to-transparent px-3 pb-2.5 pt-6 text-white">
        {target.kind === "vod" && duration > 0 && (
          <input
            type="range"
            aria-label="Seek VOD"
            min={0}
            max={duration}
            step={1}
            value={Math.min(currentTime, duration)}
            onChange={(e) => {
              const v = videoRef.current;
              if (!v) return;
              v.currentTime = Number(e.target.value);
            }}
            className="h-1 w-full cursor-pointer accent-purple-500"
          />
        )}

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={togglePlay}
            aria-label={playing ? "Pause" : "Play"}
            className="inline-flex size-7 items-center justify-center rounded hover:bg-white/15"
          >
            <Icon name={playing ? "pause" : "play"} size={14} />
          </button>

          <button
            type="button"
            onClick={onToggleMute}
            aria-label={userMuted || adHide ? "Unmute" : "Mute"}
            className="inline-flex size-7 items-center justify-center rounded hover:bg-white/15"
          >
            <Icon name="audio" size={14} className={userMuted || adHide ? "opacity-45" : undefined} />
          </button>

          <input
            type="range"
            aria-label="Volume"
            min={0}
            max={1}
            step={0.05}
            value={userMuted || adHide ? 0 : userVolume}
            onChange={(e) => onChangeVolume(Number(e.target.value))}
            className="h-1 w-16 cursor-pointer accent-purple-500"
          />

          {target.kind === "vod" && (
            <span className="font-mono text-11 text-white/80">
              {formatTwitchTime(currentTime)}
              {duration > 0 ? ` / ${formatTwitchTime(duration)}` : ""}
            </span>
          )}

          <div className="ml-auto flex items-center gap-1.5">
            {levels.length > 0 && (
              <select
                aria-label="Stream quality"
                value={String(selectedLevel)}
                onChange={(e) => {
                  const idx = Number(e.target.value);
                  setSelectedLevel(idx);
                  if (hlsRef.current) {
                    hlsRef.current.currentLevel = idx;
                  }
                }}
                className="h-7 rounded border border-white/20 bg-black/70 px-1.5 text-11 text-white outline-none"
              >
                <option value="-1">Auto</option>
                {levels.map((lvl) => (
                  <option key={lvl.index} value={String(lvl.index)}>
                    {lvl.label}
                  </option>
                ))}
              </select>
            )}

            <button
              type="button"
              onClick={() => setSettingsOpen((o) => !o)}
              aria-label="Player settings"
              className={`inline-flex size-7 items-center justify-center rounded hover:bg-white/15 ${
                settingsOpen ? "bg-white/20" : ""
              }`}
            >
              <Icon name="sliders" size={14} />
            </button>

            {pipSupported && (
              <button
                type="button"
                onClick={togglePiP}
                aria-label="Picture in Picture"
                className="inline-flex size-7 items-center justify-center rounded hover:bg-white/15"
              >
                <Icon name="film" size={14} />
              </button>
            )}

            {airPlaySupported && (
              <button
                type="button"
                onClick={openAirPlay}
                aria-label="AirPlay"
                className="inline-flex h-7 items-center rounded px-1.5 text-11 font-medium hover:bg-white/15"
              >
                AirPlay
              </button>
            )}

            <button
              type="button"
              onClick={toggleFullscreen}
              aria-label={isFullscreen ? "Exit fullscreen" : "Fullscreen"}
              className="inline-flex size-7 items-center justify-center rounded hover:bg-white/15"
            >
              <Icon name={isFullscreen ? "shrink" : "expand"} size={14} />
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function TwitchChatPane({ channel }: { channel: string }) {
  const [reconnectSeq, setReconnectSeq] = useState(0);
  return (
    <TwitchChatSocket
      key={`${channel}:${reconnectSeq}`}
      channel={channel}
      onReconnect={() => setReconnectSeq((s) => s + 1)}
    />
  );
}

function TwitchChatSocket({ channel, onReconnect }: { channel: string; onReconnect: () => void }) {
  const [messages, setMessages] = useState<TwitchChatMessage[]>([]);
  const [status, setStatus] = useState<"connecting" | "connected" | "disconnected">("connecting");
  const [autoScroll, setAutoScroll] = useState(true);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let closed = false;
    const ws = new WebSocket("wss://irc-ws.chat.twitch.tv:443");

    ws.onopen = () => {
      if (closed) return;
      const nick = `justinfan${Math.floor(10000 + Math.random() * 89999)}`;
      ws.send("CAP REQ :twitch.tv/tags twitch.tv/commands");
      ws.send("PASS SCHMOOPIIE");
      ws.send(`NICK ${nick}`);
      ws.send(`JOIN #${channel.toLowerCase()}`);
      setStatus("connected");
    };

    ws.onmessage = (ev) => {
      if (closed || typeof ev.data !== "string") return;
      for (const line of ev.data.split("\r\n")) {
        if (!line) continue;
        const parsed = parseIrcLine(line);
        if (!parsed) continue;
        if (parsed.type === "ping") {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(`PONG :${parsed.payload}`);
          }
        } else if (parsed.type === "privmsg") {
          setMessages((prev) => appendChatMessage(prev, parsed.message, 200));
        } else if (parsed.type === "clearmsg") {
          setMessages((prev) => prev.filter((m) => m.id !== parsed.targetMsgId));
        } else if (parsed.type === "clearchat") {
          setMessages((prev) => (parsed.targetUser ? prev.filter((m) => m.user !== parsed.targetUser) : []));
        }
      }
    };

    ws.onerror = () => {
      if (!closed) setStatus("disconnected");
    };
    ws.onclose = () => {
      if (!closed) setStatus("disconnected");
    };

    return () => {
      closed = true;
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close();
      }
    };
  }, [channel]);

  useEffect(() => {
    const el = listRef.current;
    if (el && autoScroll) {
      el.scrollTop = el.scrollHeight;
    }
  }, [messages, autoScroll]);

  return (
    <aside className="flex h-72 w-full flex-none flex-col border-t border-border-subtle bg-surface lg:h-auto lg:max-h-[min(75vh,620px)] lg:w-80 lg:border-l lg:border-t-0">
      <div className="flex items-center justify-between border-b border-border-subtle px-3 py-2 text-12">
        <span className="font-semibold text-fg">Stream Chat · #{channel}</span>
        {status === "disconnected" ? (
          <button type="button" onClick={onReconnect} className="text-11 text-accent hover:underline">
            Reconnect
          </button>
        ) : (
          <span className="text-11 text-fg-tertiary">{status === "connected" ? "Live" : "Connecting…"}</span>
        )}
      </div>

      <div
        ref={listRef}
        onScroll={(e) => {
          const el = e.currentTarget;
          const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
          if (nearBottom !== autoScroll) setAutoScroll(nearBottom);
        }}
        className="flex-1 space-y-1.5 overflow-y-auto px-3 py-2 text-12 leading-snug"
      >
        {messages.length === 0 && (
          <p className="py-4 text-center text-11 text-fg-tertiary">
            {status === "connected" ? "Waiting for chat messages…" : "Joining IRC chat…"}
          </p>
        )}
        {messages.map((m) => (
          <div key={m.id} className="break-words">
            {m.badges.map((b) => (
              <span
                key={b}
                className="mr-1 inline-block rounded bg-surface-sunken px-1 py-0.5 font-mono text-10 font-semibold text-fg-secondary"
              >
                {b}
              </span>
            ))}
            <span className="font-semibold" style={{ color: m.color }}>
              {m.displayName}
            </span>
            <span className={m.isAction ? "ml-1 italic text-fg-2" : "text-fg"}>
              {m.isAction ? m.text : `: ${m.text}`}
            </span>
          </div>
        ))}
      </div>

      {!autoScroll && (
        <button
          type="button"
          onClick={() => {
            setAutoScroll(true);
            if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
          }}
          className="border-t border-border-subtle bg-surface-raised px-3 py-1.5 text-center text-11 font-medium text-accent hover:bg-hover"
        >
          Resume auto-scroll
        </button>
      )}
    </aside>
  );
}
