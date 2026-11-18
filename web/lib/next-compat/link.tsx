// next/link for the static app: an <a> that navigates through the data router.
import type { AnchorHTMLAttributes, MouseEvent, Ref } from "react";
import { appRouter } from "./router";

export type LinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href"> & {
  href: string | { pathname?: string; query?: Record<string, string | number | boolean | undefined>; hash?: string };
  replace?: boolean;
  scroll?: boolean;
  /** Accepted for API parity; routes are code-split and loaded on navigation. */
  prefetch?: boolean | null;
  ref?: Ref<HTMLAnchorElement>;
};

function toHref(href: LinkProps["href"]): string {
  if (typeof href === "string") return href;
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(href.query ?? {})) if (v !== undefined) q.set(k, String(v));
  const qs = q.toString();
  return `${href.pathname ?? ""}${qs ? `?${qs}` : ""}${href.hash ? `#${href.hash.replace(/^#/, "")}` : ""}`;
}

export default function Link({ href, replace, scroll, prefetch, onClick, target, ...rest }: LinkProps) {
  void prefetch;
  const to = toHref(href);
  function click(e: MouseEvent<HTMLAnchorElement>) {
    onClick?.(e);
    if (e.defaultPrevented) return;
    // Let the browser handle new-tab gestures, downloads and other targets.
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if ((target && target !== "_self") || e.currentTarget.hasAttribute("download")) return;
    e.preventDefault();
    if (replace) appRouter.replace(to, { scroll });
    else appRouter.push(to, { scroll });
  }
  return <a href={to} target={target} onClick={click} {...rest} />;
}
