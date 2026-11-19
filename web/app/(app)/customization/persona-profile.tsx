"use client";

import { useRouter } from "next/navigation";
import { Dialog } from "radix-ui";
import { useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useCreateChat } from "@/lib/api/hooks";
import { useDeletePersona, useSetDefaultPersona, type Persona } from "@/lib/api/persona-hooks";
import { deleteConsequence, isConflict, promotionCandidate, sortPersonas, toneLabel } from "@/lib/persona-ui";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { CAPABILITIES, PersonaAvatar, PersonaName, usePersonaFilter } from "../chat/_components/persona";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

export function DefaultBadge({ small }: { small?: boolean }) {
  return (
    <span className={cx("rounded-full bg-accent-soft px-2 text-accent", small ? "py-px text-10" : "py-0.5 text-11")}>Default</span>
  );
}

const link = "text-12 text-accent hover:underline disabled:opacity-50";

/**
 * Delete confirmation (mockup state 5b). Deleting the default asks who takes
 * over, preselecting the one the server would promote; the client sets that
 * default first so the choice holds.
 */
export function DeleteDialog({ persona, all, onClose }: { persona: Persona; all: Persona[]; onClose: () => void }) {
  const del = useDeletePersona();
  const others = sortPersonas(all.filter((p) => p.id !== persona.id));
  const [next, setNext] = useState(() => promotionCandidate(all, persona.id)?.id);
  const confirm = () =>
    del
      .mutateAsync({ id: persona.id, revision: persona.revision, nextDefault: persona.is_default ? next : undefined })
      .then(onClose, () => undefined);
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content className="motion-dialog fixed left-1/2 top-[18vh] z-50 flex w-[min(400px,calc(100%-32px))] -translate-x-1/2 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none">
          <Dialog.Title className="type-heading">Delete {persona.name}?</Dialog.Title>
          {persona.is_default ? (
            others.length ? (
              <fieldset className="flex flex-col gap-1">
                <legend className="mb-2 text-12 text-fg-secondary">{persona.name} is your default. Choose a new default:</legend>
                {others.map((p) => (
                  <label key={p.id} className={cx("flex cursor-pointer items-center gap-2.5 rounded-md px-2 py-1.5", next === p.id ? "bg-selected" : "hover:bg-hover")}>
                    <input type="radio" name="next-default" checked={next === p.id} onChange={() => setNext(p.id)} className="accent-[var(--accent)]" />
                    <PersonaAvatar persona={p} size={18} />
                    <PersonaName persona={p} className="text-13" />
                  </label>
                ))}
              </fieldset>
            ) : (
              <p className="text-12 text-fg-secondary">{persona.name} is your default. The built-in Assistant becomes your default.</p>
            )
          ) : (
            <p className="text-12 text-fg-secondary">This can’t be undone.</p>
          )}
          <Dialog.Description className="text-12 text-fg-secondary">{deleteConsequence(persona.chat_count)}</Dialog.Description>
          {del.isError && (
            <p role="alert" className="text-12 text-pill-blocked-fg">
              {isConflict(del.error) ? `${persona.name} changed somewhere else. Close this and try again on the latest version.` : errorText(del.error)}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Dialog.Close asChild>
              <Button variant="secondary">Cancel</Button>
            </Dialog.Close>
            <Button
              variant="outline"
              className="border-pill-blocked-fg/40 bg-pill-blocked-bg font-semibold text-pill-blocked-fg hover:bg-pill-blocked-bg"
              disabled={del.isPending}
              onClick={confirm}
            >
              Delete {persona.name}
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/** The profile picture or animated SVG character, ringed when using a photo/initials. */
function Portrait({ persona }: { persona: Persona }) {
  if (persona.character_svg) {
    return (
      <span className="flex flex-none items-center justify-center rounded-full p-1" style={{ background: `radial-gradient(circle, color-mix(in srgb, ${persona.color} 18%, transparent) 0%, transparent 72%)` }}>
        <PersonaAvatar persona={persona} size={76} state="idle" framed={false} />
      </span>
    );
  }
  return (
    <span className="flex flex-none rounded-full p-1" style={{ boxShadow: `inset 0 0 0 2px color-mix(in srgb, ${persona.color} 45%, transparent)` }}>
      <PersonaAvatar persona={persona} size={72} />
    </span>
  );
}

/** What the person has allowed this persona to do, spelled out. */
function Permissions({ capabilities }: { capabilities?: Schemas["PersonaCapabilities"] }) {
  const granted = CAPABILITIES.filter((c) => capabilities?.[c.key]);
  if (!granted.length) return <p className="text-12 text-fg-tertiary">No extra permissions</p>;
  return (
    <ul aria-label="Permissions" data-testid="persona-permissions" className="flex flex-wrap gap-1">
      {granted.map((c) => (
        <li key={c.key} title={c.title} className="inline-flex items-center gap-1 rounded-full bg-selected px-2 py-0.5 text-11 text-fg-secondary">
          <Icon name={c.icon} size={12} />
          {c.label}
        </li>
      ))}
    </ul>
  );
}

/** The top of a persona's page: who it is, what it may do, and what can be done to it. */
export function PersonaProfile({ p, memories, onEdit, onDelete }: { p: Persona; memories?: number; onEdit: () => void; onDelete: () => void }) {
  const setDefault = useSetDefaultPersona();
  const filter = usePersonaFilter();
  const router = useRouter();
  const create = useCreateChat();
  const stats = [`${toneLabel(p.tone)} tone`, ...(memories === undefined ? [] : [`${memories} ${memories === 1 ? "memory" : "memories"}`]), `${p.chat_count} ${p.chat_count === 1 ? "conversation" : "conversations"}`];
  function newChat() {
    create.mutate(
      { persona_id: p.id },
      {
        onSuccess: (c) => {
          // The history follows, so the new conversation is in the list it lands on.
          filter.set(p.is_default ? "default" : p.id);
          router.push(`/chat/${c.id}`);
        },
      },
    );
  }
  return (
    <header data-testid="persona-profile" className="flex flex-wrap items-start gap-4">
      <Portrait persona={p} />
      <div className="flex min-w-0 flex-1 basis-64 flex-col gap-1.5">
        <div className="flex items-center gap-2">
          <PersonaName persona={p} className="truncate type-display" />
          {p.is_default && <DefaultBadge />}
        </div>
        <p className="text-14 text-fg-secondary">{stats.join(" · ")}</p>
        <Permissions capabilities={p.capabilities} />
      </div>
      {/* Actions get their own row so a long name or stats line never crowds them. */}
      <div className="flex basis-full flex-wrap items-center gap-2">
        <Button variant="secondary" onClick={onEdit} aria-label={`Edit ${p.name}`}>Edit</Button>
        <Button variant="outline" disabled={create.isPending} onClick={newChat}>New chat</Button>
        {!p.is_default && (
          <button type="button" className={cx(link, "ml-2")} disabled={setDefault.isPending} onClick={() => setDefault.mutate(p.id)}>
            Set as default
          </button>
        )}
        <button type="button" className={cx("text-12 text-pill-blocked-fg hover:underline", p.is_default && "ml-2")} onClick={onDelete} aria-label={`Delete ${p.name}`}>
          Delete
        </button>
      </div>
      {setDefault.isError && <p role="alert" className="basis-full text-12 text-pill-blocked-fg">{errorText(setDefault.error)}</p>}
      {create.isError && <p role="alert" className="basis-full text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
    </header>
  );
}
