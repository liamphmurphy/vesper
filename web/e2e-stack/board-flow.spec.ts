import { expect, test, type APIRequestContext } from "@playwright/test";

// Real-stack Kanban flow (LAZYAGENTS-36): no page.route mocks. The agent talks
// to the real /mcp endpoint with an unmanaged-session token; the board updates
// over the real SSE stream; the person edits through the real modal and REST.
// run.sh inserts the "Board e2e epic" row (there is no REST endpoint that
// creates an epic); everything else is created here through the API.

const API = process.env.E2E_STACK_API_URL;
if (!API) throw new Error("E2E_STACK_API_URL is not set; run `npm run e2e:stack`");

/** Minimal streamable-HTTP MCP client: initialize once, then tools/call. */
async function mcpSession(request: APIRequestContext, token: string) {
  const headers = { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" };
  let id = 0;
  const parse = async (res: Awaited<ReturnType<APIRequestContext["post"]>>) => {
    const body = await res.text();
    const data = body.split("\n").filter((l) => l.startsWith("data: ")).map((l) => JSON.parse(l.slice(6)));
    const msg = data.length ? data[data.length - 1] : JSON.parse(body);
    if (msg.error) throw new Error(`MCP error: ${JSON.stringify(msg.error)}`);
    return msg.result;
  };
  const init = await request.post(`${API}/mcp`, { headers, data: { jsonrpc: "2.0", id: ++id, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "board-flow-e2e", version: "1" } } } });
  expect(init.ok()).toBeTruthy();
  await parse(init);
  const session = { ...headers, "mcp-session-id": init.headers()["mcp-session-id"] };
  expect(session["mcp-session-id"]).toBeTruthy();
  await request.post(`${API}/mcp`, { headers: session, data: { jsonrpc: "2.0", method: "notifications/initialized" } });
  return async (name: string, args: Record<string, unknown>) => {
    const result = await parse(await request.post(`${API}/mcp`, { headers: session,
      data: { jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } } }));
    expect(result.isError, `${name}: ${JSON.stringify(result.content)}`).toBeFalsy();
    return result.structuredContent as Record<string, unknown>;
  };
}

