"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { api, chatAttachmentUrl, unwrap, type Schemas } from "@/lib/api/client";
import { chatKeys, useBootstrap, useChat, useSecrets, useVerifyHarness } from "@/lib/api/hooks";
import { usePersonas, useSetDefaultPersona } from "@/lib/api/persona-hooks";
import { useCreateMemory } from "@/lib/api/persona-memory-hooks";
import { useCompleteOnboarding, useUpdateProfile, useUploadProfileAvatar } from "@/lib/api/profile-hooks";
import { cx } from "@/lib/cx";
import {
  assistantLine,
  credentialHelp,
  credentialPlaceholder,
  draftBullets,
  draftPrompt,
  HARNESS_CARDS,
  HARNESS_SECRETS,
  harnessHint,
  initialOf,
  PERSONA_EXAMPLES,
  prefillName,
  refinePrompt,
  setupHarness,
  type CredentialKind,
  type HarnessCard as HarnessCardInfo,
  type HarnessId,
  type WizardStep,
} from "@/lib/onboarding";
import { ROLE_MAX } from "@/lib/profile-ui";
import { setWizardStep } from "@/components/domain/setup-progress";
import { PersonaAvatar, PersonaPortrait, personaLook, toneLabel } from "./persona";
import { Spinner } from "@/components/ui/loading";

// The first-run Welcome Wizard (LAZYAGENTS-102). It is the new-chat welcome:
// the default Assistant hosts it from the carousel slot, says each step's line
// where the tagline sits, and the step card takes the composer's place. The
// finale hands back to the ordinary welcome (chat-screen.tsx) with the new
// persona, which slides into the centre.

type Proposal = Schemas["PersonaProposal"];

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function subscribeMotion(cb: () => void) {
  const m = window.matchMedia("(prefers-reduced-motion: reduce)");
  m.addEventListener("change", cb);
  return () => m.removeEventListener("change", cb);
}

function useReducedMotion() {
  return useSyncExternalStore(subscribeMotion, () => window.matchMedia("(prefers-reduced-motion: reduce)").matches, () => false);
}

/** Types `text` out a letter at a time (all at once with reduced motion). */
function useTyped(text: string, every: number) {
  const reduced = useReducedMotion();
  const [n, setN] = useState(0);
  useEffect(() => {
    if (reduced) return;
    const t = window.setInterval(() => setN((i) => (i >= text.length ? (window.clearInterval(t), i) : i + 1)), every);
    return () => window.clearInterval(t);
  }, [text, every, reduced]);
  return reduced ? text : text.slice(0, n);
}

/** The Assistant's line, typed where the tagline sits, with a blinking caret. Screen readers get it whole. */
function SaidLine({ text }: { text: string }) {
  const typed = useTyped(text, 18);
  return (
    <p aria-live="polite" className="mt-2 min-h-[42px] max-w-[440px] text-center text-14 text-fg-secondary">
      <Typed typed={typed} text={text} />
      <span aria-hidden className="wizard-caret" />
    </p>
  );
}

/** The typed part on screen and the whole for screen readers; once typed, just the text. */
function Typed({ typed, text }: { typed: string; text: string }) {
  if (typed === text) return <>{text}</>;
  return (
    <>
      <span aria-hidden>{typed}</span>
      <span className="sr-only">{text}</span>
    </>
  );
}

function TypedName({ text }: { text: string }) {
  return <Typed typed={useTyped(text, 35)} text={text} />;
}

const field = "h-[30px] w-full rounded-[7px] border border-border-strong bg-surface-sunken px-2.5 text-13 text-fg outline-none transition-[border-color,box-shadow] focus:border-accent focus:shadow-[0_0_0_3px_var(--accent-soft)]";
const primary = "h-[30px] rounded-[7px] bg-accent px-3.5 text-13 font-semibold text-on-accent transition-[opacity,transform] active:scale-[0.97] disabled:cursor-not-allowed disabled:opacity-35";
const ghost = "inline-flex h-[30px] items-center gap-2 rounded-[7px] border border-border-strong px-3 text-13 text-fg-2 hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50";

