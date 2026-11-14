"use client";

import { useRouter } from "next/navigation";
import { useCallback } from "react";
import { useCreateDeck, type StarterKey } from "@/lib/api/slides-hooks";
import { toast } from "@/lib/toast";

/**
 * Makes a deck and opens it (as its page in Knowledge, LAZYAGENTS-212): from Knowledge's New page
 * and a chat's "Create with" menu, now that Slides has no index of its own to start one from.
 */
export function useNewDeck() {
  const router = useRouter();
  const create = useCreateDeck();
  const { mutate, isPending } = create;
  // Stable, as the chat's command handlers that call it are effect dependencies.
  const start = useCallback(
    (starter?: StarterKey) =>
      mutate(
        { title: "Untitled deck", starter },
        {
          onSuccess: (d) => router.push(`/apps/slides/${d.id}`),
          onError: (e) => toast({ id: "new-deck", tone: "error", title: "Couldn’t make the deck", description: e.message }),
        },
      ),
    [mutate, router],
  );
  return { start, pending: isPending };
}
