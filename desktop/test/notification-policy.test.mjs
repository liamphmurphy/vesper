import assert from "node:assert/strict";
import test from "node:test";
import {
  alertActionFor,
  alertGroupId,
  collectNewNotifications,
  decisionRequest,
  isWithinQuietHours,
  replyRequest,
  shouldShowAlert,
  touchIdScopeForKind,
} from "../dist/notifications.js";
import { defaultNativeSettings } from "../dist/settings.js";

const APPROVAL = "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const RUN = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b";

function alert(over = {}) {
  return { title: "t", body: "b", href: "/inbox", signature: "s", kind: "approval", itemId: `approval:${APPROVAL}`, ...over };
}

function at(hh, mm) {
  const d = new Date(2026, 10, 17, hh, mm, 0);
  return d;
}

test("collectNewNotifications carries kind, ids, ticket and agent handle onto alerts", () => {
  const seen = new Set();
  collectNewNotifications(seen, [], false);
  const { alerts } = collectNewNotifications(
    seen,
    [
      {
        id: `question:${RUN}`,
        kind: "question",
        title: "Which DB?",
        href: `/runs/${RUN}`,
        created_at: "2026-11-17T00:00:00Z",
        resolved: false,
        read: false,
        needs_you: true,
        run_id: RUN,
        ticket_key: "PAY-9",
        agent: { name: "Pike", handle: "pike" },
      },
    ],
    true,
  );
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].kind, "question");
  assert.equal(alerts[0].itemId, `question:${RUN}`);
  assert.equal(alerts[0].runId, RUN);
  assert.equal(alerts[0].ticketKey, "PAY-9");
  assert.equal(alerts[0].agentHandle, "pike");
});

test("isWithinQuietHours handles same-day and overnight windows", () => {
  const overnight = { enabled: true, start: "22:00", end: "08:00" };
  assert.equal(isWithinQuietHours(at(23, 30), overnight), true);
  assert.equal(isWithinQuietHours(at(3, 0), overnight), true);
  assert.equal(isWithinQuietHours(at(8, 0), overnight), false, "end is exclusive");
  assert.equal(isWithinQuietHours(at(12, 0), overnight), false);
  const lunch = { enabled: true, start: "12:00", end: "13:00" };
  assert.equal(isWithinQuietHours(at(12, 30), lunch), true);
  assert.equal(isWithinQuietHours(at(13, 0), lunch), false);
  assert.equal(isWithinQuietHours(at(23, 30), { ...overnight, enabled: false }), false);
  assert.equal(isWithinQuietHours(at(10, 0), { enabled: true, start: "10:00", end: "10:00" }), false, "empty window");
});

test("shouldShowAlert honours the master switch, per-kind switches, quiet hours and run-finished", () => {
  const policy = defaultNativeSettings().notifications;
  assert.equal(shouldShowAlert(alert(), policy, at(12, 0)), true);
  assert.equal(shouldShowAlert(alert(), { ...policy, enabled: false }, at(12, 0)), false);
  assert.equal(shouldShowAlert(alert(), { ...policy, kinds: { ...policy.kinds, approval: false } }, at(12, 0)), false);
  assert.equal(shouldShowAlert(alert({ kind: "merged" }), { ...policy, kinds: { ...policy.kinds, approval: false } }, at(12, 0)), true);
  assert.equal(
    shouldShowAlert(alert(), { ...policy, quietHours: { enabled: true, start: "11:00", end: "13:00" } }, at(12, 0)),
    false,
  );
  assert.equal(shouldShowAlert(alert({ kind: "run_finished" }), { ...policy, runFinished: false }, at(12, 0)), false);
  assert.equal(shouldShowAlert(alert({ kind: "run_finished" }), policy, at(12, 0)), true);
});

