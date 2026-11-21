import assert from "node:assert/strict";
import { test } from "node:test";
import {
  activeMusicProvider,
  buildProviderPatch,
  effectiveSettings,
  isFieldVisible,
  musicProviders,
  providerStatus,
} from "./media-providers.ts";

const geminiFixture = {
  id: "gemini",
  label: "Gemini (Lyria)",
  description: "Lyria 3 music generation via AI Studio or Vertex AI.",
  capabilities: ["music"],
  coming_soon: false,
  enabled: true,
  available: false,
  unavailable_reason: "Add a Gemini API key in Settings → Workspace → Media providers.",
  fields: [
    {
      key: "backend",
      label: "Backend",
      kind: "segmented",
      default: "gemini_api",
      options: [
        { value: "gemini_api", label: "Gemini API" },
        { value: "vertex_ai", label: "Vertex AI" },
      ],
    },
    {
      key: "api_key",
      label: "API Key",
      kind: "secret",
      required: true,
      show_when: { backend: "gemini_api" },
    },
    {
      key: "project",
      label: "GCP Project ID",
      kind: "text",
      required: true,
      show_when: { backend: "vertex_ai" },
    },
    {
      key: "location",
      label: "GCP Location",
      kind: "text",
      required: true,
      default: "us-central1",
      show_when: { backend: "vertex_ai" },
    },
    {
      key: "model",
      label: "Model",
      kind: "select",
      default: "auto",
      options: [{ value: "auto", label: "Auto" }],
    },
  ],
  settings: {},
  secrets_set: {},
};

const mlxFixture = {
  id: "local-mlx",
  label: "Local MLX Audio",
  capabilities: ["music", "tts"],
  coming_soon: true,
  enabled: false,
  available: false,
  unavailable_reason: "Coming soon on Apple Silicon.",
  fields: [],
  settings: {},
  secrets_set: {},
};

test("effectiveSettings & isFieldVisible toggle conditional fields by backend", () => {
  const apiSettings = effectiveSettings(geminiFixture, {});
  assert.equal(apiSettings.backend, "gemini_api");
  assert.equal(apiSettings.location, "us-central1");
  assert.equal(isFieldVisible(geminiFixture.fields[1], apiSettings), true);
  assert.equal(isFieldVisible(geminiFixture.fields[2], apiSettings), false);

  const vertexSettings = effectiveSettings(geminiFixture, { backend: "vertex_ai", project: "my-proj" });
  assert.equal(isFieldVisible(geminiFixture.fields[1], vertexSettings), false);
  assert.equal(isFieldVisible(geminiFixture.fields[2], vertexSettings), true);
  assert.equal(isFieldVisible(geminiFixture.fields[3], vertexSettings), true);
});

test("musicProviders & activeMusicProvider resolve defaults safely", () => {
  assert.equal(activeMusicProvider({ providers: [geminiFixture, mlxFixture], defaults: {} }), null);

  const readyGemini = { ...geminiFixture, available: true, unavailable_reason: undefined };
  const active = activeMusicProvider({
    providers: [readyGemini, mlxFixture],
    defaults: { music: "local-mlx" },
  });
  // Falls back to readyGemini when default points to unavailable/coming-soon provider.
  assert.equal(active?.id, "gemini");
  assert.deepEqual(musicProviders({ providers: [readyGemini, mlxFixture], defaults: {} }).map((p) => p.id), ["gemini", "local-mlx"]);
});

test("providerStatus & buildProviderPatch omit empty secrets", () => {
  assert.deepEqual(providerStatus(geminiFixture), { tone: "needs-setup", label: "Not configured" });
  assert.deepEqual(providerStatus({ ...geminiFixture, available: true }), { tone: "ready", label: "Connected" });
  assert.deepEqual(providerStatus(mlxFixture), { tone: "soon", label: "Coming soon" });
  assert.deepEqual(providerStatus({ coming_soon: false, enabled: false, available: false }), { tone: "disabled", label: "Disabled" });

  const noSecretPatch = buildProviderPatch(geminiFixture, { backend: "vertex_ai", project: "demo" }, { api_key: "   " });
  assert.equal("secrets" in noSecretPatch, false);
  assert.equal(noSecretPatch.settings.backend, "vertex_ai");
  assert.equal(noSecretPatch.settings.project, "demo");

  const withSecretPatch = buildProviderPatch(geminiFixture, {}, { api_key: " AIza-test-123 " });
  assert.deepEqual(withSecretPatch.secrets, { api_key: "AIza-test-123" });
});
