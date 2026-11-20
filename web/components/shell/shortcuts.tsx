"use client";

import { Dialog } from "radix-ui";
import { useEffect, useState } from "react";
import { isNativeShell, post } from "@/lib/native-shell/bridge";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { IconButton } from "@/components/ui/button";
import { Kbd } from "@/components/ui/primitives";
import { SHORTCUTS } from "@/lib/command-palette";

/** Open the shortcut reference from a button or shortcut. Native macOS uses its own Shortcuts window. */
export function openShortcuts() {
  if (isNativeShell()) {
    post({ v: 1, type: "showShortcuts" });
    return;
  }
  window.dispatchEvent(new Event("la:shortcuts"));
}

/** Typing into a field: single-key shortcuts must not fire. */
export function isTyping(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false;
  return (
    el.isContentEditable ||
    ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) ||
    el.getAttribute("role") === "combobox"
  );
}

/**
 * Whether a page's single-key shortcut must stand down: a modifier is held, focus
 * is in a field, a dialog is open, or a menu or listbox is open (Radix menus
 * typeahead on letters and let the key bubble to window).
 */
export function shortcutBlocked(e: KeyboardEvent): boolean {
  if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target)) return true;
  if (e.target instanceof Element && e.target.closest('[role="menu"],[role="menubar"],[role="listbox"],[role="menuitem"],[role="menuitemradio"],[role="option"]')) return true;
  return !!document.querySelector('[role="dialog"],[role="menu"],[role="listbox"]:not([hidden])');
}

/** The `?` keyboard shortcut reference; opened by `?` (app-shell.tsx) or the palette's action. */
export function ShortcutsDialog() {
  const native = useIsNativeShell();
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const show = () => {
      if (isNativeShell()) {
        post({ v: 1, type: "showShortcuts" });
        return;
      }
      setOpen(true);
    };
    window.addEventListener("la:shortcuts", show);
    return () => window.removeEventListener("la:shortcuts", show);
  }, []);
  if (native) return null;
  return (
    <Dialog.Root open={open} onOpenChange={setOpen}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-50 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-[12vh] z-50 flex max-h-[80vh] w-[600px] max-w-[calc(100vw-24px)] -translate-x-1/2 flex-col overflow-hidden rounded-xl border border-border-float bg-surface-raised shadow-xl outline-none"
        >
          <div className="flex items-center border-b border-border px-6 py-3">
            <Dialog.Title className="flex-1 text-16 font-semibold">Keyboard shortcuts</Dialog.Title>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close keyboard shortcuts" />
            </Dialog.Close>
          </div>
          <div className="overflow-y-auto px-6 pb-5">
            {SHORTCUTS.map((s) => (
              <section key={s.section} aria-labelledby={`shortcuts-${s.section.replaceAll(" ", "-")}`}>
                <h3 id={`shortcuts-${s.section.replaceAll(" ", "-")}`} className="pb-1 pt-4 text-11 font-medium uppercase tracking-wide text-fg-tertiary">
                  {s.section}
                </h3>
                <dl>
                  {s.items.map((i) => (
                    <div key={i.label} className="flex min-h-[28px] items-center gap-4 text-14">
                      <dt className="flex-1">{i.label}</dt>
                      <dd className="flex gap-1">
                        {i.keys.map((k) => (
                          <Kbd key={k}>{k}</Kbd>
                        ))}
                      </dd>
                    </div>
                  ))}
                </dl>
              </section>
            ))}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
