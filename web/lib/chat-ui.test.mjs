import test from "node:test";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { connectorCall, activityOf, bareTool, chatStatus, chatCalls, chatStatusOf, chatSteps, stepDetail, chatTitle, foldSteps, formatSpan, NEXT_STEP_AFTER_MS, NEXT_STEP_KEY, QUIET_AFTER_MS, QUIET_RUNNING_MS, quietFor, turnActivity, turnClock, turnPulse, interimLine, intentOf, linkLabel, needsSwitchConfirm, replyCost, runningSince, toolCalls, turnNotes, turnTrace, turnWindows, finishedTurn, endedTurns, groupByDay, catalogModelLabel, readableModelId, rowMark } from "./chat-ui.ts";

test("rowMark shows an unread dot until the chat is read or opened, and running wins", () => {
  assert.equal(rowMark({ state: "idle", unread: 0 }), null);
  assert.equal(rowMark({ state: "idle", unread: 2 }), "unread");
  // Reading it (unread back to 0) or opening it clears the dot.
  assert.equal(rowMark({ state: "idle", unread: 0 }), null);
  assert.equal(rowMark({ state: "idle", unread: 2 }, true), null);
  assert.equal(rowMark({ state: "running", unread: 2 }), "running");
  assert.equal(rowMark({ state: "running", unread: 0 }, true), "running");
  assert.equal(rowMark({ state: "failed" }), null);
});

test("tool calls pair with results and skip events before the turn", () => {
  const events = [
    { seq: 1, type: "tool_call", at: "2026-11-06T10:00:00Z", payload: { id: "old", tool: "whoami" } },
    { seq: 2, type: "tool_call", at: "2026-11-06T10:01:00Z", payload: { id: "x", tool: "read_page", input: { ref: "Plan" } } },
    { seq: 3, type: "tool_result", at: "2026-11-06T10:01:01Z", payload: { id: "x" } },
    { seq: 4, type: "tool_call", at: "2026-11-06T10:01:02Z", payload: { id: "y", tool: "get_ticket", input: { ticket: "WEB-3" } } },
  ];
  assert.deepEqual(toolCalls(events, "2026-11-06T10:00:30Z"), [
    { key: 2, tool: "read_page", input: { ref: "Plan" }, done: true },
    { key: 4, tool: "get_ticket", input: { ticket: "WEB-3" }, done: false },
  ]);
  assert.equal(toolCalls(undefined).length, 0);
  // `until` (the next user message) closes the turn.
  assert.deepEqual(toolCalls(events, "2026-11-06T10:00:30Z", "2026-11-06T10:01:01.500Z").map((c) => c.key), [2]);
});

test("MCP tool names lose the lazyagents prefix from either harness", () => {
  assert.equal(bareTool("mcp__lazyagents__read_page"), "read_page");
  assert.equal(bareTool("lazyagents.read_page"), "read_page");
  assert.equal(bareTool("lazyagents_read_page"), "read_page");
  assert.equal(bareTool("read_page"), "read_page");
  assert.equal(bareTool("mcp__github__get_issue"), "github.get_issue");
});

test("the live line names the page, ticket or query being used", () => {
  assert.deepEqual(activityOf({ tool: "mcp__lazyagents__read_page", input: { ref: "Architecture/ADR - Project chat sessions" } }), {
    verb: "Reading", ref: "Architecture/ADR - Project chat sessions", label: "ADR - Project chat sessions",
  });
  assert.deepEqual(activityOf({ tool: "read_page", input: { ref: "[[ADR-012]]" } }), { verb: "Reading", ref: "ADR-012", label: "ADR-012" });
  assert.deepEqual(activityOf({ tool: "read_artifact", input: { artifact: "ADR-012", section: "risks" } }), {
    verb: "Reading", ref: "ADR-012#risks", label: "ADR-012 › risks",
  });
  assert.deepEqual(activityOf({ tool: "read_artifact", input: { artifact: "01a1b4ab-1853-7647-8534-85c284cec5ec" } }), { verb: "Reading an artifact" });
  assert.deepEqual(activityOf({ tool: "get_ticket", input: { ticket: "LAZYAGENTS-12" } }), { verb: "Opening", ref: "LAZYAGENTS-12", label: "LAZYAGENTS-12" });
  assert.deepEqual(activityOf({ tool: "search_knowledge", input: { q: "harness switch" } }), { verb: "Searching", text: "“harness switch”" });
  assert.deepEqual(activityOf({ tool: "read_page", input: {} }), { verb: "Reading a page" });
  assert.deepEqual(activityOf({ tool: "shell", input: { command: "ls" } }), { verb: "Running a command" });
  assert.deepEqual(activityOf({ tool: "mcp__github__get_issue", input: null }), { verb: "Using Github:", text: "get_issue" });
});

test("link labels drop folders and keep the section", () => {
  assert.equal(linkLabel("Eng/Ledger/Runbook"), "Runbook");
  assert.equal(linkLabel("Runbook#rollback"), "Runbook › rollback");
  assert.equal(linkLabel("#rollback"), "rollback");
});

test("only a harness change on a chat with messages asks first", () => {
  const claude = { harness: "claude-code" };
  const codex = { harness: "codex" };
  assert.equal(needsSwitchConfirm(claude, codex, null, 3), true);
  assert.equal(needsSwitchConfirm(claude, { harness: "claude-code" }, null, 3), false, "same harness, new model");
  assert.equal(needsSwitchConfirm(claude, codex, null, 0), false, "nothing to lose yet");
  assert.equal(needsSwitchConfirm(claude, codex, codex, 3), false, "already confirmed for codex");
  assert.equal(needsSwitchConfirm(claude, { harness: "other" }, codex, 3), true);
});

test("reply cost keeps small turns visible and never shows unknown as free", () => {
  assert.equal(replyCost(0.0421), "$0.042");
  assert.equal(replyCost(1.5), "$1.50");
  assert.equal(replyCost(0.0002), "< $0.001");
  assert.equal(replyCost(0), undefined);
  assert.equal(replyCost(undefined), undefined);
  assert.equal(replyCost(Number.NaN), undefined);
});

test("an empty chat title reads as New conversation", () => {
  assert.equal(chatTitle({ title: "" }), "New conversation");
  assert.equal(chatTitle({ title: "   " }), "New conversation");
  assert.equal(chatTitle({ title: "Roadmap" }), "Roadmap");
});

test("the chat status is high level and never leaks the call's details", () => {
  const cases = [
    [{ tool: "mcp__lazyagents__read_page", input: { ref: "Architecture/ADR - Secret" } }, "looking through the wiki"],
    [{ tool: "search_knowledge", input: { q: "payroll" } }, "looking through the wiki"],
    [{ tool: "create_ticket", input: { title: "x" } }, "drafting a ticket"],
    [{ tool: "save_memory", input: { body: "likes tea" } }, "making a note"],
    [{ tool: "image_gen", input: {} }, "creating an image"],
    [{ tool: "mcp__lazyagents__generate_image", input: { prompt: "a cat" } }, "creating an image"],
    [{ tool: "Grep", input: { pattern: "TODO" } }, "searching the code"],
    [{ tool: "apply_patch", input: { files: ["modify src/a.ts"] } }, "writing code"],
    [{ tool: "Bash", input: { command: "go test ./internal/..." } }, "running tests"],
    [{ tool: "shell", input: { command: "bash -lc 'npm run test:unit'" } }, "running tests"],
    [{ tool: "shell", input: { command: "git commit -m 'secret plan'" } }, "committing changes"],
    [{ tool: "Bash", input: { command: "git push -u origin vesper/ava-1234abcd" } }, "pushing its branch"],
    [{ tool: "Bash", input: { command: "gh pr create --fill" } }, "preparing a pull request"],
    [{ tool: "Bash", input: { command: "npm ci" } }, "installing dependencies"],
    [{ tool: "Bash", input: { command: "go vet ./..." } }, "checking the build"],
    [{ tool: "Bash", input: { command: "git status" } }, "looking over the repository"],
    [{ tool: "Bash", input: { command: "rg -n token src" } }, "searching the code"],
    [{ tool: "Bash", input: { command: "cat src/main.go" } }, "reading the code"],
    [{ tool: "WebFetch", input: { url: "https://example.com/private" } }, "reading a page"],
    [{ tool: "mcp__lazyagents__browser_snapshot", input: {} }, "reading the Safari tab you shared"],
    [{ tool: "exec_command", input: { cmd: "cp /h/.codex/generated_images/t/a.png .lazyagents/outbox/a.png" } }, "saving the image"],
    [{ tool: "Read", input: { file_path: "/w/.lazyagents/attachments/generated/turn-1/1-fox.png" } }, "looking at the image"],
    [{ tool: "Read", input: { file_path: "src/main.go" } }, "reading the code"],
    [{ tool: "Bash", input: { command: "python3 scripts/migrate.py" } }, "working in the terminal"],
    [{ tool: "mcp__lazyagents__canvas_patch", input: { body: "secret" } }, "revising a canvas"],
    [{ tool: "canvas_reply", input: { body: "secret" } }, "commenting on a canvas"],
    [{ tool: "mcp__lazyagents__start_playground", input: { env: { SECRETS_KEY: "secret" } } }, "spinning up a playground"],
    [{ tool: "stop_playground", input: {} }, "stopping the playground"],
    [{ tool: "propose_workflow_edit", input: { graph: "secret" } }, "sketching a workflow"],
    [{ tool: "get_video_transcript", input: { url: "https://example.com/private" } }, "watching a video"],
    [{ tool: "some.other_tool", input: { secret: "x" } }, "using Some"],
  ];
  for (const [call, want] of cases) assert.equal(chatStatusOf(call).phrase, want, call.tool);
  assert.deepEqual(chatStatus([]), { kind: "thinking", phrase: "thinking" });
  assert.deepEqual(chatStatus([{ tool: "Read", input: {} }, { tool: "Bash", input: { command: "go test ./..." } }]), { kind: "tests", phrase: "running tests" });
});

