// Pure helpers for the first-run Welcome Wizard (welcome-wizard.tsx).

/** 0 is the Assistant's greeting; 1–3 the steps; 4 the finale. */
export type WizardStep = 0 | 1 | 2 | 3 | 4;

/** The sidebar's "Getting set up" rows, one per step. */
export const SETUP_ROWS = ["About you", "Connect a harness", "Your first persona"] as const;

/**
 * Which wizard to show: all of it until the person finishes it; only the
 * harness step for someone who has, while chats have no harness to run on.
 */
export function wizardMode(me: { onboarded_at?: string; harness_connected?: boolean } | undefined): "full" | "harness" | null {
  if (!me) return null;
  if (!me.onboarded_at) return "full";
  return me.harness_connected === false ? "harness" : null;
}

export function needsWizard(me: { onboarded_at?: string; harness_connected?: boolean } | undefined): boolean {
  return wizardMode(me) !== null;
}

/** How far the progress bar is filled, 0–1: a step counts once it is finished. */
export function setupProgress(step: WizardStep): number {
  return Math.max(0, Math.min(step - 1, 3)) / 3;
}

export function rowState(row: number, step: WizardStep): "done" | "current" | "todo" {
  if (row < step - 1) return "done";
  return row === step - 1 ? "current" : "todo";
}

/** "Good morning" before noon, "Good afternoon" until six, then "Good evening". */
export function greeting(hour: number): string {
  if (hour >= 5 && hour < 12) return "Good morning";
  if (hour >= 12 && hour < 18) return "Good afternoon";
  return "Good evening";
}

/** What the Assistant says above each step's card. */
export function assistantLine(step: WizardStep, hour: number): string {
  switch (step) {
    case 0:
      return `${greeting(hour)}. I’m your Assistant. Let’s get Vesper ready for you; it takes about a minute.`;
    case 1:
      return "First, how should I address you, and what do you do? Every persona will know this from the first message.";
    case 2:
      return "Next, I need a mind to run on. Connect Claude Code, Codex, Antigravity or any mix.";
    case 3:
      return "Lastly, who else would you like to talk to? Describe them in your own words and I’ll draft them.";
    default:
      return "";
  }
}

/** The photo circle's letter: the name's first, live as it is typed. */
export function initialOf(name: string): string {
  return name.trim().slice(0, 1).toUpperCase() || "?";
}

/** The first-boot placeholder name isn't worth prefilling. */
export function prefillName(name: string | undefined): string {
  return !name || name === "Local user" ? "" : name;
}

export type HarnessId = "claude-code" | "codex" | "antigravity";
export type CredentialKind = "subscription" | "api_key";

export type HarnessCard = {
  id: HarnessId;
  label: string;
  /** Who runs it and how it signs in, under the name. */
  by: string;
  /** Makes images (a badge on the card). */
  images?: boolean;
  /** Native sign-in only (no API key). */
  subscriptionOnly?: boolean;
};

export const HARNESS_CARDS: HarnessCard[] = [
  { id: "claude-code", label: "Claude Code", by: "Anthropic · subscription or API key" },
  { id: "codex", label: "Codex", by: "OpenAI · subscription or API key", images: true },
  { id: "antigravity", label: "Antigravity", by: "Google · Antigravity sign-in", images: true, subscriptionOnly: true },
];

/** The secret each harness's credential is stored under (chatmodels.KeySecret). */
export const HARNESS_SECRETS: Record<HarnessId, string> = { "claude-code": "harness:anthropic", codex: "harness:openai", antigravity: "harness:google" };

/** Harnesses that can make images. */
export const IMAGE_HARNESSES: readonly HarnessId[] = ["codex", "antigravity"];

/** The shapes runner/prepare.go recognises: .credentials.json / setup-token, auth.json, or Antigravity login, else an API key. */
export function credentialPlaceholder(h: HarnessId, kind: CredentialKind): string {
  if (h === "antigravity") return "Paste Antigravity login";
  if (h === "codex") return kind === "subscription" ? "Paste auth.json" : "OPENAI_API_KEY";
  return kind === "subscription" ? "Paste .credentials.json or setup-token" : "ANTHROPIC_API_KEY";
}

export function credentialHelp(h: HarnessId, kind: CredentialKind): string {
  if (h === "antigravity") return "Sign in to Google (Antigravity) in Settings → Connections, or paste a saved Antigravity login.";
  if (h === "codex") return kind === "subscription" ? "The contents of ~/.codex/auth.json after `codex login`." : "An OpenAI API key (sk-…).";
  return kind === "subscription" ? "The contents of ~/.claude/.credentials.json from `claude auth login --claudeai` (or an sk-ant-oat… setup-token)." : "An Anthropic API key (sk-ant-…).";
}

/** The harness step's hint: what is still missing. */
/** The harness the setup chat runs on: Claude Code when it is connected, else the other. */
export function setupHarness(verified: readonly HarnessId[]): HarnessId | undefined {
  return verified.includes("claude-code") ? "claude-code" : verified[0];
}

export function harnessHint(verified: readonly HarnessId[]): string {
  if (!verified.length) return "Connect at least one to continue.";
  return verified.some((h) => IMAGE_HARNESSES.includes(h)) ? "" : "Image generation stays off until Codex or Antigravity is connected.";
}

export const PERSONA_EXAMPLES = ["A blunt senior engineer who pairs with me", "A dry-witted D&D dungeon master", "A calm health coach"];

/**
 * The hidden setup chat's messages. "(Vesper setup)" marks them for the fake
 * harness (server/cmd/fake-harness), which proposes a persona in reply.
 */
export function draftPrompt(description: string): string {
  return (
    `(Vesper setup) I’m setting up Vesper and would like a new persona to talk to. In my words: "${description.trim()}"\n\n` +
    "Call propose_persona once now with a short, memorable name, a fitting tone and colour, instructions written to it in the second person " +
    "(three or four short sentences on how it works and what it focuses on) and a one-sentence reason. Give it a profile picture with " +
    "avatar_prompt only if you can make images. Then reply with one short sentence."
  );
}

export function refinePrompt(change: string): string {
  return `(Vesper setup) Change the draft: "${change.trim()}"\n\nCall propose_persona again with the whole updated persona, then reply with one short sentence.`;
}

/** Up to three bullets from a persona's instructions: its sentences, without the leading "You". */
export function draftBullets(instructions: string): string[] {
  return instructions
    .split(/(?<=[.!?])\s+|\n+/)
    .map((s) => s.trim().replace(/^[-*•]\s*/, "").replace(/[.!]$/, ""))
    .filter(Boolean)
    .map((s) => s.replace(/^you\s+/i, ""))
    .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
    .slice(0, 3);
}
