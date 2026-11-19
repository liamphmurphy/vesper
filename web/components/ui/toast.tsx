"use client";

import { useEffect, useRef, useSyncExternalStore } from "react";
import { cx } from "@/lib/cx";
import { currentToasts, dismissToast, subscribeToasts, type Toast } from "@/lib/toast";
import { Icon } from "./icon";

export { toast, dismissToast, undoable } from "@/lib/toast";

const NONE: Toast[] = [];

/** Rendered once, in Providers. */
export function Toaster() {
  const items = useSyncExternalStore(subscribeToasts, currentToasts, () => NONE);
  return (
    // The live region exists before any toast does, so screen readers announce each arrival.
    <section aria-label="Notifications" aria-live="polite" className="pointer-events-none fixed inset-x-0 bottom-5 z-[70] flex flex-col items-center px-4">
      <div className="flex w-full max-w-[420px] flex-col gap-2">
        {items.map((t) => <ToastItem key={t.id} toast={t} />)}
      </div>
    </section>
  );
}

const ICON = { neutral: null, success: "check", error: "alert" } as const;

function ToastItem({ toast: t }: { toast: Toast }) {
  const paused = useRef(false);
  const remaining = useRef(t.duration);
  useEffect(() => {
    if (t.leaving) return;
    remaining.current = t.duration;
    let started = Date.now();
    let timer = 0;
    const tick = () => {
      if (paused.current) { started = Date.now(); timer = window.setTimeout(tick, 250); return; }
      remaining.current -= Date.now() - started;
      started = Date.now();
      if (remaining.current <= 0) dismissToast(t.id, "timeout");
      else timer = window.setTimeout(tick, Math.min(remaining.current, 250));
    };
    timer = window.setTimeout(tick, 250);
    return () => window.clearTimeout(timer);
  }, [t]);
  const icon = ICON[t.tone];
  const hold = () => { paused.current = true; };
  const release = () => { paused.current = false; };
  return (
    <div
      data-state={t.leaving ? "closed" : "open"}
      // Leaving: still painted for its exit, but no longer clickable or announced.
      inert={t.leaving}
      aria-hidden={t.leaving || undefined}
      onMouseEnter={hold} onMouseLeave={release} onFocus={hold} onBlur={release}
      className={cx(
        "motion-toast pointer-events-auto flex items-start gap-2.5 rounded-lg border bg-surface-raised py-2.5 pl-3.5 pr-2 text-13 shadow-[var(--shadow-float)]",
        t.tone === "error" ? "border-pill-blocked-fg/40" : "border-border-float",
      )}
    >
      {icon && <span className={cx("mt-px flex-none", t.tone === "error" ? "text-pill-blocked-fg" : "text-state-done")}><Icon name={icon} size={15} /></span>}
      <div className="min-w-0 flex-1">
        <p className={cx("font-medium", t.tone === "error" ? "text-pill-blocked-fg" : "text-fg")}>{t.title}</p>
        {t.description && <p className="mt-0.5 text-12 text-fg-secondary">{t.description}</p>}
      </div>
      {t.action && (
        <button type="button" className="flex-none rounded-sm px-2 py-0.5 text-13 font-medium text-accent hover:bg-hover" onClick={() => { t.action!.onClick(); dismissToast(t.id, "action"); }}>
          {t.action.label}
        </button>
      )}
      <button type="button" aria-label="Dismiss notification" className="grid size-6 flex-none place-items-center rounded-sm text-fg-tertiary hover:bg-hover hover:text-fg" onClick={() => dismissToast(t.id)}>
        <Icon name="x" size={12} />
      </button>
    </div>
  );
}