function Foot({ hint, children }: { hint?: ReactNode; children: ReactNode }) {
  return (
    <div className="mt-3 flex items-center justify-end gap-2.5">
      <span className="mr-auto text-12 text-fg-tertiary" data-testid="wizard-hint">{hint}</span>
      {children}
    </div>
  );
}

function Alert({ error }: { error?: string }) {
  return error ? <p role="alert" className="mt-2 text-13 text-pill-blocked-fg">{error}</p> : null;
}

// ------------------------------------------------------------ 0 · greeting

function Greeting({ onNext }: { onNext: () => void }) {
  return (
    <>
      <p className="px-0.5 pb-7 pt-1 text-15 text-fg-tertiary">Three short steps: who you are, how I’ll think, and who else you’d like to talk to.</p>
      <Foot>
        <button type="button" className={primary} onClick={onNext}>Let’s begin</button>
      </Foot>
    </>
  );
}

// ------------------------------------------------------------ 1 · about you

const PHOTO_TYPES = ["image/png", "image/jpeg", "image/webp"];
const PHOTO_MAX = 1 << 20;

function AboutYou({ onNext }: { onNext: () => void }) {
  const me = useBootstrap().data?.me;
  const [name, setName] = useState(() => prefillName(me?.name));
  const [work, setWork] = useState(me?.role_title ?? "");
  // The picked photo stays in the browser until Continue.
  const [photo, setPhoto] = useState<File | null>(null);
  const preview = useMemo(() => (photo ? URL.createObjectURL(photo) : undefined), [photo]);
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);
  const [drag, setDrag] = useState(false);
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const update = useUpdateProfile();
  const upload = useUploadProfileAvatar();
  const remember = useCreateMemory();

  const pick = (f?: File | null) => {
    if (!f) return;
    if (!PHOTO_TYPES.includes(f.type)) return setError("Use a PNG, JPEG or WebP image.");
    if (f.size > PHOTO_MAX) return setError("Use an image under 1 MB.");
    setError(undefined);
    setPhoto(f);
  };
  const shown = preview ?? me?.avatar_url;
  const tooLong = [...work.trim()].length > ROLE_MAX;

  async function save() {
    const w = work.trim();
    setBusy(true);
    setError(undefined);
    try {
      await update.mutateAsync({ name: name.trim(), role_title: w });
      if (photo) await upload.mutateAsync(photo);
      // What they do goes to memory once, not again when setup is re-run unchanged.
      if (w && w !== (me?.role_title ?? "").trim()) await remember.mutateAsync({ title: "What I do", summary: w, body: w, type: "work" });
      onNext();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="flex items-center gap-4 max-sm:flex-col">
        <label
          title="Upload a photo"
          className={cx(
            "relative grid size-16 flex-none cursor-pointer place-items-center rounded-full shadow-[0_0_0_2px_var(--border-strong)] transition-[box-shadow,transform] hover:shadow-[0_0_0_2px_var(--accent),0_0_0_6px_var(--accent-soft)] active:scale-[0.96]",
            drag && "shadow-[0_0_0_2px_var(--accent),0_0_0_6px_var(--accent-soft)]",
          )}
          style={{ background: "linear-gradient(160deg, var(--brand-deep), var(--brand-violet) 62%, var(--brand-star))" }}
          onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
          onDragLeave={() => setDrag(false)}
          onDrop={(e) => { e.preventDefault(); setDrag(false); pick(e.dataTransfer.files[0]); }}
          data-testid="profile-photo"
        >
          <span aria-hidden className="text-26 font-semibold text-[#FFF6DD]">{initialOf(name)}</span>
          {shown && (
            // A local object URL or the private avatar route: next/image adds nothing.
            <img key={shown} src={shown} alt="Your profile photo" className="wizard-photo absolute inset-0 size-full rounded-full object-cover" />
          )}
          <span aria-hidden className="absolute -bottom-0.5 -right-0.5 grid size-[22px] place-items-center rounded-full bg-accent text-14 font-bold text-on-accent shadow-[0_0_0_3px_var(--surface)]">＋</span>
          <input ref={input} type="file" accept={PHOTO_TYPES.join(",")} aria-label="Profile photo" className="sr-only" onChange={(e) => { pick(e.target.files?.[0]); e.target.value = ""; }} />
        </label>
        <div className="min-w-0 flex-1">
          <div className="grid grid-cols-[repeat(auto-fit,minmax(200px,1fr))] gap-2.5">
            <label className="block">
              <span className="mb-[5px] block text-12 text-fg-secondary">Your name</span>
              <input className={field} value={name} maxLength={80} autoFocus onChange={(e) => setName(e.target.value)} />
            </label>
            <label className="block">
              <span className="mb-[5px] block text-12 text-fg-secondary">What you do</span>
              <input className={field} value={work} placeholder="e.g. Backend engineer, Go" onChange={(e) => setWork(e.target.value)} />
            </label>
          </div>
          <p className="mt-2 text-12 text-fg-tertiary">
            Profile photo <span className="ml-0.5 rounded bg-selected px-[5px] py-0.5 text-10 font-semibold uppercase tracking-[0.06em] text-fg-secondary">Optional</span>{" · "}
            {photo ? (
              <>looking good · <button type="button" className="text-accent hover:underline" onClick={() => setPhoto(null)}>Remove</button></>
            ) : (
              "click the circle or drop an image"
            )}
          </p>
        </div>
      </div>
      {tooLong && <Alert error={`Keep “What you do” to ${ROLE_MAX} characters.`} />}
      <Alert error={error} />
      <Foot hint="You can change these in Customization.">
        <button type="button" className={primary} disabled={!name.trim() || tooLong || busy} onClick={save}>
          {busy ? "Saving…" : "Continue"}
        </button>
      </Foot>
    </>
  );
}

