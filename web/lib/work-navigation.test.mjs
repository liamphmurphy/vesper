import test from "node:test";
import assert from "node:assert/strict";
import { workHref, workTarget, workView } from "./work-navigation.ts";

test("workTarget only translates /runs/:id onto /work; tickets and epics open canonically", () => {
  const p = new URLSearchParams("run=r1&project=WEB&agent=builder&q=nav&context=ticket");
  assert.equal(workTarget("/tickets/WEB-1", p), null);
  assert.equal(workTarget("/epics/e1", p), null);
  assert.equal(workTarget("/tickets/new", p), null);
  assert.equal(workTarget("/knowledge/p1", p), null);
  assert.equal(
    workTarget("/runs/r2", p),
    "/work?run=r2&project=WEB&agent=builder&q=nav",
  );
});

test("workHref updates Work query params and workView defaults unknown views to activity", () => {
  const p = new URLSearchParams("run=r1&project=WEB&status=todo");
  assert.equal(
    workHref(p, { run: null, filter: "needs_you" }),
    "/work?project=WEB&status=todo&filter=needs_you",
  );
  assert.equal(workView(new URLSearchParams("view=tickets")), "tickets");
  assert.equal(workView(new URLSearchParams("view=epics")), "epics");
  assert.equal(workView(new URLSearchParams("view=unknown")), "activity");
});
