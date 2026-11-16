"use client";

import { ContextMenu } from "radix-ui";
import type { ReactNode } from "react";
import { floatPanel } from "@/components/domain/pickers";
import { Icon, type IconName } from "@/components/ui/icon";
import { cx } from "@/lib/cx";

export type TreeMenuEntry =
  | { icon: IconName; label: string; onSelect: () => void; danger?: boolean }
  | "separator";

const itemCls =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 text-12 outline-none data-[highlighted]:bg-hover";

/**
 * Right-click on children opens this menu instead of the browser's. Menus nest:
 * a row inside the tree's own menu opens only its own.
 */
export function TreeMenu({
  entries,
  children,
  className,
}: {
  entries: TreeMenuEntry[];
  children: ReactNode;
  className?: string;
}) {
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger asChild>
        {/* Radix doesn't stop the event, so without this the tree's menu would open under a row's. */}
        <div className={className} onContextMenu={(e) => e.stopPropagation()}>
          {children}
        </div>
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        {/* Focus stays where the chosen action puts it (a dialog, the new request), not back on the row. */}
        <ContextMenu.Content
          collisionPadding={8}
          onCloseAutoFocus={(e) => e.preventDefault()}
          className={cx(floatPanel, "min-w-[200px]")}
        >
          {entries.map((e, i) =>
            e === "separator" ? (
              <ContextMenu.Separator key={`sep-${i}`} className="mx-1 my-1 h-px bg-border-subtle" />
            ) : (
              <ContextMenu.Item key={e.label} onSelect={e.onSelect} className={cx(itemCls, e.danger && "text-pill-blocked-fg")}>
                <Icon name={e.icon} size={14} className={e.danger ? undefined : "text-fg-secondary"} />
                {e.label}
              </ContextMenu.Item>
            ),
          )}
        </ContextMenu.Content>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  );
}
