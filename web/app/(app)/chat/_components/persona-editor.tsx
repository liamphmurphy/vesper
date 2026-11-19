"use client";

import { ColorWheel } from "@/components/ui/color-wheel";
import { useRouter } from "next/navigation";
import { Dialog } from "radix-ui";
import { useEffect, useMemo, useReducer, useRef, useState, type FormEvent } from "react";
import { useCreateChat } from "@/lib/api/hooks";
import {
  useCreatePersona,
  useDeletePersonaAvatar,
  usePersonas,
  useSetDefaultPersona,
  useUpdatePersona,
  useUploadPersonaAvatar,
  type Persona,
  type PersonaPatch,
  type PersonaTone,
} from "@/lib/api/persona-hooks";
import { CHARACTER_PREVIEW_STATES, detectCharacterStates, type CharacterState } from "@/lib/persona-character";
import {
  AVATAR_ACCEPT,
  AVATAR_HINT,
  CHAT_BG,
  INSTRUCTIONS_MAX,
  NAME_MAX,
  PRESET_COLORS,
  TONES,
  avatarUploadError,
  checkAvatarFile,
  colorPicker,
  contrastWarning,
  fieldError,
  hslToHex,
  isConflict,
  cssHex,
  parseHex,
  sameList,
  unusedPreset,
  type AvatarError,
  type ColorAction,
  type ColorPicker as ColorState,
} from "@/lib/persona-ui";
import { cx } from "@/lib/cx";
import { PersonaAvatar } from "@/components/domain/persona-avatar";
import { Button, IconButton } from "@/components/ui/button";
import { TextArea, TextInput } from "@/components/ui/primitives";

const label = "text-11 font-medium uppercase tracking-wide text-fg-tertiary";
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** The chat background the name is read on: the theme's --bg, or the dark ground. */
function useChatBackground() {
  const [bg, setBg] = useState(CHAT_BG);
  useEffect(() => {
    const read = () => setBg(cssHex(getComputedStyle(document.documentElement).getPropertyValue("--bg")) ?? CHAT_BG);
    read();
    const mo = new MutationObserver(read);
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "data-theme", "style"] });
    return () => mo.disconnect();
  }, []);
  return bg;
}

// ---- color ----


function CustomColor({ state, dispatch }: { state: NonNullable<ColorState["custom"]>; dispatch: (a: ColorAction) => void }) {
  const mid = hslToHex(state.h, state.s, 0.5);
  const live = parseHex(state.hex);
  return (
    <div className="flex gap-4 rounded-lg border border-border bg-surface-raised p-3" role="group" aria-label="Custom color">
      <ColorWheel h={state.h} s={state.s} onPick={(h, s) => dispatch({ type: "wheel", h, s })} />
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <label htmlFor="persona-lightness" className={label}>Lightness</label>
        <input
          id="persona-lightness"
          type="range"
          min={0}
          max={100}
          value={Math.round(state.l * 100)}
          onChange={(e) => dispatch({ type: "lightness", l: Number(e.target.value) / 100 })}
          className="h-2 w-full cursor-pointer appearance-none rounded-full"
          style={{ background: `linear-gradient(to right, #000, ${mid}, #fff)` }}
        />
        <label htmlFor="persona-hex" className={cx(label, "mt-1")}>Hex</label>
        <div className="flex items-center gap-2">
          <span className="relative w-28">
            <span aria-hidden className="absolute left-2 top-1/2 size-3.5 -translate-y-1/2 rounded-[3px] border border-border-strong" style={{ background: live ?? "transparent" }} />
            <TextInput
              id="persona-hex"
              mono
              value={state.hex}
              maxLength={7}
              spellCheck={false}
              aria-invalid={!!state.error}
              aria-describedby={state.error ? "persona-hex-error" : undefined}
              onChange={(e) => dispatch({ type: "hex", text: e.target.value })}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  dispatch({ type: "apply" });
                }
              }}
              className="pl-7"
            />
          </span>
          <Button variant="primary" disabled={!live} onClick={() => dispatch({ type: "apply" })}>
            Apply
          </Button>
          <Button variant="outline" onClick={() => dispatch({ type: "cancel" })}>
            Cancel
          </Button>
        </div>
        {state.error ? (
          <p id="persona-hex-error" role="alert" className="text-12 text-pill-blocked-fg">{state.error}</p>
        ) : (
          <p className="text-12 text-fg-tertiary">Pick on the wheel or type a hex value.</p>
        )}
      </div>
    </div>
  );
}