// ------------------------------------------------------------ 2 · harness

type Verified = Partial<Record<HarnessId, number>>;

function HarnessCard({ id, label, by, images, subscriptionOnly, paste, hostLogins, stored, verified, onVerified }: HarnessCardInfo & {
  /** Whether a credential can be pasted here: runs use stored keys, and secrets are on. */
  paste: boolean;
  /** Runs use the server host's own CLI sign-in: nothing to paste, only to check. */
  hostLogins: boolean;
  /** This workspace already has a key for it. */
  stored: boolean;
  verified?: number; onVerified: (models: number) => void;
}) {
  const [pickedKind, setKind] = useState<CredentialKind>("subscription");
  const kind: CredentialKind = subscriptionOnly ? "subscription" : pickedKind;
  const [value, setValue] = useState("");
  const [error, setError] = useState<string>();
  const [checking, setChecking] = useState(false);
  const verify = useVerifyHarness();
  const retry = useRef(0);
  useEffect(() => () => { retry.current = -1; }, []);

  // With nothing pasted, Verify checks what is already configured (a stored key, or the server's CLI sign-in).
  // Retries only follow the listing: the credential was stored by the first call.
  const run = (again = false) => {
    if (!again) retry.current = 0;
    setError(undefined);
    const credential = again ? "" : value.trim();
    if (credential) setValue("");
    verify.mutate(
      { harness: id, ...(credential && paste ? { body: { kind, credential } } : {}) },
      {
        onSuccess: (r) => {
          if (r.ok) {
            setChecking(false);
            return onVerified(r.models.length);
          }
          // A plan login's models come from a runner: ask again for a little while.
          if (r.checking && retry.current >= 0 && retry.current < 15) {
            retry.current++;
            setChecking(true);
            window.setTimeout(() => retry.current >= 0 && run(true), 2000);
            return;
          }
          setChecking(false);
          setError(r.error ?? "No chat models came back.");
        },
        onError: (e) => { setChecking(false); setError(errorText(e)); },
      },
    );
  };
  const busy = verify.isPending || checking;
  const ok = verified !== undefined;
  return (
    <section aria-label={label} data-verified={ok || undefined} className={cx("rounded-[10px] border border-border bg-surface-sunken p-3 transition-[border-color,box-shadow] duration-(--motion-slow)", ok && "wizard-verified")}>
      <h3 className="flex items-center gap-2 text-14 font-semibold">
        {label}
        {images && <span data-testid={`${id}-images`} className="rounded-full bg-[color-mix(in_srgb,var(--brand-star)_22%,transparent)] px-2 py-px text-11 font-semibold text-[var(--brand-star)]">Images</span>}
      </h3>
      <p className="mt-0.5 text-12 text-fg-tertiary">{by}</p>
      <p className="mb-2.5 mt-1 min-h-[52px] text-12 text-fg-tertiary">
        {subscriptionOnly
          ? hostLogins
            ? "Runs use the agy sign-in on this host. Sign it in there, then Verify checks it. Nothing to paste."
            : "Chat, coding and agent runs via Google Antigravity sign-in (Settings → Connections), or paste an Antigravity login bundle."
          : "Chat, coding and agent runs."}
      </p>
      {paste && (
        <>
          {!subscriptionOnly && <div role="radiogroup" aria-label={`${label} sign-in`} className="mb-2 flex rounded-[7px] border border-border bg-bg p-0.5">
            {(["subscription", "api_key"] as const).map((k) => (
              <button key={k} type="button" role="radio" aria-checked={kind === k} onClick={() => setKind(k)}
                className={cx("h-[22px] flex-1 rounded-[5px] text-12 transition-colors", kind === k ? "bg-selected text-fg" : "text-fg-tertiary hover:text-fg")}>
                {k === "subscription" ? "Subscription" : "API key"}
              </button>
            ))}
          </div>}
          <input type="password" autoComplete="off" spellCheck={false} aria-label={`${label} credential`} className={field}
            placeholder={credentialPlaceholder(id, kind)} title={credentialHelp(id, kind)} value={value} onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && value.trim()) run(); }} />
          {stored && !ok && <p className="mt-1.5 text-12 text-fg-tertiary">Already set up for this workspace: leave it empty to check that one. Pasting replaces it for everyone.</p>}
        </>
      )}
      <div className="mt-2 flex items-center gap-2">
        <button type="button" className={ghost} disabled={busy} onClick={() => run()} aria-label={ok ? `${label} verified` : `Verify ${label}`}>
          {busy ? <><Spinner /><span className="sr-only">Verifying</span></> : ok ? "Verified" : "Verify"}
        </button>
        {ok && (
          <span className="wizard-badge text-12 text-state-done" data-testid={`${id}-models`}>
            <svg aria-hidden className="wizard-check mr-1 inline" width="12" height="12" viewBox="0 0 12 12" style={{ verticalAlign: -1 }}>
              <path d="M2 6.5l2.5 2.5L10 3" stroke="currentColor" strokeWidth="2" fill="none" strokeLinecap="round" />
            </svg>
            {verified} {verified === 1 ? "model" : "models"}
          </span>
        )}
        {checking && <span className="text-12 text-fg-tertiary">Asking the runner…</span>}
      </div>
      <Alert error={error} />
    </section>
  );
}

