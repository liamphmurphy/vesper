"use client";

import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { invalidatedKeys } from "@/lib/live-updates";
import { createSseClient } from "@/lib/sse-multiplexer";

/** One stream per origin (leader-elected via Web Locks + BroadcastChannel). Coalesce bursts from harness logs before refetching. */
export function LiveUpdates() {
  const qc = useQueryClient();
  const [offline, setOffline] = useState(false);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const pending = new Map<string, readonly unknown[]>();
    const flush = () => {
      timer = undefined;
      for (const queryKey of pending.values()) void qc.invalidateQueries({ queryKey });
      pending.clear();
    };
    const client = createSseClient({
      url: "/events",
      onStatus: (isOffline) => setOffline(isOffline),
      onEvent: (payload) => {
        if (payload.type === "reset") {
          void qc.invalidateQueries();
          return;
        }
        window.dispatchEvent(new CustomEvent("vesper:sse", { detail: payload }));
        for (const queryKey of invalidatedKeys(payload)) pending.set(JSON.stringify(queryKey), queryKey);
        if (!timer) timer = setTimeout(flush, 100);
      },
    });
    return () => {
      client.stop();
      if (timer) clearTimeout(timer);
    };
  }, [qc]);
  return offline ? (
    <div
      role="status"
      className="pointer-events-none fixed bottom-5 left-1/2 z-50 max-md:top-[calc(env(safe-area-inset-top,0px)+12px)] max-md:bottom-auto -translate-x-1/2 rounded-lg border border-border-float bg-surface-raised px-4 py-2 text-14 text-fg-secondary shadow-lg"
    >
      Live updates paused. Reconnecting…
    </div>
  ) : null;
}
