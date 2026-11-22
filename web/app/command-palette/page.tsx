"use client";

import { useEffect } from "react";
import { CommandMenu } from "@/components/shell/command-menu";
import { LiveUpdates } from "@/components/shell/live-updates";
import { applyNativeAppearance } from "@/components/shell/theme";
import { onCommand, post } from "@/lib/native-shell/bridge";

/**
 * Dedicated route hosted inside macOS's native floating Liquid Glass `NSPanel` for ⌘K.
 * Stays mounted across openings so searches, shortcuts, and preview actions remain instant.
 */
export default function NativeCommandPalettePage() {
  useEffect(() => {
    post({ v: 1, type: "ready", path: "/command-palette" });
    return onCommand((cmd) => {
      if (cmd.type === "appearance") {
        applyNativeAppearance(cmd);
      }
    });
  }, []);

  return (
    <div className="flex h-dvh min-h-0 flex-col bg-transparent text-fg">
      <LiveUpdates />
      <CommandMenu embedded />
    </div>
  );
}