test("each tool call maps to the kind of scene it shows", () => {
  const bash = (command) => ({ tool: "Bash", input: { command } });
  const cases = [
    [{ tool: "mcp__lazyagents__read_page", input: {} }, "wiki"],
    [{ tool: "get_ticket", input: {} }, "ticket-lookup"],
    [{ tool: "list_epics", input: {} }, "ticket-lookup"],
    [{ tool: "update_ticket", input: {} }, "tickets"],
    [{ tool: "create_epic", input: {} }, "tickets"],
    [{ tool: "get_run", input: {} }, "runs"],
    [{ tool: "Read", input: { file_path: "src/a.go" } }, "reading-code"],
    [bash("rg -n token src"), "searching-code"],
    [bash("ls src | head"), "reading-code"],
    [{ tool: "Grep", input: {} }, "searching-code"],
    [{ tool: "WebSearch", input: {} }, "web"],
    [{ tool: "apply_patch", input: {} }, "writing-code"],
    [bash("go test ./..."), "tests"],
    [bash("npm run lint"), "build"],
    [bash("npm ci"), "install"],
    [{ tool: "WebFetch", input: {} }, "web-page"],
    [{ tool: "generate_image", input: {} }, "image"],
    [{ tool: "Read", input: { file_path: "/w/.lazyagents/attachments/generated/t/1.png" } }, "image-view"],
    [{ tool: "get_video_transcript", input: {} }, "video"],
    [{ tool: "canvas_create", input: {} }, "canvas"],
    [{ tool: "canvas_comment", input: {} }, "canvas-comment"],
    [{ tool: "mcp__lazyagents__design_flows", input: {} }, "design-view"],
    ...["design_create", "design_patch", "design_import", "design_comment", "design_reply", "design_link_ticket"].map((tool) => [{ tool: `mcp__lazyagents__${tool}`, input: {} }, "design"]),
    ...["design_list", "design_outline", "design_read", "design_render", "design_comments", "design_components", "design_tokens", "design_inspect"].map((tool) => [{ tool, input: {} }, "design-view"]),
    [{ tool: "mcp__lazyagents__start_playground", input: {} }, "playground"],
    [{ tool: "playground_status", input: {} }, "playground"],
    [{ tool: "read_workflow", input: {} }, "workflow"],
    [{ tool: "save_memory", input: {} }, "memory-save"],
    [{ tool: "search_memory", input: {} }, "memory"],
    [{ tool: "search_chats", input: { query: "secret" } }, "chat-history"],
    [{ tool: "mcp__lazyagents__read_chat", input: {} }, "chat-history"],
    [{ tool: "some.other_tool", input: {} }, "connector"],
    [{ tool: "", input: undefined }, "thinking"],
    [bash("python3 scripts/migrate.py"), "terminal"],
    [{ tool: "mcp__lazyagents__get_epic", input: {} }, "ticket-lookup"],
    [{ tool: "update_epic", input: {} }, "tickets"],
    [{ tool: "update_ticket_blockers", input: {} }, "tickets"],
    [{ tool: "reply_to_run", input: { text: "secret" } }, "runs"],
    [{ tool: "mcp__lazyagents__propose_connector", input: {} }, "connector"],
    [{ tool: "propose_secret", input: {} }, "secret"],
    [{ tool: "set_playground_openapi", input: {} }, "playground"],
    [{ tool: "mcp__lazyagents__search_repositories", input: { query: "secret" } }, "repo-search"],
    [{ tool: "use_repository", input: {} }, "repo-attach"],
    [{ tool: "request_push", input: {} }, "push"],
    [{ tool: "start_video", input: {} }, "video-render"],
    [{ tool: "update_video", input: {} }, "video-render"],
    [{ tool: "finish_video", input: {} }, "video-render"],
    [{ tool: "fail_video", input: {} }, "video-render"],
    [{ tool: "save_file", input: {} }, "library"],
    [{ tool: "render_pdf", input: {} }, "pdf"],
    [{ tool: "start_audio", input: {} }, "audio-render"],
    [{ tool: "update_audio", input: {} }, "audio-render"],
    [{ tool: "finish_audio", input: {} }, "audio-render"],
    [{ tool: "fail_audio", input: {} }, "audio-render"],
    [{ tool: "propose_persona", input: {} }, "persona"],
    [{ tool: "create_scheduled_task", input: {} }, "schedule"],
    [{ tool: "create_learning_module", input: {} }, "learning"],
    [{ tool: "submit_research_report", input: {} }, "research"],
    [{ tool: "list_custom_apps", input: {} }, "custom-app"],
    [{ tool: "mcp__lazyagents__get_custom_app", input: {} }, "custom-app"],
    ...["create_custom_app", "update_custom_app", "delete_custom_app"].map((tool) => [{ tool, input: {} }, "custom-app"]),
    [{ tool: "custom_app_sql", input: {} }, "database"],
    ...["http_list_workspaces", "http_get_workspace", "http_save_request", "http_run_request"].map((tool) => [{ tool, input: {} }, "http"]),
    ...["Agent", "Task", "delegate"].map((tool) => [{ tool, input: {} }, "subagent"]),
    [{ tool: "reply_block", input: { kind: "pdf" } }, "pdf"],
    [{ tool: "create_space", input: {} }, "space"],
    [{ tool: "list_saved_links", input: {} }, "saved-links"],
    [{ tool: "mcp__lazyagents__list_tickets", input: {} }, "ticket-lookup"],
    [{ tool: "list_projects", input: {} }, "projects"],
    [{ tool: "list_scheduled_tasks", input: {} }, "schedule"],
    [{ tool: "mcp__lazyagents__update_scheduled_task", input: {} }, "schedule"],
    [{ tool: "delete_scheduled_task", input: {} }, "schedule"],
    [{ tool: "mcp__lazyagents__save_link", input: {} }, "saved-links"],
    [{ tool: "browser_snapshot", input: {} }, "web-page"],
    [{ tool: "search_library", input: {} }, "library"],
    [{ tool: "read_library_item", input: {} }, "library"],
    [{ tool: "mcp__lazyagents__list_inbox", input: {} }, "inbox"],
    [{ tool: "list_learning_modules", input: {} }, "learning"],
    [{ tool: "mcp__lazyagents__get_learning_progress", input: {} }, "learning"],
    [{ tool: "mcp__lazyagents__list_connectors", input: {} }, "connector"],
    [{ tool: "mcp__lazyagents__list_secret_names", input: {} }, "secret"],
    [{ tool: "mcp__lazyagents__write_note", input: { body: "secret" } }, "wiki"],
    [{ tool: "reply_block", input: { kind: "chart" } }, "chart"],
    [{ tool: "reply_block", input: { kind: "mermaid" } }, "diagram"],
    [{ tool: "reply_block", input: { kind: "app" } }, "app"],
    [{ tool: "reply_block", input: { kind: "choices" } }, "choices"],
  ];
  for (const [call, want] of cases) assert.equal(chatStatusOf(call).kind, want, call.tool);
});

test("GitHub work is detected from MCP tools, gh and repository commands, without leaking details", () => {
  const bash = (command) => ({ tool: "Bash", input: { command } });
  const cases = [
    [{ tool: "mcp__github__create_pull_request", input: { title: "secret" } }, "connector", "using Github"],
    [{ tool: "github.update_pull_request", input: {} }, "connector", "using Github"],
    [{ tool: "mcp__github__list_issues", input: { repo: "secret" } }, "connector", "using Github"],
    [{ tool: "mcp__plugin_github_github__get_issue", input: {} }, "github", "working on GitHub"],
    [bash("gh issue view 12"), "github", "working on GitHub"],
    [bash("gh run watch"), "github", "working on GitHub"],
    [bash("gh pr create --fill"), "pull-request", "preparing a pull request"],
    [bash("git -C /work/repo push origin main"), "push", "pushing its branch"],
    [bash("git -c user.name=x commit -m secret"), "commit", "committing changes"],
    [bash("git --no-pager log -3"), "repo-history", "looking over the repository"],
    [bash("git add -A"), "repo-history", "looking over the repository"],
    [bash("git stash"), "repo-history", "looking over the repository"],
  ];
  for (const [call, kind, phrase] of cases) assert.deepEqual(chatStatusOf(call), { kind, phrase }, call.tool);
  // Tests win over reading the repository's state in one chained command.
  assert.equal(chatStatusOf(bash("git status && go test ./...")).kind, "tests");
});

