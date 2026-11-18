// What the page tells the shell about the navigator (the sidebar's middle). One module owns it so
// a screen's model, the default Chats model and the fallback column never fight: the shell sees
// the screen's model if a screen has one, else null while a screen claims the navigator without
// one (its list shows in the page's fallback column), else the default Chats model.
// No React; the clock and the transport are injectable for tests.

import { navigatorClaimed } from "../navigator.ts";
import { postDeduped } from "./bridge.ts";
import type { NavModel, PageMessage } from "./protocol.ts";

export interface PublisherDeps {
  send: (msg: PageMessage) => void;
  /** Whether any screen claims the navigator (lib/navigator.ts claims). */
  claimed: () => boolean;
  /** Bursts of changes within this window send once. */
  delayMs: number;
}

export function createNavigatorPublisher(deps: PublisherDeps) {
  const screens = new Map<symbol, NavModel>();
  const fallbacks = new Set<symbol>();
  let defaultModel: NavModel | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastFallback: boolean | undefined;
  let lastModel = "null"; // the shell starts with no navigator

  const effective = (): NavModel | null => {
    const last = [...screens.values()].at(-1);
    if (last) return last;
    return deps.claimed() ? null : defaultModel;
  };

  function sendNow() {
    timer = undefined;
    const model = effective();
    const json = JSON.stringify(model);
    if (json !== lastModel) {
      lastModel = json;
      deps.send({ v: 1, type: "navigator", model });
    }
    const active = fallbacks.size > 0;
    if (active !== (lastFallback ?? false)) {
      lastFallback = active;
      deps.send({ v: 1, type: "navigatorFallback", active });
    }
  }

  function schedule() {
    if (timer === undefined) timer = setTimeout(sendNow, deps.delayMs);
  }

  return {
    /** A screen's own model (NavigatorPortal's `native` prop); null withdraws it. */
    setScreen(token: symbol, model: NavModel | null) {
      if (model) {
        screens.delete(token); // the latest to publish wins
        screens.set(token, model);
      } else screens.delete(token);
      schedule();
    },
    /** A screen without a model, drawing its list in the fallback column. */
    setFallback(token: symbol, active: boolean) {
      if (active) fallbacks.add(token);
      else fallbacks.delete(token);
      schedule();
    },
    /** The model shown when no screen claims the navigator (Chats). */
    setDefault(model: NavModel | null) {
      defaultModel = model;
      schedule();
    },
    /** Claims changed. */
    refresh: schedule,
    flush() {
      if (timer !== undefined) clearTimeout(timer);
      sendNow();
    },
  };
}

/** The page's one publisher. */
export const publisher = createNavigatorPublisher({ send: postDeduped, claimed: navigatorClaimed, delayMs: 50 });