test("alertGroupId groups by ticket, then run, and only when grouping is on", () => {
  assert.equal(alertGroupId(alert({ ticketKey: "PAY-1", runId: RUN }), { groupByWork: true }), "ticket:PAY-1");
  assert.equal(alertGroupId(alert({ runId: RUN }), { groupByWork: true }), `run:${RUN}`);
  assert.equal(alertGroupId(alert(), { groupByWork: true }), null);
  assert.equal(alertGroupId(alert({ ticketKey: "PAY-1" }), { groupByWork: false }), null);
});

test("decisionRequest maps each approval kind to its existing endpoint and refuses mismatches", () => {
  assert.deepEqual(decisionRequest(alert(), "approve"), { method: "POST", path: `/api/v1/approvals/${APPROVAL}/approve`, body: {} });
  assert.deepEqual(decisionRequest(alert(), "deny"), { method: "POST", path: `/api/v1/approvals/${APPROVAL}/deny`, body: {} });
  assert.deepEqual(decisionRequest(alert({ kind: "connector_approval", itemId: `connector_approval:${APPROVAL}` }), "approve"), {
    method: "POST",
    path: `/api/v1/connector-approvals/${APPROVAL}`,
    body: { decision: "allow" },
  });
  assert.deepEqual(decisionRequest(alert({ kind: "secret_approval", itemId: `secret_approval:${APPROVAL}` }), "deny"), {
    method: "POST",
    path: `/api/v1/api-secret-approvals/${APPROVAL}`,
    body: { decision: "deny" },
  });
  for (const bad of [
    alert({ itemId: "approval:not-a-uuid" }),
    alert({ itemId: `approval:${APPROVAL}:extra` }),
    alert({ itemId: `approval:${APPROVAL}/../../runs` }),
    alert({ kind: "question", itemId: `approval:${APPROVAL}` }),
    alert({ kind: "workflow_gate", itemId: `workflow_gate:${APPROVAL}` }),
    alert({ itemId: "" }),
  ]) {
    assert.equal(decisionRequest(bad, "approve"), null, JSON.stringify(bad));
  }
});

test("replyRequest posts a ticket comment that mentions the agent once", () => {
  const q = alert({ kind: "question", itemId: `question:${RUN}`, ticketKey: "PAY-9", agentHandle: "pike" });
  assert.deepEqual(replyRequest(q, "  use Postgres  "), {
    method: "POST",
    path: "/api/v1/tickets/PAY-9/comments",
    body: { body_md: "@pike use Postgres" },
  });
  assert.equal(replyRequest(q, "@pike use Postgres").body.body_md, "@pike use Postgres", "no double mention");
  assert.equal(replyRequest(q, "   "), null);
  assert.equal(replyRequest({ ...q, ticketKey: "../x" }, "hi"), null);
  assert.equal(replyRequest({ ...q, agentHandle: "pi ke" }, "hi"), null);
  assert.equal(replyRequest({ ...q, kind: "approval" }, "hi"), null);
});

test("alertActionFor offers buttons for approvals, reply for questions, nothing otherwise or when off", () => {
  assert.deepEqual(alertActionFor(alert(), { actions: true }), { type: "decide", labels: ["Approve", "Decline"] });
  assert.equal(alertActionFor(alert({ kind: "question", itemId: `question:${RUN}`, ticketKey: "PAY-9", agentHandle: "pike" }), { actions: true }).type, "reply");
  assert.equal(alertActionFor(alert({ kind: "question", itemId: `question:${RUN}` }), { actions: true }).type, "none", "no ticket to comment on");
  assert.equal(alertActionFor(alert({ kind: "merged", itemId: "merged:x" }), { actions: true }).type, "none");
  assert.equal(alertActionFor(alert(), { actions: false }).type, "none");
});

test("touchIdScopeForKind maps approval kinds to Touch ID scopes", () => {
  assert.equal(touchIdScopeForKind("approval"), "run_approvals");
  assert.equal(touchIdScopeForKind("connector_approval"), "connector_approvals");
  assert.equal(touchIdScopeForKind("secret_approval"), "secret_approvals");
  assert.equal(touchIdScopeForKind("question"), null);
});
