"use client";

import { Dialog } from "radix-ui";
import { useState, type FormEvent } from "react";
import { useStartChatMusic } from "@/lib/api/audio-hooks";
import { ApiError } from "@/lib/api/client";
import { useMediaProviders } from "@/lib/api/media-hooks";
import { activeMusicProvider } from "@/lib/media-providers";
import { Button, ButtonLink } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, Field, TextArea, TextInput } from "@/components/ui/primitives";

export interface MusicDialogInitial {
  title?: string;
  prompt?: string;
  lyrics?: string;
  instrumental?: boolean;
  length?: "clip" | "full";
}

/** Modal that starts a music generation track inside a chat using the active workspace provider. */
export function GenerateMusicDialog({
  open,
  chatId,
  initial,
  onClose,
}: {
  open: boolean;
  chatId: string;
  initial?: MusicDialogInitial;
  onClose: () => void;
}) {
  return (
    <Dialog.Root
      open={open}
      onOpenChange={(next) => {
        if (!next) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-[12vh] z-50 max-h-[80vh] w-[min(500px,calc(100%-32px))] -translate-x-1/2 overflow-y-auto rounded-2xl border border-border-float bg-surface-raised p-5 shadow-[var(--shadow-float)] outline-none"
        >
          {open && <GenerateMusicForm chatId={chatId} initial={initial} onClose={onClose} />}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function GenerateMusicForm({
  chatId,
  initial,
  onClose,
}: {
  chatId: string;
  initial?: MusicDialogInitial;
  onClose: () => void;
}) {
  const providers = useMediaProviders();
  const startMusic = useStartChatMusic(chatId);
  const active = activeMusicProvider(providers.data);

  const [title, setTitle] = useState(initial?.title ?? "");
  const [prompt, setPrompt] = useState(initial?.prompt ?? "");
  const [instrumental, setInstrumental] = useState(initial?.instrumental ?? false);
  const [length, setLength] = useState<"clip" | "full">(initial?.length ?? "clip");
  const [lyrics, setLyrics] = useState(initial?.lyrics ?? "");

  const unconfigured = !!providers.data && !active;
  const canSubmit = !!active && prompt.trim().length > 0 && !startMusic.isPending;

  const errText =
    startMusic.error instanceof ApiError
      ? startMusic.error.message
      : startMusic.error instanceof Error
        ? startMusic.error.message
        : "Couldn’t start music generation. Try again.";

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!canSubmit || !active) return;
    startMusic.mutate(
      {
        prompt: prompt.trim(),
        ...(title.trim() ? { title: title.trim() } : {}),
        ...(instrumental ? { instrumental: true } : { instrumental: false, ...(lyrics.trim() ? { lyrics: lyrics.trim() } : {}) }),
        length,
        provider_id: active.id,
      },
      {
        onSuccess: () => onClose(),
      },
    );
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-3.5" data-testid="generate-music-dialog">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Icon name="audio" size={16} className="text-accent" />
          <Dialog.Title className="text-16 font-semibold text-fg">Generate music</Dialog.Title>
        </div>
        {active && (
          <span className="rounded-full border border-border bg-surface px-2.5 py-0.5 text-11 font-medium text-fg-secondary">
            {active.label}
          </span>
        )}
      </div>

      {unconfigured && (
        <Banner
          tone="human"
          title="No music provider configured"
          actions={
            <ButtonLink variant="secondary" href="/settings?section=workspace#media" onClick={onClose}>
              Media settings
            </ButtonLink>
          }
        >
          Add a Gemini API key or connect a media provider before generating music.
        </Banner>
      )}

      <Field label="Title (optional)" htmlFor="music-title">
        <TextInput
          id="music-title"
          value={title}
          placeholder="Auto-named from prompt if blank"
          maxLength={200}
          disabled={startMusic.isPending}
          onChange={(e) => setTitle(e.target.value)}
        />
      </Field>

      <Field label="Prompt" htmlFor="music-prompt" hint="Style, mood, tempo, and instruments (required)">
        <TextArea
          id="music-prompt"
          rows={3}
          autoFocus
          required
          value={prompt}
          maxLength={4000}
          disabled={startMusic.isPending}
          placeholder="Warm analog synthwave with tape delay, punchy drums at 105 bpm…"
          onChange={(e) => setPrompt(e.target.value)}
        />
      </Field>

      <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border-subtle bg-surface px-3 py-2.5">
        <Toggle
          checked={instrumental}
          disabled={startMusic.isPending}
          onChange={setInstrumental}
          label="Instrumental only"
        />
        <Segmented
          small
          label="Track length"
          value={length}
          onChange={setLength}
          options={[
            { value: "clip", label: "30s clip" },
            { value: "full", label: "Full track" },
          ]}
        />
      </div>

      <Field
        label="Lyrics (optional)"
        htmlFor="music-lyrics"
        hint={instrumental ? "Turn off Instrumental only to include vocals and lyrics." : undefined}
      >
        <TextArea
          id="music-lyrics"
          rows={3}
          value={instrumental ? "" : lyrics}
          maxLength={8000}
          disabled={startMusic.isPending || instrumental}
          placeholder={instrumental ? "Disabled in instrumental mode" : "Optional verses or chorus lines…"}
          onChange={(e) => setLyrics(e.target.value)}
          className={instrumental ? "opacity-50" : undefined}
        />
      </Field>

      {startMusic.isError && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {errText}
        </p>
      )}

      <div className="flex justify-end gap-2 pt-1">
        <Dialog.Close asChild>
          <Button variant="secondary" type="button" disabled={startMusic.isPending}>
            Cancel
          </Button>
        </Dialog.Close>
        <Button variant="primary" type="submit" disabled={!canSubmit}>
          {startMusic.isPending ? "Starting…" : "Generate track"}
        </Button>
      </div>
    </form>
  );
}
