/**
 * Quick capture (LAZYAGENTS-243): a note, a message to a persona, or a ticket,
 * from a global shortcut. Builds the existing API calls the web app uses:
 *   note    → POST /api/v1/knowledge/capture   { body_md }
 *   message → POST /api/v1/chats               { persona_id?, message: { body } }
 *   ticket  → POST /api/v1/tickets             { project_key, title, description_md }
 */

export type CaptureKind = "note" | "message" | "ticket";

export interface CaptureInput {
  kind: CaptureKind;
  text: string;
  /** message: one of the person's persona ids; empty for their default persona. */
  personaId?: string;
  /** ticket: the project key. */
  projectKey?: string;
}

export interface CaptureRequest {
  method: "POST";
  path: string;
  body: Record<string, unknown>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROJECT_KEY_RE = /^[A-Z][A-Z0-9_]{0,31}$/;
const MAX_TEXT = 100_000;
const TICKET_TITLE_MAX = 300;

export function buildCaptureRequest(input: CaptureInput): { ok: true; request: CaptureRequest } | { ok: false; error: string } {
  const text = typeof input?.text === "string" ? input.text.replace(/\r\n/g, "\n").trim() : "";
  if (!text) return { ok: false, error: "Write something first." };
  if (text.length > MAX_TEXT) return { ok: false, error: "That's too long for a quick capture." };

  switch (input.kind) {
    case "note":
      return { ok: true, request: { method: "POST", path: "/api/v1/knowledge/capture", body: { body_md: text } } };
    case "message": {
      const persona = (input.personaId ?? "").trim();
      if (persona && !UUID_RE.test(persona)) return { ok: false, error: "Pick a persona from the list." };
      return {
        ok: true,
        request: {
          method: "POST",
          path: "/api/v1/chats",
          body: { ...(persona ? { persona_id: persona } : {}), message: { body: text } },
        },
      };
    }
    case "ticket": {
      const project = (input.projectKey ?? "").trim();
      if (!PROJECT_KEY_RE.test(project)) return { ok: false, error: "Pick a project for the ticket." };
      const [firstLine, ...rest] = text.split("\n");
      const title = firstLine.trim().slice(0, TICKET_TITLE_MAX);
      const description = rest.join("\n").trim();
      return {
        ok: true,
        request: {
          method: "POST",
          path: "/api/v1/tickets",
          body: { project_key: project, title, ...(description ? { description_md: description } : {}) },
        },
      };
    }
    default:
      return { ok: false, error: "Unknown capture kind." };
  }
}

/** Where to go after a successful capture, from the API's response. Only known id shapes are used. */
export function captureResultHref(kind: CaptureKind, response: unknown): string | null {
  const r = response && typeof response === "object" ? (response as Record<string, unknown>) : {};
  if (kind === "message" && typeof r.id === "string" && UUID_RE.test(r.id)) return `/chat/${r.id}`;
  if (kind === "ticket" && typeof r.key === "string" && /^[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}$/.test(r.key)) return `/tickets/${r.key}`;
  if (kind === "note" && typeof r.id === "string" && UUID_RE.test(r.id)) return `/knowledge/${r.id}`;
  return null;
}

const MODIFIERS = new Set([
  "Command", "Cmd", "Control", "Ctrl", "CommandOrControl", "CmdOrCtrl", "Alt", "Option", "AltGr", "Shift", "Super", "Meta",
]);
const NAMED_KEYS = new Set([
  "Space", "Tab", "Backspace", "Delete", "Insert", "Return", "Enter", "Up", "Down", "Left", "Right", "Home", "End",
  "PageUp", "PageDown", "Escape", "Esc", "Plus",
]);

/**
 * Validates an Electron accelerator for a global shortcut: at least one
 * modifier other than Shift (a bare or Shift-only key would steal typing in
 * every app), then exactly one key.
 */
export function validateGlobalShortcut(raw: unknown): { ok: true; accelerator: string } | { ok: false; error: string } {
  if (typeof raw !== "string" || !raw.trim()) return { ok: false, error: "Enter a shortcut." };
  const parts = raw.trim().split("+").map((p) => p.trim());
  if (parts.some((p) => !p)) return { ok: false, error: "That shortcut isn't valid." };
  const mods = parts.slice(0, -1);
  const key = parts[parts.length - 1];
  if (mods.length === 0) return { ok: false, error: "Add a modifier such as ⌘, ⌥ or ⌃." };
  for (const m of mods) if (!MODIFIERS.has(m)) return { ok: false, error: `"${m}" isn't a modifier.` };
  if (new Set(mods).size !== mods.length) return { ok: false, error: "A modifier is repeated." };
  if (mods.every((m) => m === "Shift")) return { ok: false, error: "Shift alone isn't enough; add ⌘, ⌥ or ⌃." };
  const keyOk = /^[A-Z0-9]$/i.test(key) || /^F([1-9]|1[0-9]|2[0-4])$/.test(key) || NAMED_KEYS.has(key) || /^[`\-=[\];',./]$/.test(key);
  if (!keyOk || MODIFIERS.has(key)) return { ok: false, error: `"${key}" isn't a key a shortcut can use.` };
  const normalizedKey = key.length === 1 ? key.toUpperCase() : key;
  return { ok: true, accelerator: [...mods, normalizedKey].join("+") };
}

/** Renders an accelerator with macOS symbols for display (⌥⇧Space). */
export function formatAccelerator(accelerator: string): string {
  const symbols: Record<string, string> = {
    Command: "⌘", Cmd: "⌘", CommandOrControl: "⌘", CmdOrCtrl: "⌘", Control: "⌃", Ctrl: "⌃",
    Alt: "⌥", Option: "⌥", Shift: "⇧", Super: "⌘", Meta: "⌘",
  };
  return accelerator
    .split("+")
    .map((p) => symbols[p] ?? p)
    .join("");
}

/**
 * macOS system shortcuts a global shortcut can't take. Electron may report
 * these as registered, but the system keeps them, so the shortcut would
 * silently never fire. Compared on the normalized modifier set + key.
 */
const SYSTEM_SHORTCUTS: Array<[string[], string, string]> = [
  [["Command"], "Space", "Spotlight"],
  [["Alt", "Command"], "Space", "Finder search"],
  [["Control"], "Space", "Input source switching"],
  [["Control", "Command"], "Space", "Emoji & Symbols"],
  [["Command"], "Tab", "the app switcher"],
  [["Command", "Shift"], "3", "screenshots"],
  [["Command", "Shift"], "4", "screenshots"],
  [["Command", "Shift"], "5", "screenshots"],
  [["Control", "Command"], "Q", "Lock Screen"],
  [["Command"], "Q", "Quit"],
  [["Command"], "H", "Hide"],
  [["Command"], "M", "Minimize"],
  [["Command"], "W", "Close"],
];

function canonicalModifier(m: string): string {
  if (m === "Cmd" || m === "CommandOrControl" || m === "CmdOrCtrl" || m === "Super" || m === "Meta") return "Command";
  if (m === "Ctrl") return "Control";
  if (m === "Option" || m === "AltGr") return "Alt";
  return m;
}

/** The system feature that owns this shortcut, or null. */
export function systemShortcutConflict(accelerator: string): string | null {
  const parts = accelerator.split("+");
  const key = (parts.pop() ?? "").toUpperCase();
  const mods = parts.map(canonicalModifier).sort().join("+");
  for (const [sysMods, sysKey, owner] of SYSTEM_SHORTCUTS) {
    if (sysKey.toUpperCase() === key && [...sysMods].sort().join("+") === mods) return owner;
  }
  return null;
}