function ConnectHarness({ onNext }: { onNext: (verified: HarnessId[]) => void }) {
  const secrets = useSecrets();
  const qc = useQueryClient();
  const [verified, setVerified] = useState<Verified>({});
  const done = HARNESS_CARDS.map((c) => c.id).filter((h) => verified[h] !== undefined);
  const secretsOff = secrets.data ? !secrets.data.key_configured : false;
  // Runs on the host use its CLI sign-ins: there is nothing to paste, only to check.
  const hostLogins = secrets.data?.harness_keys_required === false;
  const has = (name: string) => !!secrets.data?.secrets.some((x) => x.name === name && !x.project);
  return (
    <>
      {hostLogins ? (
        <p role="note" className="mb-2.5 rounded-[8px] border border-border bg-surface-sunken px-3 py-2 text-13 text-fg-secondary">
          This server runs Claude Code, Codex and Antigravity with the <code>claude</code>, <code>codex</code> and <code>agy</code> sign-ins on its host. Sign the CLI in there, then Verify checks it.
        </p>
      ) : secretsOff ? (
        <p role="note" className="mb-2.5 rounded-[8px] border border-border bg-surface-sunken px-3 py-2 text-13 text-fg-secondary">
          Secrets are off on this server (<code>SECRETS_KEY</code> isn’t set), so Vesper can’t store a credential here. Set it and restart the API, then paste one here.
        </p>
      ) : null}
      <div className="grid grid-cols-2 gap-2.5 max-sm:grid-cols-1">
        {HARNESS_CARDS.map((c) => (
          <HarnessCard key={c.id} {...c} paste={!hostLogins && !secretsOff} hostLogins={hostLogins} stored={has(HARNESS_SECRETS[c.id])}
            verified={verified[c.id]} onVerified={(n) => setVerified((v) => ({ ...v, [c.id]: n }))} />
        ))}
      </div>
      <Foot hint={harnessHint(done)}>
        <button type="button" className={primary} disabled={!done.length} onClick={() => { void qc.invalidateQueries({ queryKey: chatKeys.models }); onNext(done); }}>
          Continue
        </button>
      </Foot>
    </>
  );
}

