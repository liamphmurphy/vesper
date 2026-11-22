import type { components } from "./api/schema";

export type MediaCapability = components["schemas"]["MediaCapability"];
export type MediaFieldSpec = components["schemas"]["MediaFieldSpec"];
export type MediaProvider = components["schemas"]["MediaProvider"];
export type MediaProvidersResponse = components["schemas"]["MediaProvidersResponse"];

/** Merges field defaults, saved settings, and unsaved draft edits. */
export function effectiveSettings(
  provider: Pick<MediaProvider, "fields" | "settings">,
  draftSettings: Record<string, string> = {},
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of provider.fields) {
    if (f.kind === "secret") continue;
    if (f.default !== undefined && f.default !== "") out[f.key] = f.default;
  }
  for (const [k, v] of Object.entries(provider.settings ?? {})) {
    out[k] = v;
  }
  for (const [k, v] of Object.entries(draftSettings)) {
    out[k] = v;
  }
  return out;
}

/** True when every key in field.show_when matches the effective setting value. */
export function isFieldVisible(field: Pick<MediaFieldSpec, "show_when">, settings: Record<string, string>): boolean {
  if (!field.show_when) return true;
  for (const [k, expected] of Object.entries(field.show_when)) {
    if ((settings[k] ?? "") !== expected) return false;
  }
  return true;
}

export function musicProviders(data?: MediaProvidersResponse): MediaProvider[] {
  if (!data) return [];
  return data.providers.filter((p) => p.capabilities.includes("music"));
}

/** Resolved active music provider: workspace default when ready, else first available provider. */
export function activeMusicProvider(data?: MediaProvidersResponse): MediaProvider | null {
  const list = musicProviders(data);
  const defId = data?.defaults?.music;
  if (defId) {
    const chosen = list.find((p) => p.id === defId && p.available && p.enabled && !p.coming_soon);
    if (chosen) return chosen;
  }
  return list.find((p) => p.available && p.enabled && !p.coming_soon) ?? null;
}

export function providerStatus(p: Pick<MediaProvider, "coming_soon" | "enabled" | "available">): {
  tone: "ready" | "needs-setup" | "soon" | "disabled";
  label: string;
} {
  if (p.coming_soon) return { tone: "soon", label: "Coming soon" };
  if (!p.enabled) return { tone: "disabled", label: "Disabled" };
  if (p.available) return { tone: "ready", label: "Connected" };
  return { tone: "needs-setup", label: "Not configured" };
}

/** Builds a PUT /media/providers/{id} payload, sending secrets only when non-empty. */
export function buildProviderPatch(
  provider: Pick<MediaProvider, "fields" | "settings">,
  draftSettings: Record<string, string>,
  draftSecrets: Record<string, string>,
): { settings: Record<string, string>; secrets?: Record<string, string> } {
  const merged = effectiveSettings(provider, draftSettings);
  const settings: Record<string, string> = {};
  for (const f of provider.fields) {
    if (f.kind === "secret") continue;
    if (f.key in merged) settings[f.key] = merged[f.key];
  }
  const secrets: Record<string, string> = {};
  let hasSecret = false;
  for (const f of provider.fields) {
    if (f.kind !== "secret") continue;
    const raw = (draftSecrets[f.key] ?? "").trim();
    if (raw) {
      secrets[f.key] = raw;
      hasSecret = true;
    }
  }
  return hasSecret ? { settings, secrets } : { settings };
}
