import assert from "node:assert/strict";
import test from "node:test";
import { CHAT_COMMANDS, CREATE_KINDS, SHOW_LIVE_THINKING_KEY, commandMenu, designRequest, literalBody, parseCommand, readShowLiveThinking, resolveCompareTarget, resolveThinkingToggle, writeShowLiveThinking } from "./chat-commands.ts";

test("parseCommand reads a one-line /command and its argument", () => {
  assert.deepEqual(parseCommand("/stop"), { name: "stop", arg: "" });
  assert.deepEqual(parseCommand("/Persona  Bea Arthur \n"), { name: "persona", arg: "Bea Arthur" });
});

test("parseCommand leaves ordinary text alone", () => {
  assert.equal(parseCommand("/usr/bin is missing"), null);
  assert.equal(parseCommand("see /stop"), null);
  assert.equal(parseCommand("/stop\nand more"), null);
  assert.equal(parseCommand("//stop"), null);
  assert.equal(parseCommand("/"), null);
});

test("literalBody drops the escaping slash only", () => {
  assert.equal(literalBody("//stop"), "/stop");
  assert.equal(literalBody("/stop"), "/stop");
  assert.equal(literalBody("hello // there"), "hello // there");
});

test("commandMenu offers names, then arguments of commands that take one", () => {
  assert.deepEqual(commandMenu("/"), { stage: "command", query: "" });
  assert.deepEqual(commandMenu("/mo"), { stage: "command", query: "mo" });
  assert.deepEqual(commandMenu("/model "), { stage: "arg", name: "model", query: "" });
  assert.deepEqual(commandMenu("/MODEL op"), { stage: "arg", name: "model", query: "op" });
  assert.equal(commandMenu("/stop "), null);
  assert.equal(commandMenu("/nope x"), null);
  assert.equal(commandMenu("//"), null);
  assert.equal(commandMenu("/usr/bin"), null);
  assert.equal(commandMenu("hello"), null);
});

test("/workflow takes a workflow to pick", () => {
  assert.deepEqual(commandMenu("/workflow "), { stage: "arg", name: "workflow", query: "" });
  assert.deepEqual(parseCommand("/workflow Research to wiki"), { name: "workflow", arg: "Research to wiki" });
});

test("/aside, /queue, and /steer take free text, with nothing to pick", () => {
  assert.equal(commandMenu("/aside how far along?"), null);
  assert.equal(commandMenu("/queue "), null);
  assert.equal(commandMenu("/steer switch to sqlite"), null);
  assert.deepEqual(commandMenu("/as"), { stage: "command", query: "as" });
  assert.deepEqual(commandMenu("/st"), { stage: "command", query: "st" });
  assert.deepEqual(parseCommand("/aside how far along?"), { name: "aside", arg: "how far along?" });
  assert.deepEqual(parseCommand("/steer switch to sqlite"), { name: "steer", arg: "switch to sqlite" });
});

test("/design takes what to design as free text and asks the persona for a design", () => {
  assert.equal(commandMenu("/design onboarding flow"), null);
  assert.deepEqual(commandMenu("/des"), { stage: "command", query: "des" });
  assert.deepEqual(parseCommand("/design  sketch onboarding "), { name: "design", arg: "sketch onboarding" });
  assert.ok(CHAT_COMMANDS.find((c) => c.name === "design")?.free);
  assert.equal(designRequest(" sketch onboarding "), "Create a design: sketch onboarding");
  assert.deepEqual(CREATE_KINDS.map((k) => k.label), ["Doc", "Slides", "Design", "Music"]);
  assert.equal(CREATE_KINDS.find((k) => k.kind === "design")?.command, "/design");
  assert.equal(CREATE_KINDS.find((k) => k.kind === "music")?.command, "/music");
  assert.deepEqual(parseCommand("/music lo-fi rainy beats"), { name: "music", arg: "lo-fi rainy beats" });
});

