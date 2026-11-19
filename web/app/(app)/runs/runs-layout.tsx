"use client";

// The Runs page layout (LAZYAGENTS-163): the run list in the left column (the shell),
// then the run thread and its Context panel (the page). On compact the list and
// the run are separate screens: /runs is the list, a row pushes /runs/[id].

import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { RunsNavigator } from "./run-list";

export function RunsLayout({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const id = /^\/runs\/([^/]+)/.exec(pathname)?.[1];
  return (
    <div className="flex min-h-0 flex-1">
      <RunsNavigator selected={id} />
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">{children}</div>
    </div>
  );
}
