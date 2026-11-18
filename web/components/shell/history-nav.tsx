"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { Icon } from "@/components/ui/icon";
import { cx } from "@/lib/cx";
import { useIsNativeShell } from "@/lib/native-shell/hooks";

/** The parts of the Navigation API this reads; not every browser (or TypeScript's DOM lib) has it. */
type HistoryApi = EventTarget & { canGoBack: boolean; canGoForward: boolean };

function historyApi(): HistoryApi | undefined {
  return (window as unknown as { navigation?: HistoryApi }).navigation;
}

/**
 * Back and forward at the top left of the page's content, first in every header (TopBar,
 * PageHeader, an editor's bar, the chat header, Knowledge's tabs): following a link from a run to
 * its ticket, a chat to a page or Settings to a design keeps your place one click away. Where the
 * browser can say whether there is anywhere to go (the Navigation API), the buttons disable at
 * either end; elsewhere they stay on. Phones hide them: they have the system's back gesture, and
 * the Mac app hides them: its toolbar has back and forward.
 */
export function HistoryNav({ className }: { className?: string }) {
  const router = useRouter();
  // The server render and first client render agree: back on, forward off until the browser says otherwise.
  const [can, setCan] = useState({ back: true, forward: false });
  useEffect(() => {
    const api = historyApi();
    if (!api) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- no Navigation API: offer both, as a browser's own buttons would
      setCan({ back: true, forward: true });
      return;
    }
    const update = () => setCan({ back: api.canGoBack, forward: api.canGoForward });
    update();
    api.addEventListener("currententrychange", update);
    return () => api.removeEventListener("currententrychange", update);
  }, []);
  // The Mac app's toolbar has its own back and forward.
  const native = useIsNativeShell();
  if (native) return null;
  const button = "grid size-7 flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent";
  return (
    <div role="group" aria-label="History" data-testid="history-nav" className={cx("flex flex-none items-center max-md:hidden", className)}>
      <button type="button" aria-label="Go back" title="Back" disabled={!can.back} onClick={() => router.back()} className={button}>
        <Icon name="chevr" size={14} className="rotate-180" />
      </button>
      <button type="button" aria-label="Go forward" title="Forward" disabled={!can.forward} onClick={() => router.forward()} className={button}>
        <Icon name="chevr" size={14} />
      </button>
    </div>
  );
}