// ------------------------------------------------------------ 3 · first persona

function DraftCard({ draft }: { draft?: Proposal }) {
  if (!draft) {
    return (
      <div aria-busy="true" aria-label="Drafting" className="wizard-enter mt-3 flex items-start gap-3 rounded-[10px] border border-border bg-surface-sunken p-3">
        <span className="wizard-shimmer size-11 flex-none rounded-full" />
        <div className="flex flex-1 flex-col gap-2 pt-1">
          <span className="wizard-shimmer h-3.5 w-28 rounded" />
          <span className="wizard-shimmer h-3 w-44 rounded" />
        </div>
      </div>
    );
  }
  const picture = draft.avatar_state === "ready" && draft.avatar_attachment_id ? chatAttachmentUrl(draft.avatar_attachment_id) : undefined;
  return (
    <div key={draft.id} data-testid="persona-draft" className="wizard-enter mt-3 flex items-start gap-3 rounded-[10px] border border-border bg-surface-sunken p-3">
      <span className="wizard-photo flex-none">
        <PersonaAvatar persona={{ name: draft.name, color: draft.color, avatar_url: picture }} size={44} />
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-14 font-semibold"><TypedName text={draft.name} /></div>
        <div className="text-12 text-fg-tertiary">{toneLabel(draft.tone)}{draft.reason && ` · ${draft.reason}`}</div>
        <ul className="wizard-stagger mt-1 list-disc pl-4 text-13 text-fg-2">
          {draftBullets(draft.custom_instructions).map((b, i) => (
            <li key={b} style={{ "--i": i } as CSSProperties}>{b}</li>
          ))}
        </ul>
      </div>
    </div>
  );
}

type ChatSeen = { running: boolean; updatedAt: number } | undefined;

/**
 * Where the draft stands after the last message (sent at `sentAt`): the newest
 * pending proposal not in `before` is it, settled once its picture is too. The
 * turn failed to draft when it ended and the proposals read since show none.
 */
function draftState(list: Proposal[], before: string[], sentAt: number, chat: ChatSeen, listedAt: number) {
  const fresh = sentAt ? list.filter((p) => p.state === "pending" && !before.includes(p.id)).at(-1) : undefined;
  const settled = !!fresh && fresh.avatar_state !== "pending";
  const turnOver = !!chat && !chat.running && chat.updatedAt > sentAt;
  const failed = sentAt > 0 && !fresh && turnOver && listedAt > chat!.updatedAt;
  return { fresh, failed, waiting: sentAt > 0 && !settled && !failed };
}