test("the opening line shows only once a tool call follows it", () => {
  const at = (s) => `2026-11-06T10:0${s}:00Z`;
  const msg = (seq, text, extra = {}) => ({ seq, type: "message", at: at(seq), payload: { role: "assistant", text, ...extra } });
  const call = (seq) => ({ seq, type: "tool_call", at: at(seq), payload: { id: `c${seq}`, tool: "list_runs" } });
  const since = "2026-11-06T10:00:30Z";
  // A straight answer has no tool call: its text is the reply, not an opening line.
  assert.equal(interimLine([msg(1, "Hello!")], since), undefined);
  assert.equal(interimLine([msg(1, "  Let me check the runs.  "), call(2), msg(3, "Two are running.")], since), "Let me check the runs.");
  // An earlier turn's text and plan messages don't count.
  assert.equal(interimLine([msg(0, "old"), msg(1, "plan", { kind: "plan" }), call(2)], since), undefined);
  assert.equal(interimLine(undefined), undefined);
});

test("each turn's reply gets its own event window, including a follow-up with no user message", () => {
  const t = (m) => `2026-11-06T10:${String(m).padStart(2, "0")}:00Z`;
  const list = [
    { id: "u1", role: "user", created_at: t(0) },
    { id: "a1", role: "assistant", created_at: t(1), run_id: "r", turn_seq: 1 },
    { id: "u2", role: "user", created_at: t(2) },
    // The opening line and the answer of one turn share a window.
    { id: "o2", role: "assistant", created_at: t(3), run_id: "r", turn_seq: 2 },
    { id: "a2", role: "assistant", created_at: t(3), run_id: "r", turn_seq: 2 },
    { id: "s2", role: "system", created_at: t(3), run_id: "r" },
    // The image follow-up: another run turn the person didn't start.
    { id: "f2", role: "assistant", created_at: t(5), run_id: "r", turn_seq: 3 },
  ];
  const w = turnWindows(list);
  assert.deepEqual([...w.keys()], ["a1", "a2", "f2"]);
  assert.deepEqual(w.get("a1"), { since: t(0), until: t(2), followup: false });
  assert.deepEqual(w.get("a2"), { since: t(2), until: t(3), followup: false });
  assert.deepEqual(w.get("f2"), { since: t(3), until: undefined, followup: true });
  // Messages without a turn keep one window per user message, under its last reply.
  const old = [list[0], { id: "x", role: "assistant", created_at: t(1) }, { id: "y", role: "assistant", created_at: t(1) }];
  assert.deepEqual([...turnWindows(old).keys()], ["y"]);
  assert.equal(turnWindows(undefined).size, 0);
});

test("the running turn starts at the newest message", () => {
  const user = { id: "u", role: "user", created_at: "2026-11-06T10:00:00Z" };
  const reply = { id: "a", role: "assistant", created_at: "2026-11-06T10:01:00Z", run_id: "r", turn_seq: 1 };
  const note = { id: "s", role: "system", created_at: "2026-11-06T10:01:00.500Z" };
  assert.equal(runningSince([user]), user.created_at);
  // The image follow-up has no message of its own: it starts after the reply and its notes.
  assert.equal(runningSince([user, reply, note]), note.created_at);
  assert.equal(runningSince(undefined), undefined);
});

test("mid-turn steers preserve the active turn window in runningSince and turnWindows", () => {
  const t = (m) => `2026-11-06T10:${String(m).padStart(2, "0")}:00Z`;
  const u1 = { id: "u1", role: "user", created_at: t(0), run_id: "r1", turn_seq: 1 };
  const s1 = { id: "s1", role: "user", created_at: t(1) };
  const s2 = { id: "s2", role: "user", created_at: t(2) };
  const a1 = { id: "a1", role: "assistant", created_at: t(3), run_id: "r1", turn_seq: 1 };
  const u2 = { id: "u2", role: "user", created_at: t(4), run_id: "r1", turn_seq: 2 };
  const u3 = { id: "u3", role: "user", created_at: t(5), run_id: "r1", turn_seq: 3 };
  assert.equal(runningSince([u1, s1]), t(0));
  assert.equal(runningSince([u1, s1, s2]), t(0));
  // Consecutive normal turns (with run_id set) still advance since.
  assert.equal(runningSince([u1, a1, u2, u3]), t(5));

  const w = turnWindows([u1, s1, s2, a1, u2]);
  assert.deepEqual(w.get("a1"), { since: t(0), until: t(4), followup: false });
});

const stepsOf = (calls) => chatSteps(calls.map((c, key) => ({ key, done: true, input: {}, ...c })));

test("chatSteps follows the newest whole-list plan and marks steps added after work began", () => {
  const todo = (...rows) => ({ tool: "TodoWrite", input: { todos: rows.map(([content, status]) => ({ content, status })) } });
  const { steps, planned } = stepsOf([todo(["Read", "in_progress"], ["Test", "pending"]), { tool: "Read" }, todo(["Read", "completed"], ["Fix", "in_progress"], ["Test", "pending"])]);
  assert.equal(planned, true);
  assert.deepEqual(steps.map((s) => [s.title, s.state, !!s.added]), [["Read", "done", false], ["Fix", "active", true], ["Test", "planned", false]]);
  assert.deepEqual(stepsOf([{ tool: "todowrite", input: { todos: [{ content: "One", status: "in_progress" }, { content: "Gone", status: "cancelled" }] } }]).steps.map((s) => [s.title, s.state]), [["One", "active"]]);
});

test("chatSteps tracks TaskCreate and TaskUpdate by the id in the result", () => {
  const create = (subject, id) => ({ tool: "TaskCreate", input: { subject }, output: `Task #${id} created successfully: ${subject}` });
  const update = (taskId, status) => ({ tool: "TaskUpdate", input: { taskId, status } });
  const { steps } = stepsOf([create("A", 7), create("B", 8), create("C", 9), update("7", "completed"), update("8", "in_progress"), update("9", "deleted"), create("D", 10)]);
  assert.deepEqual(steps.map((s) => [s.title, s.state, !!s.added]), [["A", "done", false], ["B", "active", false], ["D", "planned", true]]);
});

test("a step keeps its key when another is added before it", () => {
  const todo = (...titles) => ({ tool: "TodoWrite", input: { todos: titles.map((content) => ({ content, status: "pending" })) } });
  const key = (calls, title) => stepsOf(calls).steps.find((s) => s.title === title).key;
  assert.equal(key([todo("A", "B")], "B"), key([todo("A", "New", "B")], "B"));
  assert.notEqual(...stepsOf([todo("Same", "Same")]).steps.map((s) => s.key));
});

test("every harness's tools and each chat tool land on a described step", () => {
  const phrases = (...tools) => stepsOf(tools.map((tool) => ({ tool }))).steps.map((s) => s.title);
  assert.deepEqual(phrases("read", "lazyagents_get_ticket", "edit", "websearch"), ["Reading the code", "Checking tickets", "Writing code", "Searching the web"]);
  assert.deepEqual(phrases("mcp__lazyagents__list_saved_links", "mcp__lazyagents__propose_persona", "mcp__lazyagents__submit_research_report"), ["Checking your saved links", "Sketching a new persona", "Writing up its research"]);
  assert.deepEqual(phrases("mcp__lazyagents__canvas_create", "mcp__lazyagents__canvas_patch", "mcp__lazyagents__canvas_patch"), ["Drafting a canvas", "Revising a canvas"]);
  assert.deepEqual(phrases("mcp__other__mystery"), ["Using Other"]);
  assert.deepEqual(phrases("mcp__lazyagents__whoami", "ToolSearch", "Skill", "mcp__lazyagents__set_chat_title"), []);
});

test("chatSteps groups a planless turn's calls, skipping bookkeeping", () => {
  const { steps, planned } = stepsOf([{ tool: "Read" }, { tool: "ToolSearch" }, { tool: "Grep" }, { tool: "Edit" }, { tool: "Bash", input: { command: "go test ./..." } }]);
  assert.equal(planned, false);
  assert.deepEqual(steps.map((s) => [s.state, s.kind]), [["done", "reading-code"], ["done", "searching-code"], ["done", "writing-code"], ["active", "tests"]]);
  assert.equal(steps[0].title, chatStatusOf({ tool: "Read", input: {} }).phrase.replace(/^./, (c) => c.toUpperCase()));
  assert.deepEqual(chatSteps([]), { steps: [], planned: false });
});

