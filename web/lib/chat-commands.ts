// Pure parsing for the chat composer's / commands. They run in the client and are
// never sent to the model; the actions live in chat/_components/conversation.tsx.

/** free: the argument is text to send (no options to pick from). */
export type ChatCommand = { name: string; args?: string; hint: string; free?: boolean; optionalArg?: boolean };

export const CHAT_COMMANDS: ChatCommand[] = [
  { name: "model", args: "model", hint: "Switch the model for the next message" },
  { name: "effort", args: "effort", hint: "Set the reasoning effort for the next message" },
  { name: "persona", args: "persona", hint: "Start a new chat with another persona" },
  { name: "workflow", args: "workflow", hint: "Run one of your published workflows" },
  { name: "new", hint: "Start a new conversation" },
  { name: "compact", args: "focus", free: true, optionalArg: true, hint: "Compact context onto a fresh window (optional focus)" },
  { name: "repo", args: "repository", hint: "Select a repository in this conversation" },
  { name: "memory", hint: "Open your memory" },
  { name: "stop", hint: "Stop the current reply" },
  { name: "steer", args: "guidance", free: true, hint: "Steer the current reply mid-turn without discarding work" },
  { name: "aside", args: "question", free: true, hint: "Ask about the current reply without stopping it" },
  { name: "queue", args: "message", free: true, hint: "Send this once the current reply ends" },
  { name: "design", args: "what to design", free: true, hint: "Create a design (flow, diagram or wireframe) beside the chat" },
  { name: "music", args: "what to compose", free: true, optionalArg: true, hint: "Generate a music track in this chat" },
  { name: "compare", args: "model", hint: "Get a second opinion from another model without switching this chat" },
  { name: "outline", hint: "Open the thread outline (bookmarks, links, checklists, diffs, files)" },
  { name: "thinking", args: "on|off", optionalArg: true, hint: "Show or hide live thinking blocks inline in the transcript" },
];

/** What the composer's + menu offers under "Create with {persona}" (docs/design/designs-from-chat.svg). */
export type CreateKind = "doc" | "slides" | "design" | "music";
export const CREATE_KINDS: { kind: CreateKind; label: string; hint?: string; command?: string }[] = [
  { kind: "doc", label: "Doc" },
  { kind: "slides", label: "Slides" },
  { kind: "design", label: "Design", hint: "Flow, diagram or wireframe", command: "/design" },
  { kind: "music", label: "Music", hint: "Generate a track", command: "/music" },
];

/**
 * The message /design sends: the persona's instructions read "Create a design" as a call
 * for design_create, which opens the design beside the chat.
 */
export function designRequest(brief: string): string {
  return `Create a design: ${brief.trim()}`;
}

/** The draft the + menu's Doc leaves in the composer, for the person to finish. */
export const DOC_DRAFT = "Create a doc: ";

/**
 * The command a finished message is, or null when it's an ordinary message. Only a
 * single line that starts with /word counts, so /usr/bin and multi-line text stay text.
 */
export function parseCommand(text: string): { name: string; arg: string } | null {
  const m = text.trimEnd().match(/^\/([a-z][a-z0-9-]*)(?:[ \t]+([^\n]*))?$/i);
  return m ? { name: m[1].toLowerCase(), arg: (m[2] ?? "").trim() } : null;
}

/** A message starting with // is sent as text, minus the first slash. */
export function literalBody(text: string): string {
  return text.startsWith("//") ? text.slice(1) : text;
}

/** What the suggestion menu should offer for the text so far: command names, then a command's arguments. */
export function commandMenu(text: string): { stage: "command"; query: string } | { stage: "arg"; name: string; query: string } | null {
  const name = text.match(/^\/([a-z0-9-]*)$/i);
  if (name) return { stage: "command", query: name[1] };
  const arg = text.match(/^\/([a-z][a-z0-9-]*)[ \t]+([^\n]*)$/i);
  if (!arg) return null;
  const command = CHAT_COMMANDS.find((c) => c.name === arg[1].toLowerCase());
  if (!command?.args || command.free) return null;
  // Once a space follows the model token in `/compare <model> <question>`, close the picker so Enter submits the full command.
  if (command.name === "compare" && /\s/.test(arg[2])) return null;
  return { stage: "arg", name: command.name, query: arg[2] };
}

