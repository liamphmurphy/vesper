import test from "node:test";
import assert from "node:assert/strict";
import {
  AUDIO_STAGES,
  MUSIC_STAGES,
  audioRetryRequest,
  audioStageStates,
  musicErrorCopy,
  nextSpeed,
  placeStandaloneAudio,
  skip,
  waveBars,
} from "./chat-audio.ts";

test("the stages read done before the job's stage, active at it, pending after", () => {
  assert.deepEqual(audioStageStates({ stage: "render", state: "running" }), ["done", "active", "pending", "pending"]);
  assert.deepEqual(audioStageStates({ stage: "save", state: "running" }), ["done", "done", "done", "active"]);
  assert.deepEqual(audioStageStates({ stage: "check", state: "failed" }), ["done", "done", "failed", "pending"]);
  assert.deepEqual(audioStageStates({ stage: "save", state: "done" }), ["done", "done", "done", "done"]);
  assert.equal(AUDIO_STAGES.length, 4);
});

test("waveBars draws the server's peaks, resampled, and a flat line without them", () => {
  assert.deepEqual(waveBars(undefined, 4), [0.08, 0.08, 0.08, 0.08]);
  assert.deepEqual(waveBars([], 2), [0.08, 0.08]);
  assert.deepEqual(waveBars([0, 255, 0, 255], 4), [0.08, 1, 0.08, 1]);
  // Fewer bars than peaks: each bar takes the loudest peak it covers.
  assert.deepEqual(waveBars([10, 255, 0, 51], 2), [1, 51 / 255]);
  // More bars than peaks: each peak repeats.
  assert.deepEqual(waveBars([255, 0], 4), [1, 1, 0.08, 0.08]);
  assert.equal(waveBars(new Array(64).fill(128)).length, 64);
});

test("speed cycles and wraps; skipping stays inside the clip", () => {
  assert.equal(nextSpeed(1), 1.25);
  assert.equal(nextSpeed(2), 0.75);
  assert.equal(nextSpeed(3), 0.75, "an unknown rate starts over");
  assert.equal(skip(5, 10, 12), 12);
  assert.equal(skip(5, -10, 12), 0);
  assert.equal(skip(5, 3, 12), 8);
  assert.equal(skip(5, 3, 0), 0, "an unknown length keeps it at the start");
});

test("Retry names the audio and the step it stopped at", () => {
  assert.equal(audioRetryRequest({ title: "Riff", stage: "render" }), 'Retry the audio "Riff" from the render step.');
  assert.equal(audioRetryRequest({ title: "Riff", stage: "check" }), 'Retry the audio "Riff" from the mix check step.');
});

test("music audio uses 3 stages, places standalone jobs chronologically, and classifies errors", () => {
  assert.equal(MUSIC_STAGES.length, 3);
  assert.deepEqual(audioStageStates({ source_kind: "music", stage: "render", state: "running" }), ["done", "active", "pending"]);
  assert.deepEqual(audioStageStates({ source_kind: "music", stage: "save", state: "done" }), ["done", "done", "done"]);
  assert.deepEqual(audioStageStates({ source_kind: "music", stage: "render", state: "failed" }), ["done", "failed", "pending"]);

  const messages = [
    { id: "m1", created_at: "2026-11-21T10:00:00Z" },
    { id: "m2", created_at: "2026-11-21T10:05:00Z" },
  ];
  const base = {
    title: "T",
    duration_ms: 30000,
    method: "Gemini (Lyria)",
    stage: "save",
    state: "done",
    checks: [],
    percent: 100,
    updated_at: "2026-11-21T10:01:00Z",
    source_kind: "music",
  };
  const placed = placeStandaloneAudio(
    [
      { ...base, id: "a0", created_at: "2026-11-21T09:59:00Z" },
      { ...base, id: "a1", created_at: "2026-11-21T10:02:00Z" },
      { ...base, id: "a2", created_at: "2026-11-21T10:06:00Z" },
      { ...base, id: "linked", message_id: "m2", created_at: "2026-11-21T10:03:00Z" },
      { ...base, id: "live", run_id: "r1", state: "running", created_at: "2026-11-21T10:07:00Z" },
    ],
    messages,
    { running: true, currentRunId: "r1" },
  );
  assert.equal(placed.total, 3);
  assert.deepEqual(placed.leading.map((a) => a.id), ["a0"]);
  assert.deepEqual(placed.afterMessage.get("m1")?.map((a) => a.id), ["a1"]);
  assert.deepEqual(placed.trailing.map((a) => a.id), ["a2"]);

  assert.equal(musicErrorCopy({ error_kind: "quota" }).showSettingsLink, true);
  assert.equal(musicErrorCopy({ error_kind: "auth" }).title, "API key rejected");
  assert.equal(musicErrorCopy({ error_kind: "filtered" }).actionLabel, "Edit prompt");
  assert.equal(musicErrorCopy({ failure_kind: "stopped" }).title, "Stopped");
});