function FirstPersona({ harness, onDone }: { harness?: HarnessId; onDone: (personaId: string) => void }) {
  const personas = usePersonas();
  const host = personas.data?.default_persona_id;
  const qc = useQueryClient();
  const [text, setText] = useState("");
  const [chatId, setChatId] = useState<string>();
  // Proposals that existed before the last message: the draft is the newest one after them.
  const [before, setBefore] = useState<string[]>([]);
  const [sentAt, setSentAt] = useState(0);
  const [sending, setSending] = useState(false);
  const [meeting, setMeeting] = useState(false);
  const [error, setError] = useState<string>();
  // Set once approved, so a retry after a later failure doesn't approve twice.
  const [approved, setApproved] = useState<string>();
  const setDefault = useSetDefaultPersona();
  const complete = useCompleteOnboarding();

  const chat = useChat(chatId);
  const seen: ChatSeen = chat.data ? { running: chat.data.state === "running", updatedAt: chat.dataUpdatedAt } : undefined;
  const proposals = useQuery({
    enabled: !!chatId,
    queryKey: chatKeys.proposals(chatId ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/persona-proposals", { params: { path: { id: chatId! } } })),
    // Polled while a draft is on its way.
    refetchInterval: (q) => (draftState(q.state.data?.proposals ?? [], before, sentAt, seen, q.state.dataUpdatedAt).waiting ? 1500 : false),
  });
  const list = proposals.data?.proposals ?? [];
  const { fresh, failed, waiting } = draftState(list, before, sentAt, seen, proposals.dataUpdatedAt);
  const draft = fresh ?? list.filter((p) => p.state === "pending").at(-1);
  const ready = !!draft && draft.avatar_state !== "pending";
  const shownError = failed && !error ? "No draft came back. Try describing them differently, or check that your Assistant may create personas (Customization → Personas)." : error;

  async function send() {
    const words = text.trim();
    if (!words) return;
    setSending(true);
    setError(undefined);
    try {
      let id = chatId;
      if (!id) {
        // A hidden, temporary chat owns the proposal, so the usual approval path applies.
        const c = await unwrap(api.POST("/chats", { body: { hidden: true, temporary: true, ...(host ? { persona_id: host } : {}), title: "Welcome setup" } }));
        id = c.id;
        setChatId(id);
      } else if (draft) {
        // Only the newest draft can be met: decline the one being replaced.
        await unwrap(api.POST("/chats/{id}/persona-proposals/{proposal_id}", { params: { path: { id, proposal_id: draft.id } }, body: { decision: "decline" } }));
      }
      const known = list.map((p) => p.id);
      // On a harness that verified: the Assistant's own may not be connected.
      await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id } }, body: { body: draft ? refinePrompt(words) : draftPrompt(words), ...(harness ? { harness } : {}) } }));
      setBefore(known);
      setSentAt(Date.now());
      setText("");
      await Promise.all([qc.invalidateQueries({ queryKey: chatKeys.detail(id) }), qc.invalidateQueries({ queryKey: chatKeys.proposals(id) })]);
    } catch (e) {
      setError(errorText(e));
      if (chatId) void qc.invalidateQueries({ queryKey: chatKeys.proposals(chatId) });
    } finally {
      setSending(false);
    }
  }

  async function meet() {
    if (!chatId || (!draft && !approved)) return;
    setMeeting(true);
    setError(undefined);
    try {
      let id = approved;
      if (!id) {
        const decided = await unwrap(api.POST("/chats/{id}/persona-proposals/{proposal_id}", { params: { path: { id: chatId, proposal_id: draft!.id } }, body: { decision: "approve" } }));
        id = decided.persona?.id;
        if (!id) throw new Error("The persona wasn’t created. Please try again.");
        setApproved(id);
      }
      await setDefault.mutateAsync(id);
      await complete.mutateAsync();
      onDone(id);
    } catch (e) {
      setError(errorText(e));
      setMeeting(false);
    }
  }

  const busy = sending || waiting || meeting;
  return (
    <>
      <textarea
        aria-label="Describe them"
        rows={2}
        value={text}
        disabled={busy}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void send(); } }}
        placeholder={draft ? "Tell me what to change…" : "A blunt senior engineer who pairs with me…"}
        className="w-full resize-none bg-transparent px-0.5 py-1 text-15 leading-[1.6] text-fg outline-none placeholder:text-fg-tertiary"
      />
      {!draft && !waiting && (
        <ul aria-label="Examples" className="mt-2.5 flex flex-wrap gap-1.5">
          {PERSONA_EXAMPLES.map((x) => (
            <li key={x}>
              <button type="button" onClick={() => setText(x)} className="inline-flex h-[26px] items-center rounded-full border border-border-strong px-2.5 text-12 text-fg-secondary transition-colors hover:bg-hover hover:text-fg">{x}</button>
            </li>
          ))}
        </ul>
      )}
      {(waiting || draft) && <DraftCard draft={waiting && !fresh ? undefined : draft} />}
      <Alert error={shownError} />
      <Foot hint={draft && !waiting ? "Tell me what to change, or meet them." : undefined}>
        <button type="button" className={ghost} disabled={busy || !text.trim() || !!approved} onClick={send}>
          {sending || waiting ? <><Spinner /> Drafting…</> : draft ? "Redraft" : "Draft persona"}
        </button>
        <button type="button" className={primary} disabled={!(ready || approved) || busy} onClick={meet}>
          {meeting ? "Meeting…" : "Meet them"}
        </button>
      </Foot>
    </>
  );
}