test("foldSteps folds old finished steps and caps upcoming ones", () => {
  const make = (state, n, p) => Array.from({ length: n }, (_, i) => ({ key: `${p}${i}`, title: `${p}${i}`, state }));
  const f = foldSteps([...make("done", 5, "d"), ...make("active", 1, "a"), ...make("planned", 6, "p")]);
  assert.deepEqual([f.earlier, f.later], [3, 2]);
  assert.deepEqual(f.shown.map((s) => s.key), ["d3", "d4", "a0", "p0", "p1", "p2", "p3"]);
  assert.equal(foldSteps(make("done", 3, "d")).earlier, 0);
});

test("rich reply blocks join the calls in order and become steps", () => {
  const events = [
    { seq: 1, type: "tool_call", at: "2026-11-06T10:01:00Z", payload: { id: "a", tool: "Read", input: {} } },
    { seq: 2, type: "lifecycle", at: "2026-11-06T10:01:01Z", payload: { state: "harness_started" } },
    { seq: 3, type: "lifecycle", at: "2026-11-06T10:01:02Z", payload: { state: "reply_block", kind: "app" } },
  ];
  const calls = chatCalls(events, "2026-11-06T10:00:30Z");
  assert.deepEqual(calls.map((c) => c.tool), ["Read", "reply_block"]);
  assert.deepEqual(chatStatus(calls), { kind: "app", phrase: "building an interactive app" });
  assert.deepEqual(chatSteps(calls).steps.map((s) => [s.title, s.state]), [["Reading the code", "done"], ["Building an interactive app", "active"]]);
  assert.equal(chatCalls(events, "2026-11-06T10:02:00Z").length, 0);
  const plan = { key: 0, tool: "TodoWrite", done: true, input: { todos: [{ content: "One", status: "completed" }] } };
  assert.deepEqual(chatSteps([plan, ...calls]).steps.map((s) => [s.title, s.state]), [["One", "done"], ["Building an interactive app", "active"]]);
});

test("a command wrapped in a login shell is judged by the command inside", () => {
  const shell = (command) => chatStatusOf({ tool: "shell", input: { command } }).kind;
  assert.equal(shell("/bin/zsh -lc 'sed -n 1,5p main.go'"), "reading-code");
  assert.equal(shell("/bin/bash -lc \"git status\""), "repo-history");
  assert.equal(shell("/bin/zsh -lc pwd"), "terminal");
});

test("stepDetail names files and searches but never paths or commands", () => {
  const cases = [
    [{ tool: "Read", input: { file_path: "/Users/me/secret/project/app.tsx" } }, "Reading app.tsx"],
    [{ tool: "Edit", input: { file_path: "/a/b.go" } }, "Editing b.go"],
    [{ tool: "Write", input: { file_path: "/a/new.md" } }, "Writing new.md"],
    [{ tool: "Grep", input: { pattern: "foldSteps" } }, "Searching “foldSteps”"],
    [{ tool: "Glob", input: { pattern: "**/*.go" } }, "Finding “**/*.go”"],
    [{ tool: "apply_patch", input: { files: ["update /r/a.go", "add /r/b.go", "delete /r/c.go"] } }, "Editing a.go and 2 more"],
    [{ tool: "mcp__lazyagents__read_page", input: { ref: "Eng/Plan" } }, "Reading Plan"],
    [{ tool: "WebFetch", input: { url: "https://www.example.com/private?token=x" } }, "Reading example.com"],
    [{ tool: "WebSearch", input: { query: "tts pricing" } }, "Searching the web for “tts pricing”"],
    [{ tool: "Bash", input: { command: "API_KEY=x go test ./..." } }, "Running tests"],
    [{ tool: "shell", input: { command: "curl -H 'Authorization: x' host" } }, "Working in the terminal"],
    [{ tool: "Read", input: { file_path: "/w/.lazyagents/attachments/generated/a.png" } }, "Looking at the image"],
    [{ tool: "Read", input: {} }, "Reading the code"],
    [{ tool: "mcp__other__mystery", input: { a: "b" } }, "Using Other: mystery"],
    [{ tool: "mcp__lazyagents__design_create", input: { title: "Onboarding" } }, "Starting the design “Onboarding”"],
  ];
  for (const [call, want] of cases) assert.equal(stepDetail(call), want, call.tool);
});

test("stepDetail surfaces safe model-authored shell summaries and coarse command targets", () => {
  const cases = [
    [{ tool: "Bash", input: { command: "go test ./internal/harness", description: "Run harness parser tests" } }, "Run harness parser tests"],
    [{ tool: "Bash", input: { command: "git status", toolSummary: "Check branch state." } }, "Check branch state"],
    // Unsafe descriptions fall back to safe target or general phrase.
    [{ tool: "Bash", input: { command: "curl -H 'Authorization: x' host", description: "API_KEY=secret curl https://internal" } }, "Working in the terminal"],
    [{ tool: "Bash", input: { command: "go test ./internal/harness", description: "Check /Users/me/secret" } }, "Testing ./internal/harness"],
    // Coarse targets when no description is given (Codex command_execution).
    [{ tool: "shell", input: { command: "/bin/bash -lc 'go test -race -run TestFoo ./internal/harness'" } }, "Testing ./internal/harness"],
    [{ tool: "shell", input: { command: "cd server && go test ./..." } }, "Testing server"],
    [{ tool: "shell", input: { command: "/bin/zsh -lc 'cd web && npm run test:unit'" } }, "Running web test:unit"],
    [{ tool: "shell", input: { command: "npx playwright test e2e/chat.spec.ts" } }, "Testing chat.spec.ts"],
    [{ tool: "shell", input: { command: "cd web && npm run build" } }, "Building web"],
    [{ tool: "shell", input: { command: "cd server && go vet ./internal/harness" } }, "Vetting ./internal/harness"],
    [{ tool: "shell", input: { command: "/bin/bash -lc 'git -C /repo status'" } }, "Checking git status"],
    [{ tool: "shell", input: { command: "git diff --stat" } }, "Checking git diff"],
    [{ tool: "shell", input: { command: "cd web && npm ci" } }, "Installing web dependencies"],
    // Secrets in env prefixes are stripped and never echoed.
    [{ tool: "shell", input: { command: "SECRET_TOKEN=abc123 go test ./internal/runs" } }, "Testing ./internal/runs"],
  ];
  for (const [call, want] of cases) assert.equal(stepDetail(call), want, JSON.stringify(call.input));
});

test("only the active step carries a detail, skipping bookkeeping and repeats", () => {
  const read = (file_path) => ({ tool: "Read", input: { file_path } });
  const todo = { tool: "TodoWrite", input: { todos: [{ content: "One", status: "completed" }, { content: "Two", status: "in_progress" }, { content: "Three", status: "pending" }] } };
  assert.deepEqual(stepsOf([todo, read("/a/one.ts"), read("/a/two.ts"), { tool: "ToolSearch" }]).steps.map((s) => s.detail), [undefined, "Reading two.ts", undefined]);
  assert.deepEqual(stepsOf([{ tool: "Edit" }, read("/a/x.ts")]).steps.map((s) => s.detail), [undefined, "Reading x.ts"]);
  assert.equal(stepsOf([{ tool: "Bash", input: { command: "go test ./..." } }]).steps[0].detail, undefined);
  assert.equal(stepsOf([todo]).steps[1].detail, undefined);
  const events = [{ seq: 1, type: "tool_call", at: "2026-11-06T10:01:00Z", payload: { id: "a", tool: "Read", input: { file_path: "/a/x.ts" } } }, { seq: 2, type: "lifecycle", at: "2026-11-06T10:01:01Z", payload: { state: "reply_block", kind: "app" } }];
  assert.deepEqual(chatSteps(chatCalls(events)).steps.map((s) => s.detail), [undefined, undefined]);
});

