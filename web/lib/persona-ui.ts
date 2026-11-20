// Pure helpers for the persona manager and editor (ADR: Assistant personas, LAZYAGENTS-85).
// No React or fetch here so node --test can cover them.

export type Tone = "neutral" | "friendly" | "concise" | "formal" | "playful";

type PersonaLike = {
  id: string;
  name: string;
  color: string;
  is_default: boolean;
  last_used_at?: string;
  created_at: string;
};

export const NAME_MAX = 60;
export const INSTRUCTIONS_MAX = 2000;
export const MAX_PERSONAS = 40;
export const AVATAR_MAX_BYTES = 1_048_576;
export const AVATAR_TYPES = ["image/png", "image/jpeg", "image/webp"] as const;
export const AVATAR_ACCEPT = ".png,.jpg,.jpeg,.webp,image/png,image/jpeg,image/webp";
export const AVATAR_HINT = "PNG, JPG or WebP · up to 1 MB · shown as a circle.";
/** The built-in Assistant's look when a chat has no persona. */
export const BUILTIN_COLOR = "#9b8cff";
/** The default dark theme's app ground (Neutral --bg); fallback before reading CSS vars. */
export const CHAT_BG = "#18181b";
export const MIN_CONTRAST = 4.5;

export const TONES: { value: Tone; label: string; hint: string; sample: string[] }[] = [
  { value: "neutral", label: "Neutral", hint: "Plain and balanced: the Assistant's usual voice.", sample: ["Four runs shipped this week.", "The billing rewrite is the one to watch:", "Acme's pricing move puts August at risk."] },
  { value: "friendly", label: "Friendly", hint: "Warm and encouraging, still to the point.", sample: ["Nice week: four runs shipped!", "One to keep an eye on is the billing rewrite,", "since Acme's pricing move puts August at risk."] },
  { value: "concise", label: "Concise", hint: "Short replies that lead with the answer.", sample: ["4 runs shipped.", "Risk: billing rewrite.", "Acme's pricing puts August at risk."] },
  { value: "formal", label: "Formal", hint: "Polished and professional, no slang.", sample: ["Four runs were completed this week.", "The billing rewrite carries the most risk:", "Acme's pricing change endangers the August date."] },
  { value: "playful", label: "Playful", hint: "Upbeat and light, the odd emoji, still accurate.", sample: ["Woohoo, four runs shipped this week!", "Billing rewrite is the one to watch:", "Acme's pricing move puts August at risk."] },
];

export const toneLabel = (t: string) => TONES.find((x) => x.value === t)?.label ?? t;

/** About eight readable presets on the dark theme (lower case, as the server stores them). */
export const PRESET_COLORS = ["#8b8fff", "#4fd1c5", "#6fcf97", "#f0bf4c", "#f0a04c", "#f48a87", "#f472b6", "#7cbefd"];

// ---- color ----

export const isHexColor = (s: string) => /^#[0-9a-f]{6}$/i.test(s);

/** Validates the hex input: `#rrggbb` (the `#` may be left off). Returns the lower-case color or null. */
export function parseHex(input: string): string | null {
  const s = input.trim();
  const v = s.startsWith("#") ? s : `#${s}`;
  return isHexColor(v) ? v.toLowerCase() : null;
}

/** A CSS custom property's color as #rrggbb. The CSS minifier shortens #ffffff to #fff, so both forms count. */
export function cssHex(value: string): string | null {
  const s = value.trim();
  const short = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(s);
  return parseHex(short ? `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}` : s);
}

