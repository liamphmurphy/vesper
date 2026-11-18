import test from "node:test";
import assert from "node:assert/strict";
import { ApprovalNotConfirmedError, canOpenWorkspaceFolder, confirmApprovalLocally, openWorkspaceFolder } from "./desktop-bridge.ts";

const native = (reply) => {
  const asked = [];
  return { asked, active: () => true, request: async (m) => (asked.push(m), reply()) };
};
const browser = { active: () => false, request: async () => assert.fail("no shell to ask") };

test("in a browser approvals go straight through", async () => {
  await confirmApprovalLocally("run_approvals", browser);
});

test("in the native shell approvals go through the shell and fail closed", async () => {
  const shell = native(() => ({ ok: true }));
  await confirmApprovalLocally("run_approvals", shell);
  assert.deepEqual(shell.asked, [{ type: "confirmApproval", scope: "run_approvals" }]);
  await assert.rejects(confirmApprovalLocally("push_requests", native(() => ({ ok: false }))), ApprovalNotConfirmedError);
  await assert.rejects(confirmApprovalLocally("push_requests", native(() => { throw new Error("timeout"); })), ApprovalNotConfirmedError);
});

test("in a browser workspace folders can't be opened", async () => {
  assert.equal(canOpenWorkspaceFolder(browser), false);
  assert.equal(await openWorkspaceFolder("/w", browser), "Opening folders needs the Vesper desktop app.");
});

test("in the native shell workspace folders open through its menu", async () => {
  const shell = native(() => ({ ok: true }));
  assert.equal(canOpenWorkspaceFolder(shell), true);
  assert.equal(await openWorkspaceFolder("/w/run-1", shell), null);
  assert.deepEqual(shell.asked, [{ type: "openWorkspaceMenu", folder: "/w/run-1" }]);
  assert.equal(await openWorkspaceFolder("/etc", native(() => ({ ok: false, error: "Not allowed." }))), "Not allowed.");
  assert.equal(await openWorkspaceFolder("/w", native(() => { throw new Error("x"); })), "Couldn't open the folder.");
});
