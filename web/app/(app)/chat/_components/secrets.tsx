"use client";

import Link from "next/link";
import { useApiSecretApprovals, useChatApiSecrets, useDisableChatApiSecret } from "@/lib/api/secret-hooks";
import { ago } from "@/lib/format";
import { Icon } from "@/components/ui/icon";

/**
 * The secrets used in this chat and any request waiting for the person. The title menu shows a
 * Secrets row (and the title a key icon, amber while a request waits) once there is either.
 */
export function useChatSecrets(chatId: string) {
  const used = useChatApiSecrets(chatId);
  const waiting = useApiSecretApprovals(chatId);
  const rows = used.data?.secrets ?? [];
  const pending = waiting.data?.approvals ?? [];
  const live = pending.length > 0;
  const label = live ? `${pending[0]?.secret_handle} waiting` : rows.length === 1 ? `${rows[0].handle} used ${rows[0].calls}×` : `${rows.length} secrets used`;
  return { rows, pending, live, label, any: rows.length > 0 || live };
}

/** Each secret's use in this chat, with a way to turn one off for the chat. */
export function SecretsList({ chatId, secrets }: { chatId: string; secrets: ReturnType<typeof useChatSecrets> }) {
  const disable = useDisableChatApiSecret(chatId);
  const { rows, live } = secrets;
  return (
    <div data-testid="secrets-list" aria-label="Secrets in this chat" className="flex flex-col p-1.5">
      <p className="mb-2 text-13 font-medium text-fg">Secrets in this chat</p>
      {live && <p className="mb-2 text-12 text-pill-human-fg">A request is waiting for you in the chat.</p>}
      <ul className="flex flex-col gap-2">
        {rows.map((s) => (
          <li key={s.id} className="flex flex-col gap-0.5 border-t border-border-subtle pt-2 first:border-t-0 first:pt-0">
            <span className="flex items-center gap-1.5 text-13 text-fg"><Icon name="key" size={13} className="text-pill-human-fg" />{s.name}</span>
            <span className="text-12 text-fg-secondary">{s.calls} {s.calls === 1 ? "request" : "requests"} · {ago(s.last_used_at)} · {s.methods.join(", ")}{!s.enabled && " · off here"}</span>
            <span className="mt-1 flex gap-3 text-12">
              <Link href={`/settings?section=secrets&tab=api&secret=${s.id}`} className="text-accent hover:underline">View activity</Link>
              {s.enabled && (
                <button type="button" className="text-pill-blocked-fg hover:underline disabled:opacity-50" disabled={disable.isPending} onClick={() => disable.mutate(s.id)}>
                  Turn off for this chat
                </button>
              )}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
