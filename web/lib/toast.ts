import type { ReactNode } from "react";
import { isNativeShell, onCommand, post } from "./native-shell/bridge.ts";

/**
 * App-wide toasts: what an action just did, or why it didn't. Call `toast()` from anywhere
 * (event handlers, mutation callbacks, hooks); in browsers the one <Toaster> (components/ui/toast.tsx)
 * shows them along the bottom edge, whereas in the native macOS shell plain-text toasts route to
 * a window-level native Liquid Glass HUD.
 */
export type ToastTone = "neutral" | "success" | "error";
export type ToastInput = {
  title: ReactNode;
  description?: ReactNode;
  tone?: ToastTone;
  /** One follow-up, such as "View" or "Undo". Choosing it dismisses the toast. */
  action?: { label: string; onClick: () => void };
  /** Milliseconds before it dismisses itself; errors stay longer by default. */
  duration?: number;
  /** Re-using an id replaces that toast instead of stacking another. */
  id?: string;
  /** Runs once when the toast goes, however it goes (timeout, ×, its action, or pushed out). */
  onClose?: (reason: ToastCloseReason) => void;
};
export type ToastCloseReason = "timeout" | "dismissed" | "action" | "replaced";
export type Toast = Required<Pick<ToastInput, "title" | "tone" | "duration" | "id">> & Pick<ToastInput, "description" | "action" | "onClose"> & { leaving: boolean };

export const MAX_TOASTS = 3;
const EXIT_MS = 140; // --motion-exit: the leave animation plays before the toast is dropped.
let toasts: Toast[] = [];
let next = 0;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

type NativeToastEntry = {
  action?: () => void;
  onClose?: (reason: ToastCloseReason) => void;
};
const nativeCallbacks = new Map<string, NativeToastEntry>();
let listeningWindow: unknown = null;
let offNativeCommand: (() => void) | null = null;

function ensureNativeListener(): void {
  const currentWin = (globalThis as { window?: unknown }).window;
  if (!currentWin) return;
  if (offNativeCommand && listeningWindow === currentWin) return;
  offNativeCommand?.();
  listeningWindow = currentWin;
  offNativeCommand = onCommand((cmd) => {
    if (cmd.type !== "toast.event") return;
    const entry = nativeCallbacks.get(cmd.id);
    if (!entry) return;
    nativeCallbacks.delete(cmd.id);
    if (cmd.event === "action") entry.action?.();
    entry.onClose?.(cmd.event);
  });
}

function canUseNativeHud(t: ToastInput): t is ToastInput & { title: string; description?: string } {
  return (
    isNativeShell() &&
    typeof t.title === "string" &&
    (t.description === undefined || typeof t.description === "string")
  );
}

export function toast(input: ToastInput | string): string {
  const t = typeof input === "string" ? { title: input } : input;
  const tone = t.tone ?? "neutral";
  const id = t.id ?? `toast-${++next}`;
  const duration = t.duration ?? (tone === "error" ? 8000 : 4500);

  if (canUseNativeHud(t)) {
    ensureNativeListener();
    const previousNative = nativeCallbacks.get(id);
    nativeCallbacks.set(id, { action: t.action?.onClick, onClose: t.onClose });
    if (previousNative) previousNative.onClose?.("replaced");
    while (nativeCallbacks.size > MAX_TOASTS) {
      const oldestId = nativeCallbacks.keys().next().value;
      if (oldestId === undefined) break;
      const oldest = nativeCallbacks.get(oldestId);
      nativeCallbacks.delete(oldestId);
      oldest?.onClose?.("replaced");
    }
    post({
      v: 1,
      type: "toast.show",
      id,
      title: t.title,
      ...(t.description !== undefined ? { description: t.description } : {}),
      tone,
      ...(t.action ? { actionLabel: t.action.label } : {}),
      durationMs: duration,
    });
    return id;
  }

  const item: Toast = { title: t.title, description: t.description, action: t.action, onClose: t.onClose, tone, id, duration, leaving: false };
  const previous = toasts.find((x) => x.id === id);
  const kept = toasts.filter((x) => x.id !== id);
  const all = previous ? toasts.map((x) => (x.id === id ? item : x)) : [...kept, item];
  // Pushed out by newer ones: close the oldest so an Undo's commit still runs.
  const overflow = all.filter((x) => !x.leaving).length - MAX_TOASTS;
  const dropped = overflow > 0 ? all.filter((x) => !x.leaving).slice(0, overflow) : [];
  toasts = all.filter((x) => !dropped.includes(x));
  if (previous && previous !== item) previous.onClose?.("replaced");
  dropped.forEach((x) => x.onClose?.("replaced"));
  emit();
  return id;
}

export function dismissToast(id: string, reason: ToastCloseReason = "dismissed") {
  const nativeEntry = nativeCallbacks.get(id);
  if (nativeEntry) {
    nativeCallbacks.delete(id);
    nativeEntry.onClose?.(reason);
    post({ v: 1, type: "toast.dismiss", id });
    return;
  }
  const target = toasts.find((t) => t.id === id && !t.leaving);
  if (!target) return;
  toasts = toasts.map((t) => (t === target ? { ...t, leaving: true } : t));
  target.onClose?.(reason);
  emit();
  setTimeout(() => {
    toasts = toasts.filter((t) => t.id !== id || !t.leaving);
    emit();
  }, EXIT_MS);
}

/** Clears both web and native toast state (unit tests). */
export function clearToasts(): void {
  for (const [id, entry] of [...nativeCallbacks.entries()]) {
    nativeCallbacks.delete(id);
    entry.onClose?.("dismissed");
  }
  offNativeCommand?.();
  offNativeCommand = null;
  listeningWindow = null;
  for (const t of [...toasts]) {
    if (!t.leaving) t.onClose?.("dismissed");
  }
  toasts = [];
  emit();
}

export function subscribeToasts(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

export const currentToasts = () => toasts;

/**
 * Undo instead of "Are you sure?" for something that's cheap to keep: hide it now, do it when
 * the toast goes, or bring it back if Undo is chosen. Nothing is deleted until then, so closing
 * the tab inside the window keeps the item rather than losing it.
 */
export function undoable({ title, description, hide, restore, commit, failed = "Couldn't finish that", duration = 6000 }: {
  title: ReactNode;
  description?: ReactNode;
  hide: () => void;
  restore: () => void;
  commit: () => Promise<unknown>;
  failed?: string;
  duration?: number;
}) {
  let undone = false;
  hide();
  return toast({
    title, description, duration,
    action: { label: "Undo", onClick: () => { undone = true; restore(); } },
    onClose: () => {
      if (undone) return;
      commit().catch((e: unknown) => {
        restore();
        toast({ tone: "error", title: failed, description: e instanceof Error ? e.message : undefined });
      });
    },
  });
}
