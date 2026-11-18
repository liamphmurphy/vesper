"use client";

import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { fromFraction, panBy, swipeKey, toFraction, zoomAt, type Fraction, type Size, type View } from "@/lib/mockup-review";
import { Button } from "@/components/ui/button";
import { TextArea } from "@/components/ui/primitives";

export type Pin = Schemas["MockupPin"];
/** One version's drawing: its data: URL, intrinsic size, version label (v3) and alt text. */
export type Drawing = { url: string; size: Size; label: string; alt: string };
export type Tool = "pan" | "pin";
/** Applies a change to the shared view (functional, so rapid events compose). */
export type ChangeView = (fn: (v: View) => View) => void;

const checker =
  "bg-surface-sunken [background-image:conic-gradient(var(--border-subtle)_25%,transparent_0_50%,var(--border-subtle)_0_75%,transparent_0)] [background-size:16px_16px]";

/**
 * The SVG through <img> with a data: URL, sized rather than CSS-scaled so the
 * browser re-rasterises the vector crisply at every zoom.
 */
function DrawingImage({ d, view }: { d: Drawing; view: View }) {
  return (
    // data: URL of user SVG source, never injected into the DOM
    <img
      src={d.url}
      alt={d.alt}
      draggable={false}
      className="pointer-events-none absolute max-w-none select-none shadow-[0_0_0_1px_var(--border)]"
      style={{ left: view.x, top: view.y, width: d.size.w * view.scale, height: d.size.h * view.scale }}
    />
  );
}

function PinMarker({ n, pin, left, top, tone, active, onHover }: {
  n: number; pin: Pin; left: number; top: number; tone: "draft" | "saved"; active: boolean; onHover?: (i: number | null) => void;
}) {
  return (
    <button
      type="button"
      aria-label={`Pin ${n}: ${pin.text}`}
      title={pin.text}
      onPointerDown={(e) => e.stopPropagation()}
      onMouseEnter={() => onHover?.(n - 1)}
      onMouseLeave={() => onHover?.(null)}
      onFocus={() => onHover?.(n - 1)}
      onBlur={() => onHover?.(null)}
      className={cx(
        "absolute grid size-6 -translate-x-1/2 -translate-y-1/2 cursor-default place-items-center rounded-full text-12 font-bold shadow-sm ring-2 ring-surface transition-transform",
        tone === "draft" ? "bg-accent text-on-accent" : "bg-fg-secondary text-surface",
        active && "scale-125",
      )}
      style={{ left, top }}
    >
      {n}
    </button>
  );
}

const COMPOSER_W = 280;
const COMPOSER_H = 156;

function PinComposer({ n, left, top, box, versionLabel, onSave, onCancel }: {
  n: number; left: number; top: number; box: Size; versionLabel: string; onSave: (text: string) => void; onCancel: () => void;
}) {
  const [text, setText] = useState("");
  const save = () => {
    if (text.trim()) onSave(text.trim());
  };
  const x = Math.max(8, Math.min(left - COMPOSER_W / 2, box.w - COMPOSER_W - 8));
  const y = top + 20 + COMPOSER_H < box.h ? top + 20 : Math.max(8, top - 20 - COMPOSER_H);
  return (
    <>
      <span
        aria-hidden="true"
        className="pointer-events-none absolute grid size-6 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full border-2 border-dashed border-accent bg-surface text-12 font-bold text-accent"
        style={{ left, top }}
      >
        {n}
      </span>
      <form
        aria-label={`Comment ${n}`}
        onPointerDown={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onCancel();
          } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            save();
          }
        }}
        className="absolute z-10 flex flex-col gap-2 rounded-xl border border-border-float bg-surface-raised p-3 text-fg shadow-[var(--shadow-float)]"
        style={{ left: x, top: y, width: COMPOSER_W }}
      >
        <div className="flex items-center justify-between">
          <span className="text-13 font-semibold">Comment {n}</span>
          <span className="text-11 text-fg-tertiary">on {versionLabel}</span>
        </div>
        <TextArea
          aria-label={`Comment ${n}`}
          autoFocus
          rows={3}
          maxLength={500}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="What should change here?"
          className="text-13"
        />
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onCancel}>
            Cancel
          </Button>
          <Button type="submit" variant="primary" disabled={!text.trim()} hint="⌘↵">
            Add pin
          </Button>
        </div>
      </form>
    </>
  );
}

function SwipeHandle({ pos, label, valueText, onChange }: { pos: number; label: string; valueText: string; onChange: (p: number) => void }) {
  const drag = (e: PointerEvent<HTMLDivElement>) => {
    const r = e.currentTarget.parentElement!.getBoundingClientRect();
    onChange(Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)));
  };
  return (
    <div
      className="absolute inset-y-0 z-[1] w-6 -translate-x-1/2 cursor-ew-resize touch-none"
      style={{ left: `${pos * 100}%` }}
      onPointerDown={(e) => {
        e.stopPropagation();
        e.currentTarget.setPointerCapture(e.pointerId);
        drag(e);
      }}
      onPointerMove={(e) => {
        if (e.currentTarget.hasPointerCapture(e.pointerId)) drag(e);
      }}
    >
      <div className="absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 bg-accent" />
      <div
        role="slider"
        tabIndex={0}
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(pos * 100)}
        aria-valuetext={valueText}
        onKeyDown={(e) => {
          const next = swipeKey(pos, e.key, e.shiftKey);
          if (next === null) return;
          e.preventDefault();
          e.stopPropagation();
          onChange(next);
        }}
        className="absolute left-1/2 top-1/2 grid size-9 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full border-2 border-accent bg-surface text-accent shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
      >
        <svg width="18" height="12" viewBox="0 0 18 12" aria-hidden="true">
          <path d="M6 1 1 6l5 5M12 1l5 5-5 5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>
    </div>
  );
}

