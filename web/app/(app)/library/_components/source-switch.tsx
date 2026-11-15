"use client";

import Link from "next/link";
import { cx } from "@/lib/cx";

export type LibrarySource = "yours" | "projects";

/**
 * Library holds two kinds of thing: your keepsakes from chats (private to
 * you) and what agents wrote on tickets (shared with the workspace). The
 * switch is that boundary.
 */
export function LibrarySourceSwitch({ source }: { source: LibrarySource }) {
  const items: Array<{ key: LibrarySource; label: string; href: string }> = [
    { key: "yours", label: "Yours", href: "/library" },
    { key: "projects", label: "From spaces", href: "/library?source=projects" },
  ];
  return (
    <nav aria-label="Library source" className="flex w-fit rounded-lg border border-border-strong bg-surface-sunken p-0.5">
      {items.map((i) => (
        <Link
          key={i.key}
          href={i.href}
          aria-current={i.key === source ? "true" : undefined}
          className={cx(
            "flex h-[26px] items-center rounded-md px-3 text-13",
            i.key === source ? "bg-selected font-medium text-fg shadow-[inset_0_0_0_1px_var(--border-strong)]" : "text-fg-secondary hover:text-fg",
          )}
        >
          {i.label}
        </Link>
      ))}
    </nav>
  );
}
