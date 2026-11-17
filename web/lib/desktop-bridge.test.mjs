import test from "node:test";
import assert from "node:assert/strict";
import { ApprovalNotConfirmedError, confirmApprovalLocally } from "./desktop-bridge.ts";

test("in a browser (no bridge) approvals go straight through", async () => {
  await confirmApprovalLocally("run_approvals", () => undefined);
  await confirmApprovalLocally("run_approvals", () => ({}));
});

test("in the desktop app the approval waits for Touch ID and stops when it isn't confirmed", async () => {
  const asked = [];
  const ok = () => ({ confirmApproval: async (scope) => (asked.push(scope), { ok: true, prompted: true }) });
  await confirmApprovalLocally("push_requests", ok);
  assert.deepEqual(asked, ["push_requests"]);

  const cancelled = () => ({ confirmApproval: async () => ({ ok: false, prompted: true }) });
  await assert.rejects(confirmApprovalLocally("run_approvals", cancelled), ApprovalNotConfirmedError);
});

test("a bridge that refuses the call behaves like a browser", async () => {
  const refusing = () => ({
    confirmApproval: async () => {
      throw new Error("Untrusted IPC caller");
    },
  });
  await confirmApprovalLocally("secret_approvals", refusing);
});