test("stepDetail names canvases, workflows, tickets, images, personas, runs and GitHub work", () => {
  const cases = [
    [{ tool: "mcp__lazyagents__canvas_create", input: { title: "Rail mockups", body: "secret" } }, "Drafting “Rail mockups”"],
    [{ tool: "mcp__lazyagents__canvas_patch", input: { canvas_id: "c9", note: "tighten the intro" } }, "Revising: tighten the intro"],
    [{ tool: "mcp__lazyagents__propose_workflow_edit", input: { name: "Map maker" } }, "Sketching “Map maker”"],
    [{ tool: "mcp__lazyagents__propose_workflow_edit", input: { workflow_id: "w9", summary: "Adds a gate" } }, "Sketching: Adds a gate"],
    [{ tool: "mcp__lazyagents__create_ticket", input: { title: "Fix login" } }, "Drafting “Fix login”"],
    [{ tool: "mcp__lazyagents__create_epic", input: { name: "Billing" } }, "Drafting “Billing”"],
    [{ tool: "mcp__lazyagents__generate_image", input: { prompt: "a cat on a bike" } }, "Creating “a cat on a bike”"],
    [{ tool: "mcp__lazyagents__propose_persona", input: { name: "Nora", instructions: "secret" } }, "Sketching “Nora”"],
    [{ tool: "mcp__lazyagents__propose_persona_character", input: { persona: "Nora", svg: "<svg/>" } }, "Designing character for “Nora”"],
    [{ tool: "mcp__lazyagents__propose_persona_character", input: { summary: "Bouncy ears" } }, "Designing character: Bouncy ears"],
    [{ tool: "mcp__lazyagents__create_space", input: { name: "Health", instructions: "secret" } }, "Setting up “Health”"],
    [{ tool: "mcp__lazyagents__create_scheduled_task", input: { name: "Weekly check-in", instructions: "secret" } }, "Scheduling “Weekly check-in”"],
    [{ tool: "mcp__lazyagents__create_learning_module", input: { topic: "Strength training" } }, "Starting a module on “Strength training”"],
    [{ tool: "mcp__lazyagents__create_scheduled_task", input: {} }, "Scheduling a task"],
    [{ tool: "mcp__lazyagents__list_runs", input: { ticket: "PAY-214" } }, "Checking runs of PAY-214"],
    [{ tool: "mcp__lazyagents__get_ticket", input: { ticket: "PAY-214" } }, "Reading PAY-214"],
    [{ tool: "mcp__lazyagents__list_epics", input: { project: "PAY" } }, "Looking over PAY epics"],
    [{ tool: "mcp__lazyagents__list_epics", input: {} }, "Checking tickets"],
    [{ tool: "mcp__lazyagents__list_tickets", input: { project: "lazyagents", status: ["in_progress"] } }, "Looking over LAZYAGENTS in-progress tickets"],
    [{ tool: "mcp__lazyagents__list_tickets", input: { status: ["todo", "backlog"], q: "secret" } }, "Checking tickets"],
    [{ tool: "mcp__lazyagents__list_projects", input: {} }, "Looking over your projects"],
    [{ tool: "mcp__lazyagents__list_scheduled_tasks", input: {} }, "Checking your scheduled tasks"],
    [{ tool: "mcp__lazyagents__update_scheduled_task", input: { task_id: "t9", instructions: "secret" } }, "Changing a scheduled task"],
    [{ tool: "mcp__lazyagents__browser_snapshot", input: {} }, "Reading your shared Safari tab · untrusted page"],
    [{ tool: "mcp__lazyagents__save_link", input: { url: "https://youtube.com/watch?v=1", title: "Truth or Drink" } }, "Saving “Truth or Drink”"],
    [{ tool: "mcp__lazyagents__save_link", input: { url: "https://www.example.com/a?token=secret" } }, "Saving “example.com”"],
    [{ tool: "mcp__lazyagents__search_library", input: { q: "dusk logo" } }, "Searching “dusk logo”"],
    [{ tool: "mcp__lazyagents__search_library", input: {} }, "Looking through your Library"],
    [{ tool: "mcp__lazyagents__read_library_item", input: { item_id: "i9" } }, "Opening something from your Library"],
    [{ tool: "mcp__lazyagents__list_inbox", input: { project: "PAY" } }, "Checking what needs you"],
    [{ tool: "mcp__lazyagents__list_learning_modules", input: {} }, "Looking over your learning modules"],
    [{ tool: "mcp__lazyagents__get_learning_progress", input: { module_id: "m9" } }, "Checking your progress"],
    [{ tool: "mcp__lazyagents__list_connectors", input: {} }, "Checking your connectors"],
    [{ tool: "mcp__lazyagents__list_secret_names", input: {} }, "Checking which secrets you have"],
    [{ tool: "mcp__lazyagents__update_ticket", input: { ticket: "PAY-214", description: "secret" } }, "Updating PAY-214"],
    [{ tool: "mcp__lazyagents__comment_ticket", input: { ticket: "PAY-214", body: "secret" } }, "Commenting on PAY-214"],
    [{ tool: "mcp__lazyagents__get_video_transcript", input: { url: "https://youtu.be/x", from_seconds: 272 } }, "Watching from 4:32"],
    [{ tool: "mcp__github__create_pull_request", input: { owner: "o", repo: "r", title: "Add rail", body: "secret" } }, "Using Github: create_pull_request"],
    [{ tool: "mcp__github__get_issue", input: { owner: "o", repo: "r", issue_number: 12 } }, "Using Github: get_issue"],
    [{ tool: "mcp__lazyagents__save_memory", input: { body: "private" } }, "Making a note"],
    [{ tool: "mcp__lazyagents__canvas_read", input: { canvas_id: "unknown" } }, "Looking at a canvas"],
  ];
  for (const [call, want] of cases) assert.equal(stepDetail(call), want, call.tool);
});

test("tools that take an id use the name an earlier call in the turn gave it", () => {
  const detail = (calls) => stepsOf(calls).steps.at(-1).detail;
  const created = { tool: "mcp__lazyagents__canvas_create", input: { title: "Rail" }, output: JSON.stringify({ canvas_id: "c1", version: 1 }) };
  assert.equal(detail([created, { tool: "mcp__lazyagents__canvas_patch", input: { canvas_id: "c1", note: "n" } }]), "Revising “Rail”");
  const listed = { tool: "list_workflows", input: {}, output: JSON.stringify({ content: [{ type: "text", text: JSON.stringify({ workflows: [{ id: "w1", name: "Maps" }] }) }] }) };
  assert.equal(detail([listed, { tool: "read_workflow", input: { workflow_id: "w1" } }]), "Looking over “Maps”");
  const runs = { tool: "list_runs", input: {}, output: JSON.stringify({ runs: [{ id: "r1", ticket: "PAY-1" }] }) };
  assert.equal(detail([runs, { tool: "get_run", input: { id: "r1" } }]), "Checking PAY-1");
  const tasks = { tool: "list_scheduled_tasks", input: {}, output: JSON.stringify({ tasks: [{ task_id: "t1", name: "Weekly check-in" }] }) };
  assert.equal(detail([tasks, { tool: "update_scheduled_task", input: { task_id: "t1" } }]), "Changing “Weekly check-in”");
  assert.equal(detail([tasks, { tool: "delete_scheduled_task", input: { task_id: "t1" } }]), "Removing “Weekly check-in”");
  const found = { tool: "search_library", input: { q: "logo" }, output: JSON.stringify({ items: [{ item_id: "i1", title: "Dusk logo v3" }] }) };
  assert.equal(detail([found, { tool: "read_library_item", input: { item_id: "i1" } }]), "Opening “Dusk logo v3”");
  const modules = { tool: "list_learning_modules", input: {}, output: JSON.stringify({ modules: [{ module_id: "m1", topic: "Rust ownership" }] }) };
  assert.equal(detail([modules, { tool: "get_learning_progress", input: { module_id: "m1" } }]), "Checking progress on “Rust ownership”");
  const clipped = { tool: "canvas_read", input: { canvas_id: "c2" }, output: '{"body":"long and cut' };
  // No name to show, so the detail would only repeat the step's title.
  assert.equal(detail([clipped, { tool: "canvas_comment", input: { canvas_id: "c2" } }]), undefined);
});

test("a connector's tools get their own scene and read by the connector's name", () => {
  assert.deepEqual(connectorCall("mcp__google-calendar__list_events"), { name: "Google Calendar", tool: "list_events" });
  assert.equal(connectorCall("mcp__lazyagents__whoami"), null);
  assert.equal(chatStatusOf({ tool: "google-calendar.list_events", input: {} }).kind, "connector");
});

test("a request with a secret shows the key scene and names the handle, not a value", () => {
  const call = { tool: "mcp__vesper_secrets__http_request", input: { secret: "acme-jwt", url: "https://api.acme.com/v1/orders?since=2026-11-02" } };
  assert.deepEqual(chatStatusOf(call), { kind: "secret", phrase: "using acme-jwt" });
  assert.deepEqual(activityOf(call), { verb: "Using acme-jwt:", text: "GET api.acme.com/v1/orders" });
  assert.equal(chatStatusOf({ tool: "vesper_secrets.list_secrets", input: {} }).kind, "secret");
  // Not a connector named "vesper_secrets".
  assert.equal(connectorCall("mcp__vesper_secrets__http_request"), null);
});

test("each step carries the kind of its newest call, and a planned step gets one once its work starts", () => {
  const todo = (...rows) => ({ tool: "TodoWrite", input: { todos: rows.map(([content, status]) => ({ content, status })) } });
  const bash = (command, failed) => ({ tool: "Bash", input: { command }, ...(failed ? { failed: true } : {}) });
  const { steps } = stepsOf([
    todo(["Look", "in_progress"], ["Check", "pending"], ["Ship", "pending"]),
    { tool: "Grep" },
    { tool: "Read" },
    todo(["Look", "completed"], ["Check", "in_progress"], ["Ship", "pending"]),
    bash("go test ./..."),
  ]);
  assert.deepEqual(steps.map((s) => [s.title, s.state, s.kind]), [["Look", "done", "reading-code"], ["Check", "active", "tests"], ["Ship", "planned", undefined]]);
});

