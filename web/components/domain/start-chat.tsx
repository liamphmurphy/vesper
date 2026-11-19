"use client";

import { useRouter } from "next/navigation";
import { useCreateChat } from "@/lib/api/hooks";
import { attachQuery, type ContextRef } from "@/lib/chat-context";
import { toast } from "@/lib/toast";
import { Button } from "@/components/ui/button";
import { NoHarnessNote, useHarnessHealth } from "@/components/domain/setup";

/**
 * Opens a new chat with the item attached as a chip and its project, if it has
 * one, attached to the chat.
 */
export function useStartChat({ attach, title, project }: { attach: ContextRef; title: string; project?: string }) {
  const router = useRouter();
  const create = useCreateChat();
  const health = useHarnessHealth();
  const noHarness = !!health && !health.ready;
  return {
    health,
    noHarness,
    create,
    disabled: noHarness || create.isPending,
    start: () =>
      create.mutate(
        project ? { project } : {},
        {
          onSuccess: (c) => router.push(`/chat/${c.id}?${attachQuery(project, attach, title)}`),
          onError: (e) => { toast({ title: e instanceof Error ? e.message : "Couldn’t start the chat.", tone: "error" }); },
        },
      ),
  };
}

export function StartChatButton(props: { attach: ContextRef; title: string; project?: string }) {
  const { health, noHarness, create, disabled, start } = useStartChat(props);
  return (
    <>
      <Button variant="outline" icon="msg" disabled={disabled} onClick={start}>
        Start chat
      </Button>
      {noHarness && health && <NoHarnessNote health={health} />}
      {create.isError && (
        <span role="alert" className="text-12 text-pill-blocked-fg">
          {create.error instanceof Error ? create.error.message : "Couldn’t start the chat."}
        </span>
      )}
    </>
  );
}
