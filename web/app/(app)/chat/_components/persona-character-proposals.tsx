"use client";

import { useMemo, useState } from "react";
import { ApiError, type Schemas } from "@/lib/api/client";
import { useDecidePersonaCharacterProposal, usePersonaCharacterProposals } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { CHARACTER_PREVIEW_STATES, detectCharacterStates, type CharacterState } from "@/lib/persona-character";
import { PersonaCharacterView, rasterizeCharacterPngBase64 } from "@/components/domain/persona-character";
import { Button } from "@/components/ui/button";
import { PersonaAvatar, PersonaName, personaLook } from "./persona";

type CharacterProposal = Schemas["PersonaCharacterProposal"];
type Backdrop = "theme" | "dark" | "light";

const BACKDROP: Record<Backdrop, string> = {
  theme: "bg-bg border-border",
  dark: "bg-[#15141f] border-[#2e2b42]",
  light: "bg-[#f8f7fc] border-[#dcd8ea]",
};

/**
 * Animated SVG character drafts proposed in this chat, waiting for approval.
 * Iterative calls for the same persona supersede earlier pending drafts so
 * only the latest revision per target stays active here.
 */
export function PersonaCharacterProposals({ chatId, disabled }: { chatId: string; disabled?: boolean }) {
  const proposals = usePersonaCharacterProposals(chatId);
  const decide = useDecidePersonaCharacterProposal(chatId);
  const [approvingId, setApprovingId] = useState<string>();
  const pending = (proposals.data?.proposals ?? []).filter((p) => p.state === "pending");
  if (!pending.length) return null;
  const error = decide.error instanceof ApiError || decide.error instanceof Error ? decide.error.message : null;
  return (
    <li className="flex flex-col gap-2" data-testid="persona-character-proposals">
      {pending.map((p) => (
        <CharacterProposalCard
          key={p.id}
          p={p}
          busy={decide.isPending || approvingId === p.id || !!disabled}
          onDecide={async (decision) => {
            if (decision === "decline") {
              decide.mutate({ id: p.id, decision });
              return;
            }
            setApprovingId(p.id);
            try {
              const fallback_png_base64 = await rasterizeCharacterPngBase64(p.character_svg, p.target_persona.color);
              decide.mutate({ id: p.id, decision, fallback_png_base64 });
            } finally {
              setApprovingId(undefined);
            }
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

function CharacterProposalCard({
  p,
  busy,
  onDecide,
}: {
  p: CharacterProposal;
  busy: boolean;
  onDecide: (d: "approve" | "decline") => void;
}) {
  const [state, setState] = useState<CharacterState>("idle");
  const [backdrop, setBackdrop] = useState<Backdrop>("theme");
  const customStates = useMemo(() => detectCharacterStates(p.character_svg), [p.character_svg]);
  const by = personaLook(p.proposed_by);
  const target = personaLook(p.target_persona);

  return (
    <div
      className="flex max-w-[min(720px,100%)] flex-col gap-3 rounded-xl border border-border bg-surface px-3.5 py-3"
      data-testid="persona-character-proposal"
    >
      <div className="flex flex-wrap items-center justify-between gap-2 text-12 text-fg-tertiary">
        <p className="flex flex-wrap items-center gap-1.5">
          <PersonaAvatar persona={by} size={16} />
          <PersonaName persona={by} />
          <span>designed an animated character for</span>
          <PersonaName persona={target} />
        </p>
        <div role="group" aria-label="Preview backdrop" className="inline-flex items-center gap-0.5 rounded-md border border-border bg-surface-sunken p-0.5">
          {(["theme", "dark", "light"] as const).map((b) => (
            <button
              key={b}
              type="button"
              aria-pressed={backdrop === b}
              onClick={() => setBackdrop(b)}
              className={cx(
                "rounded px-1.5 py-0.5 text-11 capitalize transition-colors",
                backdrop === b ? "bg-surface text-fg shadow-xs" : "text-fg-tertiary hover:text-fg-secondary",
              )}
            >
              {b}
            </button>
          ))}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-4">
        <div className={cx("flex items-center gap-4 rounded-xl border px-4 py-3", BACKDROP[backdrop])}>
          <PersonaCharacterView svg={p.character_svg} color={target.color} size={92} state={state} framed={false} />
          <div className="flex flex-col items-center gap-2">
            <PersonaCharacterView svg={p.character_svg} color={target.color} size={44} state={state} framed={false} />
            <PersonaCharacterView svg={p.character_svg} color={target.color} size={22} state={state} framed clipped />
          </div>
        </div>

        <div className="flex min-w-0 flex-1 flex-col gap-2">
          <div role="group" aria-label="Preview action state" className="flex flex-wrap gap-1.5">
            {CHARACTER_PREVIEW_STATES.map((s) => {
              const active = state === s.value;
              const customized = customStates.has(s.value);
              return (
                <button
                  key={s.value}
                  type="button"
                  aria-pressed={active}
                  onClick={() => setState(s.value)}
                  className={cx(
                    "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-11 transition-colors",
                    active ? "border-accent bg-accent-soft font-medium text-accent" : "border-border bg-surface-sunken text-fg-secondary hover:bg-hover hover:text-fg",
                  )}
                >
                  {customized && <span aria-hidden className={cx("size-1.5 rounded-full", active ? "bg-accent" : "bg-fg-tertiary")} />}
                  {s.label}
                </button>
              );
            })}
          </div>
          {p.summary && <p className="text-13 text-fg-secondary">{p.summary}</p>}
          <p className="text-12 text-fg-tertiary">
            Ask in chat to tweak its silhouette, colors, or action animations before applying.
          </p>
        </div>
      </div>

      <div className="flex justify-end gap-2">
        <Button variant="outline" disabled={busy} onClick={() => onDecide("decline")}>
          Decline
        </Button>
        <Button variant="primary" disabled={busy} onClick={() => onDecide("approve")}>
          Use for {target.name}
        </Button>
      </div>
    </div>
  );
}
