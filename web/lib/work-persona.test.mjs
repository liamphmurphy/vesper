import assert from "node:assert/strict";
import test from "node:test";
import { matchWorkPersona, personaNavAvatar, runCharacterState } from "./work-persona.ts";
import { agentAvatarColor } from "./native-shell/models/common.ts";

const personas = [
  { id: "p-meow", name: "Meow", handle: "meow", color: "#5b8af5", avatar_url: "/api/v1/personas/p-meow/avatar", character_svg: "<svg/>" },
  { id: "p-ada", name: "Ada", handle: "tech-lead", color: "#34d399", avatar_url: null, character_svg: null },
];

test("matchWorkPersona resolves by exact UUID, handle fallback, then case-insensitive name", () => {
  assert.equal(matchWorkPersona(personas, { id: "p-meow", handle: "other", name: "Other" })?.id, "p-meow");
  assert.equal(matchWorkPersona(personas, { id: "agent-old", handle: "tech-lead", name: "tech-lead" })?.id, "p-ada");
  assert.equal(matchWorkPersona(personas, { id: "agent-old", handle: "p-ada", name: "Ada" })?.id, "p-ada");
  assert.equal(matchWorkPersona(personas, { id: "agent-old", handle: "other", name: " meow " })?.id, "p-meow");
  assert.equal(matchWorkPersona(personas, { id: "unknown", handle: "ghost", name: "Ghost" }), undefined);
  assert.equal(matchWorkPersona(undefined, { id: "p-meow", name: "Meow" }), undefined);
});

test("personaNavAvatar uses matched persona color and origin-resolved imageUrl, falling back to color_index", () => {
  assert.deepEqual(
    personaNavAvatar(personas, { id: "p-meow", name: "Meow", color_index: 2 }, "https://vesper.local"),
    { initials: "M", color: "#5b8af5", imageUrl: "https://vesper.local/api/v1/personas/p-meow/avatar" },
  );
  assert.deepEqual(
    personaNavAvatar(personas, { id: "p-ada", name: "Ada", color_index: 1 }, "https://vesper.local"),
    { initials: "A", color: "#34d399" },
  );
  assert.deepEqual(
    personaNavAvatar(personas, { id: "legacy", name: "Builder", color_index: 0 }),
    { initials: "B", color: agentAvatarColor(0) },
  );
});

test("runCharacterState maps live and waiting run states to character animations", () => {
  assert.equal(runCharacterState({ state: "running" }), "coding");
  assert.equal(runCharacterState({ state: "waiting" }), "needs_you");
  assert.equal(runCharacterState({ state: "paused" }), "needs_you");
  assert.equal(runCharacterState({ state: "queued" }), "thinking");
  assert.equal(runCharacterState({ state: "starting" }), "thinking");
  assert.equal(runCharacterState({ state: "completed" }), "static");
  assert.equal(runCharacterState({ state: "failed" }), "static");
  assert.equal(runCharacterState({ state: "cancelled" }), "static");
});