test("/compare offers model completion until a space separates an optional question", () => {
  assert.deepEqual(commandMenu("/comp"), { stage: "command", query: "comp" });
  assert.deepEqual(commandMenu("/compare "), { stage: "arg", name: "compare", query: "" });
  assert.deepEqual(commandMenu("/compare cod"), { stage: "arg", name: "compare", query: "cod" });
  assert.equal(commandMenu("/compare codex check for race conditions"), null);
  assert.deepEqual(parseCommand("/compare codex check for race conditions"), {
    name: "compare",
    arg: "codex check for race conditions",
  });
});

test("resolveCompareTarget matches harness names, model ids, labels, and optional focus prompts", () => {
  const options = [
    { name: "Codex · gpt-5-codex", harness: "codex", harnessLabel: "Codex", model: "gpt-5-codex", modelLabel: "gpt-5-codex", isDefault: true },
    { name: "Codex · gpt-5-mini", harness: "codex", harnessLabel: "Codex", model: "gpt-5-mini", modelLabel: "gpt-5-mini", isDefault: false },
    { name: "Claude Code · Sonnet 5.5", harness: "claude-code", harnessLabel: "Claude Code", model: "sonnet-5.5", modelLabel: "Sonnet 5.5", isDefault: false },
  ];
  assert.deepEqual(resolveCompareTarget(options, "codex"), { option: options[0], question: "" });
  assert.deepEqual(resolveCompareTarget(options, "codex check race conditions"), {
    option: options[0],
    question: "check race conditions",
  });
  assert.deepEqual(resolveCompareTarget(options, "gpt-5-mini focus on perf"), {
    option: options[1],
    question: "focus on perf",
  });
  assert.deepEqual(resolveCompareTarget(options, "Sonnet 5.5 review the SQL"), {
    option: options[2],
    question: "review the SQL",
  });
  assert.deepEqual(resolveCompareTarget(options, ""), {
    error: "Say which model: /compare <model> [question]",
  });
  assert.deepEqual(resolveCompareTarget(options, "unknown-model hi"), {
    error: "No model matches “unknown-model”.",
  });
});

test("compact parses with or without focus and leaves argument menu closed", () => {
  assert.deepEqual(parseCommand("/compact"), { name: "compact", arg: "" });
  assert.deepEqual(parseCommand("/compact keep auth invariants"), {
    name: "compact",
    arg: "keep auth invariants",
  });
  assert.equal(commandMenu("/compact "), null);
  assert.equal(commandMenu("/compact keep"), null);
});

test("/thinking offers on/off completions, resolves toggle/on/off, and persists preference with default false", () => {
  assert.deepEqual(commandMenu("/th"), { stage: "command", query: "th" });
  assert.deepEqual(commandMenu("/thinking "), { stage: "arg", name: "thinking", query: "" });
  assert.deepEqual(commandMenu("/thinking o"), { stage: "arg", name: "thinking", query: "o" });
  assert.deepEqual(parseCommand("/thinking"), { name: "thinking", arg: "" });
  assert.deepEqual(parseCommand("/thinking on"), { name: "thinking", arg: "on" });
  assert.deepEqual(parseCommand("/thinking OFF"), { name: "thinking", arg: "OFF" });

  assert.deepEqual(resolveThinkingToggle("", false), { next: true });
  assert.deepEqual(resolveThinkingToggle("", true), { next: false });
  assert.deepEqual(resolveThinkingToggle("on", false), { next: true });
  assert.deepEqual(resolveThinkingToggle("off", true), { next: false });
  assert.deepEqual(resolveThinkingToggle("bogus", false), { error: "Usage: /thinking [on|off]" });

  const map = new Map();
  const storage = {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => { map.set(k, v); },
  };
  assert.equal(readShowLiveThinking(storage), false);
  writeShowLiveThinking(true, storage);
  assert.equal(map.get(SHOW_LIVE_THINKING_KEY), "true");
  assert.equal(readShowLiveThinking(storage), true);
  writeShowLiveThinking(false, storage);
  assert.equal(readShowLiveThinking(storage), false);
});
