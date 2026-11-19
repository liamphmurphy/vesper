"use client";

import { useState } from "react";
import { ApiError, chatAttachmentUrl, type Schemas } from "@/lib/api/client";
import { useDecidePersonaProposal, usePersonaProposals } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { CHARACTER_PREVIEW_STATES, type CharacterState } from "@/lib/persona-character";
import { PersonaCharacterView, rasterizeCharacterPngBase64 } from "@/components/domain/persona-character";
import { Button } from "@/components/ui/button";
import { PersonaAvatar, PersonaName, personaLook, toneLabel } from "./persona";

type Proposal = Schemas["PersonaProposal"];

/**
 * Personas a persona proposed in this chat, waiting for the person: nothing is
 * created until they approve. Decided ones show as system messages instead.
 */
export function PersonaProposals({ chatId, disabled }: { chatId: string; disabled?: boolean }) {
  const proposals = usePersonaProposals(chatId);
  const decide = useDecidePersonaProposal(chatId);
  const [approvingId, setApprovingId] = useState<string>();
  const pending = (proposals.data?.proposals ?? []).filter((p) => p.state === "pending");
  if (!pending.length) return null;
  const error = decide.error instanceof ApiError || decide.error instanceof Error ? decide.error.message : null;
  return (
    <li className="flex flex-col gap-2" data-testid="persona-proposals">
      {pending.map((p) => (
        <ProposalCard
          key={p.id}
          p={p}
          busy={decide.isPending || approvingId === p.id || !!disabled}
          onDecide={async (decision) => {
            if (decision === "approve" && p.character_svg) {
              setApprovingId(p.id);
              try {
                const fallback_png_base64 = await rasterizeCharacterPngBase64(p.character_svg, p.color);
                decide.mutate({ id: p.id, decision, fallback_png_base64 });
              } finally {
                setApprovingId(undefined);
              }
              return;
            }
            decide.mutate({ id: p.id, decision });
          }}
        />
      ))}
      {error && (
        <p role="alert" className="text-13 text-pill-blocked-fg">
          {error}
        </p>
      )}
    </li>
  );
}

/** What the card says about the picture the proposing persona asked for. */
const AVATAR_NOTE: Record<NonNullable<Proposal["avatar_state"]>, string | null> = {
  pending: "Making its picture… You can approve once it's ready.",
  ready: "Approving makes this picture its avatar and its reference image.",
  failed: "Its picture couldn't be made; approving creates it without one.",
};

function ProposalCard({ p, busy, onDecide }: { p: Proposal; busy: boolean; onDecide: (d: "approve" | "decline") => void }) {
  const [previewState, setPreviewState] = useState<CharacterState>("idle");
  const picture = p.avatar_state === "ready" && p.avatar_attachment_id ? chatAttachmentUrl(p.avatar_attachment_id) : undefined;
  const look = personaLook({ id: p.id, name: p.name, color: p.color, avatar_url: picture });
  const by = personaLook(p.proposed_by);
  const pictureNote = p.avatar_state ? AVATAR_NOTE[p.avatar_state] : null;
  return (
    <div className="flex max-w-[min(720px,100%)] flex-col gap-2 rounded-xl border border-border bg-surface px-3.5 py-3" data-testid="persona-proposal">
      <p className="flex flex-wrap items-center gap-1.5 text-12 text-fg-tertiary">
        <PersonaAvatar persona={by} size={16} />
        <PersonaName persona={by} />
        <span>wants to create a new persona</span>
      </p>
      <div className="flex items-start gap-3">
        {p.character_svg ? (
          <PersonaCharacterView svg={p.character_svg} color={p.color} size={64} state={previewState} framed={false} />
        ) : (
          <PersonaAvatar persona={look} size={picture ? 56 : 36} className={p.avatar_state === "pending" ? "animate-pulse" : undefined} />
        )}
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <span className="flex items-center gap-2">
            <PersonaName persona={look} className="text-14" />
            <span className="rounded-full bg-selected px-2 py-0.5 text-12 text-fg-secondary">{toneLabel(p.tone)}</span>
          </span>
          {p.reason && <p className="text-13 text-fg-secondary">{p.reason}</p>}
          {p.custom_instructions && <p className="whitespace-pre-wrap text-13 text-fg-tertiary">{p.custom_instructions}</p>}
          {p.character_svg && (
            <div role="group" aria-label="Preview action state" className="flex flex-wrap gap-1 pt-0.5">
              {CHARACTER_PREVIEW_STATES.map((s) => (
                <button
                  key={s.value}
                  type="button"
                  aria-pressed={previewState === s.value}
                  onClick={() => setPreviewState(s.value)}
                  className={cx(
                    "rounded-full border px-2 py-0.5 text-11 transition-colors",
                    previewState === s.value ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface-sunken text-fg-secondary hover:bg-hover",
                  )}
                >
                  {s.label}
                </button>
              ))}
            </div>
          )}
          {pictureNote && <p className="text-12 text-fg-tertiary" data-testid="proposal-avatar-note">{pictureNote}</p>}
          <p className="text-12 text-fg-tertiary">Starts with no abilities (code, images, creating personas). You can change it later in Manage personas.</p>
        </div>
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" disabled={busy} onClick={() => onDecide("decline")}>
          Decline
        </Button>
        <Button variant="primary" disabled={busy || p.avatar_state === "pending"} onClick={() => onDecide("approve")}>
          Approve {p.name}
        </Button>
      </div>
    </div>
  );
}
