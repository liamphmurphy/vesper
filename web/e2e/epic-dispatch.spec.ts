import { expect, test } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

for (const mixed of [false, true]) {
  test(`epic assigns and starts the ready tickets in one click (${mixed ? "mixed assignments" : "all unassigned"})`, async ({ page }) => {
    await installChatApi(page);
    const agent = { id: "agent-1", name: "Builder", handle: "builder", kind: "main", color_index: 0, role: "Developer", specialty: "", model: "test", status: "idle" };
    const other = { ...agent, id: "agent-2", name: "Reviewer", handle: "reviewer" };
    const project = { id: "project-1", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
    const epic = { id: "epic-1", name: "Ship it", project_id: project.id, health: "on_track" };
    const tickets = [
      { id: "1", key: "WEB-1", title: "First", status: "todo", priority: "medium" },
      { id: "2", key: "WEB-2", title: "Dependent", status: "todo", priority: "medium", ...(mixed ? { assignee: other } : {}) },
      { id: "3", key: "WEB-3", title: "Finished", status: "done", priority: "medium" },
      { id: "4", key: "WEB-4", title: "Already queued", status: "todo", priority: "medium", run: { state: "queued" } },
      { id: "5", key: "WEB-5", title: "Waits on WEB-1", status: "todo", priority: "medium", unmet_dependencies: 1 },
    ];
    const calls: Array<{ path: string; body: unknown }> = [];
    await page.route("**/api/v1/bootstrap", (route) => route.fulfill({ json: {
      workspace: { id: "workspace-1", name: "Acme", slug: "acme" },
      me: { id: "user-1", name: "Liam", initials: "L" }, users: [], agents: [agent, other, { ...agent, id: "pa", name: "Personal Assistant", kind: "assistant" }],
      projects: [project], epics: [epic], labels: [], counts: { inbox: 0, wiki_suggestions: 0, live_agents: 0 },
    } }));
    await page.route("**/api/v1/epics", (route) => route.fulfill({ json: { epics: [{
      epic, project, objective: "Deliver", counts: { total: 5, done: 1, todo: 4, backlog: 0, in_progress: 0, in_review: 0 },
      agents: [], agent_seconds: 0, tickets: tickets.slice(0, 1),
    }] } }));
    await page.route("**/api/v1/projects/WEB/board**", (route) => route.fulfill({ json: {
      project, columns: [], epic: { epic: { ...epic, requires_mockup: false, status: "open", criteria_total: 0, criteria_done: 0, points_total: 0, points_done: 0, tickets_total: 5, tickets_open: 4 },
        criteria: [], done_blockers: { open_tickets: [], unchecked_criteria: [] } },
    } }));
    await page.route("**/api/v1/tickets**", async (route) => {
      const url = new URL(route.request().url());
      if (route.request().method() === "POST") {
        const body = route.request().postDataJSON();
        calls.push({ path: url.pathname, body });
        if (url.pathname.endsWith("/bulk")) {
          expect(body.keys).toEqual(mixed ? ["WEB-1"] : ["WEB-1", "WEB-2"]);
          for (const t of tickets) if (body.keys.includes(t.key)) Object.assign(t, { assignee: agent });
          return route.fulfill({ json: { updated: body.keys.length } });
        }
        expect(url.pathname).toBe("/api/v1/tickets/dispatch");
        expect(body.keys).toEqual(["WEB-1", "WEB-2"]);
        return route.fulfill({ json: { dispatched: 2 } });
      }
      if (url.pathname === "/api/v1/tickets") {
        expect(url.searchParams.get("epic")).toBe(epic.id);
        expect(url.searchParams.get("view")).toBe("all");
        return route.fulfill({ json: { tickets } });
      }
      const ticket = tickets.find((t) => t.key === url.pathname.split("/").at(-1));
      if (ticket) return route.fulfill({ json: { ...ticket, project } });
      return route.fallback();
    });
    await page.goto("/epics/epic-1");
    const select = page.getByRole("combobox", { name: "Persona for unassigned tickets" });
    await expect(select).toHaveValue(agent.id);
    await expect(select.getByRole("option", { name: "Personal Assistant" })).toHaveCount(0);
    // Start ready leaves the blocked ticket alone and says why.
    await expect(page.getByRole("region", { name: "Start ready" })).toContainText("WEB-5");
    await expect(page.getByRole("region", { name: "Start ready" })).toContainText("blocked by 1");
    await page.getByRole("button", { name: "Assign & start ready (2)", exact: true }).click();
    await expect(page.getByRole("status")).toContainText("2 epic tickets queued");
    expect(calls).toEqual([
      { path: "/api/v1/tickets/bulk", body: { keys: mixed ? ["WEB-1"] : ["WEB-1", "WEB-2"], patch: { assignee_agent_id: agent.id } } },
      { path: "/api/v1/tickets/dispatch", body: { keys: ["WEB-1", "WEB-2"] } },
    ]);
  });
}