export function hexToRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function rgbToHex(r: number, g: number, b: number): string {
  const c = (x: number) => Math.round(Math.min(255, Math.max(0, x))).toString(16).padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

/** h in degrees [0, 360), s and l in [0, 1]. */
export function hslToHex(h: number, s: number, l: number): string {
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return rgbToHex(f(0) * 255, f(8) * 255, f(4) * 255);
}

export function hexToHsl(hex: string): { h: number; s: number; l: number } {
  const [r, g, b] = hexToRgb(hex).map((x) => x / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  h *= 60;
  if (h < 0) h += 360;
  return { h, s, l };
}

/**
 * A point on the color wheel (relative to its centre, radius `r`) as hue and
 * saturation: angle 0° points right and grows clockwise (screen y grows down).
 */
export function wheelPoint(dx: number, dy: number, r: number): { h: number; s: number } {
  let h = (Math.atan2(dy, dx) * 180) / Math.PI;
  if (h < 0) h += 360;
  return { h, s: Math.min(1, Math.hypot(dx, dy) / r) };
}

/** Where a hue and saturation sit on the wheel, as offsets from its centre. */
export function wheelPosition(h: number, s: number, r: number): { x: number; y: number } {
  const a = (h * Math.PI) / 180;
  return { x: Math.cos(a) * s * r, y: Math.sin(a) * s * r };
}

function luminance(hex: string): number {
  const [r, g, b] = hexToRgb(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio, from 1 to 21. */
export function contrastRatio(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
}

/** The same hue, lightened (dark background) or darkened (light one) until it reads at MIN_CONTRAST. */
export function readableColor(hex: string, bg = CHAT_BG): string {
  if (contrastRatio(hex, bg) >= MIN_CONTRAST) return hex;
  const { h, s, l } = hexToHsl(hex);
  const up = luminance(bg) < 0.5;
  for (let i = 1; i <= 100; i++) {
    const next = up ? Math.min(1, l + i / 100) : Math.max(0, l - i / 100);
    const c = hslToHex(h, s, next);
    if (contrastRatio(c, bg) >= MIN_CONTRAST) return c;
  }
  return up ? "#ffffff" : "#000000";
}

/** A low-contrast warning for the color on the chat background, or null when it reads fine. */
export function contrastWarning(hex: string, bg = CHAT_BG): { ratio: string; suggestion: string } | null {
  if (!isHexColor(hex) || !isHexColor(bg)) return null;
  const ratio = contrastRatio(hex, bg);
  if (ratio >= MIN_CONTRAST) return null;
  return { ratio: `${(Math.floor(ratio * 10) / 10).toFixed(1)}:1`, suggestion: readableColor(hex, bg) };
}

/**
 * The editor's color row: a preset swatch sets the color at once; "Custom…"
 * opens the wheel, lightness slider and hex input, which only set it on Apply.
 */
export type ColorPicker = {
  color: string;
  custom: null | { h: number; s: number; l: number; hex: string; error?: string };
};

export type ColorAction =
  | { type: "preset"; color: string }
  | { type: "open" }
  | { type: "wheel"; h: number; s: number }
  | { type: "lightness"; l: number }
  | { type: "hex"; text: string }
  | { type: "apply" }
  | { type: "cancel" };

export function colorPicker(state: ColorPicker, a: ColorAction): ColorPicker {
  const c = state.custom;
  switch (a.type) {
    case "preset":
      return { color: a.color.toLowerCase(), custom: null };
    case "open": {
      const { h, s, l } = hexToHsl(state.color);
      return { ...state, custom: { h, s, l, hex: state.color } };
    }
    case "wheel":
      return c ? { ...state, custom: { ...c, h: a.h, s: a.s, hex: hslToHex(a.h, a.s, c.l), error: undefined } } : state;
    case "lightness":
      return c ? { ...state, custom: { ...c, l: a.l, hex: hslToHex(c.h, c.s, a.l), error: undefined } } : state;
    case "hex": {
      if (!c) return state;
      const v = parseHex(a.text);
      if (!v) return { ...state, custom: { ...c, hex: a.text, error: "Use #rrggbb, e.g. #5b3fa8." } };
      return { ...state, custom: { ...hexToHsl(v), hex: a.text, error: undefined } };
    }
    case "apply": {
      const v = c && parseHex(c.hex);
      if (!c) return state;
      if (!v) return { ...state, custom: { ...c, error: c.error ?? "Use #rrggbb, e.g. #5b3fa8." } };
      return { color: v, custom: null };
    }
    case "cancel":
      return { ...state, custom: null };
  }
}

/** A new persona gets the first preset nobody uses yet. */
export function unusedPreset(personas: { color: string }[]): string {
  const used = new Set(personas.map((p) => p.color.toLowerCase()));
  return PRESET_COLORS.find((c) => !used.has(c)) ?? PRESET_COLORS[0];
}

// ---- avatar ----

export function personaInitial(name: string): string {
  const first = [...name.trim()][0];
  return first ? first.toUpperCase() : "?";
}

export function formatBytes(n: number): string {
  if (n >= 1_048_576) return `${(n / 1_048_576).toFixed(1)} MB`;
  if (n >= 1024) return `${Math.round(n / 1024)} KB`;
  return `${n} bytes`;
}

export type AvatarError = { title: string; hint: string };

const typeError = (name: string): AvatarError => ({ title: `${name}: type not supported.`, hint: "Use PNG, JPG or WebP." });
const sizeError = (name: string, size?: number): AvatarError => ({
  title: size ? `${name} is ${formatBytes(size)}.` : `${name} is too large.`,
  hint: "The limit is 1 MB. Try a smaller image.",
});
const unreadable = (name: string): AvatarError => ({ title: `${name}: couldn't read this image.`, hint: "Try another file." });

/**
 * Quick client-side checks before uploading. The server sniffs the bytes and
 * stays authoritative; this only saves a round trip for the obvious cases.
 */
export function checkAvatarFile(f: { name: string; type: string; size: number }): AvatarError | null {
  if (f.size === 0) return unreadable(f.name);
  // An empty type means the browser didn't recognise it; let the server decide.
  if (f.type && !(AVATAR_TYPES as readonly string[]).includes(f.type)) return typeError(f.name);
  if (f.size > AVATAR_MAX_BYTES) return sizeError(f.name, f.size);
  return null;
}

/** The server's answer to an avatar upload, as the inline error under the avatar. */
export function avatarUploadError(err: unknown, f: { name: string; size: number }): AvatarError {
  const status = (err as { status?: number } | null)?.status;
  if (status === 413) return sizeError(f.name, f.size);
  if (status === 415) return typeError(f.name);
  if (status === 422) return unreadable(f.name);
  return { title: `${f.name} didn't upload.`, hint: err instanceof Error ? err.message : "Please try again." };
}

// ---- errors ----

export const isConflict = (err: unknown) => (err as { status?: number } | null)?.status === 409;

/** A 422 with a field, for showing next to that input. */
export function fieldError(err: unknown): { field: string; message: string } | null {
  const e = err as { status?: number; field?: string; message?: string } | null;
  if (e?.status !== 422 || !e.field) return null;
  return { field: e.field, message: e.message ?? "Invalid value." };
}

// ---- list ----

/** The manager's order: the default first, then A–Z. */
export function sortPersonas<T extends PersonaLike>(personas: T[]): T[] {
  return [...personas].sort(
    (a, b) => Number(b.is_default) - Number(a.is_default) || a.name.localeCompare(b.name, undefined, { sensitivity: "base" }),
  );
}

/** The list after "Set as default": the old default cleared, the new one set (optimistic update). */
export function withDefault<T extends PersonaLike>(personas: T[], id: string): T[] {
  return personas.map((p) => (p.is_default === (p.id === id) ? p : { ...p, is_default: p.id === id }));
}

/**
 * Who the server would promote if this default were deleted: the most recently
 * used remaining persona, ties to the most recently created. Undefined means
 * the built-in Assistant becomes the default.
 */
export function promotionCandidate<T extends PersonaLike>(personas: T[], deletingId: string): T | undefined {
  const t = (s?: string) => (s ? Date.parse(s) : -Infinity);
  return personas
    .filter((p) => p.id !== deletingId)
    .sort((a, b) => t(b.last_used_at) - t(a.last_used_at) || t(b.created_at) - t(a.created_at))[0];
}

/** What deleting a persona does to its conversations, in one sentence. */
export function deleteConsequence(chatCount: number): string {
  if (chatCount === 0) return "It has no conversations.";
  if (chatCount === 1) return "Its conversation is kept and continues with the built-in Assistant.";
  return `Its ${chatCount} conversations are kept and continue with the built-in Assistant.`;
}

// ---- abilities (capabilities and repositories) ----

export const MAX_REPOS = 10;
export const REPO_MAX = 500;
export const CREDENTIALS_HINT = "Don’t put a token in the URL. Store it in Settings → Connections & secrets instead.";
export const REPO_FORMAT_HINT = "Use https://host/owner/repo, ssh://git@host/owner/repo or git@host:owner/repo.";

/**
 * Light client-side check of a repository URL before it joins the list: https://,
 * ssh:// or user@host:owner/repo, never with credentials. The server normalizes
 * and stays authoritative (422 with field "repos").
 */
export function checkRepoUrl(input: string): { ok: true; url: string } | { ok: false; message: string } {
  const url = input.trim();
  if (!url) return { ok: false, message: "Enter a repository URL." };
  if (url.length > REPO_MAX) return { ok: false, message: `Up to ${REPO_MAX} characters.` };
  if (/\s/.test(url)) return { ok: false, message: REPO_FORMAT_HINT };
  if (/^https:\/\/[^/]*@/i.test(url) || /^ssh:\/\/[^/@]*:[^/@]*@/i.test(url)) return { ok: false, message: CREDENTIALS_HINT };
  if (/^https:\/\/[^/@\s]+\/[^/\s]+\/[^\s]+$/i.test(url)) return { ok: true, url };
  if (/^ssh:\/\/(?:[^/@\s]+@)?[^/@\s]+\/[^/\s]+\/[^\s]+$/i.test(url)) return { ok: true, url };
  if (/^[A-Za-z0-9._-]+@[^/@\s:]+:[^/\s][^\s]*\/[^\s]+$/.test(url)) return { ok: true, url };
  return { ok: false, message: REPO_FORMAT_HINT };
}

/** owner/repo from a git URL, for chips; the URL itself when it doesn't parse. */
export function repoShortName(url: string): string {
  const m = /^(?:[a-z][a-z0-9+.-]*:\/\/[^/]+\/|[^/@\s]+@[^/:\s]+:)(.+?)\/?$/i.exec(url.trim());
  const path = m?.[1].replace(/\.git$/i, "");
  if (!path) return url;
  return path.split("/").slice(-2).join("/");
}

/** Whether two repository URLs name the same owner/repo, however each is written (https or scp-style, with or without .git). */
export const sameRepo = (a: string, b: string) => repoShortName(a).toLowerCase() === repoShortName(b).toLowerCase();

export type RepoChoice = { url: string; name: string };

/**
 * What the composer's repository chip offers, in order: the repo this chat already uses when
 * neither list holds it (so the current choice is always visible), the persona's own repos
 * (the first is the default for new chats), then the shared saved ones. A repo shows once.
 */
export function repositoryChoices(personaRepos: string[], saved: { url: string }[], current?: string, savedLimit = 8) {
  const seen: string[] = [];
  const fresh = (url: string) => !seen.some((s) => sameRepo(s, url)) && !!seen.push(url);
  const toChoice = (url: string): RepoChoice => ({ url, name: repoShortName(url) });
  const own = personaRepos.filter(fresh).map(toChoice);
  const used = current && fresh(current) ? toChoice(current) : undefined;
  const shared = saved.map((r) => r.url).filter(fresh).slice(0, savedLimit).map(toChoice);
  return { current: used, persona: own, saved: shared };
}

/** Adds a repo to the list: trimmed, validated, no duplicates, at most MAX_REPOS. */
export function addRepo(repos: string[], input: string): { repos: string[] } | { error: string } {
  const c = checkRepoUrl(input);
  if (!c.ok) return { error: c.message };
  if (repos.length >= MAX_REPOS) return { error: `Up to ${MAX_REPOS} repositories.` };
  if (repos.some((r) => r.toLowerCase() === c.url.toLowerCase())) return { error: "Already in the list." };
  return { repos: [...repos, c.url] };
}

export const isImageType = (contentType: string) => contentType.toLowerCase().startsWith("image/");

type Abilities = { capabilities?: { code?: boolean; images?: boolean }; repos?: string[] };

/** A persona that can code and has somewhere to do it. */
export const codesInRepos = (p?: Abilities) => !!p?.capabilities?.code && !!p.repos?.length;

/** True when the lists hold the same entries in the same order. */
export const sameList = (a: string[], b: string[]) => a.length === b.length && a.every((x, i) => x === b[i]);

// ---- @mentions (several personas in one chat) ----

const WORD = /[\p{L}\p{N}_]/u;

/**
 * The @mention being typed just before the caret: where its @ is and what follows
 * it. Like the server, the @ must start the text or follow a non-word character
 * (so an email address isn't a mention); the query stops at a line break.
 */
export function mentionQuery(text: string, caret: number): { start: number; query: string } | null {
  const before = text.slice(0, caret);
  const at = before.lastIndexOf("@");
  if (at < 0 || (at > 0 && WORD.test(before[at - 1]))) return null;
  const query = before.slice(at + 1);
  if (query.length > 60 || /[\n@]/.test(query) || /^\s/.test(query)) return null;
  return { start: at, query };
}

/** Personas whose name starts with the query (then those containing it), case-insensitively; at most `max`. */
/**
 * The personas offered in the chat switcher and the @ menu: those in the chat list, plus
 * `keep` (the one a conversation already uses) so a picker never loses its own value.
 */
export function inChatList<P extends { id: string; in_chat_list?: boolean }>(personas: P[], keep?: string): P[] {
  return personas.filter((p) => p.in_chat_list !== false || p.id === keep);
}

export type PersonaWork = "none" | "tickets";

/** What a persona does besides chatting, as the Personas list and its Work section say it. */
export const WORK: { value: PersonaWork; label: string; hint: string }[] = [
  { value: "none", label: "Chat only", hint: "Talks with you. It can't be assigned tickets." },
  { value: "tickets", label: "Takes tickets", hint: "Can be assigned tickets and started from a Start card. Works in its own workspace and branch, and can start sub agents or copies of itself for parts of the work." },
];

export function mentionSuggestions<P extends { name: string; in_chat_list?: boolean }>(personas: P[], query: string, max = 6): P[] {
  personas = personas.filter((p) => p.in_chat_list !== false);
  const q = query.trim().toLowerCase();
  const name = (p: P) => p.name.trim().toLowerCase();
  const starts = personas.filter((p) => name(p).startsWith(q));
  const contains = q ? personas.filter((p) => !name(p).startsWith(q) && name(p).includes(q)) : [];
  return [...starts, ...contains].slice(0, max);
}

/** Replaces the typed @query with @Name and a space; returns the new text and caret. */
export function insertMention(text: string, start: number, caret: number, name: string): { text: string; caret: number } {
  const mention = `@${name.trim()} `;
  return { text: text.slice(0, start) + mention + text.slice(caret), caret: start + mention.length };
}

/**
 * The persona the person chats with most, by chat count (archived included), ties going
 * to the one used more recently; `fallback` (the default persona) when none has a chat yet.
 */
export function mostUsedPersona(personas: readonly { id: string; chat_count: number; last_used_at?: string }[] | undefined, fallback: string | undefined): string | undefined {
  const used = (p: { last_used_at?: string }) => (p.last_used_at ? Date.parse(p.last_used_at) : -Infinity);
  let best: (typeof personas & {})[number] | undefined;
  for (const p of personas ?? []) {
    if (p.chat_count < 1) continue;
    if (!best || p.chat_count > best.chat_count || (p.chat_count === best.chat_count && used(p) > used(best))) best = p;
  }
  return best?.id ?? fallback;
}
