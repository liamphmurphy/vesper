import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

// Real-stack Needs you tray (LAZYAGENTS-162): no page.route mocks. An agent's
// run (an unmanaged session on the real /mcp endpoint, beside the fake runner)
// asks for approval and asks a question; the person answers each from the
// sidebar tray, and the waiting run resumes with the decision or the reply.

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
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "needs-you-e2e", version: "1" } } } });
  expect(init.ok()).toBeTruthy();
  await parse(init);
  const session = { ...headers, "mcp-session-id": init.headers()["mcp-session-id"] };
  await request.post(`${API}/mcp`, { headers: session, data: { jsonrpc: "2.0", method: "notifications/initialized" } });
  return async (name: string, args: Record<string, unknown>) => {
    const result = await parse(await request.post(`${API}/mcp`, { headers: session,
      data: { jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } } }));
    expect(result.isError, `${name}: ${JSON.stringify(result.content)}`).toBeFalsy();
    return result.structuredContent as Record<string, unknown>;
  };
}

const pill = (page: Page) => page.getByRole("button", { name: /^Needs you,/ });
const tray = (page: Page) => page.getByRole("dialog", { name: "Needs you" });
const waiting = async (page: Page) => Number((await pill(page).getAttribute("aria-label"))?.match(/(\d+) waiting/)?.[1] ?? 0);

test("approve, deny and answer a waiting run from the Needs you tray", async ({ page, request }) => {
  const api = async (method: string, path: string, data?: unknown) => {
    const res = await request.fetch(`${API}/api/v1${path}`, { method, data });
    expect(res.ok(), `${method} ${path}: ${res.status()} ${await res.text()}`).toBeTruthy();
    return res.status() === 204 ? undefined : res.json();
  };
  const runState = async (id: string) => (await api("GET", `/runs/${id}`)).run.state as string;

  // --- An agent whose deploy:staging needs a person, on its own ticket ----
  const created = await api("POST", "/agents", { handle: "tray-agent", name: "Tray agent", kind: "main" });
  await api("PUT", "/agents/tray-agent/definition", { name: "Tray agent", role: "", specialty: "", color_index: 2,
    spec: { ...created.spec, scopes: { ...created.spec.scopes, "deploy:staging": "requires_approval" } } });
  const ticket = await api("POST", "/tickets", { project_key: "E2E", title: "Ship the tray", status: "todo", assignee_agent_id: created.agent.id });
  const { token } = await api("POST", "/agents/tray-agent/tokens", { label: "needs-you e2e" });
  const call = await mcpSession(request, token);
  const claimed = await call("claim_ticket", { ticket: ticket.key });
  const runId = String(claimed.run_id);
  expect(runId).toMatch(/[0-9a-f-]{36}/);

  // --- The page is open before the agent asks: the badge goes up live ------
  await page.goto("/chat");
  await expect(pill(page)).toBeVisible();
  const before = await waiting(page);
  const first = await call("request_approval", { ticket: ticket.key, scope: "deploy:staging", action: "Deploy build 41 to staging", risk: "Staging is down for a minute" });
  expect(first.state).toBe("pending");
  await expect(pill(page)).toHaveAccessibleName(`Needs you, ${before + 1} waiting`);
  expect(await runState(runId)).toBe("waiting");

  // --- Deny… with a reason; the run resumes and the agent gets the note -----
  await pill(page).click();
  const deny = tray(page).locator("[data-tray-row]").filter({ hasText: "Ship the tray" });
  await expect(deny).toContainText("Deploy build 41 to staging");
  await deny.getByRole("button", { name: "Deny…" }).click();
  await deny.getByRole("textbox", { name: /Reason for denying/ }).fill("Not during the demo");
  await deny.getByRole("button", { name: "Deny", exact: true }).click();
  expect(await call("wait_for_approval", { approval_id: first.approval_id, timeout_s: 5 })).toMatchObject({ state: "denied", note: "Not during the demo" });
  await expect.poll(() => runState(runId)).toBe("running");
  await expect(pill(page)).toHaveAccessibleName(before ? `Needs you, ${before} waiting` : "Needs you, nothing waiting");

  // --- A second request, approved with A from the keyboard -----------------
  const second = await call("request_approval", { ticket: ticket.key, scope: "deploy:staging", action: "Deploy build 42 to staging" });
  const approve = tray(page).locator("[data-tray-row]").filter({ hasText: "Deploy build 42 to staging" });
  await expect(approve).toBeVisible(); // arrives in the open tray over SSE
  await approve.focus();
  await page.keyboard.press("a");
  expect(await call("wait_for_approval", { approval_id: second.approval_id, timeout_s: 5 })).toMatchObject({ state: "approved" });
  await expect.poll(() => runState(runId)).toBe("running");
  await expect(approve).toHaveCount(0);

  // --- A question, answered from the inline reply ---------------------------
  await call("await_human", { ticket: ticket.key, reason: "Which region should staging use?" });
  const question = tray(page).locator("[data-tray-row]").filter({ hasText: "Which region should staging use?" });
  await expect(question).toBeVisible();
  await question.getByRole("textbox", { name: "Reply to Tray agent" }).fill("eu-west-1, please.");
  await question.getByRole("button", { name: "Send" }).click();
  await expect.poll(() => runState(runId)).toBe("running");
  const signal = await call("await_signal", { ticket: ticket.key, timeout_s: 5 });
  expect(JSON.stringify(signal)).toContain("eu-west-1, please.");
  await expect(question).toHaveCount(0);

  // The tray's Open all link reaches the Work page, with Needs you in view.
  await tray(page).getByRole("link", { name: "Open all →" }).click();
  await expect(page).toHaveURL(/\/work(\?[^#]*)?#needs-you$/);
});
