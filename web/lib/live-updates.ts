// Which cached queries a server change hint (/events) makes stale. Each hint's
// type is "entity.verb"; the entity picks the query key prefixes to refetch.

const prefixes: Record<string, string[]> = {
  planning: ["planning", "inbox", "bootstrap"],
  metrics: ["dashboard", "agent-overviews"],
  ticket: ["planning", "tickets", "boards", "inbox", "bootstrap", "knowledge", "search"],
  epic: ["projects", "planning", "bootstrap", "tickets", "boards", "epics", "inbox", "search"],
  activity: ["tickets", "inbox", "bootstrap"],
  approval: ["tickets", "runs", "chats", "inbox", "bootstrap"],
  // "dock" is the activity orb: which harnesses are running.
  run: ["planning", "runs", "boards", "tickets", "agents", "inbox", "bootstrap", "runner", "search", "dock"],
  agent: ["agents", "bootstrap", "search"],
  artifact: ["artifacts", "wiki", "knowledge", "inbox", "bootstrap", "search"],
  knowledge: ["knowledge", "wiki"],
  project: ["projects", "planning", "bootstrap", "tickets", "boards", "inbox", "search"],
  inbox: ["inbox", "bootstrap"],
  chat: ["chats", "canvases", "videos", "audio", "push-requests", "dock"],
  // A persona's patch on a design (applied with direct edit, or held as a suggestion) and its
  // settings, mid-turn: chat.* only fires when the turn's messages land, which is too late.
  design: ["canvases"],
  // A chat video's progress, copied every couple of seconds while it renders.
  video: ["videos"],
  // The same for a chat's audio.
  audio: ["audio"],
  // A chat's playground starting, resetting or stopping on the runner.
  playground: ["playgrounds"],
  // A coding chat's Code dock, refreshed while a turn edits the workspace.
  code_review: ["code-review"],
  // A persona's push request staged, approved, pushed or failed.
  push_request: ["push-requests"],
  // PR check runs and unresolved review threads synced from GitHub.
  pr_feedback: ["tickets", "push-requests", "inbox", "bootstrap"],
  // A persona edit changes the name, color and avatar every chat using it embeds.
  persona: ["personas", "chats", "dock"],
  // A Safari tab shared with a chat: started, re-snapshotted, read by a persona or stopped.
  browser_share: ["browser-shares"],
  // User-built custom apps refresh their launcher and active editor state.
  custom_app: ["custom-apps"],
};

/** The query key prefixes a change hint of this type invalidates. */
export function invalidatedBy(type: string): string[] {
  if (type === "run.events") return ["runs"];
  const keys = prefixes[type.split(".")[0]] ?? [];
  const quiet = ["video.updated", "audio.updated", "code_review.updated", "push_request.updated", "pr_feedback.updated", "custom_app.updated", "browser_share.updated"];
  return quiet.includes(type) ? keys : [...keys, "dashboard", "epics", "agent-overviews"];
}

/** Specific React Query keys invalidated by an SSE change hint (scopes `run.events` to listed run IDs). */
export function invalidatedKeys(msg: { type?: unknown; ids?: unknown }): (readonly unknown[])[] {
  if (typeof msg.type !== "string" || !msg.type) return [];
  if (msg.type === "run.events") {
    const ids = Array.isArray(msg.ids) ? msg.ids.filter((id): id is string => typeof id === "string" && id.length > 0) : [];
    if (ids.length === 0) return [["runs"]];
    return ids.flatMap((id) => [["runs", id], ["runs", "chat", id]] as const);
  }
  return invalidatedBy(msg.type).map((k) => [k]);
}