test("a finished step fails when its newest call errored at work where that means failure", () => {
  const bash = (command, failed) => ({ tool: "Bash", input: { command }, ...(failed ? { failed: true } : {}) });
  // Tests fail, then pass on the rerun: done. The build breaks and the turn moves on: failed.
  const run = stepsOf([bash("go test ./...", true), bash("go test ./..."), bash("go build ./...", true), { tool: "Edit" }]).steps;
  assert.deepEqual(run.map((s) => [s.kind, s.state]), [["tests", "done"], ["build", "failed"], ["writing-code", "active"]]);
  // A search with no match exits non-zero but isn't a failure.
  assert.equal(stepsOf([bash("rg missing", true), { tool: "Edit" }]).steps[0].state, "done");
  // A plan step the agent completed after a failing run still shows the failure.
  const todo = (...rows) => ({ tool: "TodoWrite", input: { todos: rows.map(([content, status]) => ({ content, status })) } });
  const planned = stepsOf([todo(["Test", "in_progress"], ["Ship", "pending"]), bash("npm test", true), todo(["Test", "completed"], ["Ship", "in_progress"])]).steps;
  assert.deepEqual(planned.map((s) => [s.title, s.state]), [["Test", "failed"], ["Ship", "active"]]);
});

test("toolCalls marks a call failed when its result is an error", () => {
  const at = "2026-11-09T00:00:00Z";
  const calls = toolCalls([
    { seq: 1, type: "tool_call", at, payload: { id: "a", tool: "Bash", input: {} } },
    { seq: 2, type: "tool_result", at, payload: { id: "a", is_error: true, output: "FAIL" } },
    { seq: 3, type: "tool_call", at, payload: { id: "b", tool: "Bash", input: {} } },
    { seq: 4, type: "tool_result", at, payload: { id: "b", output: "ok" } },
  ]);
  assert.deepEqual(calls.map((c) => c.failed), [true, undefined]);
});

test("foldSteps never folds a failed step", () => {
  const steps = [{ key: "f", title: "f", state: "failed" }, ...["a", "b", "c", "d"].map((k) => ({ key: k, title: k, state: "done" })), { key: "x", title: "x", state: "active" }];
  const f = foldSteps(steps);
  assert.equal(f.earlier, 2);
  assert.deepEqual(f.shown.map((s) => s.key), ["f", "c", "d", "x"]);
});

// ---- narrated decisions and thinking ----

const ev = (seq, type, payload) => ({ seq, type, at: `2026-11-09T10:00:${String(seq).padStart(2, "0")}Z`, payload });
const say = (seq, text) => ev(seq, "message", { role: "assistant", text });
const think = (seq, text) => ev(seq, "message", { kind: "thinking", text });
const call = (seq, tool, input = {}) => ev(seq, "tool_call", { id: `c${seq}`, tool, input });
const result = (seq, id, extra = {}) => ev(seq, "tool_result", { id, ...extra });

test("intentOf turns a leading marker into a tag", () => {
  assert.deepEqual(intentOf("New approach: swap the sleep for a fake clock."), { text: "Swap the sleep for a fake clock.", tag: "approach" });
  assert.deepEqual(intentOf("surprise — it fails on main too"), { text: "It fails on main too", tag: "surprise" });
  assert.deepEqual(intentOf("  Reading the poller first. "), { text: "Reading the poller first." });
  assert.deepEqual(intentOf("Surprise:"), { text: "Surprise:" });
});

test("turnNotes skips the opening line and the reply, and pins the rest to the next call", () => {
  const events = [
    say(1, "On it, let me look."),
    think(2, "Start with the poller."),
    call(3, "Read", { file_path: "/r/poller.go" }),
    result(4, "c3"),
    say(5, "Surprise: fails on main too."),
    call(6, "Bash", { command: "go test ./..." }),
    result(7, "c6"),
    think(8, "Wrap up."),
    say(9, "Fixed it."),
  ];
  assert.deepEqual(turnNotes(events), [
    { kind: "thinking", text: "Start with the poller.", before: 3 },
    { kind: "intent", text: "Fails on main too.", tag: "surprise", before: 6 },
    { kind: "thinking", text: "Wrap up." },
  ]);
  // Text no call follows yet may still be the reply.
  assert.deepEqual(turnNotes(events.slice(0, 5)).map((n) => n.kind), ["thinking"]);
});

test("chatSteps puts the newest intent and its tag on the step, and flags thinking", () => {
  const events = [
    say(1, "Looking."),
    call(2, "Read", { file_path: "/r/a.go" }),
    result(3, "c2"),
    think(4, "Tests next."),
    say(5, "Running the suite before touching anything."),
    call(6, "Bash", { command: "go test ./..." }),
    say(7, "New approach: fake the clock."),
    call(8, "Bash", { command: "go test ./... -count=10" }),
  ];
  const { steps } = chatSteps(toolCalls(events), turnNotes(events));
  assert.equal(steps.length, 2);
  assert.equal(steps[0].intent, undefined);
  assert.equal(steps[1].intent, "Fake the clock.");
  assert.equal(steps[1].tag, "approach");
  assert.equal(steps[1].reasoning, true);
  // Without notes, steps are unchanged.
  assert.equal(chatSteps(toolCalls(events)).steps[1].intent, undefined);
});

test("turnTrace groups calls, intents and thinking by step, with bookkeeping and the reply placed", () => {
  const plan = (seq, a, b) => call(seq, "TodoWrite", { todos: [{ content: "Find it", status: a }, { content: "Fix it", status: b }] });
  const events = [
    say(1, "Let me check."),
    think(2, "Plan first."),
    plan(3, "in_progress", "pending"),
    call(4, "Grep", { pattern: "retry" }),
    result(5, "c4"),
    say(6, "It lives in the poller."),
    plan(7, "completed", "in_progress"),
    call(8, "Edit", { file_path: "/r/poller.go" }),
    result(9, "c8"),
    think(10, "Say what changed."),
    say(11, "Done."),
  ];
  const trace = turnTrace(events);
  assert.deepEqual(trace.map((s) => s.title), ["Find it", "Fix it", "Writing the reply"]);
  assert.deepEqual(trace[0].calls.map((c) => c.key), [3, 4]);
  assert.deepEqual(trace[0].thinking, ["Plan first."]);
  assert.deepEqual(trace[1].calls.map((c) => c.key), [7, 8]);
  assert.deepEqual(trace[1].intents, ["It lives in the poller."]);
  assert.deepEqual(trace[2].thinking, ["Say what changed."]);
  assert.deepEqual(turnTrace([]), []);
});

test("history groups chats by the local day of their last activity", () => {
  const now = new Date(2026, 10, 10, 15, 0).getTime();
  const at = (d, h) => new Date(2026, 10, d, h, 0).toISOString();
  const chats = [
    { id: "a", created_at: at(10, 1), last_message_at: at(10, 14) },
    { id: "b", created_at: at(8, 1), last_message_at: at(9, 23) },
    { id: "c", created_at: at(10, 0) },
    { id: "d", created_at: at(1, 1), last_message_at: at(9, 0) },
    { id: "e", created_at: at(2, 1), last_message_at: at(8, 23) },
  ];
  assert.deepEqual(groupByDay(chats, now).map((g) => [g.label, g.chats.map((c) => c.id)]), [
    ["Today", ["a", "c"]],
    ["Yesterday", ["b", "d"]],
    ["Earlier", ["e"]],
  ]);
  assert.deepEqual(groupByDay([], now), [], "no empty sections");
});

test("a chat's model shows the catalog's label, even when it is the definition's alias", () => {
  const models = [{ id: "claude-opus-5-5", label: "Opus 5.5" }, { id: "sonnet-5.5", label: "Sonnet 5.5" }];
  assert.equal(catalogModelLabel(models, "sonnet-5.5"), "Sonnet 5.5");
  assert.equal(catalogModelLabel(models, "opus-5.5"), "Opus 5.5", "alias matches the catalog id");
  assert.equal(catalogModelLabel([{ id: "x", label: "Opus 5.5" }], "opus-5.5"), "Opus 5.5", "or its label");
  assert.equal(catalogModelLabel([], "opus-5.5"), "Opus 5.5", "unknown: made readable");
  assert.equal(readableModelId("gpt-5-codex"), "GPT-5 Codex");
  assert.equal(readableModelId("claude-haiku-5-5"), "Haiku 5.5");
});

test("every chat tool the server offers has a scene of its own", () => {
  // The server refuses chat tools missing from chatTools; nothing here forced the UI to keep
  // up, so new tools silently showed the idle dots. Read the list from the source of truth.
  const source = readFileSync(new URL("../../server/internal/runs/chat_tools.go", import.meta.url), "utf8");
  const list = /var ChatTools = \[\]string\{([^}]*)\}/.exec(source)?.[1];
  assert.ok(list, "ChatTools not found in runs/chat_tools.go");
  const tools = [...list.matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
  assert.ok(tools.length > 40, `parsed only ${tools.length} chat tools`);
  // Bookkeeping that isn't work the person would want pictured.
  const idle = new Set(["whoami", "set_chat_title"]);
  const unpictured = tools.filter((tool) => !idle.has(tool) && chatStatusOf({ tool: `mcp__lazyagents__${tool}`, input: {} }).kind === "thinking");
  assert.deepEqual(unpictured, []);
});

