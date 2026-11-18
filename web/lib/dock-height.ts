// The Mac app floats the chat composer over the transcript. The overlap and the transcript's bottom
// padding follow the dock's real height (--chat-dock-h), so a tall status tray or a multi-line
// composer never covers the last message.

export const DOCK_HEIGHT_VAR = "--chat-dock-h";

/** The CSS length for a measured height: whole pixels, never negative, empty for junk. */
export function dockHeightValue(px: number): string {
  if (!Number.isFinite(px) || px < 0) return "";
  return `${Math.ceil(px)}px`;
}

/** Keeps `--chat-dock-h` on the dock's parent equal to the dock's height. Returns the cleanup. */
export function trackDockHeight(dock: HTMLElement): () => void {
  const host = dock.parentElement;
  if (!host || typeof ResizeObserver === "undefined") return () => {};
  const apply = (px: number) => {
    const v = dockHeightValue(px);
    if (v) host.style.setProperty(DOCK_HEIGHT_VAR, v);
    else host.style.removeProperty(DOCK_HEIGHT_VAR);
  };
  apply(dock.getBoundingClientRect().height);
  const ro = new ResizeObserver((entries) => {
    const e = entries[entries.length - 1];
    apply(e?.borderBoxSize?.[0]?.blockSize ?? dock.getBoundingClientRect().height);
  });
  ro.observe(dock);
  return () => {
    ro.disconnect();
    host.style.removeProperty(DOCK_HEIGHT_VAR);
  };
}
