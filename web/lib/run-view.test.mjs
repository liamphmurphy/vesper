import test from "node:test";
import assert from "node:assert/strict";
import {
  advancedFilterCount, argSummary, cacheShare, condenseFeed, delegateChild, finalMessage, groupByTurn, nowLine, parseRunAnchor, pickRunView, hasActiveFilters, parseRunFilters, rowsOf, runColumns, runFilterQuery, runViewTabs,
  toolLink, toolName, turnAt, turnByEvent, turnStarts, usageByModel, workHref,
} from "./run-view.ts";

const ev = (seq, type, payload, at = `2026-11-03T12:00:${String(seq).padStart(2, "0")}Z`) => ({ seq, type, payload, at });
const marker = (seq, turn) => ev(seq, "lifecycle", { state: "turn_started", turn });

test("toolName and argSummary", () => {
  assert.equal(toolName("mcp__lazyagents__read_page"), "lazyagents.read_page");
  assert.equal(toolName("Bash"), "Bash");
  assert.equal(argSummary({ command: "ls" }), "ls");
  assert.equal(argSummary({ ref: "a" }), '(ref: "a")');
});

test("rowsOf pairs results by id", () => {
  const rows = rowsOf([ev(1, "tool_call", { id: "x", tool: "Bash" }), ev(2, "message", { text: "hi" }), ev(3, "tool_result", { id: "x", output: "ok" })]);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].kind, "tool");
  assert.equal(rows[0].result.seq, 3);
});

test("turnByEvent assigns events to turns, with setup before the first marker", () => {
  const events = [ev(1, "message", {}), marker(2, 1), ev(3, "message", {}), marker(4, 2), ev(5, "message", {})];
  const m = turnByEvent(events);
  assert.deepEqual([1, 2, 3, 4, 5].map((s) => m.get(s)), [0, 1, 1, 2, 2]);
  const groups = groupByTurn(events, (e) => m.get(e.seq));
  assert.deepEqual(groups.map((g) => [g.turn, g.items.length]), [[0, 1], [1, 2], [2, 2]]);
});

test("turnAt places child events by time", () => {
  const starts = turnStarts([marker(2, 1), marker(10, 2)]);
  assert.equal(turnAt(starts, "2026-11-03T12:00:01Z"), 0);
  assert.equal(turnAt(starts, "2026-11-03T12:00:05Z"), 1);
  assert.equal(turnAt(starts, "2026-11-03T12:00:30Z"), 2);
});

test("toolLink maps wiki and artifact reads", () => {
  assert.deepEqual(toolLink("mcp__lazyagents__read_page", { ref: "Patterns/Go errors" }), { href: "/wiki/Patterns/Go%20errors", label: "Patterns/Go errors" });
  assert.equal(toolLink("mcp__lazyagents__read_artifact", { artifact: "abc" })?.href, "/artifacts/abc");
  assert.equal(toolLink("Bash", { ref: "x" }), null);
  assert.equal(toolLink("mcp__lazyagents__read_page", {}), null);
});

test("delegateChild picks the closest child of that agent after the call", () => {
  const children = [
    { id: "early", started_at: "2026-11-03T11:00:00Z", agent: { handle: "rev" } },
    { id: "b", started_at: "2026-11-03T12:00:09Z", agent: { handle: "rev" } },
    { id: "a", started_at: "2026-11-03T12:00:05Z", agent: { handle: "rev" } },
    { id: "other", started_at: "2026-11-03T12:00:04Z", agent: { handle: "qa" } },
  ];
  const call = ev(3, "tool_call", { tool: "mcp__lazyagents__delegate", input: { agent: "rev" } });
  assert.equal(delegateChild(call, children)?.id, "a");
  assert.equal(delegateChild(ev(3, "tool_call", { tool: "Bash" }), children), undefined);
});

test("usageByModel groups this run and its children", () => {
  const r = (model, cost, source = "harness") => ({ model, cost_usd: cost, cost_source: source, input_tokens: 0, output_tokens: 0 });
  const out = usageByModel([r("opus", 1), r("sonnet", 0.5), r("sonnet", 0.25, "unknown")]);
  assert.deepEqual(out.map((m) => [m.model, m.runs, m.cost, m.unpriced]), [["opus", 1, 1, false], ["sonnet", 2, 0.75, true]]);
});