test("the design kinds have their own scene, with no placeholder left", () => {
  // ADR-designs §3.9: design tools play the design scene; reads (design-view) share it, like image-view.
  const scenes = readFileSync(new URL("../app/(app)/chat/_components/activity-scene.tsx", import.meta.url), "utf8");
  assert.match(scenes, /^ {2}"design-view": "design",$/m, "design-view shares the design scene");
  assert.match(scenes, /^ {2}design: \($/m, "design has a scene of its own");
  assert.doesNotMatch(scenes, /^ {2}design: canvasScene\(/m);
  assert.doesNotMatch(scenes, /placeholder/i);
  const css = readFileSync(new URL("../app/globals.css", import.meta.url), "utf8");
  for (const part of [...scenes.matchAll(/scene-dz-([a-z0-9]+)/g)].map((m) => m[1])) assert.match(css, new RegExp(`@keyframes scene-dz-${part} `), `scene-dz-${part} has keyframes`);
  for (const tool of ["design_create", "design_patch"]) assert.equal(chatStatusOf({ tool, input: {} }).kind, "design", tool);
  for (const tool of ["design_render", "design_outline", "design_read", "design_flows"]) assert.equal(chatStatusOf({ tool, input: {} }).kind, "design-view", tool);
});

test("every ChatStatusKind has a scene, a step glyph, and defined scene CSS classes", () => {
  const ui = readFileSync(new URL("./chat-ui.ts", import.meta.url), "utf8");
  const typeBlock = /export type ChatStatusKind =([\s\S]*?);/.exec(ui)?.[1];
  assert.ok(typeBlock, "ChatStatusKind union not found");
  const kinds = [...typeBlock.matchAll(/"([a-z-]+)"/g)].map((m) => m[1]);
  assert.ok(kinds.length >= 40, `expected >= 40 kinds, got ${kinds.length}`);

  const scenesSrc = readFileSync(new URL("../app/(app)/chat/_components/activity-scene.tsx", import.meta.url), "utf8");
  const glyphsSrc = readFileSync(new URL("../app/(app)/chat/_components/step-glyph.tsx", import.meta.url), "utf8");
  const css = readFileSync(new URL("../app/globals.css", import.meta.url), "utf8");

  for (const k of kinds) {
    const keyRe = new RegExp(`^ {2}(?:"${k}"|${k}):`, "m");
    assert.match(scenesSrc, keyRe, `activity-scene.tsx missing scene or alias for "${k}"`);
    assert.match(glyphsSrc, keyRe, `step-glyph.tsx missing glyph for "${k}"`);
  }

  // Every static scene-* class referenced in activity-scene.tsx must exist in globals.css.
  const referenced = new Set([...scenesSrc.matchAll(/\b(scene-[a-z0-9-]+)\b/g)].map((m) => m[1]));
  // Dynamic prefix templates like scene-db-r${i} produce scene-db-r; skip prefixes ending with - or single-letter stem followed by ${.
  const missingCss = [...referenced].filter((cls) => {
    if (scenesSrc.includes(`${cls}${"${"}`) || scenesSrc.includes(`${cls}-${"${"}`)) return false;
    return !new RegExp(`\\.${cls}(?![a-z0-9-])`).test(css);
  });
  assert.deepEqual(missingCss, [], `globals.css missing scene classes: ${missingCss.join(", ")}`);
});

test("subagent and run-level MCP tools map to dedicated non-thinking scenes", () => {
  assert.equal(stepDetail({ tool: "Agent", input: { description: "Audit scenes" } }), "Delegating “Audit scenes”");
  const runCases = [
    ["claim_ticket", "ticket-lookup"],
    ["check_criterion", "tickets"],
    ["create_mockup", "design"],
    ["post_plan", "next-step"],
    ["set_branch", "repo-history"],
    ["set_pr", "pull-request"],
    ["await_human", "inbox"],
    ["submit_findings", "research"],
    ["submit_lesson", "learning"],
    ["submit_workflow_output", "workflow"],
    ["run_gated", "secret"],
    ["get_prior_attempts", "runs"],
  ];
  for (const [tool, want] of runCases) assert.equal(chatStatusOf({ tool, input: {} }).kind, want, tool);
});

// ---- the status card's pulse: alive, between steps, or quiet ----

const T0 = Date.parse("2026-11-09T10:00:00Z");
const at = (s) => T0 + s * 1000;

test("turnClock times each call from its event to its result, and the turn's newest event", () => {
  const events = [ev(1, "tool_call", { id: "old", tool: "Read" }), call(5, "Read"), result(9, "c5"), think(12, "Next."), call(14, "Edit")];
  const clock = turnClock(events, "2026-11-09T10:00:03Z");
  assert.equal(clock.started, at(3));
  assert.equal(clock.last, at(14));
  assert.deepEqual([...clock.calls], [[5, { at: at(5), doneAt: at(9) }], [14, { at: at(14) }]]);
  assert.equal(turnClock(undefined, "2026-11-09T10:00:03Z").last, undefined);
});

test("turnPulse is between steps only once the newest call has been done for a few seconds", () => {
  const events = [call(1, "Read"), result(2, "c1")];
  const calls = toolCalls(events);
  const clock = turnClock(events, "2026-11-09T10:00:00Z");
  assert.equal(turnPulse(calls, clock, at(2) + NEXT_STEP_AFTER_MS - 1).between, false);
  assert.equal(turnPulse(calls, clock, at(2) + NEXT_STEP_AFTER_MS).between, true);
  // A call still running is what it's doing, however long it takes.
  const running = [call(1, "Bash", { command: "go test ./..." })];
  assert.equal(turnPulse(toolCalls(running), turnClock(running), at(60)).between, false);
  // Before any call there's nothing to be between.
  assert.equal(turnPulse([], turnClock([]), at(60)).between, false);
});

test("turnPulse goes quiet after two minutes without events, or five while a call runs", () => {
  const done = [call(1, "Read"), result(2, "c1")];
  const pulse = (events, s) => turnPulse(toolCalls(events), turnClock(events, "2026-11-09T10:00:00Z"), at(s));
  assert.equal(pulse(done, 2 + 119).quiet, false);
  assert.equal(pulse(done, 2 + 120).quiet, true);
  assert.equal(pulse(done, 2 + 120).idle, QUIET_AFTER_MS);
  const running = [call(1, "Bash", { command: "go test ./..." })];
  assert.equal(pulse(running, 1 + 240).quiet, false);
  assert.equal(pulse(running, 1 + QUIET_RUNNING_MS / 1000).quiet, true);
  // Nothing has happened yet: quiet counts from the turn's start.
  assert.equal(turnPulse([], turnClock([], "2026-11-09T10:00:00Z"), at(120)).quiet, true);
  assert.equal(pulse(done, 30).elapsed, 30_000);
});

test("chatStatus adapts the between-steps phrase to what just finished, and prefers live writing_reply", () => {
  const edit = [{ key: 1, tool: "Edit", input: {}, done: true }];
  assert.equal(chatStatus(edit).phrase, "writing code");
  assert.deepEqual(chatStatus(edit, true), { kind: "next-step", phrase: "planning the next step" });

  // Contextual phrases after common inspection/verification steps.
  assert.deepEqual(chatStatus([{ key: 1, tool: "Bash", input: { command: "go test ./..." }, done: true }], true), { kind: "next-step", phrase: "reviewing the test results" });
  assert.deepEqual(chatStatus([{ key: 1, tool: "Bash", input: { command: "npm run build" }, done: true }], true), { kind: "next-step", phrase: "checking the build output" });
  assert.deepEqual(chatStatus([{ key: 1, tool: "Read", input: { file_path: "a.go" }, done: true }], true), { kind: "next-step", phrase: "reviewing the code" });
  assert.deepEqual(chatStatus([{ key: 1, tool: "Grep", input: { pattern: "x" }, done: true }], true), { kind: "next-step", phrase: "reviewing what it found" });
  assert.deepEqual(chatStatus([{ key: 1, tool: "Bash", input: { command: "pwd" }, done: true }], true), { kind: "next-step", phrase: "checking the command output" });

  // Live writing_reply takes over immediately once prose streams.
  assert.deepEqual(chatStatus(edit, false, { phase: "writing_reply", at: at(10) }), { kind: "writing-reply", phrase: "drafting a reply" });
  assert.deepEqual(chatStatus([], false, { phase: "writing_reply", at: at(10) }), { kind: "writing-reply", phrase: "drafting a reply" });
  // An in-flight tool call or active reply block isn't overridden by a stale activity phase.
  assert.equal(chatStatus([{ key: 1, tool: "Bash", input: { command: "go test ./..." }, done: false }], true, { phase: "writing_reply", at: at(10) }).phrase, "running tests");
  assert.equal(chatStatus([{ key: 1, tool: "reply_block", input: { kind: "app" }, done: true }], true, { phase: "writing_reply", at: at(10) }).phrase, "building an interactive app");
});

test("turnActivity tracks live thinking headings and writing_reply, and heartbeats prevent false quiet warnings", () => {
  const act = (s, phase, detail) => ({ seq: s, type: "lifecycle", at: new Date(at(s)).toISOString(), payload: { state: "activity", phase, ...(detail ? { detail } : {}) } });
  const events = [
    call(1, "Bash", { command: "go test ./internal/harness" }),
    result(5, "c1"),
    act(12, "thinking", "Checking parser failure"),
    act(110, "thinking"), // heartbeat keeps the heading and refreshes clock.last
  ];
  const activity = turnActivity(events, "2026-11-09T10:00:00Z");
  assert.deepEqual(activity, { phase: "thinking", detail: "Checking parser failure", at: at(110) });

  // 2m 05s after the test finished, the 110s heartbeat keeps the turn alive (not quiet).
  const clock = turnClock(events, "2026-11-09T10:00:00Z");
  const pulse = turnPulse(toolCalls(events), clock, at(130));
  assert.equal(pulse.between, true);
  assert.equal(pulse.quiet, false);
  assert.equal(pulse.idle, 20_000);

  // The stand-in step shows the contextual title plus the live thinking heading as detail.
  const { steps } = chatSteps(toolCalls(events), [], { between: false, clock, activity });
  assert.deepEqual(steps.map((s) => [s.title, s.state, s.detail]), [
    ["Running tests", "done", "Testing ./internal/harness"],
    ["Reviewing the test results", "active", "Checking parser failure"],
  ]);

  // Transitioning to writing_reply clears the thinking heading and updates the stand-in step.
  const writing = [...events, act(135, "writing_reply")];
  const wAct = turnActivity(writing, "2026-11-09T10:00:00Z");
  assert.deepEqual(wAct, { phase: "writing_reply", at: at(135) });
  const { steps: wSteps } = chatSteps(toolCalls(writing), [], { between: false, clock: turnClock(writing, "2026-11-09T10:00:00Z"), activity: wAct });
  assert.deepEqual(wSteps.map((s) => [s.title, s.state, s.kind]), [
    ["Running tests", "done", "tests"],
    ["Drafting a reply", "active", "writing-reply"],
  ]);

  // A new tool call clears the activity phase; a completed non-streaming thinking block supplies its heading.
  assert.equal(turnActivity([...writing, { seq: 140, type: "tool_call", at: new Date(at(140)).toISOString(), payload: { id: "c140", tool: "Read", input: {} } }], "2026-11-09T10:00:00Z"), undefined);
  assert.deepEqual(
    turnActivity([call(1, "Read"), result(2, "c1"), think(3, "**Comparing branch diff**\nLooking closely.")], "2026-11-09T10:00:00Z"),
    { phase: "thinking", detail: "Comparing branch diff", at: at(3) },
  );
  // Before any tool call, a thinking heading shows on its own thinking step.
  const preTool = chatSteps([], [], { activity: { phase: "thinking", detail: "Checking the request", at: at(2) } }).steps;
  assert.deepEqual(preTool.map((s) => [s.title, s.kind, s.detail]), [["Thinking", "thinking", "Checking the request"]]);
});

test("between steps, the finished step keeps its detail and a stand-in next step is under way", () => {
  const events = [call(1, "Read", { file_path: "/r/a.go" }), result(3, "c1"), call(4, "Edit", { file_path: "/r/runner.go" }), result(9, "c4")];
  const calls = toolCalls(events);
  const clock = turnClock(events, "2026-11-09T10:00:00Z");
  const { steps } = chatSteps(calls, [], { between: true, clock });
  assert.deepEqual(steps.map((s) => [s.title, s.state]), [["Reading the code", "done"], ["Writing code", "done"], ["Planning the next step", "active"]]);
  assert.equal(steps[1].detail, "Editing runner.go");
  assert.equal(steps[2].key, NEXT_STEP_KEY);
  assert.equal(steps[2].kind, "next-step");
  // Each step spans its calls; the stand-in starts when the last call finished.
  assert.deepEqual(steps.map((s) => [s.startedAt, s.endedAt]), [[at(1), at(3)], [at(4), at(9)], [at(9), undefined]]);
  // Not between: the newest step is still the active one.
  assert.deepEqual(chatSteps(calls, [], { clock }).steps.map((s) => s.state), ["done", "active"]);
});

test("a failed step stays failed when the turn moves on to the next step", () => {
  const events = [call(1, "Bash", { command: "go test ./..." }), result(2, "c1", { is_error: true })];
  const { steps } = chatSteps(toolCalls(events), [], { between: true });
  assert.deepEqual(steps.map((s) => s.state), ["failed", "active"]);
});

test("a planned turn keeps its plan step active between calls and surfaces live phase details", () => {
  const plan = { tool: "TodoWrite", input: { todos: [{ content: "Fix it", status: "in_progress" }, { content: "Test it", status: "pending" }] } };
  const { steps, planned } = chatSteps([{ key: 1, done: true, ...plan }, { key: 2, tool: "Edit", input: {}, done: true }], [], { between: true });
  assert.equal(planned, true);
  assert.deepEqual(steps.map((s) => [s.title, s.state]), [["Fix it", "active"], ["Test it", "planned"]]);
  const withHeading = chatSteps([{ key: 1, done: true, ...plan }, { key: 2, tool: "Edit", input: {}, done: true }], [], { between: false, activity: { phase: "thinking", detail: "Double-checking edge cases", at: at(5) } }).steps;
  assert.equal(withHeading[0].detail, "Double-checking edge cases");
});

test("formatSpan and quietFor read at a glance", () => {
  assert.equal(formatSpan(0), "0s");
  assert.equal(formatSpan(12_400), "12s");
  assert.equal(formatSpan(252_000), "4m 12s");
  assert.equal(formatSpan(3_725_000), "1h 02m");
  assert.equal(quietFor(2 * 60_000), "2 minutes");
  assert.equal(quietFor(3 * 60_000 + 59_000), "3 minutes");
  assert.equal(quietFor(61 * 60_000), "over an hour");
});

test("a finished turn keeps the live card's steps, none still under way", () => {
  const events = [
    say(0, "Let me look."),
    call(1, "Read", { file_path: "a.go" }), result(2, "c1"),
    say(3, "Surprise: the build passes without agy."),
    call(4, "Bash", { command: "go test ./..." }), result(5, "c4"),
  ];
  const done = finishedTurn(events, "done", "2026-11-09T10:00:00Z", undefined, at(9));
  assert.deepEqual(done.steps.map((s) => s.state), ["done", "done"]);
  assert.equal(done.steps[1].tag, "surprise");
  assert.equal(done.duration, 9000);
  // A failed turn failed at its last step; a stopped one ran until its last event.
  assert.deepEqual(finishedTurn(events, "failed", "2026-11-09T10:00:00Z").steps.map((s) => s.state), ["done", "failed"]);
  assert.equal(finishedTurn(events, "stopped", "2026-11-09T10:00:00Z").duration, 5000);
  // The window bounds the turn: a later turn's calls stay out.
  assert.equal(finishedTurn(events, "done", "2026-11-09T10:00:00Z", "2026-11-09T10:00:02Z").steps.length, 1);
});

test("a turn with only bookkeeping and reply blocks gets no strip", () => {
  const events = [call(1, "set_chat_title"), result(2, "c1"), ev(3, "lifecycle", { state: "reply_block", kind: "choices" })];
  assert.deepEqual(finishedTurn(events, "done").steps, []);
  assert.deepEqual(finishedTurn(undefined, "done").steps, []);
});

test("turns that ended without a reply keep a strip under their failure or unanswered message", () => {
  const t = (s) => `2026-11-09T10:00:${String(s).padStart(2, "0")}Z`;
  const list = [
    { id: "u1", role: "user", created_at: t(0), run_id: "r" },
    { id: "a1", role: "assistant", created_at: t(1), run_id: "r", turn_seq: 1 },
    { id: "u2", role: "user", created_at: t(2), run_id: "r" },
    { id: "f2", role: "system", created_at: t(3), run_id: "r", turn_seq: 2 },
    { id: "n", role: "system", created_at: t(4) },
    { id: "u3", role: "user", created_at: t(5), run_id: "r" },
    { id: "u4", role: "user", created_at: t(6), run_id: "r" },
  ];
  const ended = endedTurns(list, false);
  assert.deepEqual([...ended.keys()], ["f2", "u3", "u4"]);
  assert.deepEqual(ended.get("f2"), { outcome: "failed", since: t(2), until: t(3), end: Date.parse(t(3)) });
  // Interrupted by the next message, or stopped with nothing after it.
  assert.deepEqual(ended.get("u3"), { outcome: "stopped", since: t(5), until: t(6) });
  assert.deepEqual(ended.get("u4"), { outcome: "stopped", since: t(6) });
  // While a turn runs, the newest message is that turn: the live card shows it.
  assert.equal(endedTurns(list, true).has("u4"), false);
  // A system note without a turn (a switch, a persona joining) isn't a failure.
  assert.equal(endedTurns([list[0], list[4]], false).get("u1")?.outcome, "stopped");
});
