"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { cx } from "@/lib/cx";
import { loopFor, type CompanionState, type StateMediaSummary } from "@/lib/persona-state-media";

// The crossfade between two state loops; --motion-base in globals.css.
const FADE_MS = 220;

const REDUCE = "(prefers-reduced-motion: reduce)";
function subscribeReduce(cb: () => void) {
  const mq = window.matchMedia(REDUCE);
  mq.addEventListener("change", cb);
  return () => mq.removeEventListener("change", cb);
}
const reduceNow = () => window.matchMedia(REDUCE).matches;

/** Follows prefers-reduced-motion live. */
export function useReducedMotion(): boolean {
  return useSyncExternalStore(subscribeReduce, reduceNow, () => false);
}

type Layer = { url: string; key: number };

/**
 * A persona's photorealistic state loop on a transparent background, sized by
 * width at the loops' 9:16. A new state preloads its loop, then crossfades
 * over the old one so the switch never flashes empty. With reduced motion it
 * shows the idle loop's first frame, still.
 */
export function PersonaStateStage({
  media,
  state,
  width,
  label,
  className,
}: {
  media: StateMediaSummary;
  state: CompanionState;
  width: number;
  /** Accessible name, e.g. "Iris is thinking"; decorative without one. */
  label?: string;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const target = loopFor(media, reduce ? "idle" : state);
  const height = Math.round((width * 16) / 9);
  const box = { width, height };
  const a11y = label ? { role: "img" as const, "aria-label": label } : { "aria-hidden": true };
  if (!target) return null;
  return (
    <span {...a11y} style={box} data-testid="persona-state-stage" data-loop-state={target.state} className={cx("relative block flex-none select-none", className)}>
      {reduce ? <StillFrame url={target.url} width={width} height={height} /> : <Crossfade url={target.url} />}
    </span>
  );
}

function Crossfade({ url }: { url: string }) {
  const [layers, setLayers] = useState<Layer[]>(() => [{ url, key: 0 }]);
  const seq = useRef(0);
  useEffect(() => {
    if (layers.at(-1)?.url === url) return;
    let cancelled = false;
    // Decode first, so the new loop is ready the moment it starts fading in.
    const img = new Image();
    img.src = url;
    const show = () => {
      if (cancelled) return;
      const key = ++seq.current;
      setLayers((ls) => [...ls.slice(-1), { url, key }]);
      window.setTimeout(() => !cancelled && setLayers((ls) => ls.filter((l) => l.key >= key)), FADE_MS + 40);
    };
    img.decode().then(show, show);
    return () => {
      cancelled = true;
    };
  }, [url, layers]);
  return (
    <>
      {layers.map((l, i) => (
        <img
          key={l.key}
          src={l.url}
          alt=""
          draggable={false}
          // Both loops are transparent, so the old one fades out as the new one
          // fades in; otherwise the two poses would show through each other.
          style={{ animationDuration: `${FADE_MS}ms` }}
          className={cx(
            "absolute inset-0 h-full w-full object-contain",
            layers.length > 1 && (i === layers.length - 1 ? "animate-[scene-in_ease-out_both]" : "animate-[scene-out_ease-out_both]"),
          )}
        />
      ))}
    </>
  );
}

/** The loop's first frame on a canvas: createImageBitmap decodes only frame 0 of an animated image. */
function StillFrame({ url, width, height }: { url: string; width: number; height: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const ctl = new AbortController();
    (async () => {
      try {
        const res = await fetch(url, { signal: ctl.signal, credentials: "same-origin" });
        if (!res.ok) return;
        const bitmap = await createImageBitmap(await res.blob());
        const c = canvas.current;
        if (ctl.signal.aborted || !c) return bitmap.close();
        const dpr = window.devicePixelRatio || 1;
        c.width = Math.round(width * dpr);
        c.height = Math.round(height * dpr);
        const ctx = c.getContext("2d");
        ctx?.clearRect(0, 0, c.width, c.height);
        // object-contain, like the animated layers.
        const scale = Math.min(c.width / bitmap.width, c.height / bitmap.height);
        const w = bitmap.width * scale;
        const h = bitmap.height * scale;
        ctx?.drawImage(bitmap, (c.width - w) / 2, (c.height - h) / 2, w, h);
        bitmap.close();
      } catch {
        // Aborted, or the loop is gone: the stage stays empty, which is harmless.
      }
    })();
    return () => ctl.abort();
  }, [url, width, height]);
  return <canvas ref={canvas} style={{ width, height }} className="absolute inset-0" />;
}