/**
 * One viewport onto a drawing. Drag or scroll pans; ⌘/Ctrl+scroll and pinch
 * zoom about the pointer. In pin mode a click (not a drag) on the drawing
 * calls onPlace with the clicked point as fractions of the drawing.
 */
export function Pane({
  label,
  box,
  view,
  change,
  drawing,
  swipeWith,
  swipe,
  onSwipe,
  pins,
  tone,
  showPins,
  tool,
  onPlace,
  composing,
  onCompose,
  onCancelCompose,
  activePin,
  onHoverPin,
  describedBy,
  chip,
}: {
  label: string;
  box: Size;
  view: View;
  change: ChangeView;
  drawing: Drawing | null;
  /** Swipe compare: this drawing shows left of the handle. */
  swipeWith?: Drawing | null;
  swipe?: number;
  onSwipe?: (p: number) => void;
  pins: Pin[];
  tone: "draft" | "saved";
  showPins: boolean;
  tool: Tool;
  onPlace?: (f: Fraction) => void;
  composing?: Fraction | null;
  onCompose?: (text: string) => void;
  onCancelCompose?: () => void;
  activePin?: number | null;
  onHoverPin?: (i: number | null) => void;
  describedBy?: string;
  chip?: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const drag = useRef<{ id: number; sx: number; sy: number; lx: number; ly: number; moved: boolean } | null>(null);
  const [dragging, setDragging] = useState(false);

  // Wheel needs a non-passive listener so it can stop the page from scrolling.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 16 : 1;
      const r = el.getBoundingClientRect();
      if (e.ctrlKey || e.metaKey) {
        const dy = Math.max(-50, Math.min(50, e.deltaY * unit));
        change((v) => zoomAt(v, Math.exp(-dy * 0.006), e.clientX - r.left, e.clientY - r.top));
      } else {
        change((v) => panBy(v, -e.deltaX * unit, -e.deltaY * unit));
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [change]);

  const end = () => {
    drag.current = null;
    setDragging(false);
  };

  const placing = tool === "pin" && !!onPlace;
  return (
    <div
      ref={ref}
      role="group"
      aria-roledescription="canvas"
      aria-label={label}
      aria-describedby={describedBy}
      className={cx("relative isolate min-w-0 flex-1 touch-none select-none overflow-hidden", checker, dragging ? "cursor-grabbing" : placing ? "cursor-crosshair" : "cursor-grab")}
      onPointerDown={(e) => {
        if (e.button !== 0) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        drag.current = { id: e.pointerId, sx: e.clientX, sy: e.clientY, lx: e.clientX, ly: e.clientY, moved: false };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d || d.id !== e.pointerId) return;
        if (!d.moved && Math.hypot(e.clientX - d.sx, e.clientY - d.sy) < 4) return;
        if (!d.moved) {
          d.moved = true;
          setDragging(true);
        }
        const dx = e.clientX - d.lx;
        const dy = e.clientY - d.ly;
        d.lx = e.clientX;
        d.ly = e.clientY;
        change((v) => panBy(v, dx, dy));
      }}
      onPointerUp={(e) => {
        const d = drag.current;
        if (!d || d.id !== e.pointerId) return;
        end();
        if (d.moved || !placing || !drawing) return;
        const r = e.currentTarget.getBoundingClientRect();
        if (swipeWith && swipe !== undefined && e.clientX - r.left < swipe * r.width) return; // that side shows the other version
        const f = toFraction(view, drawing.size, e.clientX - r.left, e.clientY - r.top);
        if (f) onPlace!(f);
      }}
      onPointerCancel={end}
    >
      {!drawing ? (
        <p className="absolute inset-0 grid place-items-center text-13 text-fg-tertiary">Loading mockup…</p>
      ) : swipeWith && swipe !== undefined ? (
        // Clip both sides: drawings without an opaque background would otherwise show through each other.
        <div className="pointer-events-none absolute inset-0" style={{ clipPath: `inset(0 0 0 ${swipe * 100}%)` }}>
          <DrawingImage d={drawing} view={view} />
        </div>
      ) : (
        <DrawingImage d={drawing} view={view} />
      )}
      {swipeWith && swipe !== undefined && (
        <div aria-hidden="true" className="pointer-events-none absolute inset-0" style={{ clipPath: `inset(0 ${(1 - swipe) * 100}% 0 0)` }}>
          <DrawingImage d={swipeWith} view={view} />
        </div>
      )}
      {drawing &&
        showPins &&
        pins.map((p, i) => {
          const at = fromFraction(view, drawing.size, p);
          // In swipe, this version only shows right of the handle; so do its pins.
          if (swipeWith && swipe !== undefined && at.left < swipe * box.w) return null;
          return <PinMarker key={i} n={i + 1} pin={p} left={at.left} top={at.top} tone={tone} active={activePin === i} onHover={onHoverPin} />;
        })}
      {drawing && composing && onCompose && onCancelCompose && (() => {
        const at = fromFraction(view, drawing.size, composing);
        return <PinComposer n={pins.length + 1} left={at.left} top={at.top} box={box} versionLabel={drawing.label} onSave={onCompose} onCancel={onCancelCompose} />;
      })()}
      {swipeWith && swipe !== undefined && onSwipe && (
        <SwipeHandle
          pos={swipe}
          onChange={onSwipe}
          label={`Swipe between ${swipeWith.label} and ${drawing?.label ?? "the reviewed version"}`}
          valueText={`${Math.round(swipe * 100)}% ${swipeWith.label}`}
        />
      )}
      {chip && <div className="pointer-events-none absolute left-3 top-3">{chip}</div>}
    </div>
  );
}