function ColorRow({ state, dispatch, bg }: { state: ColorState; dispatch: (a: ColorAction) => void; bg: string }) {
  const custom = !PRESET_COLORS.includes(state.color);
  const warn = contrastWarning(state.color, bg);
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-baseline justify-between">
        <span id="persona-color-label" className={label}>Color</span>
        <span className="text-11 text-fg-tertiary">Used for the name and the initials avatar</span>
      </div>
      <div role="radiogroup" aria-labelledby="persona-color-label" className="flex flex-wrap items-center gap-2">
        {PRESET_COLORS.map((c) => (
          <button
            key={c}
            type="button"
            role="radio"
            aria-checked={state.color === c}
            aria-label={c}
            title={c}
            onClick={() => dispatch({ type: "preset", color: c })}
            className={cx(
              "size-[22px] rounded-full outline-none ring-offset-2 ring-offset-surface-raised focus-visible:ring-2 focus-visible:ring-accent",
              state.color === c && "ring-2 ring-fg",
            )}
            style={{ background: c }}
          />
        ))}
        <button
          type="button"
          role="radio"
          aria-checked={custom}
          onClick={() => dispatch(state.custom ? { type: "cancel" } : { type: "open" })}
          className="ml-1 inline-flex items-center gap-2 rounded-full pr-2 text-12 text-fg outline-none hover:bg-hover focus-visible:ring-2 focus-visible:ring-accent"
        >
          <span
            aria-hidden
            className={cx("size-[22px] rounded-full", (custom || state.custom) && "ring-2 ring-fg ring-offset-2 ring-offset-surface-raised")}
            style={{ background: custom ? state.color : "conic-gradient(#f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)" }}
          />
          {custom ? `Custom · ${state.color}` : "Custom…"}
        </button>
      </div>
      {state.custom && <CustomColor state={state.custom} dispatch={dispatch} />}
      {warn && (
        <div role="status" className="flex items-start gap-2 rounded-lg border border-pill-human-fg/40 bg-pill-human-bg px-3 py-2">
          <span aria-hidden className="text-pill-human-fg">⚠</span>
          <div className="flex min-w-0 flex-1 flex-col">
            <span className="text-12 text-pill-human-fg">
              Low contrast: {warn.ratio} on this theme (aim for 4.5:1).
            </span>
            <span className="text-12 text-fg-secondary">Names in this color will be hard to read.</span>
          </div>
          <button type="button" className="self-end text-12 text-accent hover:underline" onClick={() => dispatch({ type: "preset", color: warn.suggestion })}>
            Use {warn.suggestion}
          </button>
        </div>
      )}
    </div>
  );
}

// ---- avatar ----

type AvatarChoice = { kind: "keep" } | { kind: "file"; file: File; url: string } | { kind: "remove" };

