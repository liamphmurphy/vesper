// "You have unsaved changes" guards that also work in the Mac app.
//
// A browser asks a page's beforeunload listeners before it closes the tab. A WKWebView never does,
// so the Mac app asks instead: before closing a tab, window or the app it calls
// window.__vesperHasUnsavedChanges(), which runs only these guards (not every beforeunload listener:
// some, like the live-updates connection, shut things down when they run).

type Guard = (e: BeforeUnloadEvent) => void;

const guards = new Set<Guard>();

/** True when any registered guard objects to leaving (it called preventDefault). */
export function hasUnsavedChanges(): boolean {
  let prevented = false;
  const event = {
    preventDefault() {
      prevented = true;
    },
    set returnValue(v: unknown) {
      if (v !== undefined && v !== true) prevented = true;
    },
    get returnValue() {
      return !prevented;
    },
  } as unknown as BeforeUnloadEvent;
  for (const guard of guards) {
    try {
      guard(event);
    } catch {
      /* a broken guard doesn't block closing */
    }
  }
  return prevented;
}

/** Adds `guard` as a beforeunload listener and for the Mac app's close check; returns the remover. */
export function addLeaveGuard(guard: Guard): () => void {
  guards.add(guard);
  window.addEventListener("beforeunload", guard);
  (window as { __vesperHasUnsavedChanges?: () => boolean }).__vesperHasUnsavedChanges = hasUnsavedChanges;
  return () => {
    guards.delete(guard);
    window.removeEventListener("beforeunload", guard);
  };
}
