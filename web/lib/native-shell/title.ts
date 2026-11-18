// The page title sent to the shell: the document title without the " · Vesper" suffix, unless the
// top bar published a title of its own (the breadcrumb's current crumb, which it doesn't draw).

import { postDeduped } from "./bridge.ts";
import type { MenuItem } from "./protocol.ts";

/** "VES-412 · Vesper" -> "VES-412"; "Vesper" alone -> "". */
export function stripVesperSuffix(title: string): string {
  const t = title.trim().replace(/\s*[·\-—–|]\s*Vesper$/, "");
  return t === "Vesper" ? "" : t;
}

type Override = { title: string; subtitle?: string };
const overrides = new Map<symbol, Override>();

const menus = new Map<symbol, MenuItem[]>();

function current(): Override {
  const last = [...overrides.values()].at(-1);
  if (last) return last;
  const doc = (globalThis as { document?: { title?: string } }).document;
  return { title: stripVesperSuffix(doc?.title ?? "") };
}

/** Send the current title (deduped). */
export function publishTitle(): void {
  const { title, subtitle } = current();
  const menu = [...menus.values()].at(-1);
  postDeduped({ v: 1, type: "title", title, ...(subtitle ? { subtitle } : {}), ...(menu?.length ? { menu } : {}) });
}

/**
 * The title's own menu (rename, archive…), sent with the title so there is one source for it; the
 * shell draws it on a chevron beside the title. Pass null to withdraw it.
 */
export function setTitleMenu(token: symbol, menu: MenuItem[] | null): void {
  if (menu?.length) menus.set(token, menu);
  else menus.delete(token);
  publishTitle();
}

/** The top bar's title; pass null to withdraw it. */
export function setTopBarTitle(token: symbol, value: Override | null): void {
  if (value) {
    overrides.delete(token);
    overrides.set(token, value);
  } else overrides.delete(token);
  publishTitle();
}