// ------------------------------------------------------------ the wizard

/**
 * Starts at the greeting; `onDone` gets the new default persona once the person
 * meets them. With `only="harness"` (someone already set up whose harness went
 * missing) it is just the harness step, and `onDone` gets nothing.
 */
export function WelcomeWizard({ only, onDone }: { only?: "harness"; onDone: (personaId?: string) => void }) {
  const personas = usePersonas();
  const host = personaLook(personas.data?.personas.find((p) => p.id === personas.data?.default_persona_id));
  const reduced = useReducedMotion();
  const [step, setStep] = useState<WizardStep>(only ? 2 : 0);
  const [verified, setVerified] = useState<HarnessId[]>([]);
  const [leaving, setLeaving] = useState(false);
  const [hour] = useState(() => new Date().getHours());
  useEffect(() => {
    if (!only) setWizardStep(step);
  }, [step, only]);
  useEffect(() => () => setWizardStep(null), []);

  // The card fades and lifts out, then the next one rises in.
  const go = (next: WizardStep) => {
    setLeaving(true);
    window.setTimeout(() => {
      setStep(next);
      setLeaving(false);
    }, reduced ? 120 : 200);
  };
  const finish = (id?: string) => {
    if (!only) setWizardStep(4);
    onDone(id);
  };
  const line = only ? "Chats need a mind to run on again: connect Claude Code, Codex, Antigravity or any mix." : assistantLine(step, hour);
  return (
    <div className="relative flex min-h-0 flex-1 flex-col overflow-y-auto" data-testid="welcome-wizard">
      <div className="mx-auto flex w-full max-w-[600px] flex-1 flex-col items-center justify-center px-6 py-10">
        <div className="flex h-28 items-center">
          <PersonaPortrait persona={host} breathe />
        </div>
        <h1 className="mt-5 text-26 font-semibold leading-tight tracking-[-0.02em] text-fg">{host.name}</h1>
        <SaidLine key={line} text={line} />
        <div className="mt-[22px] w-full overflow-hidden rounded-xl border border-border-strong bg-surface p-3.5">
          <div key={step} className={leaving ? "wizard-leave" : "wizard-enter"} aria-label={["Welcome", "About you", "Connect a harness", "Your first persona"][step]} role="group">
            {step === 0 && <Greeting onNext={() => go(1)} />}
            {step === 1 && <AboutYou onNext={() => go(2)} />}
            {step === 2 && <ConnectHarness onNext={(v) => { setVerified(v); if (only) finish(); else go(3); }} />}
            {step === 3 && <FirstPersona harness={setupHarness(verified)} onDone={finish} />}
          </div>
        </div>
      </div>
    </div>
  );
}
