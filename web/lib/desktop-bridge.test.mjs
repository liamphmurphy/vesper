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

test("workspace folders open through the desktop menu, with errors passed back", async () => {
  const { canOpenWorkspaceFolder, openWorkspaceFolder } = await import("./desktop-bridge.ts");
  assert.equal(canOpenWorkspaceFolder(() => undefined), false);
  const opened = [];
  const ok = () => ({ openWorkspaceMenu: async (p) => (opened.push(p), { ok: true }) });
  assert.equal(canOpenWorkspaceFolder(ok), true);
  assert.equal(await openWorkspaceFolder("/w/run-1", ok), null);
  assert.deepEqual(opened, ["/w/run-1"]);
  const refused = () => ({ openWorkspaceMenu: async () => ({ ok: false, error: "Only run and chat workspace folders can be opened." }) });
  assert.equal(await openWorkspaceFolder("/etc", refused), "Only run and chat workspace folders can be opened.");
  const broken = () => ({ openWorkspaceMenu: async () => { throw new Error("x"); } });
  assert.equal(await openWorkspaceFolder("/w", broken), "Couldn't open the folder.");
  assert.equal(await openWorkspaceFolder("/w", () => undefined), "Opening folders needs the Vesper desktop app.");
});