function AvatarField({
  name,
  color,
  current,
  currentCharacter,
  choice,
  setChoice,
  errors,
  setErrors,
  onDesignInChat,
  designing,
}: {
  name: string;
  color: string;
  current?: string;
  currentCharacter?: string;
  choice: AvatarChoice;
  setChoice: (c: AvatarChoice) => void;
  errors: AvatarError[];
  setErrors: (e: AvatarError[]) => void;
  onDesignInChat?: () => void;
  designing?: boolean;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const [previewState, setPreviewState] = useState<CharacterState>("idle");
  const src = choice.kind === "file" ? choice.url : choice.kind === "remove" ? undefined : current;
  const characterSvg = choice.kind === "keep" ? currentCharacter : undefined;
  const customStates = useMemo(() => (characterSvg ? detectCharacterStates(characterSvg) : new Set<CharacterState>()), [characterSvg]);
  const hasVisual = !!(src || characterSvg);
  function take(files: FileList | null) {
    const f = files?.[0];
    if (!f) return;
    const bad = checkAvatarFile(f);
    if (bad) {
      setErrors([bad]);
      return;
    }
    setErrors([]);
    setChoice({ kind: "file", file: f, url: URL.createObjectURL(f) });
  }
  return (
    <div
      className="flex flex-col gap-2"
      onDragOver={(e) => {
        if (!e.dataTransfer.types.includes("Files")) return;
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={(e) => {
        e.preventDefault();
        setDragging(false);
        take(e.dataTransfer.files);
      }}
    >
      <span className={label}>{characterSvg ? "Animated character" : "Avatar"}</span>
      <div className="flex items-center gap-4">
        <PersonaAvatar name={name || "?"} color={color} src={src} characterSvg={characterSvg} state={previewState} framed={!characterSvg} size={96} />
        <div className="flex flex-col items-center gap-2">
          <PersonaAvatar name={name || "?"} color={color} src={src} characterSvg={characterSvg} state={previewState} framed={!characterSvg} size={48} />
          <PersonaAvatar name={name || "?"} color={color} src={src} characterSvg={characterSvg} state={previewState} framed clipped size={24} />
          <span className="text-11 text-fg-tertiary">Result</span>
        </div>
      </div>
      {characterSvg && (
        <div role="group" aria-label="Preview action state" className="flex flex-wrap gap-1 pt-1">
          {CHARACTER_PREVIEW_STATES.map((s) => {
            const active = previewState === s.value;
            return (
              <button
                key={s.value}
                type="button"
                aria-pressed={active}
                onClick={() => setPreviewState(s.value)}
                className={cx(
                  "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-11 transition-colors",
                  active ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface-sunken text-fg-secondary hover:bg-hover",
                )}
              >
                {customStates.has(s.value) && <span aria-hidden className={cx("size-1.5 rounded-full", active ? "bg-accent" : "bg-fg-tertiary")} />}
                {s.label}
              </button>
            );
          })}
        </div>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <input ref={input} type="file" accept={AVATAR_ACCEPT} hidden aria-label="Avatar image" onChange={(e) => { take(e.target.files); e.target.value = ""; }} />
        <Button variant="secondary" icon="upload" onClick={() => input.current?.click()}>
          Upload image
        </Button>
        {onDesignInChat && (
          <Button variant="secondary" disabled={designing} onClick={onDesignInChat}>
            {characterSvg ? "Tweak in chat" : "Design character in chat"}
          </Button>
        )}
        <Button variant="secondary" disabled={!hasVisual} onClick={() => { setErrors([]); setChoice(current || currentCharacter ? { kind: "remove" } : { kind: "keep" }); }}>
          Use initials
        </Button>
      </div>
      {characterSvg ? (
        <p className="text-12 text-fg-tertiary">Animated SVG character; talk to this persona in chat to redesign its look or action animations.</p>
      ) : (
        <>
          <p className="text-12 text-fg-tertiary">{AVATAR_HINT}</p>
          <p className="text-12 text-fg-tertiary">No image: initials on the persona color.</p>
        </>
      )}
      <div aria-live="polite" className="flex flex-col gap-2">
        {errors.map((e, i) => (
          <div key={i} role="alert" className="flex items-start gap-2 rounded-lg bg-pill-blocked-bg px-3 py-2">
            <div className="flex min-w-0 flex-1 flex-col">
              <span className="text-12 text-pill-blocked-fg">{e.title}</span>
              <span className="text-12 text-fg-secondary">{e.hint}</span>
            </div>
            <button type="button" aria-label="Dismiss" className="text-12 text-pill-blocked-fg" onClick={() => setErrors(errors.filter((_, j) => j !== i))}>
              ✕
            </button>
          </div>
        ))}
      </div>
      {dragging && (
        <div className="rounded-lg border border-dashed border-accent bg-accent-soft px-3 py-4 text-center">
          <p className="text-13 text-fg">Drop an image to upload</p>
          <p className="text-11 text-fg-tertiary">Your current avatar is kept until a new one uploads.</p>
        </div>
      )}
    </div>
  );
}

// ---- preview ----

function Preview({ name, color, src, characterSvg, tone }: { name: string; color: string; src?: string; characterSvg?: string; tone: PersonaTone }) {
  const t = TONES.find((x) => x.value === tone) ?? TONES[0];
  const shown = name.trim() || "New persona";
  return (
    <div className="flex flex-col gap-2">
      <span className={label}>Preview</span>
      <div className="flex flex-col gap-3 rounded-lg border border-border bg-bg p-3" aria-label="Message preview">
        <div className="flex gap-2.5">
          <PersonaAvatar name={shown} color={color} src={src} characterSvg={characterSvg} size={28} />
          <div className="flex min-w-0 flex-col gap-1">
            <p className="text-13">
              <span className="font-semibold" style={{ color }}>{shown}</span>
              <span className="ml-2 text-11 text-fg-tertiary">{t.label} · now</span>
            </p>
            {t.sample.map((line) => (
              <p key={line} className="text-13 text-fg">{line}</p>
            ))}
          </div>
        </div>
        <div className="flex flex-col gap-1.5 border-t border-border pt-2">
          <span className="text-11 uppercase tracking-wide text-fg-tertiary">In the sidebar</span>
          <div className="flex items-center gap-2">
            <PersonaAvatar name={shown} color={color} src={src} characterSvg={characterSvg} size={20} />
            <span className="flex-1 truncate text-12 text-fg">Weekly recap</span>
            <span className="text-11 text-fg-tertiary">Today</span>
          </div>
        </div>
      </div>
      <p className="text-12 text-fg-tertiary">Updates as you edit.</p>
    </div>
  );
}

// ---- abilities ----

function Toggle({ id, checked, onChange, title, hint }: { id: string; checked: boolean; onChange: (v: boolean) => void; title: string; hint: string }) {
  return (
    <div className="flex items-start gap-2.5">
      <input
        id={id}
        type="checkbox"
        role="switch"
        checked={checked}
        aria-describedby={`${id}-hint`}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 size-4 flex-none accent-[var(--accent)]"
      />
      <div className="flex flex-col gap-0.5">
        <label htmlFor={id} className="text-13 text-fg">{title}</label>
        <p id={`${id}-hint`} className="text-12 text-fg-tertiary">{hint}</p>
      </div>
    </div>
  );
}

// ---- editor ----

type Draft = { name: string; tone: PersonaTone; instructions: string; makeDefault: boolean; code: boolean; images: boolean; imageEngine: string; personas: boolean; svg: boolean; workflows: boolean; connectors: boolean; ticketsUnasked: boolean; repos: string[] };

const draftOf = (p?: Persona): Draft => ({
  name: p?.name ?? "",
  tone: p?.tone ?? "neutral",
  instructions: p?.custom_instructions ?? "",
  makeDefault: p?.is_default ?? false,
  code: p?.capabilities.code ?? false,
  images: p?.capabilities.images ?? false,
  imageEngine: p?.capabilities.image_engine ?? "",
  personas: p?.capabilities.personas ?? false,
  svg: p?.capabilities.svg ?? false,
  workflows: p?.capabilities.workflows ?? false,
  connectors: p?.capabilities.connectors ?? false,
  ticketsUnasked: p?.capabilities.ticket_edits === "allow",
  repos: p?.repos ?? [],
});

/**
 * The persona editor (mockup frame 3): name, tone, color (presets, wheel, hex),
 * avatar with preview, custom instructions and a live message preview. Edits are
 * revision-checked; a 409 offers a reload. The avatar is uploaded after the
 * fields save, and the server's 413/415 come back inline under the avatar.
 */
export function PersonaEditor({ persona, onClose }: { persona: Persona | "new"; onClose: () => void }) {
  const list = usePersonas();
  const all = useMemo(() => list.data?.personas ?? [], [list.data]);
  const [saved, setSaved] = useState<Persona | undefined>(persona === "new" ? undefined : persona);
  const latest = saved && all.find((p) => p.id === saved.id);
  const [draft, setDraft] = useState<Draft>(() => draftOf(saved));
  const [color, dispatch] = useReducer(colorPicker, undefined, (): ColorState => ({
    color: saved?.color ?? unusedPreset(all),
    custom: null,
  }));
  const [avatar, setAvatar] = useState<AvatarChoice>({ kind: "keep" });
  const [avatarErrors, setAvatarErrors] = useState<AvatarError[]>([]);
  const [conflict, setConflict] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const bg = useChatBackground();

  const create = useCreatePersona();
  const update = useUpdatePersona();
  const setDefault = useSetDefaultPersona();
  const upload = useUploadPersonaAvatar();
  const removeAvatar = useDeletePersonaAvatar();
  const createChat = useCreateChat();
  const router = useRouter();

  useEffect(() => () => void (avatar.kind === "file" && URL.revokeObjectURL(avatar.url)), [avatar]);

  const name = draft.name.trim();
  const taken = all.some((p) => p.id !== saved?.id && p.name.trim().toLowerCase() === name.toLowerCase());
  const field = fieldError(error);
  const nameError = taken ? "You already have a persona with this name." : field?.field === "name" ? field.message : null;
  const src = avatar.kind === "file" ? avatar.url : avatar.kind === "remove" ? undefined : saved?.avatar_url;
  const characterSvg = avatar.kind === "keep" ? saved?.character_svg : undefined;
  const set = (p: Partial<Draft>) => setDraft((d) => ({ ...d, ...p }));

  function reload() {
    const fresh = latest ?? saved;
    if (!fresh) return;
    setSaved(fresh);
    setDraft(draftOf(fresh));
    dispatch({ type: "preset", color: fresh.color });
    setConflict(false);
    setError(null);
  }

  async function save(e: FormEvent) {
    e.preventDefault();
    if (!name || name.length > NAME_MAX || taken || color.custom) return;
    setBusy(true);
    setError(null);
    try {
      let p = saved;
      if (!p) {
        p = await create.mutateAsync({
          name,
          tone: draft.tone,
          color: color.color,
          custom_instructions: draft.instructions,
          is_default: draft.makeDefault,
          capabilities: { code: draft.code, images: draft.images, image_engine: draft.imageEngine, personas: draft.personas, svg: draft.svg, workflows: draft.workflows, connectors: draft.connectors, ticket_edits: draft.ticketsUnasked ? "allow" : "ask" },
          repos: draft.repos,
        });
      } else {
        const patch: PersonaPatch = { revision: p.revision };
        if (name !== p.name) patch.name = name;
        if (draft.tone !== p.tone) patch.tone = draft.tone;
        if (color.color !== p.color.toLowerCase()) patch.color = color.color;
        if (draft.instructions !== p.custom_instructions) patch.custom_instructions = draft.instructions;
        // Repos persist while code is off; a change to either sends both (the list replaces the old one).
        if (
          draft.code !== p.capabilities.code ||
          draft.images !== p.capabilities.images ||
          draft.imageEngine !== (p.capabilities.image_engine ?? "") ||
          draft.personas !== (p.capabilities.personas ?? false) ||
          draft.svg !== (p.capabilities.svg ?? false) ||
          draft.workflows !== (p.capabilities.workflows ?? false) ||
          draft.connectors !== (p.capabilities.connectors ?? false) ||
          draft.ticketsUnasked !== (p.capabilities.ticket_edits === "allow") ||
          !sameList(draft.repos, p.repos)
        ) {
          patch.capabilities = { code: draft.code, images: draft.images, image_engine: draft.imageEngine, personas: draft.personas, svg: draft.svg, workflows: draft.workflows, connectors: draft.connectors, ticket_edits: draft.ticketsUnasked ? "allow" : "ask" };
          patch.repos = draft.repos;
        }
        if (Object.keys(patch).length > 1) p = await update.mutateAsync({ id: p.id, patch });
        if (draft.makeDefault && !p.is_default) p = await setDefault.mutateAsync(p.id);
      }
      setSaved(p);
      if (avatar.kind === "file") {
        try {
          p = await upload.mutateAsync({ id: p.id, file: avatar.file });
        } catch (err) {
          // The fields are saved; keep the editor open on this persona with the error under the avatar.
          setAvatarErrors([avatarUploadError(err, avatar.file)]);
          setAvatar({ kind: "keep" });
          return;
        }
      } else if (avatar.kind === "remove") {
        p = await removeAvatar.mutateAsync(p.id);
      }
      onClose();
    } catch (err) {
      if (isConflict(err)) setConflict(true);
      else setError(err);
    } finally {
      setBusy(false);
    }
  }

  const isDefault = !!saved?.is_default;
  const tone = TONES.find((t) => t.value === draft.tone) ?? TONES[0];
  return (
    <Dialog.Root open onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-[4vh] z-50 flex max-h-[92vh] w-[min(860px,calc(100%-32px))] -translate-x-1/2 flex-col rounded-xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <form onSubmit={save} className="flex min-h-0 flex-1 flex-col" aria-label={saved ? `Edit ${saved.name}` : "New persona"}>
            <div className="flex items-center gap-2 border-b border-border-subtle px-6 py-4">
              <Dialog.Title className="type-heading flex-1">{saved ? "Edit persona" : "New persona"}</Dialog.Title>
              <Dialog.Close asChild>
                <IconButton icon="x" label="Close" />
              </Dialog.Close>
            </div>

            {conflict && (
              <div role="alert" className="flex flex-wrap items-center gap-2 border-b border-border-subtle bg-pill-human-bg px-6 py-2.5">
                <span className="flex-1 text-13 text-pill-human-fg">
                  This persona changed somewhere else since you opened it. Reload to get the latest; your edits here will be lost.
                </span>
                <Button variant="approve" disabled={!latest || latest.revision === saved?.revision} onClick={reload}>
                  Reload
                </Button>
                <Button variant="outline" onClick={() => setConflict(false)}>
                  Keep editing
                </Button>
              </div>
            )}

            <div className="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)_340px] gap-8 overflow-y-auto px-6 py-5 max-md:grid-cols-1">
              <div className="flex flex-col gap-5">
                <div className="flex flex-col gap-1.5">
                  <label htmlFor="persona-name" className={label}>Name</label>
                  <span className="relative">
                    <TextInput
                      id="persona-name"
                      value={draft.name}
                      maxLength={NAME_MAX}
                      required
                      autoFocus
                      placeholder="e.g. Writing coach"
                      aria-invalid={!!nameError}
                      aria-describedby={nameError ? "persona-name-error" : undefined}
                      onChange={(e) => set({ name: e.target.value })}
                      className="pr-16"
                    />
                    <span className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 text-11 text-fg-tertiary">
                      {draft.name.length} / {NAME_MAX}
                    </span>
                  </span>
                  {nameError && <p id="persona-name-error" role="alert" className="text-12 text-pill-blocked-fg">{nameError}</p>}
                </div>

                <div className="flex flex-col gap-2">
                  <span id="persona-tone-label" className={label}>Conversation tone</span>
                  <div role="radiogroup" aria-labelledby="persona-tone-label" className="flex flex-wrap gap-2">
                    {TONES.map((t) => (
                      <button
                        key={t.value}
                        type="button"
                        role="radio"
                        aria-checked={draft.tone === t.value}
                        onClick={() => set({ tone: t.value })}
                        className={cx(
                          "h-7 rounded-full border px-3 text-12 outline-none focus-visible:ring-2 focus-visible:ring-accent",
                          draft.tone === t.value ? "border-accent bg-accent-soft text-accent" : "border-border bg-surface text-fg-secondary hover:bg-hover",
                        )}
                      >
                        {t.label}
                      </button>
                    ))}
                  </div>
                  <p className="text-12 text-fg-secondary">{tone.label}: {tone.hint}</p>
                </div>

                <ColorRow state={color} dispatch={dispatch} bg={bg} />

                <div className="flex flex-col gap-1.5">
                  <label htmlFor="persona-instructions" className={label}>Custom instructions</label>
                  <TextArea
                    id="persona-instructions"
                    rows={6}
                    value={draft.instructions}
                    maxLength={INSTRUCTIONS_MAX}
                    placeholder="e.g. Keep replies under 150 words unless I ask for more."
                    aria-describedby="persona-instructions-hint"
                    aria-invalid={field?.field === "custom_instructions"}
                    onChange={(e) => set({ instructions: e.target.value })}
                  />
                  <div id="persona-instructions-hint" className="flex justify-between gap-3 text-12 text-fg-tertiary">
                    <span>
                      Added to the Assistant&apos;s instructions for this persona. Can&apos;t override safety rules, memory or tool permissions.
                    </span>
                    <span className="flex-none" aria-live="polite">
                      {draft.instructions.length} / {INSTRUCTIONS_MAX}
                    </span>
                  </div>
                  {field?.field === "custom_instructions" && <p role="alert" className="text-12 text-pill-blocked-fg">{field.message}</p>}
                </div>

                <fieldset className="flex flex-col gap-3">
                  <legend className={cx(label, "mb-2")}>Abilities</legend>
                  <Toggle
                    id="persona-code"
                    checked={draft.code}
                    onChange={(v) => set({ code: v })}
                    title="Write code"
                    hint="Writes and runs code in its chat’s workspace and any repository your GitHub credential can access."
                  />
                  {draft.code && <a href="/settings#repositories" className="pl-[26px] text-12 text-accent">Manage saved repositories & organizations</a>}
                  {!draft.code && field?.field === "repos" && <p role="alert" className="text-12 text-pill-blocked-fg">{field.message}</p>}
                  <Toggle
                    id="persona-images"
                    checked={draft.images}
                    onChange={(v) => set({ images: v })}
                    title="Generate images"
                    hint="Creates images with Codex or Antigravity; works with any model in the chat. Images appear in the conversation."
                  />
                  {draft.images && (
                    <label htmlFor="persona-image-engine" className="flex items-center gap-2 pl-[26px] text-12 text-fg-secondary">
                      Image engine
                      <select id="persona-image-engine" value={draft.imageEngine} onChange={(e) => set({ imageEngine: e.target.value })}
                        className="h-[26px] rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none">
                        <option value="">Workspace setting</option>
                        <option value="auto">Auto</option>
                        <option value="codex">Codex</option>
                        <option value="antigravity">Antigravity</option>
                      </select>
                    </label>
                  )}
                  <Toggle
                    id="persona-svg"
                    checked={draft.svg}
                    onChange={(v) => set({ svg: v })}
                    title="Create SVG images"
                    hint="Draws vector images such as design mockups and diagrams. They appear in the conversation."
                  />
                  <Toggle
                    id="persona-personas"
                    checked={draft.personas}
                    onChange={(v) => set({ personas: v })}
                    title="Create personas"
                    hint="Can propose new personas in a chat. Each one is created only after you approve it, with no abilities turned on."
                  />
                  <Toggle
                    id="persona-workflows"
                    checked={draft.workflows}
                    onChange={(v) => set({ workflows: v })}
                    title="Create workflows"
                    hint="Can suggest new workflows and changes to them. Each suggestion is applied only after you accept it."
                  />
                  <Toggle
                    id="persona-connectors"
                    checked={draft.connectors}
                    onChange={(v) => set({ connectors: v })}
                    title="Request connectors and secrets"
                    hint="Can propose MCP connectors and ask for API secrets in a chat. Each one is added only after you review it; you enter secret values yourself."
                  />
                  <Toggle
                    id="persona-ticket-edits"
                    checked={draft.ticketsUnasked}
                    onChange={(v) => set({ ticketsUnasked: v })}
                    title="Edit tickets without asking"
                    hint="Changes tickets, comments and blockers right away. Off, each edit waits as a card in the chat for you to apply or decline. Canceling a ticket always asks."
                  />
                </fieldset>
              </div>

              <div className="flex flex-col gap-6">
                <AvatarField
                  name={name}
                  color={color.color}
                  current={saved?.avatar_url}
                  currentCharacter={saved?.character_svg}
                  choice={avatar}
                  setChoice={setAvatar}
                  errors={avatarErrors}
                  setErrors={setAvatarErrors}
                  onDesignInChat={saved ? () => {
                    createChat.mutate(
                      { persona_id: saved.id },
                      { onSuccess: (c) => { onClose(); router.push(`/chat/${c.id}`); } },
                    );
                  } : undefined}
                  designing={createChat.isPending}
                />
                <Preview name={draft.name} color={color.color} src={src} characterSvg={characterSvg} tone={draft.tone} />
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-3 border-t border-border-subtle px-6 py-4">
              <div className="flex min-w-0 flex-1 flex-col gap-1">
                <label className="flex items-center gap-2 text-13 text-fg">
                  <input
                    type="checkbox"
                    checked={draft.makeDefault}
                    disabled={isDefault}
                    onChange={(e) => set({ makeDefault: e.target.checked })}
                    className="size-4 accent-[var(--accent)]"
                  />
                  {isDefault ? "This is your default persona" : "Make this my default persona"}
                </label>
                <p className="text-12 text-fg-tertiary">Applies to your Assistant conversations only, never to ticket or epic agents.</p>
                {error !== null && !field && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(error)}</p>}
              </div>
              <Dialog.Close asChild>
                <Button variant="secondary">Cancel</Button>
              </Dialog.Close>
              <Button type="submit" variant="primary" disabled={busy || !name || taken || !!color.custom}>
                {busy ? "Saving…" : "Save persona"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

