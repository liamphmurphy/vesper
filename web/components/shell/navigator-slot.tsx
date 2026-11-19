"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, type ReactNode } from "react";
import { claimNavigator } from "@/lib/navigator";
import { onCommand } from "@/lib/native-shell/bridge";
import { routeNavCommand } from "@/lib/native-shell/nav-model";
import { publisher } from "@/lib/native-shell/publisher";
import type { NativeCommand, NavModel } from "@/lib/native-shell/protocol";

/** A new tab in the Mac app: the shell opens a link with no target window as a tab beside this one. */
export function openInNewTab(href: string) {
  window.open(href, "_blank", "noopener");
}

/** A screen's list described as data for the native sidebar, with a handler for its commands. */
export type NativeNavigator = { model: NavModel; onCommand?: (cmd: NativeCommand) => void };

/**
 * Publishes a screen's own list (the Runs list, the Knowledge explorer, an editor's pages and
 * layers) to the native Mac sidebar as a NavModel, claiming the navigator slot so the default
 * Chats list stands down. nav.* commands for the model's id go to `native.onCommand`;
 * nav.activate on an item with an href navigates by itself.
 */
export function NavigatorPortal({ native }: { children?: ReactNode; native?: NativeNavigator }) {
  const router = useRouter();
  useEffect(() => claimNavigator(), []);

  const model = native?.model;
  const json = model ? JSON.stringify(model) : null;
  const handler = useRef(native?.onCommand);
  useEffect(() => {
    handler.current = native?.onCommand;
  });
  useEffect(() => {
    if (!json) return;
    const token = Symbol("navigator");
    const parsed = JSON.parse(json) as NavModel;
    publisher.setScreen(token, parsed);
    const off = onCommand((cmd) => routeNavCommand(parsed, cmd, (href) => router.push(href), handler.current, openInNewTab));
    return () => {
      off();
      publisher.setScreen(token, null);
    };
  }, [json, router]);

  return null;
}