test("Kanban: agent estimates via MCP, board shows it live, person edits to done, epic gate opens", async ({ page, request }) => {
  const api = async (method: string, path: string, data?: unknown) => {
    const res = await request.fetch(`${API}/api/v1${path}`, { method, data });
    expect(res.ok(), `${method} ${path}: ${res.status()} ${await res.text()}`).toBeTruthy();
    return res.json();
  };

  // --- Setup through the real API ------------------------------------------
  const bootstrap = await api("GET", "/bootstrap");
  const epic = bootstrap.epics.find((e: { name: string }) => e.name === "Board e2e epic");
  expect(epic, "run.sh should have created the Board e2e epic").toBeTruthy();
  const created = await api("POST", "/agents", { handle: "board-lead", name: "Board lead", kind: "main" });
  // check_epic_criterion needs tracker:epics allowed in the agent's definition.
  await api("PUT", "/agents/board-lead/definition", { name: "Board lead", role: "", specialty: "", color_index: 0,
    spec: { ...created.spec, scopes: { ...created.spec.scopes, "tracker:epics": "allowed" } } });
  const own = await api("POST", "/tickets", { project_key: "E2E", title: "Lead's own ticket", status: "todo", assignee_agent_id: created.agent.id });
  const target = await api("POST", "/tickets", { project_key: "E2E", title: "Board flow ticket", status: "todo", epic_id: epic.id, criteria: ["Shows on the board"] });
  await api("POST", `/epics/${epic.id}/criteria`, { text: "Agent estimates show on the board" });
  await api("POST", `/epics/${epic.id}/criteria`, { text: "A person confirms the flow" });
  const { token } = await api("POST", "/agents/board-lead/tokens", { label: "board-flow e2e" });

  // --- The board, before the agent acts -----------------------------------
  await page.goto(`/board?project=E2E&epic=${epic.id}`);
  const card = page.getByRole("article", { name: `Ticket ${target.key}` });
  await expect(page.getByTestId("column-todo").getByRole("article", { name: `Ticket ${target.key}` })).toBeVisible();
  // An unestimated card shows no points (it no longer says "unestimated").
  await expect(card).not.toContainText(/\d+ pt/);

  // --- Agent: claim its own ticket, estimate a sibling, tick epic criterion 1
  const call = await mcpSession(request, token);
  await call("claim_ticket", { ticket: own.key });
  expect(await call("estimate_ticket", { ticket: target.key, points: 5, rationale: "One board flow, no schema change" }))
    .toMatchObject({ ticket: target.key, estimate_points: 5 });
  const seen = await call("get_ticket", { ticket: target.key });
  expect(seen).toMatchObject({ estimate_points: 5, epic: { name: "Board e2e epic", points_total: 5 } });
  await call("check_epic_criterion", { ticket: own.key, epic: "Board e2e epic", n: 1 });

  // The open board picks both changes up over SSE, without a reload.
  await expect(card).toContainText("5 pt");
  await expect(page.getByLabel("Criterion 1 met")).toBeChecked();
  await expect(page.getByLabel("Criterion 2 met")).not.toBeChecked();
  await expect(page.getByRole("region", { name: "Done blockers" })).toContainText(target.key);
  await expect(page.getByRole("button", { name: "Mark epic done" })).toBeDisabled();

  // --- Person: open the card, edit in the modal, move it to done -----------
  await card.getByRole("link", { name: "Board flow ticket" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: `Edit ${target.key}` })).toBeVisible();
  await expect(dialog.getByLabel("Point estimate")).toHaveValue("5");
  await expect(dialog.getByText("Set by @board-lead")).toBeVisible();
  await dialog.getByLabel("Title").fill("Board flow ticket (verified)");
  await dialog.getByLabel("Status").selectOption("done");
  await dialog.getByLabel("Criterion 1 done").check();
  await dialog.getByRole("button", { name: "Save changes" }).click();
  await expect(dialog).toBeHidden();

  const doneCard = page.getByTestId("column-done").getByRole("article", { name: `Ticket ${target.key}` });
  await expect(doneCard).toContainText("Board flow ticket (verified)");
  await expect(doneCard).toContainText("5 pt");
  await expect(doneCard.getByLabel("1 of 1 criteria met")).toBeVisible();
  await expect(page.getByRole("progressbar", { name: "Points" })).toHaveAttribute("aria-valuetext", "5 / 5 pts done");

  // --- Epic gate: closed while criterion 2 is unchecked, opens once it is ---
  const markDone = page.getByRole("button", { name: "Mark epic done" });
  await expect(markDone).toBeDisabled();
  await expect(page.getByRole("list", { name: "Unchecked criteria" })).toContainText("2. A person confirms the flow");
  const refused = await request.patch(`${API}/api/v1/epics/${epic.id}`, { data: { status: "done" } });
  expect(refused.status()).toBe(409);

  // Finishing the epic's last ticket made its final review ticket, which holds the gate shut
  // until it finishes too. The POST is idempotent: it returns that ticket, not a new one.
  await expect(page.getByTestId("column-todo").getByRole("article").filter({ hasText: "Final review" })).toBeVisible();
  const finalReview = await api("POST", `/epics/${epic.id}/review`);
  expect(finalReview).toMatchObject({ epic_review: true, status: "todo" });
  await expect(page.getByRole("list", { name: "Open tickets" })).toContainText(finalReview.key);
  await api("PATCH", `/tickets/${finalReview.key}`, { status: "done" });
  await expect(page.getByRole("list", { name: "Open tickets" })).toHaveCount(0);

  await page.getByLabel("Criterion 2 met").check();
  await expect(page.getByText("Ready to mark done")).toBeVisible();
  await expect(markDone).toBeEnabled();
  await markDone.click();
  await expect(page.getByRole("button", { name: "Reopen epic" })).toBeVisible();
  await expect(page.getByText("Reopen the epic to edit its criteria.")).toBeVisible();

  // The server agrees: epic done, ticket done with the person's edits and the agent's estimate.
  const after = await api("GET", "/bootstrap");
  expect(after.epics.find((e: { id: string }) => e.id === epic.id)).toMatchObject({ status: "done" });
  const final = await api("GET", `/tickets/${target.key}`);
  expect(final).toMatchObject({ status: "done", title: "Board flow ticket (verified)", estimate_points: 5 });
});