test("cacheShare", () => {
  assert.equal(cacheShare(100, 90), 0.9);
  assert.equal(cacheShare(0, 0), null);
  assert.equal(cacheShare(100, undefined), null);
});

test("filters round-trip through the URL", () => {
  assert.deepEqual(parseRunFilters(new URLSearchParams("")), { state: "live", agent: undefined, project: undefined, purpose: undefined });
  const f = parseRunFilters(new URLSearchParams("state=failed&agent=dev&project=WEB&purpose=chat"));
  assert.deepEqual(f, { state: "failed", agent: "dev", project: "WEB", purpose: "chat" });
  assert.equal(runFilterQuery(f), "state=failed&agent=dev&project=WEB&purpose=chat");
  assert.equal(runFilterQuery({ state: "live" }), "");
  assert.equal(parseRunFilters(new URLSearchParams("state=bogus&purpose=x")).state, "live");
  assert.equal(hasActiveFilters({ state: "live" }), false);
  assert.equal(hasActiveFilters({ state: "all" }), true);
  assert.equal(advancedFilterCount({ state: "failed", project: "WEB" }), 0);
  assert.equal(advancedFilterCount(parseRunFilters(new URLSearchParams("purpose=chat"))), 1);
  assert.equal(advancedFilterCount({ state: "live", agent: "dev", purpose: "ticket" }), 2);
});

test("runColumns prefers the URL, then the remembered choice", () => {
  assert.equal(runColumns(null, undefined), "default");
  assert.equal(runColumns(null, "more"), "more");
  assert.equal(runColumns("default", "more"), "default");
  assert.equal(runColumns("more", null), "more");
  assert.equal(runColumns("bogus", "bogus"), "default");
});

test("workHref never links a ticket without a key", () => {
  assert.equal(workHref({ purpose: "ticket", ticket_key: "WEB-1" }), "/tickets/WEB-1");
  assert.equal(workHref({ purpose: "ticket", ticket_key: "" }), null);
  assert.equal(workHref({ purpose: "planning", ticket_key: "", planning_id: "p1" }), "/plans?id=p1");
  assert.equal(workHref({ purpose: "chat", ticket_key: "", chat_id: "c1", project_key: "WEB" }), "/chat/c1?project=WEB");
});

test("parallel delegations consume distinct children in call order", () => {
  const calls = [ev(1, "tool_call", { tool: "mcp__lazyagents__delegate", input: { agent: "rev" } }), ev(2, "tool_call", { tool: "mcp__lazyagents__delegate", input: { agent: "rev" } })];
  const children = [3, 4].map((n) => ({ id: String(n), started_at: ev(n, "", {}).at, agent: { handle: "rev" } }));
  assert.equal(delegateChild(calls[0], children, calls)?.id, "3");
  assert.equal(delegateChild(calls[1], children, calls)?.id, "4");
  for (const state of ["starting", "blocked"]) assert.equal(parseRunFilters(new URLSearchParams({ state })).state, state);
});

test("pickRunView: deep links open Details, then ?view=, then localStorage, then Simple", () => {
  assert.equal(pickRunView(null, "", null), "simple");
  assert.equal(pickRunView(null, "", "details"), "details");
  assert.equal(pickRunView("simple", "", "details"), "simple");
  assert.equal(pickRunView("details", "", "simple"), "details");
  assert.equal(pickRunView("bogus", "", "nonsense"), "simple");
  assert.equal(pickRunView("simple", "#turn-3", "simple"), "details");
  assert.equal(pickRunView(null, "#event-42", null), "details");
  assert.equal(pickRunView(null, "#top", null), "simple");
  assert.equal(pickRunView("graph", "", null), "graph");
  assert.equal(pickRunView(null, "", "graph"), "graph");
  assert.deepEqual(parseRunAnchor("#turn-3"), { kind: "turn", n: 3 });
  assert.deepEqual(parseRunAnchor("event-7"), { kind: "event", n: 7 });
  assert.equal(parseRunAnchor("#turn-x"), null);
});