export type CompareModelOption = {
  name: string;
  harness: string;
  harnessLabel: string;
  model: string;
  modelLabel: string;
  isDefault?: boolean;
};

/** Parses `/compare <model|harness> [question]` against the sorted candidate models. */
export function resolveCompareTarget(
  options: CompareModelOption[],
  raw: string,
): { option: CompareModelOption; question: string } | { error: string } {
  const trimmed = raw.trim();
  if (!trimmed) return { error: "Say which model: /compare <model> [question]" };

  const lower = trimmed.toLowerCase();
  const byPhrase = [...options]
    .flatMap((option) => [
      { option, phrase: option.name.toLowerCase() },
      { option, phrase: option.modelLabel.toLowerCase() },
    ])
    .filter(({ phrase }) => lower === phrase || lower.startsWith(`${phrase} `) || lower.startsWith(`${phrase}\t`))
    .sort((a, b) => b.phrase.length - a.phrase.length)[0];
  if (byPhrase) {
    return { option: byPhrase.option, question: trimmed.slice(byPhrase.phrase.length).trim() };
  }

  const m = trimmed.match(/^(\S+)(?:\s+([\s\S]+))?$/);
  const first = m![1];
  const token = first.toLowerCase();
  const question = (m![2] ?? "").trim();

  const pickDefault = (matches: CompareModelOption[]) => matches.find((o) => o.isDefault) ?? matches[0];
  const exactModel = options.find((o) => o.model.toLowerCase() === token || o.modelLabel.toLowerCase() === token);
  if (exactModel) return { option: exactModel, question };

  const exactHarness = options.filter((o) => o.harness.toLowerCase() === token || o.harnessLabel.toLowerCase() === token);
  if (exactHarness.length) return { option: pickDefault(exactHarness), question };

  const startsWith = options.filter(
    (o) =>
      o.model.toLowerCase().startsWith(token) ||
      o.modelLabel.toLowerCase().startsWith(token) ||
      o.harness.toLowerCase().startsWith(token) ||
      o.harnessLabel.toLowerCase().startsWith(token),
  );
  if (startsWith.length) return { option: startsWith[0], question };

  const includes = options.find(
    (o) =>
      o.model.toLowerCase().includes(token) ||
      o.modelLabel.toLowerCase().includes(token) ||
      o.name.toLowerCase().includes(token),
  );
  if (includes) return { option: includes, question };

  return { error: `No model matches “${first}”.` };
}

/** Parses `/thinking [on|off]` against the current `showLiveThinking` preference. Empty toggles. */
export function resolveThinkingToggle(raw: string, current: boolean): { next: boolean } | { error: string } {
  const token = raw.trim().toLowerCase();
  if (!token || token === "toggle") return { next: !current };
  if (token === "on" || token === "true" || token === "1" || token === "show" || token === "enable") return { next: true };
  if (token === "off" || token === "false" || token === "0" || token === "hide" || token === "disable") return { next: false };
  return { error: "Usage: /thinking [on|off]" };
}

/** Persistent preference for live inline thinking streams in Chat (default false). */
export const SHOW_LIVE_THINKING_KEY = "vesper.chat.showLiveThinking";
const LIVE_THINKING_EVENT = "vesper:show-live-thinking";

type StorageLike = Pick<Storage, "getItem" | "setItem">;

export function readShowLiveThinking(storage?: StorageLike | null): boolean {
  try {
    const s = storage ?? (typeof window !== "undefined" ? window.localStorage : null);
    return s?.getItem(SHOW_LIVE_THINKING_KEY) === "true";
  } catch {
    return false;
  }
}

export function writeShowLiveThinking(enabled: boolean, storage?: StorageLike | null): boolean {
  try {
    const s = storage ?? (typeof window !== "undefined" ? window.localStorage : null);
    s?.setItem(SHOW_LIVE_THINKING_KEY, enabled ? "true" : "false");
  } catch {
    /* Storage unavailable or blocked; in-session listeners still update. */
  }
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent(LIVE_THINKING_EVENT, { detail: enabled }));
  }
  return enabled;
}

export function subscribeShowLiveThinking(listener: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const onStorage = (e: StorageEvent) => {
    if (e.key === null || e.key === SHOW_LIVE_THINKING_KEY) listener();
  };
  window.addEventListener(LIVE_THINKING_EVENT, listener);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(LIVE_THINKING_EVENT, listener);
    window.removeEventListener("storage", onStorage);
  };
}
