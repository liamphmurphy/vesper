"use client";

import { useState } from "react";
import { ApiError } from "@/lib/api/client";
import { useChatToolApprovals, useDecideApproval } from "@/lib/api/hooks";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { TextArea } from "@/components/ui/primitives";

const message = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : null);

/**
 * In-turn tool calls waiting for a yes/no from the person inside this chat.
 * Rendered inside the live status card alongside connector and API secret approvals.
 */
export function ChatToolApprovalCards({ chatId, disabled }: { chatId: string; disabled?: boolean }) {
  const approvals = useChatToolApprovals(chatId, true);
  const decide = useDecideApproval("");
  const [notes, setNotes] = useState<Record<string, string>>({});
  const waiting = (approvals.data?.approvals ?? []).filter((a) => a.state === "pending");
  if (!waiting.length) return null;
  const busy = decide.isPending || !!disabled;
  const error = message(decide.error);

  return (
    <>
      {waiting.map((ap) => {
        const note = notes[ap.id] ?? "";
        return (
          <div key={ap.id} data-testid="chat-tool-approval" className="flex flex-col gap-2.5 rounded-lg border border-pill-human-fg/35 bg-pill-human-bg px-3 py-2.5">
            <div className="flex flex-wrap items-center gap-1.5 text-13 text-fg">
              <span className="inline-flex items-center gap-1 rounded-full bg-surface-sunken px-2 py-0.5 font-mono text-11 text-fg-secondary">
                <Icon name="terminal" size={12} />
                {ap.scope}
              </span>
              <span className="font-medium text-fg">{ap.action_summary}</span>
            </div>
            {ap.action_preview && (
              <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md border border-border-subtle bg-surface-sunken px-2.5 py-2 font-mono text-12 text-fg-2">
                {ap.action_preview}
              </pre>
            )}
            {ap.risk_summary && <p className="text-12 text-fg-secondary">{ap.risk_summary}</p>}
            <TextArea
              aria-label={`Optional note for ${ap.action_summary}`}
              rows={1}
              value={note}
              onChange={(e) => setNotes((prev) => ({ ...prev, [ap.id]: e.target.value }))}
              placeholder="Optional note (shown if denied or approved)…"
              disabled={busy}
              className="min-h-[34px] resize-none bg-surface px-2.5 py-1.5 text-13"
            />
            <div className="flex flex-wrap gap-2">
              <Button
                variant="approve"
                disabled={busy}
                onClick={() => decide.mutate({ id: ap.id, decision: "approve", note: note.trim() || undefined })}
              >
                Approve
              </Button>
              <Button
                variant="approve-outline"
                disabled={busy}
                onClick={() => decide.mutate({ id: ap.id, decision: "deny", note: note.trim() || undefined })}
              >
                Deny
              </Button>
            </div>
            <p className="text-12 text-fg-tertiary">The tool resumes right inside this turn once you approve.</p>
          </div>
        );
      })}
      {error && <p role="alert" className="text-13 text-pill-blocked-fg">{error}</p>}
    </>
  );
}
