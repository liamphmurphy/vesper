"use client";

import { useEffect, useState } from "react";
import { cx } from "@/lib/cx";
import { canOpenWorkspaceFolder, openWorkspaceFolder } from "@/lib/desktop-bridge";
import { toast } from "@/lib/toast";
import { Icon } from "@/components/ui/icon";
import { IconButton } from "@/components/ui/button";
import { CopyButton } from "@/components/ui/copy-button";

/**
 * The folder on the person's machine holding a run's checkout (host-folder
 * workspaces), with a button that copies its path and, in the desktop app,
 * one that opens it in Finder, a terminal or an editor.
 */
export function WorkspaceFolderChip({ path, className }: { path: string; className?: string }) {
  // Feature-detected after mount: the server render never sees the desktop bridge.
  const [canOpen, setCanOpen] = useState(false);
  useEffect(() => setCanOpen(canOpenWorkspaceFolder()), []);
  return (
    <span
      data-testid="workspace-folder"
      title={`Checkout on this machine:\n${path}`}
      className={cx("flex min-w-0 flex-none items-center gap-1 rounded-full border border-border bg-surface py-px pl-2.5 pr-0.5 text-12 text-fg-secondary", className)}
    >
      <Icon name="folder" size={13} className="flex-none" />
      <span className="max-w-[220px] truncate font-mono text-12" dir="rtl">
        {/* rtl keeps the run's own folder visible when the path truncates */}
        <bdi>{path}</bdi>
      </span>
      <CopyButton text={path} label="Copy folder path" size={18} />
      {canOpen && (
        <IconButton
          icon="expand"
          label="Open folder in…"
          size={18}
          onClick={() => {
            void openWorkspaceFolder(path).then((error) => {
              if (error) toast({ title: error, tone: "error" });
            });
          }}
        />
      )}
    </span>
  );
}

