"use client";

import { AlertDialog } from "radix-ui";
import { useSyncExternalStore } from "react";
import { isNativeShell, nativeConfirm } from "@/lib/native-shell/bridge";
import { buttonClass } from "./button";

/**
 * The in-app "Are you sure?", for actions that can't be taken back (a delete the server can't
 * restore, cancelling a run, discarding unsaved edits). `await confirmAction(...)` resolves true
 * only when the person chooses the confirm button; Esc, Cancel and the scrim resolve false.
 * Something cheap to restore should use `undoable` (lib/toast.ts) instead of asking first.
 * In the Mac app it's a sheet on the window instead, so title and body are plain text.
 */
export type ConfirmOptions = {
  title: string;
  body?: string;
  /** The confirm button: a verb for what happens ("Delete", "Discard"). */
  confirmLabel: string;
  cancelLabel?: string;
  /** destructive (the default) tints the confirm button red; neutral keeps it the accent. */
  tone?: "destructive" | "neutral";
};
type Request = ConfirmOptions & { resolve: (ok: boolean) => void };

let current: Request | null = null;
// What the dialog shows while it plays its exit, after the request has settled.
let shown: ConfirmOptions | null = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());

export function confirmAction(options: ConfirmOptions): Promise<boolean> {
  if (isNativeShell()) {
    const { tone, ...rest } = options;
    return nativeConfirm({ ...rest, destructive: (tone ?? "destructive") === "destructive" });
  }
  current?.resolve(false);
  return new Promise((resolve) => {
    current = { ...options, resolve };
    shown = options;
    emit();
  });
}

function settle(ok: boolean) {
  if (!current) return;
  current.resolve(ok);
  current = null;
  emit();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** Rendered once, in Providers. */
export function ConfirmHost() {
  const open = !!useSyncExternalStore(subscribe, () => current, () => null);
  const request = shown;
  const destructive = (request?.tone ?? "destructive") === "destructive";
  return (
    <AlertDialog.Root open={open} onOpenChange={(open) => { if (!open) settle(false); }}>
      <AlertDialog.Portal>
        <AlertDialog.Overlay className="motion-scrim fixed inset-0 z-[60] bg-scrim" />
        <AlertDialog.Content
          className="motion-dialog fixed left-1/2 top-[22vh] z-[60] flex w-[min(420px,calc(100%-32px))] -translate-x-1/2 flex-col gap-2 rounded-2xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none"
          {...(request?.body ? {} : { "aria-describedby": undefined })}
        >
          <AlertDialog.Title className="type-heading text-fg">{request?.title}</AlertDialog.Title>
          {request?.body && <AlertDialog.Description className="text-13 text-fg-secondary">{request.body}</AlertDialog.Description>}
          <div className="mt-3 flex flex-wrap justify-end gap-2">
            <AlertDialog.Cancel className={buttonClass("outline")}>{request?.cancelLabel ?? "Cancel"}</AlertDialog.Cancel>
            <AlertDialog.Action
              className={buttonClass(destructive ? "secondary" : "primary", destructive ? "border-pill-blocked-fg/40 text-pill-blocked-fg hover:bg-pill-blocked-bg" : undefined)}
              onClick={() => settle(true)}
            >
              {request?.confirmLabel}
            </AlertDialog.Action>
          </div>
        </AlertDialog.Content>
      </AlertDialog.Portal>
    </AlertDialog.Root>
  );
}
