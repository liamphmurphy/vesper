"use client";

import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import { cx } from "@/lib/cx";

// Mirrors --motion-* in globals.css, for animations that have to start from script.
const BASE = 200;
const SLOW = 320;
// el.animate() takes no var(), so this restates --motion-ease.
const EASE = "cubic-bezier(0.16, 1, 0.3, 1)";

const still = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** One soft bump, for a value that just changed. */
function bump(el: Element | null) {
  if (el && !still()) el.animate([{ transform: "scale(1)" }, { transform: "scale(1.08)" }, { transform: "scale(1)" }], { duration: SLOW, easing: EASE });
}

/** Bumps the returned element when `value` changes; never on mount. */
export function usePulse<T extends HTMLElement>(value: unknown) {
  const ref = useRef<T>(null);
  const previous = useRef(value);
  useLayoutEffect(() => {
    if (previous.current !== value) bump(ref.current);
    previous.current = value;
  }, [value]);
  return ref;
}

/** usePulse for many elements: each `[data-pulse-id]` bumps when its `data-pulse` changes. */
export function usePulseList(root: RefObject<HTMLElement | null>) {
  const seen = useRef(new Map<string, string>());
  useLayoutEffect(() => {
    const next = new Map<string, string>();
    root.current?.querySelectorAll<HTMLElement>("[data-pulse-id]").forEach((el) => {
      const id = el.dataset.pulseId!;
      const value = el.dataset.pulse ?? "";
      next.set(id, value);
      const before = seen.current.get(id);
      if (before !== undefined && before !== value) bump(el);
    });
    seen.current = next;
  });
}

/**
 * Children of `root` marked `data-enter-key` rise in the first time they appear. What's there on
 * first paint, or after the whole set was replaced (another chat opened), stays still.
 * Scoped to `items` so unrelated parent re-renders don't scan the transcript DOM.
 */
export function useEntrances(root: RefObject<HTMLElement | null>, items: readonly unknown[] | undefined) {
  const seen = useRef(new Set<string>());
  useLayoutEffect(() => {
    if (!items) {
      seen.current.clear();
      return;
    }
    const els = [...(root.current?.querySelectorAll<HTMLElement>("[data-enter-key]") ?? [])];
    const keys = els.map((el) => el.dataset.enterKey!);
    const continues = keys.some((k) => seen.current.has(k));
    if (continues && !still()) {
      for (const el of els) {
        if (seen.current.has(el.dataset.enterKey!)) continue;
        el.animate([{ opacity: 0, transform: `translateY(${el.dataset.enter === "user" ? 10 : 4}px)` }, { opacity: 1, transform: "none" }], { duration: SLOW, easing: EASE });
      }
    }
    if (continues) keys.forEach((k) => seen.current.add(k));
    else seen.current = new Set(keys);
  }, [root, items]);
}

type Place = { left: number; top: number; width: number; el: HTMLElement };

/**
 * Animates a keyed list as it changes: `[data-motion-key]` elements glide to their new place,
 * new ones fade in and removed ones fade out. `root` must be their offsetParent: offsets
 * ignore scrolling and running transforms, so polling or a scroll can't start a false move.
 * A key left in `landingRef` was just dropped there by hand, so it settles instead of flying.
 */
export function useMotionList(root: RefObject<HTMLElement | null>, landingRef?: RefObject<string | null>) {
  const places = useRef(new Map<string, Place>());
  const owner = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    const host = root.current;
    const next = new Map<string, Place>();
    host?.querySelectorAll<HTMLElement>("[data-motion-key]").forEach((el) => next.set(el.dataset.motionKey!, { left: el.offsetLeft, top: el.offsetTop, width: el.offsetWidth, el }));
    const before = places.current;
    const animate = host && owner.current === host && before.size > 0 && !still();
    owner.current = host;
    places.current = next;
    if (!animate) return;
    for (const [key, now] of next) {
      const was = before.get(key);
      if (!was) {
        now.el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: BASE, easing: "ease-out" });
      } else if (was.left === now.left && was.top === now.top) {
        continue;
      } else if (landingRef?.current === key) {
        landingRef.current = null;
        now.el.animate([{ transform: "scale(0.96)" }, { transform: "none" }], { duration: BASE, easing: EASE });
      } else {
        now.el.animate([{ transform: `translate(${was.left - now.left}px, ${was.top - now.top}px)` }, { transform: "none" }], { duration: SLOW, easing: EASE });
      }
    }
    for (const [key, was] of before) {
      if (next.has(key)) continue;
      // React has let go of this node, so it can linger in the list as a fading copy.
      const ghost = was.el;
      ghost.removeAttribute("data-motion-key");
      ghost.inert = true;
      Object.assign(ghost.style, { position: "absolute", left: `${was.left}px`, top: `${was.top}px`, width: `${was.width}px`, margin: "0", pointerEvents: "none" });
      host.append(ghost);
      ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: BASE, easing: "ease-in" }).finished.finally(() => ghost.remove());
    }
  });
}

/** Opens and closes by height. Children are only mounted while open or closing. */
export function Collapse({ open, children, className }: { open: boolean; children: ReactNode; className?: string }) {
  const [closing, setClosing] = useState(false);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    setClosing(!open);
  }
  if (!open && !closing) return null;
  return (
    <div className={cx("motion-collapse", className)} data-open={open} onTransitionEnd={(e) => { if (e.target === e.currentTarget && !open) setClosing(false); }}>
      <div className="min-h-0 overflow-hidden">{children}</div>
    </div>
  );
}