test("condenseFeed folds routine tools into a count and keeps notable events", () => {
  const call = (seq, tool, input = {}, id = `t${seq}`) => ev(seq, "tool_call", { id, tool, input });
  const result = (seq, id, extra = {}) => ev(seq, "tool_result", { id, output: "ok", ...extra });
  const events = [
    ev(1, "lifecycle", { state: "workspace_ready" }),
    marker(2, 1),
    ev(3, "message", { text: "\nClaimed it and posted a plan\nmore" }),
    call(4, "Read"), result(5, "t4"),
    call(6, "Grep"), result(7, "t6"),
    ev(8, "message", { kind: "step", step: 1, state: "done" }),
    ev(9, "message", { kind: "step", step: 2, state: "current" }),
    marker(10, 2),
    call(11, "Bash", { command: "tsc" }), result(12, "t11", { is_error: true, exit_code: 2, output: "error TS2322\nmore" }),
    call(13, "mcp__lazyagents__delegate", { agent: "@implementer", task: "Build it\nsteps" }),
    ev(14, "error", { message: "Rate limited" }),
    call(15, "mcp__lazyagents__request_approval", { scope: "db:migrate", action: "Apply 0042" }),
    marker(16, 3),
  ];
  const feed = condenseFeed(events, (n) => `Fallback ${n}`);
  assert.deepEqual(feed.map((f) => f.kind), ["turn", "step", "turn", "error", "delegation", "error", "gate", "turn"]);
  assert.deepEqual(feed[0], { kind: "turn", turn: 1, at: events[1].at, text: "Claimed it and posted a plan", tools: 2 });
  assert.equal(feed[1].step, 1);
  assert.equal(feed[2].tools, 1, "a failed routine call still counts");
  assert.equal(feed[2].text, "Fallback 2");
  assert.equal(feed[3].text, "Bash failed (exit 2): error TS2322");
  assert.equal(feed[4].agent, "implementer");
  assert.equal(feed[4].task, "Build it");
  assert.equal(feed[5].text, "Rate limited");
  assert.deepEqual([feed[6].gate, feed[6].text, feed[6].turn], ["approval", "db:migrate · Apply 0042", 2]);
  assert.deepEqual([feed[7].turn, feed[7].tools], [3, 0]);
});

test("condenseFeed keeps setup errors without a turn line", () => {
  const feed = condenseFeed([ev(1, "error", { message: "clone failed" })]);
  assert.deepEqual(feed.map((f) => [f.kind, f.turn]), [["error", 0]]);
});

test("nowLine and finalMessage", () => {
  const plan = [{ position: 1, text: "Read", state: "done" }, { position: 2, text: "Draft", state: "current" }];
  const events = [ev(1, "message", { text: "Thinking\nmore" }), ev(2, "tool_call", { tool: "Read", input: { file_path: "a.ts" } })];
  assert.equal(nowLine({ state: "running", plan }, events), "Read a.ts");
  assert.equal(nowLine({ state: "running", plan }, events.slice(0, 1)), "Thinking");
  assert.equal(nowLine({ state: "running", plan }, []), "Plan step 2 of 2: Draft");
  assert.equal(nowLine({ state: "waiting", wait_reason: "approval", plan }, events), "Waiting for a person to decide on an approval · plan step 2 of 2: Draft");
  assert.equal(nowLine({ state: "completed", plan }, events), null);
  assert.equal(nowLine({ state: "queued", plan: [] }, []), "Waiting for a runner slot");
  assert.equal(finalMessage([...events, ev(3, "message", { kind: "plan" })]), "Thinking\nmore");
  assert.equal(finalMessage([]), null);
});

test("runViewTabs hides Graph unless child runs exist or Graph mode is active", () => {
  assert.deepEqual(
    runViewTabs({ countsAll: 4, fileCount: 2, childRunCount: 0, mode: "simple" }).map((t) => t.key),
    ["simple", "details", "files"],
  );
  assert.deepEqual(
    runViewTabs({ countsAll: 4, fileCount: 0, childRunCount: 1, mode: "simple" }).map((t) => t.key),
    ["simple", "details", "graph", "files"],
  );
  assert.deepEqual(
    runViewTabs({ countsAll: 4, fileCount: 0, childRunCount: 0, mode: "graph" }).map((t) => t.key),
    ["simple", "details", "graph", "files"],
  );
});
